# Workshop 1 — Getting Started with Kasten

**Based on Instruqt track: k10tt-gs2 (Lab 1 — Veeam Kasten Training — Getting Started)**

---

## Goals

By the end of this workshop you will have:

- Deployed Kasten to your Kubernetes cluster using Helm
- Passed the Kasten pre-flight checks confirming your storage is snapshot-capable
- Configured MinIO as an immutable S3-compatible object storage backup target
- Deployed a MongoDB replica set as a sample stateful application
- Created a Kasten backup policy with export and run it on demand
- Verified data integrity by deleting MongoDB and restoring from a Kasten `RestorePoint`
- Executed a backup programmatically using the Kubernetes-native `RunAction` API

---

## Prerequisites

- Workshop 0 completed — `kind-kasten-training` cluster running with CSI hostpath driver and VolumeSnapshot support
- `helm` repo access to `charts.kasten.io` and `charts.bitnami.com`
- `helm`, `kubectl`, `jq` installed locally

---

## Step 1 — Run the Kasten Pre-flight Check

Before installing Kasten, validate that the cluster storage meets requirements.

```bash
# Add Kasten Helm repo
helm repo add kasten https://charts.kasten.io/
helm repo update

# Run the pre-flight check using k10tools primer
# Download k10tools from https://github.com/kastenhq/external-tools/releases/latest
# macOS (Apple Silicon): k10tools_*_macOS_arm64.tar.gz
# macOS (Intel):         k10tools_*_macOS_amd64.tar.gz
# Linux (amd64):         k10tools_*_linux_amd64.tar.gz
K10_VERSION=$(helm search repo kasten/k10 --output json | jq -r '.[0].app_version')
curl -sL "https://github.com/kastenhq/external-tools/releases/download/${K10_VERSION}/k10tools_${K10_VERSION}_macOS_arm64.tar.gz" \
  | tar -xz -C /tmp/ k10tools
sudo install -m 0755 /tmp/k10tools /usr/local/bin/k10tools
k10tools --version
k10tools primer
```

Look for all checks to complete with `OK` status. The CSI provisioner and VolumeSnapshotClass checks are the critical ones for Kasten.

---

## Step 2 — Install Kasten

```bash
kubectl create namespace kasten-io

helm install k10 kasten/k10 \
  --namespace kasten-io \
  --wait
```

This takes approximately 3–5 minutes. Verify all pods are healthy:

```bash
kubectl get pods -n kasten-io
```

All pods should be `Running` or `Completed`.

---

## Step 3 — Expose the Kasten Dashboard

```bash
kubectl --namespace kasten-io port-forward service/gateway 8080:80
```

Open the Kasten dashboard at [http://localhost:8080/k10/](http://localhost:8080/k10/).

Accept the EULA on first access. No login is required — Kasten runs without authentication by default on a local cluster.

> **Why no auth is acceptable here:** `kubectl port-forward` requires an active kubeconfig with sufficient cluster permissions to execute. Anyone who can reach the dashboard via this port-forward already has Kubernetes admin access — the cluster itself is the security boundary. In production you would configure authentication (tokenAuth, OIDC, etc.) so the dashboard is accessible over a stable endpoint. A future workshop will cover Kasten authentication options.

---

## Step 4 — Annotate the VolumeSnapshotClass

If you haven't already done this in Workshop 0:

```bash
kubectl annotate volumesnapshotclass csi-hostpath-snapclass \
  k10.kasten.io/is-snapshot-class="true"
```

Verify in the Kasten dashboard under **Settings > Storage** that your storage class appears as snapshot-capable.

---

## Step 5 — Deploy MinIO as Object Storage

In a real environment you would use S3, Azure Blob, or GCS. For local training, MinIO provides an S3-compatible target.

```bash
helm repo add minio https://charts.min.io/
helm repo update

kubectl create namespace minio

helm install minio minio/minio \
  --namespace minio \
  --set mode=standalone \
  --set replicas=1 \
  --set persistence.size=10Gi \
  --set resources.requests.memory=512Mi \
  --set rootUser=minioadmin \
  --set rootPassword=minioadmin \
  --wait
```

Create the backup bucket:

```bash
# Port-forward MinIO API
kubectl port-forward svc/minio -n minio 9000:9000 &

# Install mc (MinIO client) if not already installed
# brew install minio/stable/mc   # macOS
# or download from https://min.io/docs/minio/linux/reference/minio-mc.html

mc alias set local http://localhost:9000 minioadmin minioadmin
mc mb --with-lock local/lab-bucket-immutable
mc retention set --default COMPLIANCE 1d local/lab-bucket-immutable
```

---

## Step 6 — Create a Kasten Location Profile

In the Kasten dashboard:

1. Navigate to **Settings > Location**.
2. Click **+ New Profile**.
3. Fill in the following:

| Field | Value |
|-------|-------|
| Profile Name | `s3-local` |
| Cloud Storage Provider | S3 Compatible |
| S3 Endpoint | `http://minio.minio.svc.cluster.local:9000` |
| Access Key | `minioadmin` |
| Secret Key | `minioadmin` |
| Bucket | `lab-bucket-immutable` |
| Region | leave blank or `us-east-1` |

4. Click **Validate and Save**. The profile should show a green checkmark.

Alternatively, via `kubectl`:

```bash
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
        kind: Secret
        name: k10secret-minio
        namespace: kasten-io
      secretType: AwsAccessKey
    objectStore:
      endpoint: http://minio.minio.svc.cluster.local:9000
      name: lab-bucket-immutable
      objectStoreType: S3
      pathType: Directory
      region: us-east-1
    type: ObjectStore
  type: Location
EOF
```

---

## Step 7 — Deploy MongoDB

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

kubectl create namespace mongodb

helm install mongo bitnami/mongodb \
  --namespace mongodb \
  --set architecture=replicaset \
  --set persistence.size=1Gi \
  --wait
```

Populate with sample data:

```bash
export MONGODB_ROOT_PASSWORD=$(kubectl get secret mongo-mongodb \
  --namespace mongodb \
  -o jsonpath="{.data.mongodb-root-password}" | base64 --decode)

kubectl exec -it statefulset/mongo-mongodb -n mongodb \
  -- mongosh admin \
  --authenticationDatabase admin \
  -u root -p "$MONGODB_ROOT_PASSWORD" \
  --host "mongo-mongodb-0.mongo-mongodb-headless:27017,mongo-mongodb-1.mongo-mongodb-headless:27017" \
  --eval 'db.createCollection("log", { capped: true, size: 5242880, max: 5000 });
          db.log.insertMany([{ item: "card", qty: 15 }, { item: "dice", qty: 3 }]);
          db.log.find()'
```

You should see both records returned.

---

## Step 8 — Create a Backup Policy and Run It

In the Kasten dashboard:

1. Navigate to **Policies > Policies**.
2. Click **+ Create New Policy**.
3. Configure:

| Field | Value |
|-------|-------|
| Name | `mongodb-backup` |
| Application | By Name → select `mongodb` |
| Backup Frequency | Hourly |
| Enable Snapshot Exports | ✓ checked |
| Export Location Profile | `s3-local` |

4. Click **Create Policy**.
5. Click **Run Once → Yes, Continue** to trigger an immediate backup.

Monitor progress under **Dashboard → Actions**. You should see both a **BackupAction** and an **ExportAction** complete successfully.

Via `kubectl` (API-native approach):

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

# Trigger a run
cat <<EOF | kubectl apply -f -
kind: RunAction
apiVersion: actions.kio.kasten.io/v1alpha1
metadata:
  name: mongodb-backup-run-1
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

# Watch until complete
kubectl get runaction mongodb-backup-run-1 -n kasten-io -w
```

---

## Step 9 — Restore MongoDB

Simulate data loss by deleting MongoDB:

```bash
helm uninstall mongo -n mongodb
kubectl delete namespace mongodb
```

Wait for the namespace to fully terminate before proceeding.

### Option A — Dashboard restore

1. In the dashboard, navigate to **Applications**.
2. Click the **mongodb** application card (it will appear as `removed`).
3. Under **Restore Points**, select the most recent exported `RestorePoint`.
4. Click **Restore** and confirm.

### Option B — kubectl-native restore

When the namespace is deleted, namespaced `RestorePoint` objects are removed, but cluster-scoped `RestorePointContent` objects persist. Restore using these steps:

```bash
# Find the exported RestorePointContent
EXPORTED_RPC=$(kubectl get restorepointcontent \
  -l k10.kasten.io/exportType=portableAppData \
  -o jsonpath='{.items[0].metadata.name}')
echo "Using: $EXPORTED_RPC"

# Recreate the namespace
kubectl create namespace mongodb

# Create a RestorePoint from the RestorePointContent
cat <<EOF | kubectl apply -f -
kind: RestorePoint
apiVersion: apps.kio.kasten.io/v1alpha1
metadata:
  name: mongodb-from-export
  namespace: mongodb
spec:
  restorePointContentRef:
    name: ${EXPORTED_RPC}
EOF

# Trigger the restore
cat <<EOF | kubectl apply -f -
kind: RestoreAction
apiVersion: actions.kio.kasten.io/v1alpha1
metadata:
  name: mongodb-restore-1
  namespace: mongodb
spec:
  targetNamespace: mongodb
  overwriteExisting: true
  subject:
    apiVersion: apps.kio.kasten.io/v1alpha1
    kind: RestorePoint
    name: mongodb-from-export
    namespace: mongodb
EOF

# Watch until complete
kubectl get restoreaction mongodb-restore-1 -n mongodb -w
```

Wait for the restore action to complete (`state: Complete`), then verify data:

```bash
export MONGODB_ROOT_PASSWORD=$(kubectl get secret mongo-mongodb \
  --namespace mongodb \
  -o jsonpath="{.data.mongodb-root-password}" | base64 --decode)

kubectl exec -it statefulset/mongo-mongodb -n mongodb \
  -- mongosh admin \
  --authenticationDatabase admin \
  -u root -p "$MONGODB_ROOT_PASSWORD" \
  --host "mongo-mongodb-0.mongo-mongodb-headless:27017,mongo-mongodb-1.mongo-mongodb-headless:27017" \
  --eval 'db.log.find()'
```

You should see both `card` and `dice` records returned.

---

## Validation Checkpoints

| # | Check | Expected Result |
|---|-------|-----------------|
| 1 | `kubectl get pods -n kasten-io` | All pods Running or Completed |
| 2 | `kubectl get svc gateway-nodeport -n kasten-io` | Service type NodePort, port 32000 |
| 3 | `kubectl get volumesnapshotclass csi-hostpath-snapclass -o yaml \| grep k10.kasten.io` | Annotation `k10.kasten.io/is-snapshot-class: "true"` present |
| 4 | `kubectl get profile s3-local -n kasten-io` | Profile exists |
| 5 | `kubectl get backupaction -n mongodb` | At least one `BackupAction` object present |
| 6 | `kubectl get exportaction -n mongodb` | At least one `ExportAction` object present |
| 7 | After restore: `kubectl get pods -n mongodb` | MongoDB pods Running |
| 8 | After restore: query `db.log.find()` | Both records returned |

---

## Tips & References

- [Kasten Documentation](https://docs.kasten.io)
- [Kasten pre-flight checks](https://docs.kasten.io/latest/install/storage.html#pre-flight-checks)
- [Kasten Helm install guide](https://docs.kasten.io/latest/install/index.html)
- [Kasten Policy API reference](https://docs.kasten.io/latest/api/policies.html)
- [MinIO Helm chart](https://github.com/minio/minio/tree/master/helm/minio)
- [Bitnami MongoDB Helm chart](https://github.com/bitnami/charts/tree/main/bitnami/mongodb)
- The `RunAction` approach demonstrated in Step 8 is important: it allows you to integrate Kasten backups into CI/CD pipelines and automation workflows using standard Kubernetes tooling.
- Kasten stores its metadata catalog in a PVC in the `kasten-io` namespace — the catalog is the heart of Kasten and must itself be protected (see Workshop 3 — Disaster Recovery).
