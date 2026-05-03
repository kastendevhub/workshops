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
  - `kasten-west` (West — destination, set up in Step 1 below)
- Kasten installed on **both** clusters
- `s3-local` Location Profile exists on the East cluster
- MongoDB with sample data running in `mongodb` namespace on East
- Access to both cluster dashboards:
  - East: `http://localhost:8080/k10/` via `kubectl port-forward`
  - West: `http://localhost:8081/k10/` directly — no port-forward needed (kind `extraPortMappings` handles it)

---

## Quick Resume

If you are returning to this workshop with both clusters already running:

```bash
# East cluster — port-forward needed (no extraPortMappings in the Workshop 0 kind config)
# http://localhost:8080/k10/
kubectl --context=kind-kasten-training port-forward svc/gateway-nodeport -n kasten-io 8080:8000 &

# West cluster — no port-forward needed; extraPortMappings in the kind config binds
# containerPort 32080 → hostPort 8081 on localhost automatically.
# http://localhost:8081/k10/

# MinIO (on East cluster)
kubectl --context=kind-kasten-training port-forward svc/minio -n minio 9000:9000 &
mc alias set local http://localhost:9000 minioadmin minioadmin
```

> **Why two different access methods?** See the Docker bridge explanation in Step 2.

---

## Step 1 — Create the West Cluster

The kind config includes `extraPortMappings` so that the West Kasten dashboard is reachable at `http://localhost:8081/k10/` from your Mac browser without any port-forward.

```bash
cat <<EOF | kind create cluster --name kasten-west --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraMounts:
  - hostPath: /tmp/csi-data-dir-west
    containerPath: /csi-data-dir
  extraPortMappings:
  - containerPort: 32080
    hostPort: 8081
    listenAddress: "0.0.0.0"
    protocol: TCP
EOF
```

Apply Workshop 0 setup (VolumeSnapshot CRDs, CSI driver, StorageClass, annotation) to the West cluster:

```bash
kubectl config use-context kind-kasten-west

# Install VolumeSnapshot CRDs first — the CSI driver deploy script creates a VolumeSnapshotClass
# at the end and will fail with CRD-not-found if these are not already present
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml

kubectl wait pods -n kube-system -l app.kubernetes.io/name=snapshot-controller --for=condition=Ready --timeout=120s

# Install CSI driver — creates the VolumeSnapshotClass
cd csi-driver-host-path && ./deploy/kubernetes-latest/deploy.sh && cd ..

kubectl wait pods -n default -l app.kubernetes.io/name=csi-hostpathplugin --for=condition=Ready --timeout=120s

# Create StorageClass and set as default
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: csi-hostpath-sc
provisioner: hostpath.csi.k8s.io
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
EOF

kubectl patch storageclass csi-hostpath-sc \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

kubectl patch storageclass standard \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' 2>/dev/null || true

# Annotate the VolumeSnapshotClass for Kasten
kubectl annotate volumesnapshotclass csi-hostpath-snapclass \
  k10.kasten.io/is-snapshot-class="true"

# Install Kasten on West
kubectl create namespace kasten-io
helm install k10 kasten/k10 --namespace kasten-io --wait

# Expose Kasten gateway on NodePort 32080 — matches the extraPortMappings above
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: gateway-nodeport
  namespace: kasten-io
spec:
  selector:
    service: gateway
  type: NodePort
  ports:
  - name: http
    port: 8000
    targetPort: 8000
    nodePort: 32080
    protocol: TCP
EOF
```

The West Kasten dashboard is now accessible at `http://localhost:8081/k10/` — no port-forward required.

Switch back to East:
```bash
kubectl config use-context kind-kasten-training
```

---

## Step 2 — Bootstrap the Primary (East) via CLI

### Understanding the Docker bridge network

Before configuring multi-cluster, it is important to understand how kind clusters communicate — and why using `localhost` in Kasten URLs will never work here.

Each kind "node" is a Docker container. All kind containers are connected to the same Docker bridge network (the `kind` network, typically `172.18.0.0/16`). Because of this:

- **A pod inside the East cluster can reach the West cluster** using the West node's Docker container IP and a NodePort. The pod sends traffic to its default gateway (the East node), which is itself on the `kind` bridge and can forward to `172.18.0.x`.
- **`localhost` inside a pod means the pod itself**, not the host machine — so `localhost:8081` from a pod in East resolves to nothing useful.
- **From your Mac browser, `172.18.0.x` is not reachable.** Docker Desktop runs containers inside a Linux VM. The Docker bridge network exists inside that VM and has no route to your macOS host network. This is why `extraPortMappings` was added to the West kind config: it binds `localhost:8081` on macOS to the West container's port 32080, making the West dashboard accessible from your browser without a port-forward.
- **East has no `extraPortMappings`** (it was created in Workshop 0). Its dashboard is reached from the Mac via `kubectl port-forward` as usual.

In summary:

| Who is connecting | To what | URL to use |
|---|---|---|
| Your Mac browser → East dashboard | via port-forward | `http://localhost:8080/k10/` |
| Your Mac browser → West dashboard | via extraPortMappings | `http://localhost:8081/k10/` |
| East Kasten pods → West Kasten | Docker bridge | `http://<west-docker-ip>:32080/k10/` |
| West Kasten pods → East Kasten | Docker bridge | `http://<east-docker-ip>:32080/k10/` |

### Expose East Kasten via NodePort and bootstrap the primary

```bash
# Expose East Kasten on a NodePort so West cluster pods can reach it
cat <<EOF | kubectl --context=kind-kasten-training apply -f -
apiVersion: v1
kind: Service
metadata:
  name: gateway-nodeport
  namespace: kasten-io
spec:
  selector:
    service: gateway
  type: NodePort
  ports:
  - name: http
    port: 8000
    targetPort: 8000
    nodePort: 32080
    protocol: TCP
EOF

# Get the East node's Docker bridge IP — this is the URL West pods will use to reach East
EAST_IP=$(docker inspect kasten-training-control-plane \
  --format '{{.NetworkSettings.Networks.kind.IPAddress}}')
echo "East Docker IP: ${EAST_IP}"

# Create the multi-cluster namespace and bootstrap the primary
kubectl --context=kind-kasten-training create namespace kasten-io-mc

cat <<EOF | kubectl --context=kind-kasten-training apply -f -
apiVersion: dist.kio.kasten.io/v1alpha1
kind: Bootstrap
metadata:
  name: bootstrap-primary
  namespace: kasten-io-mc
spec:
  clusters:
    cluster-east:
      name: cluster-east
      primary: true
      k10:
        namespace: kasten-io
        releaseName: k10
        ingress:
          url: http://${EAST_IP}:32080/k10/
EOF
```

Verify a `Cluster` object was created for the primary:

```bash
kubectl --context=kind-kasten-training get clusters -n kasten-io-mc
# Expected: cluster-east   <age>
```

---

## Step 3 — Join West as Secondary via CLI

### Create a join token on the Primary (East)

```bash
# Use `create` not `apply` — generateName is not supported with apply
cat <<EOF | kubectl --context=kind-kasten-training create -f -
apiVersion: v1
kind: Secret
metadata:
  generateName: join-token-secret-
  namespace: kasten-io-mc
type: dist.kio.kasten.io/join-token
EOF
```

The controller auto-populates the token data. Retrieve it:

```bash
# List token secrets to find the generated name
kubectl --context=kind-kasten-training get secrets -n kasten-io-mc \
  --field-selector type=dist.kio.kasten.io/join-token

JOIN_TOKEN_SECRET=$(kubectl --context=kind-kasten-training get secrets -n kasten-io-mc \
  --field-selector type=dist.kio.kasten.io/join-token \
  -o jsonpath='{.items[0].metadata.name}')

JOIN_TOKEN=$(kubectl --context=kind-kasten-training get secret ${JOIN_TOKEN_SECRET} \
  -n kasten-io-mc -o jsonpath='{.data.token}')

echo "Token secret: ${JOIN_TOKEN_SECRET}"
echo "Token (encoded): ${JOIN_TOKEN:0:40}..."
```

### Apply the join on the Secondary (West)

```bash
WEST_IP=$(docker inspect kasten-west-control-plane \
  --format '{{.NetworkSettings.Networks.kind.IPAddress}}')
EAST_IP=$(docker inspect kasten-training-control-plane \
  --format '{{.NetworkSettings.Networks.kind.IPAddress}}')

# mc-join secret carries the token from the Primary
cat <<EOF | kubectl --context=kind-kasten-west apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: mc-join
  namespace: kasten-io
data:
  token: ${JOIN_TOKEN}
EOF

# mc-join-config tells Kasten the cluster names and ingress URLs
# allow-insecure-primary-ingress is required because we use plain HTTP in this lab
cat <<EOF | kubectl --context=kind-kasten-west apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: mc-join-config
  namespace: kasten-io
data:
  cluster-name: cluster-west
  cluster-ingress: http://${WEST_IP}:32080/k10/
  primary-ingress: http://${EAST_IP}:32080/k10/
  allow-insecure-primary-ingress: "true"
EOF
```

> **Why `allow-insecure-primary-ingress: "true"`?** Kasten rejects HTTP primary ingress by default for security reasons. In a production environment the primary ingress URL must be HTTPS. For this lab we explicitly opt in to HTTP. Note that this option only works via the CLI path — the UI does not allow adding a secondary over plain HTTP.

### Validate the join

Poll `mc-join-status` on West until `status: joined` appears:

```bash
kubectl --context=kind-kasten-west get secret mc-join-status \
  -n kasten-io -o jsonpath='{.data.status}' | base64 -d
# Expected: joined
```

Inspect the full join outcome:

```bash
kubectl --context=kind-kasten-west get secret mc-join-status \
  -n kasten-io -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'
```

Confirm the `mc-cluster-info` secret was created on West with the cluster identity:

```bash
kubectl --context=kind-kasten-west get secret mc-cluster-info \
  -n kasten-io -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}' \
  2>/dev/null | grep -v "^$"
# Expected fields: clusterName, endpoint, primaryIngress, primaryName
```

Confirm both clusters appear on East:

```bash
kubectl --context=kind-kasten-training get clusters -n kasten-io-mc
# Expected:
# NAME           AGE
# cluster-east   <age>
# cluster-west   <age>
```

### Challenge — Disconnect and reconnect West via the UI

You have just registered West using the CLI. Now use the **East Kasten Multi-Cluster dashboard** to:

1. Disconnect `cluster-west` from the primary.
2. Reconnect it — this time using the UI instead of the CLI.

Open the East dashboard at `http://localhost:8080/k10/` (port-forward required) and navigate to **Settings → Multi-Cluster Manager**. The CLI steps above should give you enough understanding to work through the UI independently.

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
cat <<EOF | kubectl --context=kind-kasten-west apply -f -
kind: RunAction
apiVersion: actions.kio.kasten.io/v1alpha1
metadata:
  name: import-run-1
  namespace: kasten-io
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

After the import completes, `RestorePointContent` objects appear on West (cluster-scoped). In the dashboard, `mongodb` will appear as a "removed" application with available RestorePoints.

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

**Option A — Dashboard restore:**
1. **Applications → mongodb → Restore Points** — select the imported point
2. Click **Restore**
3. Under **Transform Set**, select `mongodb-migration-transforms`
4. Confirm restore

**Option B — kubectl-native restore:**
```bash
# Create the target namespace
kubectl --context=kind-kasten-west create namespace mongodb

# Bind the imported RestorePointContent to a namespaced RestorePoint
MONGODB_RPC=$(kubectl --context=kind-kasten-west get restorepointcontent \
  -l k10.kasten.io/appNamespace=mongodb,k10.kasten.io/exportType=portableAppData \
  -o jsonpath='{.items[0].metadata.name}')

cat <<EOF | kubectl --context=kind-kasten-west apply -f -
kind: RestorePoint
apiVersion: apps.kio.kasten.io/v1alpha1
metadata:
  name: mongodb-from-import
  namespace: mongodb
spec:
  restorePointContentRef:
    name: ${MONGODB_RPC}
EOF

# Restore with the TransformSet
cat <<EOF | kubectl --context=kind-kasten-west apply --validate=false -f -
kind: RestoreAction
apiVersion: actions.kio.kasten.io/v1alpha1
metadata:
  name: mongodb-restore-west-1
  namespace: mongodb
spec:
  targetNamespace: mongodb
  overwriteExisting: true
  transforms:
  - transformSetRef:
      name: mongodb-migration-transforms
      namespace: kasten-io
  subject:
    apiVersion: apps.kio.kasten.io/v1alpha1
    kind: RestorePoint
    name: mongodb-from-import
    namespace: mongodb
EOF

kubectl --context=kind-kasten-west get restoreaction mongodb-restore-west-1 -n mongodb
```

> **Note:** `kubectl apply` requires `--validate=false` when using `transformSetRef` inside `transforms[]` because the local schema marks `json` as required even though it is optional when `transformSetRef` is used.

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

Verify the transform was applied — the StatefulSet should have 1 replica instead of East's 2:
```bash
kubectl --context=kind-kasten-west get statefulset mongo-mongodb -n mongodb \
  -o jsonpath='{.spec.replicas}'
# Expected: 1
```

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

- **Kind clusters communicate via Docker bridge IPs, not `localhost`.** All kind nodes are Docker containers on the same `kind` bridge network (`172.18.0.0/16`). A pod inside East can reach the West node's IP because its default gateway (the East node) is on the same bridge. `localhost` inside a pod means the pod itself and is useless for cross-cluster traffic. See the full explanation in Step 2.
- **`localhost` URLs work from your Mac browser only via port-forward or `extraPortMappings`.** The `172.18.0.x` addresses exist inside Docker Desktop's Linux VM and are not routable from macOS. `extraPortMappings` binds a container port to `localhost` on the Mac (used here for West), while `kubectl port-forward` does the same on demand (used for East).
- **`allow-insecure-primary-ingress: "true"` is required for plain HTTP primaries.** Kasten rejects HTTP primary ingress URLs by default. This flag must be set in `mc-join-config` on the secondary. It is only supported via the CLI join path — the UI requires HTTPS.
- **The `global-s3` profile on West must use East's Docker bridge IP for MinIO, not the Kubernetes service DNS name.** `minio.minio.svc.cluster.local:9000` only resolves inside the East cluster. From West, MinIO must be reached via a NodePort on East. Create one if it does not already exist: `kubectl --context=kind-kasten-training expose svc/minio -n minio --type=NodePort --name=minio-nodeport`, then use `http://<EAST_DOCKER_IP>:<nodeport>` in the Location Profile on West.
- **The `RunAction` namespace field is required in Kasten 8.x.** The `RunAction` metadata must include `namespace: kasten-io`. Without it, the resource is created in the wrong namespace and the policy reference does not resolve.
- **`kubectl apply` rejects `transformSetRef` inside `transforms[]` without `--validate=false`.** The client-side schema marks `json` as required within `TransformOrRef`, even though it is optional when a `transformSetRef` is provided. Use `--validate=false` to bypass this client-side validation error.
- **Running two Kind clusters simultaneously is resource-intensive.** You need at least 12 GB of RAM allocated to Docker Desktop. If pods are stuck in `Pending`, open Docker Desktop → Settings → Resources → Memory and increase the limit.
- **The East port-forward can silently die.** If you get connection refused on `localhost:8080`, re-run `kubectl --context=kind-kasten-training port-forward svc/gateway-nodeport -n kasten-io 8080:8000 &`. The West dashboard does not have this problem — it uses `extraPortMappings`.
- **The receive string for Import Policies** is found in East's dashboard: Applications → `mongodb` → the policy's **Copy Receive String** action. It encodes the bucket path and must be pasted verbatim — any truncation will cause the import to fail with a cryptic error.

---

## Tips & References

- [Kasten Multi-Cluster documentation](https://docs.kasten.io/latest/multicluster/index.html)
- [Kasten Multi-Cluster CLI setup](https://docs.kasten.io/latest/multicluster/getting_started#setting-up-via-cli) — Bootstrap, join tokens, and mc-join-config reference
- [Allowing HTTP primary ingress](https://docs.kasten.io/latest/multicluster/how-tos/http_primary_ingress_connection/) — lab-only, not for production
- [Kasten Transforms documentation](https://docs.kasten.io/latest/usage/migration.html#transforms)
- [Kasten Import Policy](https://docs.kasten.io/latest/usage/migration.html#import-policy)
- Multi-Cluster Manager is **optional** for migration — you can configure Export/Import policies independently on each cluster without the MCM UI. MCM simply provides a central management plane.
- Transforms use [JSON Patch (RFC 6902)](https://tools.ietf.org/html/rfc6902) syntax — `op` can be `add`, `remove`, `replace`, `copy`, `move`, or `test`.
- Setting `importParameters.receiveString` automates the Import policy to pull from a specific source export — without it, all exports in the bucket are visible.
- For a low-RTO strategy, automate the restore as part of the Import Policy itself (set `restoreClusterState: true` in the import parameters) to keep a warm standby always current.
