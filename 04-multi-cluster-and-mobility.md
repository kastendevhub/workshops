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
- Access to both cluster dashboards (port-forwarded to different local ports)

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

## Step 2 — Enable Multi-Cluster Manager on the East (Primary)

> **Note:** The `k10multicluster` CLI tool was deprecated in Kasten 7.0.0. Multi-cluster setup is now done entirely through the Kasten dashboard UI.

Ensure the East Kasten dashboard is accessible:

```bash
kubectl port-forward svc/gateway-nodeport -n kasten-io 8080:8000 &
```

In the East Kasten dashboard:

1. Navigate to **Settings → Multi-Cluster Manager**.
2. Click **Enable Multi-Cluster Manager**.
3. Enter a name for the primary cluster (e.g. `cluster-east`) and confirm.

The East cluster is now the Multi-Cluster primary. Open the Multi-Cluster dashboard at [http://localhost:8080/k10/#/clusters](http://localhost:8080/k10/#/clusters).

---

## Step 3 — Add the West Cluster as Secondary

First, expose the West Kasten dashboard via a NodePort service and create a service account for the East→West trust relationship:

```bash
# Create the same NodePort service on West
cat <<EOF | kubectl --context=kind-kasten-west apply -f -
apiVersion: v1
kind: Service
metadata:
  name: gateway-nodeport
  namespace: kasten-io
spec:
  selector:
    service: gateway
  ports:
  - name: http
    port: 8000
    nodePort: 32000
  type: NodePort
EOF

# Port-forward West dashboard on a different local port
kubectl --context=kind-kasten-west \
  port-forward svc/gateway-nodeport -n kasten-io 8081:8000 &

# Create a service account on West for multi-cluster registration
kubectl --context=kind-kasten-west create serviceaccount k10-mc-east -n kasten-io
kubectl --context=kind-kasten-west create clusterrolebinding k10-mc-east \
  --clusterrole=k10-admin \
  --serviceaccount=kasten-io:k10-mc-east

# Generate a long-lived token for the service account
WEST_TOKEN=$(kubectl --context=kind-kasten-west \
  create token k10-mc-east -n kasten-io --duration=8760h)
echo "West token: $WEST_TOKEN"
```

Get the West Kasten URL that is reachable from East (must use Docker internal IP, not `localhost`):

```bash
WEST_IP=$(docker inspect kasten-west-control-plane \
  --format '{{ .NetworkSettings.Networks.kind.IPAddress }}')
echo "West Kasten URL: http://${WEST_IP}:32000/k10/"
```

In the **East** Kasten Multi-Cluster dashboard:

1. Click **Add Cluster**.
2. Fill in:
   | Field | Value |
   |-------|-------|
   | Cluster Name | `cluster-west` |
   | Kasten URL | `http://<WEST_IP>:32000/k10/` (replace `<WEST_IP>` from above) |
   | Service Account Token | paste `$WEST_TOKEN` |
3. Click **Add**.

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

## This workshop has challenges

- **The `k10multicluster` CLI is deprecated (since Kasten 7.0.0).** All multi-cluster registration is now done via the Kasten dashboard UI. The Steps 2–3 above reflect this. If you find older instructions referencing `k10multicluster setup-primary` or `k10multicluster bootstrap`, they no longer apply.
- **Kind clusters can only communicate via their Docker bridge network IP, not `localhost`.** The West Kasten URL that East can reach is `http://<WEST_DOCKER_IP>:32000/k10/`. Get the IP with `docker inspect kasten-west-control-plane --format '{{ .NetworkSettings.Networks.kind.IPAddress }}'`. Using `localhost` will cause the connection to fail silently.
- **Running two Kind clusters simultaneously is resource-intensive.** You need at least 12 GB of RAM allocated to Docker Desktop. If pods are stuck in `Pending`, open Docker Desktop → Settings → Resources → Memory and increase the limit.
- **Port-forwarding two dashboards at once** (East on 8080, West on 8081) can silently stop working if either `kubectl port-forward` process dies. If you get connection refused on a dashboard, re-run the respective port-forward command.
- **The receive string for Import Policies** is found in East's dashboard: Applications → `mongodb` → the policy's **Copy Receive String** action. It encodes the bucket path and must be pasted verbatim — any truncation will cause the import to fail with a cryptic error.

---

## Tips & References

- [Kasten Multi-Cluster documentation](https://docs.kasten.io/latest/multicluster/index.html)
- [Kasten Multi-Cluster setup guide](https://docs.kasten.io/latest/multicluster/index.html) — the `k10multicluster` CLI (deprecated in 7.0.0) has been replaced by dashboard-based registration
- [Kasten Transforms documentation](https://docs.kasten.io/latest/usage/migration.html#transforms)
- [Kasten Import Policy](https://docs.kasten.io/latest/usage/migration.html#import-policy)
- Multi-Cluster Manager is **optional** for migration — you can configure Export/Import policies independently on each cluster without the MCM UI. MCM simply provides a central management plane.
- Transforms use [JSON Patch (RFC 6902)](https://tools.ietf.org/html/rfc6902) syntax — `op` can be `add`, `remove`, `replace`, `copy`, `move`, or `test`.
- Setting `importParameters.receiveString` automates the Import policy to pull from a specific source export — without it, all exports in the bucket are visible.
- For a low-RTO strategy, automate the restore as part of the Import Policy itself (set `restoreClusterState: true` in the import parameters) to keep a warm standby always current.
