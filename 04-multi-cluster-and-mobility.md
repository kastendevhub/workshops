# Workshop 4 — Multi-Cluster Management & Application Mobility

**Based on Instruqt track: k10tt-am (Lab 4 — Veeam Kasten Training — Multi-Cluster & Application Mobility)**

---

## Goals

By the end of this workshop you will be able to:

- Enable **Kasten Multi-Cluster Manager** on a primary cluster
- Add a secondary cluster to be managed centrally
- Create a **Global Location Profile** and distribute it to all managed clusters
- Export a MongoDB backup from the source cluster and **import it** on a destination cluster
- Apply **Transforms** during restore to change StorageClass and replica count

---

## Migration Architecture

```
Source cluster (East):
  MongoDB ──backup──▶ ExportAction ──▶ Object Store (MinIO)

Destination cluster (West):
  ImportPolicy ─reads─▶ Object Store ──▶ RestorePoint catalog
  RestorePoint ──restore (+ Transforms)──▶ MongoDB (new config)
```

Transforms allow you to modify application metadata (StorageClass, annotations, replica count, image tags, etc.) during restore without modifying the original backup.

---

## Prerequisites

- Workshop 0 pattern: **two kind clusters** must be running:
  - `kasten-training` (East — source, already set up in Workshop 1)
  - `kasten-west` (West — destination, needs Workshop 0 setup)
- Kasten installed on **both** clusters
- `s3-local` Location Profile exists on the East cluster
- MongoDB with sample data running in `mongodb` namespace on East
- `k10multicluster` CLI tool (downloaded during the exercise below)

---

## Step 1 — Create the West Cluster

```bash
cat <<EOF | kind create cluster --name kasten-west --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraMounts:
  - hostPath: /tmp/csi-data-dir-west
    containerPath: /csi-data-dir
EOF
```

Apply Workshop 0 setup (CSI driver, VolumeSnapshot CRDs, annotation) to the West cluster:

```bash
kubectl config use-context kind-kasten-west

# Install CSI driver on west cluster
cd csi-driver-host-path && ./deploy/kubernetes-latest/deploy.sh && cd ..

# Install VolumeSnapshot CRDs
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml

kubectl annotate volumesnapshotclass csi-hostpath-snapclass \
  k10.kasten.io/is-snapshot-class="true"

# Install Kasten on West
kubectl create namespace kasten-io
helm install k10 kasten/k10 --namespace kasten-io --wait
```

Switch back to East:
```bash
kubectl config use-context kind-kasten-training
```

---

## Step 2 — Bootstrap Multi-Cluster on the East (Primary)

Download the `k10multicluster` tool:

```bash
# Get the Kasten version installed on East
K10_VERSION=$(helm list -n kasten-io -o json | jq '.[0].app_version' -r)
echo "Kasten version: $K10_VERSION"

# Download the multi-cluster tool
wget "https://github.com/kastenhq/external-tools/releases/download/${K10_VERSION}/k10multicluster_${K10_VERSION}_linux_amd64.tar.gz"
tar -xf k10multicluster_*_linux_amd64.tar.gz
chmod +x k10multicluster
```

Bootstrap East as Primary:

```bash
# Port-forward East Kasten dashboard
kubectl port-forward svc/gateway-nodeport -n kasten-io 8080:8000 &

./k10multicluster setup-primary \
  --context=kind-kasten-training \
  --name=cluster-east \
  --ingress=http://localhost:8080/k10/
```

Open the Multi-Cluster dashboard at [http://localhost:8080/k10/#/clusters](http://localhost:8080/k10/#/clusters).

---

## Step 3 — Add the West Cluster as Secondary

Get the West cluster's kubeconfig with an externally-accessible API server address:

```bash
# On a local kind setup, the API server is accessible via docker network
# Get the internal IP of the West control plane container
WEST_IP=$(docker inspect kasten-west-control-plane \
  --format '{{ .NetworkSettings.Networks.kind.IPAddress }}')
echo "West control plane IP: $WEST_IP"

# Export kubeconfig with the IP-based server address
kubectl config view --context=kind-kasten-west --raw \
  | sed "s|https://127.0.0.1:[0-9]*|https://${WEST_IP}:6443|g" \
  > west-kubeconfig.yaml

cat west-kubeconfig.yaml
```

Register the West cluster:

```bash
# Port-forward West Kasten dashboard on a different port
kubectl --context=kind-kasten-west \
  port-forward svc/gateway-nodeport -n kasten-io 8081:8000 &

./k10multicluster bootstrap \
  --primary-context=kind-kasten-training \
  --primary-name=cluster-east \
  --secondary-context=kind-kasten-west \
  --secondary-name=cluster-west \
  --secondary-ingress=http://localhost:8081/k10/ \
  --secondary-kubeconfig=west-kubeconfig.yaml
```

In the Multi-Cluster dashboard, confirm both `cluster-east` and `cluster-west` appear with a green status.

---

## Step 4 — Create and Distribute a Global Location Profile

A **Global Location Profile** is defined on the Primary cluster and can be pushed to all managed clusters via **Distributions**.

In the Multi-Cluster dashboard:
1. **Global Profiles → + New Profile**
2. Configure the same `s3-local` MinIO details from Workshop 1
3. Name it `global-s3`
4. Save the profile

Create a **Distribution** to push it to West:
1. **Distributions → + Create Distribution**
2. Select `global-s3` profile
3. Target: `cluster-west`
4. Apply

Verify on West cluster:
```bash
kubectl --context=kind-kasten-west get profile -n kasten-io
```
The `global-s3` profile should appear.

---

## Step 5 — Export MongoDB from East

On East, ensure you have an exported RestorePoint for MongoDB (run the policy from Workshop 1 if needed):

```bash
kubectl get exportaction -n mongodb
```

At least one ExportAction must be `Complete`.

---

## Step 6 — Create an Import Policy on West

An **Import Policy** tells Kasten on West to periodically pull RestorePoints from the object store and make them available locally.

```bash
kubectl --context=kind-kasten-west apply -f - <<EOF
kind: Policy
apiVersion: config.kio.kasten.io/v1alpha1
metadata:
  name: mongodb-import
  namespace: kasten-io
spec:
  frequency: "@hourly"
  actions:
  - action: import
    importParameters:
      profile:
        name: global-s3
        namespace: kasten-io
      receiveString: "<paste the export receive string from East here>"
EOF
```

> **Getting the receive string:** In the East Kasten dashboard → **Applications → mongodb → Export Policy → Copy Receive String**. It encodes the bucket path for West to import from.

Run the import policy once:
```bash
kubectl --context=kind-kasten-west apply -f - <<EOF
kind: RunAction
apiVersion: actions.kio.kasten.io/v1alpha1
metadata:
  name: import-run-1
  labels:
    k10.kasten.io/policyName: mongodb-import
    k10.kasten.io/policyNamespace: kasten-io
spec:
  subject:
    apiVersion: config.kio.kasten.io/v1alpha1
    kind: Policy
    name: mongodb-import
    namespace: kasten-io
EOF
```

After the import completes, the `mongodb` namespace should appear in West's Kasten dashboard with available RestorePoints.

---

## Step 7 — Restore with Transforms

Transforms modify application metadata at restore time. Common use cases:
- Change `StorageClass` (source uses `csi-hostpath-sc`, destination uses a different provisioner)
- Scale replicas down (restore to a smaller standby)
- Update image tags
- Change `Ingress` hostnames

### 7a. Create a TransformSet

```bash
kubectl --context=kind-kasten-west apply -f - <<EOF
kind: TransformSet
apiVersion: config.kio.kasten.io/v1alpha1
metadata:
  name: mongodb-migration-transforms
  namespace: kasten-io
spec:
  transforms:
  - subject:
      resource: statefulsets
    name: scale-to-one
    json:
    - op: replace
      path: /spec/replicas
      value: 1
EOF
```

### 7b. Restore with the TransformSet applied

In the West Kasten dashboard:
1. **Applications → mongodb → Restore Points** — select the imported point
2. Click **Restore**
3. Under **Transform Set**, select `mongodb-migration-transforms`
4. Confirm restore

Verify MongoDB on West:
```bash
export MONGODB_ROOT_PASSWORD=$(kubectl --context=kind-kasten-west \
  get secret mongo-mongodb --namespace mongodb \
  -o jsonpath="{.data.mongodb-root-password}" | base64 --decode)

kubectl --context=kind-kasten-west exec -it statefulset/mongo-mongodb \
  -n mongodb \
  -- mongosh admin \
  --authenticationDatabase admin \
  -u root -p "$MONGODB_ROOT_PASSWORD" \
  --eval 'db.log.find()'
```

Both records from East should appear on West.

---

## Validation Checkpoints

| # | Check | Expected Result |
|---|-------|-----------------|
| 1 | Multi-Cluster dashboard | Both `cluster-east` and `cluster-west` show green/connected |
| 2 | `kubectl --context=kind-kasten-west get profile -n kasten-io` | `global-s3` profile present |
| 3 | `kubectl --context=kind-kasten-west get restorepoint -n mongodb` | At least one RestorePoint from East |
| 4 | `kubectl --context=kind-kasten-west get pods -n mongodb` | MongoDB pods Running |
| 5 | MongoDB query on West | `card` and `dice` records returned |
| 6 | Check replica count on West | StatefulSet has 1 replica (transform applied) |

---

## Tips & References

- [Kasten Multi-Cluster documentation](https://docs.kasten.io/latest/multicluster/index.html)
- [k10multicluster releases](https://github.com/kastenhq/external-tools/releases)
- [Kasten Transforms documentation](https://docs.kasten.io/latest/usage/migration.html#transforms)
- [Kasten Import Policy](https://docs.kasten.io/latest/usage/migration.html#import-policy)
- Multi-Cluster Manager is **optional** for migration — you can configure Export/Import policies independently on each cluster without the MCM UI. MCM simply provides a central management plane.
- Transforms use [JSON Patch (RFC 6902)](https://tools.ietf.org/html/rfc6902) syntax — `op` can be `add`, `remove`, `replace`, `copy`, `move`, or `test`.
- Setting `importParameters.receiveString` automates the Import policy to pull from a specific source export — without it, all exports in the bucket are visible.
- For a low-RTO strategy, automate the restore as part of the Import Policy itself (set `restoreClusterState: true` in the import parameters) to keep a warm standby always current.
