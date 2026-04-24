# Workshop 2 — Data Consistency

**Based on Instruqt track: k10tt-dc (Lab 2 — Veeam Kasten Training — Data Consistency)**

---

## Goals

By the end of this workshop you will understand the four backup types Kasten supports and be able to implement each one:

| Type | How it works | Best for |
|------|-------------|----------|
| **Crash Consistent** | CSI volume snapshot only | Stateless apps, low-stakes data |
| **Logical** | `mongodump`/`pgdump` via Kanister Blueprint | Any database when you own the backup path |
| **Application Consistent** | CSI snapshot + pre/post hooks that quiesce the app | Databases that must lock during snapshot |
| **Generic Volume Backup** | Kanister sidecar copies data byte-for-byte | Storage that doesn't support CSI snapshots |

You will also learn:
- How to automatically bind a Kanister Blueprint to an application using `BlueprintBindings`
- The difference between `BackupAction` (local snapshot) and `ExportAction` (portable export)

---

## Prerequisites

- Workshop 0 (cluster with CSI + VolumeSnapshot) and Workshop 1 (Kasten + MinIO + MongoDB) completed
- MongoDB must be running in the `mongodb` namespace with the `log` collection populated

Confirm:
```bash
kubectl get pods -n mongodb
kubectl get pods -n kasten-io
kubectl get profile s3-local -n kasten-io
```

---

## Part 1 — Crash Consistent (CSI) Backup

A crash consistent backup captures a point-in-time snapshot of the volume without any application coordination. Like pulling the power plug — you get exactly what was on disk.

> **Warning:** MongoDB's documentation explicitly states that a plain volume snapshot without first locking the database is **not** a dependable backup for MongoDB. This exercise demonstrates the mechanics, not a production best practice.

### Exercise

1. In the Kasten dashboard navigate to **Applications → mongodb**.
2. Click **Snapshot** (manual snapshot, no policy needed).
3. In a separate terminal, watch VolumeSnapshot objects appear:
   ```bash
   kubectl get volumesnapshot -n mongodb -w
   ```
4. After the backup completes, inspect the created snapshot:
   ```bash
   kubectl get volumesnapshot -n mongodb
   kubectl describe volumesnapshot -n mongodb <snapshot-name>
   ```

Observe that the snapshot references the underlying CSI driver snapshot handle — Kasten stores only the *reference* in its catalog, not the snapshot data itself.

**Takeaway:** Crash consistent backups are fast but may leave databases in an inconsistent state. They are not recommended for transactional data services.

---

## Part 2 — Logical Backup with a Kanister Blueprint

A logical backup uses application-native tools (`mongodump`, `pg_dump`, etc.) to export data at the application layer, independent of the underlying storage. Kanister provides a YAML-based framework for expressing these custom operations as **Blueprints**.

### 2a. Create the MongoDB logical dump Blueprint

```bash
cat <<EOF | kubectl apply -f -
apiVersion: cr.kanister.io/v1alpha1
kind: Blueprint
metadata:
  name: mongo-dump
  namespace: kasten-io
actions:
  backup:
    outputArtifacts:
      mongoBackup:
        keyValue:
          path: '{{ .Profile.Location.Bucket }}/mongo-backups/{{ .StatefulSet.Namespace }}/{{ toDate "2006-01-02T15:04:05.999999999Z07:00" .Time | date "2006-01-02T15-04-05" }}/dump.tar.gz'
    phases:
    - func: KubeTask
      name: takeDump
      args:
        image: ghcr.io/kanisterio/mongodb:0.105.0
        command:
        - bash
        - -o
        - errexit
        - -o
        - pipefail
        - -c
        - |
          export MONGODB_ROOT_PASSWORD='{{ index .Phases.takeDump.Secrets.mongoSecret.Data "mongodb-root-password" | toString }}'
          mongodump \
            --authenticationDatabase admin \
            -u root \
            -p "\$MONGODB_ROOT_PASSWORD" \
            --host "mongo-mongodb-0.mongo-mongodb-headless.{{ .StatefulSet.Namespace }}:27017" \
            --gzip \
            --archive=/tmp/dump.tar.gz
          kando location push --profile '{{ toJson .Profile }}' --path '{{ .ArtifactsIn.mongoBackup.KeyValue.path }}' /tmp/dump.tar.gz
      objects:
        mongoSecret:
          kind: Secret
          name: mongo-mongodb
          namespace: "{{ .StatefulSet.Namespace }}"
  restore:
    inputArtifactNames:
    - mongoBackup
    phases:
    - func: KubeTask
      name: restoreDump
      args:
        image: ghcr.io/kanisterio/mongodb:0.105.0
        command:
        - bash
        - -o
        - errexit
        - -o
        - pipefail
        - -c
        - |
          export MONGODB_ROOT_PASSWORD='{{ index .Phases.restoreDump.Secrets.mongoSecret.Data "mongodb-root-password" | toString }}'
          kando location pull --profile '{{ toJson .Profile }}' --path '{{ .ArtifactsIn.mongoBackup.KeyValue.path }}' /tmp/dump.tar.gz
          mongorestore \
            --authenticationDatabase admin \
            -u root \
            -p "\$MONGODB_ROOT_PASSWORD" \
            --host "mongo-mongodb-0.mongo-mongodb-headless.{{ .StatefulSet.Namespace }}:27017" \
            --gzip \
            --archive=/tmp/dump.tar.gz \
            --drop
      objects:
        mongoSecret:
          kind: Secret
          name: mongo-mongodb
          namespace: "{{ .StatefulSet.Namespace }}"
EOF
```

### 2b. Annotate the StatefulSet to use the Blueprint

```bash
kubectl annotate statefulset mongo-mongodb \
  kanister.kasten.io/blueprint='mongo-dump' \
  -n mongodb
```

Verify:
```bash
kubectl get statefulset mongo-mongodb -n mongodb \
  -o jsonpath='{.metadata.annotations.kanister\.kasten\.io/blueprint}'
```

### 2c. Run a backup and observe the difference

1. In the Kasten dashboard, navigate to **Policies → Policies → mongodb-backup → Run Once**.
2. Under **Actions**, open the running policy run and observe the **Logical** phase in addition to the usual snapshot.
3. In MinIO, confirm a `mongodump` artifact appears in the bucket alongside the snapshot manifest.

---

## Part 3 — Application Consistent Snapshot (Pre/Post Hooks)

An application consistent snapshot combines the speed of a CSI snapshot with the correctness guarantee of application coordination. The sequence is:
1. Pre-hook: quiesce the database (`db.fsyncLock()` for MongoDB)
2. CSI snapshot
3. Post-hook: release the database (`db.fsyncUnlock()`)

### 3a. Create the hooks Blueprint

```bash
cat <<EOF | kubectl apply -f -
apiVersion: cr.kanister.io/v1alpha1
kind: Blueprint
metadata:
  name: mongo-hooks
  namespace: kasten-io
actions:
  backupPrehook:
    phases:
    - func: KubeExec
      name: lockMongo
      objects:
        mongoDbSecret:
          kind: Secret
          name: '{{ .StatefulSet.Name }}'
          namespace: "{{ .StatefulSet.Namespace }}"
      args:
        namespace: "{{ .StatefulSet.Namespace }}"
        pod: "{{ index .StatefulSet.Pods 0 }}"
        container: mongodb
        command:
        - bash
        - -o
        - errexit
        - -o
        - pipefail
        - -c
        - |
          export MONGODB_ROOT_PASSWORD='{{ index .Phases.lockMongo.Secrets.mongoDbSecret.Data "mongodb-root-password" | toString }}'
          mongosh --authenticationDatabase admin -u root -p "\$MONGODB_ROOT_PASSWORD" \
            --eval="db.fsyncLock()"
  backupPosthook:
    phases:
    - func: KubeExec
      name: unlockMongo
      objects:
        mongoDbSecret:
          kind: Secret
          name: '{{ .StatefulSet.Name }}'
          namespace: "{{ .StatefulSet.Namespace }}"
      args:
        namespace: "{{ .StatefulSet.Namespace }}"
        pod: "{{ index .StatefulSet.Pods 0 }}"
        container: mongodb
        command:
        - bash
        - -o
        - errexit
        - -o
        - pipefail
        - -c
        - |
          export MONGODB_ROOT_PASSWORD='{{ index .Phases.unlockMongo.Secrets.mongoDbSecret.Data "mongodb-root-password" | toString }}'
          mongosh --authenticationDatabase admin -u root -p "\$MONGODB_ROOT_PASSWORD" \
            --eval="db.fsyncUnlock()"
EOF
```

### 3b. Switch the StatefulSet annotation to the hooks Blueprint

```bash
kubectl annotate statefulset mongo-mongodb \
  kanister.kasten.io/blueprint='mongo-hooks' \
  --overwrite \
  -n mongodb
```

### 3c. Run a backup and verify hooks fired

In two separate terminals, watch simultaneously:

**Terminal 1** — watch VolumeSnapshot objects:
```bash
kubectl get volumesnapshot -n mongodb -w
```

**Terminal 2** — watch MongoDB lock status:
```bash
# Before the snapshot: not locked
# During prehook: db.fsyncLock() → {"info": "now locked against writes"}
# After posthook: db.fsyncUnlock() → {"info": "unlock completed"}
kubectl logs -n kasten-io -l component=kanister --follow 2>/dev/null | grep -E "fsync|lock"
```

Run the policy from the dashboard and observe both hooks executing around the snapshot.

---

## Part 4 — BlueprintBindings (Automatic Blueprint Assignment)

Instead of manually annotating each workload, `BlueprintBindings` let you define a label selector so Kasten automatically applies a Blueprint to matching workloads.

```bash
cat <<EOF | kubectl apply -f -
apiVersion: config.kio.kasten.io/v1alpha1
kind: BlueprintBinding
metadata:
  name: mongodb-hooks-binding
  namespace: kasten-io
spec:
  blueprintRef:
    name: mongo-hooks
    namespace: kasten-io
  resources:
    matchAll:
    - type:
        group: apps
        resource: statefulsets
      selector:
        matchLabels:
          app.kubernetes.io/name: mongodb
EOF
```

Verify the binding was applied:
```bash
kubectl get blueprintbinding -n kasten-io
```

Now any StatefulSet with `app.kubernetes.io/name=mongodb` in any namespace will automatically use the `mongo-hooks` Blueprint — no manual annotation needed.

---

## Part 5 — Generic Volume Backup

Generic Volume Backup (GVB) is used when the underlying storage driver does not support CSI snapshots. Instead, Kasten injects a sidecar container into the workload pod at backup time and uses it to copy data byte-for-byte.

To enable GVB, annotate the StatefulSet:

```bash
kubectl annotate statefulset mongo-mongodb \
  kanister.kasten.io/blueprint='' \
  --overwrite \
  -n mongodb

kubectl label statefulset mongo-mongodb \
  kanister.kasten.io/genericBackup='true' \
  -n mongodb

# You also need to specify which storageclass to use for the staging volume
kubectl annotate statefulset mongo-mongodb \
  kanister.kasten.io/genericVolumeBackupStorageClass='csi-hostpath-sc' \
  -n mongodb
```

Trigger a backup from the dashboard and observe the Kanister sidecar pod created during the backup in the `mongodb` namespace:

```bash
kubectl get pods -n mongodb -w
```

> **Note:** GVB is slower than snapshot-based backups and should only be used when snapshots are not available. It does not require application hooks because it reads at the filesystem layer.

---

## Validation Checkpoints

| # | Check | Expected Result |
|---|-------|-----------------|
| 1 | After crash consistent backup: `kubectl get volumesnapshot -n mongodb` | At least one snapshot exists |
| 2 | After logical backup: check MinIO bucket | `mongodump` `.tar.gz` artifact present |
| 3 | Blueprint exists: `kubectl get blueprint mongo-hooks -n kasten-io` | Blueprint listed |
| 4 | Annotation applied: `kubectl get statefulset mongo-mongodb -n mongodb -o jsonpath='{.metadata.annotations}'` | Blueprint annotation visible |
| 5 | BlueprintBinding: `kubectl get blueprintbinding -n kasten-io` | `mongodb-hooks-binding` present |
| 6 | After consistent backup: check policy run in dashboard | Both Backup and Kanister hook phases show "Complete" |

---

## Tips & References

- [Kanister documentation](https://docs.kanister.io/)
- [Kasten Blueprint reference](https://docs.kasten.io/latest/kanister/blueprint.html)
- [Kasten supported backup types](https://docs.kasten.io/latest/kanister/index.html)
- [Kasten BlueprintBindings](https://docs.kasten.io/latest/kanister/blueprint_binding.html)
- [MongoDB backup with filesystem snapshots (official warning)](https://www.mongodb.com/docs/v6.0/tutorial/backup-with-filesystem-snapshots/)
- [CSI driver list (100+ production drivers)](https://kubernetes-csi.github.io/docs/drivers.html)
- `KubeExec` runs commands inside an existing pod (for hooks). `KubeTask` starts a temporary pod (for dump/restore). Choose based on whether you need the application's runtime environment.
- Blueprints are shared, community-maintained resources. Find official ones at [https://github.com/kanisterio/kanister/tree/master/examples](https://github.com/kanisterio/kanister/tree/master/examples).
