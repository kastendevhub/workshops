# Workshop 3 — Disaster Recovery

**Based on Instruqt track: k10tt-dr (Lab 3 — Veeam Kasten Training — Disaster Recovery)**

---

## Goals

By the end of this workshop you will be able to:

- Protect multiple workloads at once using a single **label-based** Kasten policy
- Automatically include new workloads under protection by labelling their namespace
- Configure Kasten's **Disaster Recovery (DR) policy** to protect the Kasten catalog itself
- Simulate a total cluster failure
- Stand up a fresh cluster, install Kasten, and restore the full catalog
- Restore your applications from the recovered catalog

---

## DR Architecture Background

Understanding *what* gets backed up and *where* is critical:

```
Application backup flow:
  PVC data  ──snapshot──▶  VolumeSnapshot (in-cluster)
                                │
                       export──▶  Object Store (MinIO / S3)
                                │
  App manifests ──────────────▶  RestorePoint (stored in Kasten catalog PVC)

Kasten DR flow:
  Catalog PVC ──encrypt──▶  Object Store (same or different bucket)
              ↑
      User-provided passphrase (Kasten can't encrypt itself)
```

If the cluster dies, you need:
1. Your external object store (the exported backups)
2. Your catalog backup (encrypted with your passphrase)
3. A new cluster with Kasten installed

---

## Prerequisites

- Workshop 0 completed (cluster running)
- Workshop 1 completed (Kasten + MinIO + MongoDB installed, `s3-local` profile exists)
- Workshop 2 recommended (MongoDB has the `mongo-hooks` Blueprint applied)
- For the DR recovery section: the same cluster is reused (MinIO must remain running)

---

## Quick Resume

If you are returning to this workshop with the cluster already running, re-establish the service tunnels before continuing:

```bash
# Kasten dashboard — http://localhost:8080/k10/
kubectl --namespace kasten-io port-forward service/gateway 8080:80 &

# MinIO
kubectl port-forward svc/minio -n minio 9000:9000 &
mc alias set local http://localhost:9000 minioadmin minioadmin
```

---

## Step 1 — Label the MongoDB Namespace

Label-based policies let a single Kasten policy automatically include every namespace matching a set of labels. When a new application is labelled, it is immediately protected without modifying the policy.

```bash
kubectl label namespace mongodb backup=true
kubectl get namespace mongodb --show-labels
```

---

## Step 2 — Create a Label-Based Backup Policy

In the Kasten dashboard:

1. **Policies → + Create New Policy**
2. Configure:

| Field | Value |
|-------|-------|
| Name | `label-backup` |
| Backup Frequency | Daily |
| Enable Snapshot Exports | ✓ |
| Export Location Profile | `s3-local` |
| Select Applications | **By Labels** |
| Label selector | `backup: true` |

3. **Create Policy → Run Once → Yes, Continue**

Watch under **Dashboard → Actions** — you should see BackupAction and ExportAction for the `mongodb` namespace.

Via `kubectl`:
```bash
cat <<EOF | kubectl apply -f -
kind: Policy
apiVersion: config.kio.kasten.io/v1alpha1
metadata:
  name: label-backup
  namespace: kasten-io
spec:
  frequency: "@daily"
  retention:
    daily: 7
    weekly: 4
    monthly: 12
    yearly: 7
  selector:
    matchLabels:
      backup: "true"
  actions:
  - action: backup
    backupParameters:
      profile:
        name: s3-local
        namespace: kasten-io
  - action: export
    exportParameters:
      frequency: "@daily"
      profile:
        name: s3-local
        namespace: kasten-io
      exportData:
        enabled: true
    retention: {}
EOF
```

---

## Step 3 — Deploy an Additional Workload (Auto-Protected)

Deploy a MySQL database to demonstrate automatic policy inclusion:

```bash
kubectl create namespace mysql
kubectl label namespace mysql backup=true

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mysql
  namespace: mysql
spec:
  selector:
    matchLabels:
      app: mysql
  serviceName: mysql
  replicas: 1
  template:
    metadata:
      labels:
        app: mysql
    spec:
      containers:
      - name: mysql
        image: mysql:8.0
        env:
        - name: MYSQL_ROOT_PASSWORD
          value: ultrasecurepassword
        ports:
        - containerPort: 3306
          name: mysql
        volumeMounts:
        - name: data
          mountPath: /var/lib/mysql
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: [ReadWriteOnce]
      resources:
        requests:
          storage: 5Gi
---
apiVersion: v1
kind: Service
metadata:
  name: mysql
  namespace: mysql
spec:
  ports:
  - port: 3306
    protocol: TCP
  selector:
    app: mysql
  type: ClusterIP
EOF
```

Wait for MySQL to be ready:
```bash
kubectl wait pod/mysql-0 -n mysql --for=condition=Ready --timeout=120s
```

Create some data:
```bash
kubectl exec mysql-0 -n mysql -- \
  mysql --user=root --password=ultrasecurepassword -h 127.0.0.1 \
  -e "CREATE DATABASE test; USE test; CREATE TABLE pets (name VARCHAR(20), owner VARCHAR(20), species VARCHAR(20)); INSERT INTO pets VALUES ('Puffball','Diane','hamster'); SELECT * FROM pets;"
```

Run the `label-backup` policy again and confirm **both** `mongodb` and `mysql` namespaces are backed up in the same policy run.

---

## Step 4 — Enable Kasten Disaster Recovery

Kasten's DR mechanism works by backing up the Kasten catalog itself to your object store. This requires two things: a user-provided passphrase (stored as a Kubernetes Secret) and a dedicated `k10-disaster-recovery-policy` that runs the catalog backup. Both must be in place **before** the disaster.

### 4a. Record your Cluster ID

The Cluster ID identifies your backup data in object storage. Record it now — you will need it during recovery.

The Cluster ID is the UID of the **`default` namespace**, not the `kasten-io` namespace. The `default` namespace is used because it is the only namespace that cannot be deleted in a Kubernetes cluster — making its UID a stable, permanent identifier for the cluster even if Kasten is uninstalled and reinstalled.

```bash
kubectl get namespace default -o jsonpath='{.metadata.uid}'
```

Alternatively, after the first backup has run, it also appears as the top-level directory in MinIO:

```bash
mc ls local/lab-bucket-immutable/k10/ 2>/dev/null
```

Save the UUID — that is your **Cluster ID**.

### 4b. Create the DR passphrase secret and enable DR

The passphrase is used to encrypt the Kasten catalog backup. Kasten looks for it automatically in a Secret named `k10-dr-secret` with key `key`.

#### Via the dashboard

The dashboard combines steps 4b and 4c into a single form — enabling DR creates both the passphrase secret and the DR policy in one action.

1. Navigate to **Settings** → **Disaster Recovery**.
2. Click **Enable Disaster Recovery**.
3. Enter your passphrase in the **Passphrase** field and confirm it.
4. Select `s3-local` as the export profile.
5. Click **Enable**.

Kasten creates the `k10-dr-secret` Secret and the `k10-disaster-recovery-policy` Policy automatically. **Skip to step 4c to trigger the first run.**

Store the passphrase in a password manager. Recovery is impossible without it.

#### Via kubectl

```bash
DR_PASSPHRASE="your-strong-passphrase-here"

kubectl create secret generic k10-dr-secret \
  --namespace kasten-io \
  --from-literal=key="${DR_PASSPHRASE}"
```

Store the passphrase in a password manager. Recovery is impossible without it.

### 4c. Create and run the DR policy

> **Dashboard users:** the policy was already created in step 4b — go straight to triggering the run below.

The `k10-disaster-recovery-policy` is a special Kasten policy that backs up the Kasten catalog itself. It uses `kdrSnapshotConfiguration` to distinguish it from a regular application backup.

#### Via the dashboard

Navigate to **Policies** and confirm `k10-disaster-recovery-policy` is listed. Click **Run Once** to trigger the first backup immediately.

#### Via kubectl

Apply the policy:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: config.kio.kasten.io/v1alpha1
kind: Policy
metadata:
  name: k10-disaster-recovery-policy
  namespace: kasten-io
spec:
  frequency: "@hourly"
  retention:
    hourly: 4
    daily: 1
    weekly: 1
    monthly: 1
    yearly: 1
  selector:
    matchExpressions:
    - key: k10.kasten.io/appNamespace
      operator: In
      values:
      - kasten-io
  actions:
  - action: backup
    backupParameters:
      filters: {}
      profile:
        name: s3-local
        namespace: kasten-io
  - action: export
    exportParameters:
      exportData:
        enabled: true
      profile:
        name: s3-local
        namespace: kasten-io
    retention: {}
  kdrSnapshotConfiguration:
    exportCatalogSnapshot: true
    takeLocalCatalogSnapshot: true
EOF
```

Trigger the DR policy run:

```bash
cat <<EOF | kubectl create -f -
apiVersion: actions.kio.kasten.io/v1alpha1
kind: RunAction
metadata:
  generateName: dr-policy-run-
  namespace: kasten-io
spec:
  subject:
    kind: Policy
    name: k10-disaster-recovery-policy
    namespace: kasten-io
EOF
```

Watch the dashboard **Actions** view until both the backup and export phases complete.

> **Order matters:** Run `label-backup` first (it backs up your applications), then run `k10-disaster-recovery-policy` (it backs up the Kasten catalog including the application restore points). Both must complete before you simulate the disaster.

### 4d. Verify exports and DR catalog reach MinIO

After both policies have run:

```bash
# Show the cluster ID directory
mc ls local/lab-bucket-immutable/k10/

# Show what is inside it
CLUSTER_ID=$(mc ls local/lab-bucket-immutable/k10/ | awk '{print $NF}' | tr -d '/')
mc ls "local/lab-bucket-immutable/k10/${CLUSTER_ID}/migration/"

# Show the per-namespace Kopia repos (application data)
mc ls "local/lab-bucket-immutable/k10/${CLUSTER_ID}/migration/repo/"

# Show the DR catalog repo (written by the k10-disaster-recovery-policy)
mc ls "local/lab-bucket-immutable/k10/${CLUSTER_ID}/migration/${CLUSTER_ID}/k10/repo/"
```

You should see:
- `repo/` — application data Kopia repos, one UUID subdirectory per backed-up namespace. Files inside are random hashes because Kopia encrypts the entire repository.
- `<cluster-id>/k10/repo/` — the **DR catalog repository**, written by `k10-disaster-recovery-policy`. This is what `KastenDRReview` and `KastenDRRestore` read during recovery. If this directory is missing, the DR policy did not run successfully before the disaster.
- `label-backup/kopia/` — the export catalog for the `label-backup` policy.
- Subdirectories for Kanister artifact exports if Workshop 2 Blueprints were used (e.g. `mongodb-backup/`).

---

## Step 5 — Simulate a Disaster

Delete the applications and Kasten, but **leave MinIO running**:

```bash
# Delete the applications
kubectl delete namespace mongodb mysql

# Delete Kasten itself
helm uninstall k10 -n kasten-io
kubectl delete namespace kasten-io --wait
```

> **Why keep MinIO?** In production, your backup target (S3, Azure Blob, GCS) is always **external** to the cluster and survives a cluster failure — that is the fundamental design principle of DR. In this local lab, MinIO runs inside the cluster, so we simulate "external storage survives" by keeping it running while deleting everything else. Deleting the entire kind cluster would also destroy MinIO and leave nothing to restore from.

Wait for the `kasten-io` namespace to fully terminate before continuing (CRD finalizers can take 1–3 minutes):

```bash
kubectl get namespace kasten-io -w
```

---

## Step 6 — Recover

### 6a. Reinstall Kasten

MinIO is still running with all your backup data. Reinstall Kasten on the same cluster:

```bash
kubectl create namespace kasten-io

helm install k10 kasten/k10 \
  --namespace kasten-io \
  --set global.acceptEULA=true \
  --wait
```

### 6b. Restore the Kasten catalog

#### Via the dashboard

The dashboard provides a guided wizard for catalog recovery. You first need a location profile so Kasten knows where to look. Recreate `s3-local` through the dashboard:

1. Navigate to **Settings → Locations** → **+ New Location Profile**.
2. Configure:

| Field | Value |
|-------|-------|
| Profile Name | `s3-local` |
| Cloud Provider | S3 Compatible |
| Endpoint | `http://minio.minio.svc.cluster.local:9000` |
| Access Key ID | `minioadmin` |
| Secret Access Key | `minioadmin` |
| Bucket Name | `lab-bucket-immutable` |
| Region | `us-east-1` |
| Path Type | Directory |
| Skip SSL Verify | ✓ |

3. Click **Validate and Save**.

Then restore the catalog:

1. Navigate to **Settings → Disaster Recovery**.
2. Click **Restore Kasten**.
3. Select `s3-local` as the location profile.
4. Enter the source **Cluster ID** (the UUID you recorded in Step 4a).
5. Enter your **Passphrase** (the one you set in Step 4b). Kasten creates the `k10-dr-secret` from this automatically.
6. Click **Find Snapshots**. Kasten queries the object store and lists available restore points.
7. Select the restore point marked **Catalog Available** (equivalent to `exportedCatalogAvailable: true`).
8. Click **Restore**.

Watch progress in **Settings → Disaster Recovery**. Once the status shows success, all policies, profiles, and restore point metadata are available — skip to step 6c.

#### Via kubectl

Recreate the DR passphrase secret and the `s3-local` profile, then use `KastenDRReview` + `KastenDRRestore`:

```bash
# Recreate the DR passphrase secret (same value used in Step 4b)
kubectl create secret generic k10-dr-secret \
  --namespace kasten-io \
  --from-literal=key="your-strong-passphrase-here"

# Recreate the MinIO credentials secret and s3-local profile
kubectl create secret generic k10secret-minio -n kasten-io \
  --from-literal=aws_access_key_id=minioadmin \
  --from-literal=aws_secret_access_key=minioadmin

cat <<EOF | kubectl apply -f -
kind: Profile
apiVersion: config.kio.kasten.io/v1alpha1
metadata:
  name: s3-local
  namespace: kasten-io
spec:
  locationSpec:
    credential:
      secret:
        apiVersion: v1
        kind: secret
        name: k10secret-minio
        namespace: kasten-io
      secretType: AwsAccessKey
    objectStore:
      endpoint: http://minio.minio.svc.cluster.local:9000
      name: lab-bucket-immutable
      objectStoreType: S3
      pathType: Directory
      protectionPeriod: 480h0m0s
      region: us-east-1
    type: ObjectStore
  type: Location
EOF
```

Get the source cluster ID from MinIO (this is the cluster ID you recorded in Step 4a):

```bash
SOURCE_CLUSTER_ID=$(mc ls local/lab-bucket-immutable/k10/ 2>/dev/null \
  | awk '{print $NF}' | tr -d '/' | head -1)
echo "Source cluster ID: ${SOURCE_CLUSTER_ID}"
```

Review available DR snapshots:

```bash
cat <<EOF | kubectl apply -f -
kind: KastenDRReview
apiVersion: dr.kio.kasten.io/v1alpha1
metadata:
  name: dr-review
  namespace: kasten-io
spec:
  sourceClusterInfo:
    profileName: s3-local
    sourceClusterID: "${SOURCE_CLUSTER_ID}"
EOF

kubectl get kastendrreview dr-review -n kasten-io -w
```

Once `KastenDRReview` reaches `state: success`, inspect its output to find the snapshot ID where `exportedCatalogAvailable: true`:

```bash
kubectl get kastendrreview dr-review -n kasten-io -o jsonpath='{.status.restorePoints.restorePointList}' | jq .
```

Extract the snapshot ID automatically:

```bash
SNAPSHOT_ID=$(kubectl get kastendrreview dr-review -n kasten-io -o json \
  | jq -r '.status.restorePoints.restorePointList[] | select(.exportedCatalogAvailable == true) | .id' \
  | head -1)
echo "Snapshot ID: ${SNAPSHOT_ID}"
```

Restore the Kasten catalog using that snapshot. Note that `kastenDRReviewDetails` and `sourceClusterInfo` are mutually exclusive — use `kastenDRReviewDetails` when you already have a `KastenDRReview` result:

```bash
cat <<EOF | kubectl apply -f -
kind: KastenDRRestore
apiVersion: dr.kio.kasten.io/v1alpha1
metadata:
  name: dr-restore
  namespace: kasten-io
spec:
  kastenDRReviewDetails:
    kastenDRReviewRef:
      name: dr-review
      namespace: kasten-io
    id: "${SNAPSHOT_ID}"
EOF

kubectl get kastendrrestore dr-restore -n kasten-io -w
```

Wait for `state: success`. Once complete, all policies, profiles, and restore point metadata from the original cluster are available in this Kasten instance.

### 6c. Restore Applications

After the catalog is restored, `RestorePointContent` objects are already present. You do not need to import anything — just create the namespaces and trigger restore actions.

> **Important:** Only restore points that were **exported** to the object store are usable after a disaster. Local-only snapshots live on the cluster's storage volumes and are lost when the cluster is gone. Always select a restore point that was produced by an export action (shown as **Exported** in the dashboard, or having a `RestorePointContent` backed by the object store profile). In this workshop, those are the restore points created by the `label-backup` policy's export step.

Via the dashboard:

1. **Applications → mongodb → Restore Points** — select the most recent **exported** restore point (marked with the export icon or the profile name `s3-local`)
2. **Restore** → confirm
3. Repeat for `mysql`

Via `kubectl`:

```bash
kubectl create namespace mongodb
kubectl create namespace mysql

# List only exported restore points (RestorePointContent must reference the s3-local profile)
kubectl get restorepoint -n mongodb --sort-by='.metadata.creationTimestamp'
kubectl get restorepoint -n mysql --sort-by='.metadata.creationTimestamp'

# Pick the most recent exported restore point name from each list
MONGODB_RP=$(kubectl get restorepoint -n mongodb --sort-by='.metadata.creationTimestamp' \
  -o jsonpath='{.items[*].metadata.name}' | awk '{print $NF}')
MYSQL_RP=$(kubectl get restorepoint -n mysql --sort-by='.metadata.creationTimestamp' \
  -o jsonpath='{.items[*].metadata.name}' | awk '{print $NF}')

cat <<EOF | kubectl apply -f -
kind: RestoreAction
apiVersion: actions.kio.kasten.io/v1alpha1
metadata:
  name: mongodb-restore
  namespace: mongodb
spec:
  targetNamespace: mongodb
  overwriteExisting: true
  subject:
    apiVersion: apps.kio.kasten.io/v1alpha1
    kind: RestorePoint
    name: ${MONGODB_RP}
    namespace: mongodb
EOF

cat <<EOF | kubectl apply -f -
kind: RestoreAction
apiVersion: actions.kio.kasten.io/v1alpha1
metadata:
  name: mysql-restore
  namespace: mysql
spec:
  targetNamespace: mysql
  overwriteExisting: true
  subject:
    apiVersion: apps.kio.kasten.io/v1alpha1
    kind: RestorePoint
    name: ${MYSQL_RP}
    namespace: mysql
EOF
```

Wait for both restore actions to complete (`state: Complete`).

Validate data:

```bash
export MONGODB_ROOT_PASSWORD=$(kubectl get secret mongo-mongodb \
  --namespace mongodb -o jsonpath="{.data.mongodb-root-password}" | base64 --decode)

kubectl exec -it statefulset/mongo-mongodb -n mongodb \
  -- mongosh admin \
  --authenticationDatabase admin \
  -u root -p "$MONGODB_ROOT_PASSWORD" \
  --eval 'db.log.find()'

kubectl exec mysql-0 -n mysql -- \
  mysql --user=root --password=ultrasecurepassword -h 127.0.0.1 \
  -e "USE test; SELECT * FROM pets;"
```

---

## Validation Checkpoints

| # | Check | Expected Result |
|---|-------|-----------------|
| 1 | `kubectl get namespace mongodb --show-labels` | Label `backup=true` present |
| 2 | `kubectl get namespace mysql --show-labels` | Label `backup=true` present |
| 3 | Dashboard → Policies → `label-backup` | Policy runs show both `mongodb` and `mysql` backed up |
| 4 | `kubectl get policy k10-disaster-recovery-policy -n kasten-io` | Policy exists with status `Success` |
| 5 | `CLUSTER_ID=$(mc ls local/lab-bucket-immutable/k10/ \| awk '{print $NF}' \| tr -d '/'); mc ls "local/lab-bucket-immutable/k10/${CLUSTER_ID}/migration/${CLUSTER_ID}/k10/repo/"` | DR catalog files present (Kopia repo files) |
| 6 | `kubectl get kastendrreview dr-review -n kasten-io -o jsonpath='{.status.state}'` | `success` |
| 7 | `kubectl get kastendrrestore dr-restore -n kasten-io -o jsonpath='{.status.state}'` | `success` |
| 8 | After recovery: `kubectl get pods -n mongodb` | MongoDB running |
| 9 | After recovery: `kubectl get pods -n mysql` | MySQL running |
| 10 | After recovery: MongoDB query | `card` and `dice` records returned |
| 11 | After recovery: MySQL query | `Puffball` record returned |

---

## This workshop has challenges

- **The DR passphrase is irreplaceable.** Losing it means the catalog backup cannot be decrypted — full cluster recovery becomes impossible. Store it in a secrets manager *before* running the DR exercise.
- **The `k10-dr-secret` key must be named `key`, not `passphrase`.** When creating the DR passphrase secret manually, use `--from-literal=key="..."`. Using any other key name (e.g. `passphrase`) causes `KastenDRReview` to fail with "Kubernetes secret does not contain key".
- **DR requires a dedicated `k10-disaster-recovery-policy`, not a helm flag.** There is no helm value to "enable DR". You must create a Policy with `kdrSnapshotConfiguration.exportCatalogSnapshot: true` and run it before the disaster. Without this policy having run at least once, the DR catalog will not exist in object storage and `KastenDRReview` will report "repository not found".
- **`KastenDRRestore` does not accept both `sourceClusterInfo` and `kastenDRReviewDetails` simultaneously.** They are mutually exclusive. If you have already run `KastenDRReview`, use `kastenDRReviewDetails` with the review reference and snapshot ID. Using both fields causes a validation error.
- **Choose the restore point with `exportedCatalogAvailable: true`.** `KastenDRReview` may list multiple restore points. Only the one with `exportedCatalogAvailable: true` contains the full catalog export needed for recovery.
- **The `k10restore` Helm chart is removed in Kasten 8.x.** Use the `KastenDRRestore` CRD described in Step 6b.
- **`mysql:8.0.26` has no ARM64 image.** On Apple Silicon (M1/M2/M3) use `mysql:8.0` which is a multi-platform image. The specific patch version images often lack ARM64 manifests.
- **After deleting Kasten (`helm uninstall k10 -n kasten-io`), the `kasten-io` namespace may take 1–3 minutes to fully terminate** due to finalizers on Kasten CRDs. Wait for `kubectl get namespace kasten-io` to disappear before recreating it.
- **Kasten determines its storage cluster ID from the existing bucket data.** When a freshly installed Kasten connects to a profile that already has backup data in the bucket, it adopts the cluster ID found there. This is why the `sourceClusterID` in `KastenDRReview` must match the UUID prefix visible in `mc ls local/lab-bucket-immutable/k10/`.

---

## Tips & References

- [Kasten Disaster Recovery documentation](https://docs.kasten.io/latest/operating/dr.html)
- [Kasten label-based policy selection](https://docs.kasten.io/latest/usage/protect.html#selecting-applications-by-label)
- The passphrase is **not recoverable** — store it in a password manager or secrets vault (e.g. HashiCorp Vault, AWS Secrets Manager)
- VolumeSnapshot data lives inside the cluster storage; the **exported** RestorePoint copies data to the external object store, making it portable to a new cluster. Always enable exports for DR scenarios.
- Kasten Multi-Cluster (Workshop 4) can automate ongoing imports to a warm standby cluster, significantly reducing RTO.
- The `k10.kasten.io/doNotRetire: "true"` label on `RunAction` objects prevents Kasten from retiring them from the dashboard — useful for debugging.
