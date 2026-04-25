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
- For the DR recovery section: ability to create a **second kind cluster**

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
        image: mysql:8.0.26
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
kubectl exec -it mysql-0 -n mysql -- \
  mysql --user=root --password=ultrasecurepassword <<'SQL'
CREATE DATABASE test;
USE test;
CREATE TABLE pets (name VARCHAR(20), owner VARCHAR(20), species VARCHAR(20));
INSERT INTO pets VALUES ('Puffball','Diane','hamster');
SELECT * FROM pets;
SQL
```

Run the `label-backup` policy again and confirm **both** `mongodb` and `mysql` namespaces are backed up in the same policy run.

---

## Step 4 — Enable Kasten Disaster Recovery

The Kasten catalog must itself be backed up so you can recover after a total cluster loss.

In the Kasten dashboard:

1. **Settings → Disaster Recovery → Enable DR**
2. Provide:
   - **Location Profile:** `s3-local`
   - **Passphrase:** choose a strong passphrase and **store it safely** — without it the catalog cannot be decrypted
3. Click **Enable**.

Note the **Cluster ID** displayed — you will need it during recovery.

Via `kubectl`:
```bash
# The DR policy is created automatically, but you can also create it explicitly:
cat <<EOF | kubectl apply -f -
kind: Policy
apiVersion: config.kio.kasten.io/v1alpha1
metadata:
  name: k10-disaster-recovery-policy
  namespace: kasten-io
spec:
  frequency: "@hourly"
  retention:
    hourly: 24
  actions:
  - action: backup
    backupParameters:
      dataStore:
        profile:
          name: s3-local
          namespace: kasten-io
EOF
```

Run the DR policy:
```bash
cat <<EOF | kubectl apply -f -
kind: RunAction
apiVersion: actions.kio.kasten.io/v1alpha1
metadata:
  name: dr-run-1
  labels:
    k10.kasten.io/policyName: k10-disaster-recovery-policy
    k10.kasten.io/policyNamespace: kasten-io
spec:
  subject:
    apiVersion: config.kio.kasten.io/v1alpha1
    kind: Policy
    name: k10-disaster-recovery-policy
    namespace: kasten-io
EOF
```

Wait for it to complete and verify in MinIO that a `k10-dr` folder appears in your bucket.

---

## Step 5 — Simulate a Disaster

Delete everything from the primary cluster (simulating a catastrophic failure):

```bash
# Delete the applications
kubectl delete namespace mongodb mysql

# Delete Kasten itself
helm uninstall k10 -n kasten-io
kubectl delete namespace kasten-io

# Optionally delete the cluster entirely (for a full DR test)
# kind delete cluster --name kasten-training
```

---

## Step 6 — Recover on a New Cluster

### 6a. Create the recovery cluster (if you deleted the original)

```bash
# Re-run Workshop 0 steps, or:
cat <<EOF | kind create cluster --name kasten-recovery --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraMounts:
  - hostPath: /tmp/csi-data-dir
    containerPath: /csi-data-dir
EOF

# Re-install CSI driver and VolumeSnapshot support (see Workshop 0)
```

### 6b. Install Kasten on the recovery cluster

```bash
kubectl create namespace kasten-io

helm install k10 kasten/k10 \
  --namespace kasten-io \
  --wait
```

### 6c. Restore the Kasten catalog

The recommended approach since Kasten 7.5.0 is the dashboard **Disaster Recovery** restore flow:

1. Expose the Kasten dashboard on the recovery cluster (same NodePort + port-forward as Workshop 1 Step 3).
2. Open the Kasten dashboard and navigate to **Settings → Disaster Recovery → Restore Kasten Backup**.
3. Enter your object store credentials:
   - Cloud Storage Provider: S3 Compatible
   - S3 Endpoint: `http://minio.minio.svc.cluster.local:9000`
   - Access Key: `minioadmin`
   - Secret Key: `minioadmin`
   - Bucket: `lab-bucket-immutable`
4. Enter your **passphrase**.
5. The dashboard lists available DR backups from the `k10-dr/` prefix — select the most recent.
6. Click **Restore** and wait for completion.

You can list available DR backups with `mc` to identify the correct one:
```bash
mc ls local/lab-bucket-immutable/k10-dr/
```

> **Note:** The `k10restore` Helm chart is **deprecated since Kasten 7.5.0** and will be removed in a future release. Use the dashboard approach above. If you need the Helm-based method for scripting, see the [Kasten DR documentation](https://docs.kasten.io/latest/operating/dr.html) for the current CRD-based `KastenDRRestore` approach.

### 6d. Restore Applications

Once the catalog is restored, all your `RestorePoints` from the original cluster appear in the dashboard:

1. **Applications → mongodb → Restore Points** — select the most recent
2. **Restore** → confirm
3. Repeat for `mysql`

Validate data:
```bash
export MONGODB_ROOT_PASSWORD=$(kubectl get secret mongo-mongodb \
  --namespace mongodb -o jsonpath="{.data.mongodb-root-password}" | base64 --decode)

kubectl exec -it statefulset/mongo-mongodb -n mongodb \
  -- mongosh admin \
  --authenticationDatabase admin \
  -u root -p "$MONGODB_ROOT_PASSWORD" \
  --eval 'db.log.find()'

kubectl exec -it mysql-0 -n mysql -- \
  mysql --user=root --password=ultrasecurepassword \
  -e "USE test; SELECT * FROM pets;"
```

---

## Validation Checkpoints

| # | Check | Expected Result |
|---|-------|-----------------|
| 1 | `kubectl get namespace mongodb --show-labels` | Label `backup=true` present |
| 2 | `kubectl get namespace mysql --show-labels` | Label `backup=true` present |
| 3 | Dashboard → Policies → `label-backup` | Policy runs show both `mongodb` and `mysql` backed up |
| 4 | MinIO bucket → `k10-dr/` prefix | Catalog backup files present |
| 5 | After recovery: `kubectl get pods -n mongodb` | MongoDB running |
| 6 | After recovery: `kubectl get pods -n mysql` | MySQL running |
| 7 | After recovery: MongoDB query | `card` and `dice` records returned |
| 8 | After recovery: MySQL query | `Puffball` record returned |

---

## This workshop has challenges

- **The DR passphrase is irreplaceable.** Losing it means the catalog backup cannot be decrypted — full cluster recovery becomes impossible. Store it in a secrets manager (e.g. `pass`, Bitwarden, HashiCorp Vault) *before* running the DR exercise. Tip: `export DR_PASSPHRASE="my-secret"; echo $DR_PASSPHRASE` and keep your terminal open.
- **The `k10restore` Helm chart is deprecated (since Kasten 7.5.0).** If you have existing instructions referencing `helm install k10restore kasten/k10restore`, follow the dashboard UI restore flow described in Step 6c instead. The Helm chart still works for now but will be removed in a future release.
- **Running two Kind clusters simultaneously is resource-intensive.** Each cluster needs approximately 4–6 GB of RAM. Docker Desktop must have at least 12 GB allocated. If pods stay `Pending`, increase Docker Desktop memory in Settings → Resources → Memory.
- **After deleting Kasten (`helm uninstall k10 -n kasten-io`), the `kasten-io` namespace may take 1–3 minutes to fully terminate** due to finalizers on Kasten CRDs. Wait for `kubectl get namespace kasten-io` to disappear before recreating it.

---

## Tips & References

- [Kasten Disaster Recovery documentation](https://docs.kasten.io/latest/operating/dr.html)
- [Kasten label-based policy selection](https://docs.kasten.io/latest/usage/protect.html#selecting-applications-by-label)
- [k10restore Helm chart](https://docs.kasten.io/latest/operating/dr.html#restoring-kasten)
- The passphrase is **not recoverable** — store it in a password manager or secrets vault (e.g. HashiCorp Vault, AWS Secrets Manager)
- VolumeSnapshot data lives inside the cluster storage; the **exported** RestorePoint copies data to the external object store, making it portable to a new cluster. Always enable exports for DR scenarios.
- Kasten Multi-Cluster (Workshop 4) can automate ongoing imports to a warm standby cluster, significantly reducing RTO.
- The `k10.kasten.io/doNotRetire: "true"` label on `RunAction` objects prevents Kasten from retiring them from the dashboard — useful for debugging.
