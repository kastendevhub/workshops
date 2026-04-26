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

> **Note:** MongoDB's documentation actually supports crash-consistent snapshots as a valid backup strategy — provided three conditions are met: the storage layer produces a true atomic snapshot, journaling is enabled, and the journal and data files live on the same volume. When all three hold, MongoDB can recover cleanly from a crash-consistent snapshot without any database locking.
>
> In this lab those conditions are **not guaranteed**: the CSI hostpath driver is a development driver that does not promise true atomic snapshots, and we have not verified that the Bitnami replica set places journal and data on the same volume. That is why later exercises add application-consistent hooks — not because locking is always required, but because it compensates for storage that cannot guarantee atomicity on its own.

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

**Takeaway:** Crash-consistent backups are fast and fully valid for MongoDB when the storage provides true atomic snapshots, journaling is enabled, and journal and data share the same volume. In this lab the hostpath CSI driver does not satisfy those guarantees, which is why the later exercises add application-consistent coordination.

---

## Part 2 — Logical Backup with a Kanister Blueprint

A logical backup uses application-native tools (`mongodump`, `pg_dump`, etc.) to export data at the application layer, independent of the underlying storage. Kanister provides a YAML-based framework for expressing these custom operations as **Blueprints**.

### 2a. Create the MongoDB logical dump Blueprint

The Blueprint uses `kando output` to record the backup path, then exposes it via `outputArtifacts` using `{{ .Phases.<name>.Output.<key> }}`. This is required because `outputArtifacts` are resolved from phase outputs — you cannot reference them via `ArtifactsIn` within the same backup phase.

Also add a `backupParameters.profile` to the policy (see step 2c) so Kasten knows which location profile to pass to `kando location push/pull`.

```bash
cat <<'EOF' | kubectl apply -f -
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
          path: '{{ .Phases.takeDump.Output.backupPath }}'
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
          BACKUP_PATH="mongo-backups/{{ .StatefulSet.Namespace }}/{{ toDate "2006-01-02T15:04:05.999999999Z07:00" .Time | date "2006-01-02T15-04-05" }}/dump.tar.gz"
          mongodump \
            --authenticationDatabase admin \
            -u root \
            -p "$MONGODB_ROOT_PASSWORD" \
            --host "mongo-mongodb-0.mongo-mongodb-headless.{{ .StatefulSet.Namespace }}:27017" \
            --gzip \
            --archive=/tmp/dump.tar.gz
          kando location push --profile '{{ toJson .Profile }}' --path "${BACKUP_PATH}" /tmp/dump.tar.gz
          kando output backupPath "${BACKUP_PATH}"
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
            -p "$MONGODB_ROOT_PASSWORD" \
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

### 2c. Update the policy to specify the location profile for Kanister

Kanister Blueprints that use `kando location push/pull` need a location profile. Add `backupParameters.profile` to the policy:

```bash
cat <<EOF | kubectl apply -f -
kind: Policy
apiVersion: config.kio.kasten.io/v1alpha1
metadata:
  name: mongodb-backup
  namespace: kasten-io
spec:
  frequency: "@hourly"
  retention:
    hourly: 24
    daily: 7
    weekly: 4
    monthly: 12
    yearly: 7
  selector:
    matchExpressions:
    - key: k10.kasten.io/appNamespace
      operator: In
      values: [mongodb]
  actions:
  - action: backup
    backupParameters:
      profile:
        name: s3-local
        namespace: kasten-io
  - action: export
    exportParameters:
      frequency: "@hourly"
      profile:
        name: s3-local
        namespace: kasten-io
      exportData:
        enabled: true
    retention: {}
EOF
```

### 2d. Run a backup and observe the difference

```bash
cat <<EOF | kubectl apply -f -
kind: RunAction
apiVersion: actions.kio.kasten.io/v1alpha1
metadata:
  name: mongodb-logical-run-1
  namespace: kasten-io
  labels:
    k10.kasten.io/policyName: mongodb-backup
    k10.kasten.io/policyNamespace: kasten-io
spec:
  subject:
    apiVersion: config.kio.kasten.io/v1alpha1
    kind: Policy
    name: mongodb-backup
    namespace: kasten-io
EOF

kubectl get runaction mongodb-logical-run-1 -n kasten-io -w
```

After the backup completes, verify the `mongodump` artifact appeared in MinIO:
```bash
mc ls local/lab-bucket-immutable/ --recursive | grep dump
```

---

## Part 3 — Application Consistent Snapshot (Pre/Post Hooks)

An application consistent snapshot combines the speed of a CSI snapshot with the correctness guarantee of application coordination. The sequence is:
1. Pre-hook: quiesce the database (`db.fsyncLock()` for MongoDB)
2. CSI snapshot
3. Post-hook: release the database (`db.fsyncUnlock()`)

### 3a. Create the hooks Blueprint

```bash
cat <<'EOF' | kubectl apply -f -
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
          mongosh --authenticationDatabase admin -u root -p "$MONGODB_ROOT_PASSWORD" \
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
          mongosh --authenticationDatabase admin -u root -p "$MONGODB_ROOT_PASSWORD" \
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

> **Important:** The `BlueprintBinding` API changed in Kasten 8.x. The selector uses a structured format with separate `type` and `labels` entries under `matchAll`, not a combined `type.group/resource + selector.matchLabels` block. Also, when using a MongoDB replica set (which includes an arbiter StatefulSet), make sure to use `app.kubernetes.io/component: mongodb` rather than `app.kubernetes.io/name: mongodb` to avoid applying hooks to the arbiter (which has no MongoDB secret).

```bash
# First remove the manual annotation (use - suffix to delete it, not set it to empty string)
kubectl annotate statefulset mongo-mongodb \
  kanister.kasten.io/blueprint- \
  -n mongodb

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
        operator: In
        values:
        - group: apps
          resource: statefulsets
          version: v1
    - labels:
        key: app.kubernetes.io/component
        operator: In
        values:
        - mongodb
EOF
```

Verify the binding was applied:
```bash
kubectl get blueprintbinding -n kasten-io
```

Now any StatefulSet with `app.kubernetes.io/component=mongodb` in any namespace will automatically use the `mongo-hooks` Blueprint — no manual annotation needed.

---

## Part 5 — Generic Volume Backup

Generic Volume Backup (GVB) is used when the underlying storage driver does not support CSI snapshots. Instead, Kasten injects a sidecar container into the workload pod at backup time and uses it to copy data byte-for-byte.

To enable GVB, remove any Blueprint annotation (using `-` suffix) and add the GVB label and annotation:

```bash
# Remove Blueprint annotation entirely (don't set to empty string — that causes errors)
kubectl annotate statefulset mongo-mongodb \
  kanister.kasten.io/blueprint- \
  -n mongodb

kubectl label statefulset mongo-mongodb \
  kanister.kasten.io/genericBackup='true' \
  -n mongodb

# Specify which StorageClass to use for the staging volume
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

## This workshop has challenges

- **Kanister `outputArtifacts` are not available as `ArtifactsIn` within the same phase.** During the backup phase, you cannot reference `{{ .ArtifactsIn.myArtifact.KeyValue.path }}` because the artifact has not been created yet. Use `kando output <key> <value>` to emit phase outputs, then reference them in `outputArtifacts` via `{{ .Phases.<name>.Output.<key> }}`. The `ArtifactsIn` reference only works in the restore phase, where backup artifacts are passed as inputs.
- **The policy must specify `backupParameters.profile` for Kanister operations.** When a Blueprint uses `kando location push/pull`, Kasten needs to know which location profile to use. Without `backupParameters.profile` in the Policy spec, Kasten looks for a profile named `kanister-profile` and fails if it doesn't exist.
- **The `BlueprintBinding` spec format changed in Kasten 8.x.** The `matchAll` list items now use separate entries for `type` and `labels` selectors (not a combined object). Use `kubectl explain blueprintbinding.spec.resources.matchAll` to see the current schema.
- **Setting `kanister.kasten.io/blueprint=''` (empty string) causes errors.** When removing a Blueprint annotation, use `kubectl annotate ... kanister.kasten.io/blueprint-` (with a `-` suffix) to delete it. Setting it to an empty string leaves the annotation present, and Kasten tries to look up a Blueprint with an empty name, which fails with "resource name may not be empty".
- **BlueprintBindings match all StatefulSets with the selector label, including arbiters.** The Bitnami MongoDB replica set chart creates a `mongo-mongodb-arbiter` StatefulSet with `app.kubernetes.io/name: mongodb`. The arbiter doesn't have a `mongo-mongodb` secret, so Blueprint hooks using `{{ .StatefulSet.Name }}` to look up the secret will fail on the arbiter. Use `app.kubernetes.io/component: mongodb` in the selector instead.

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
