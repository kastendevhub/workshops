# Workshop 0 — Kubernetes Environment Setup

**Mandatory prerequisite for all other workshops.**

---

## Goals

By the end of this workshop you will have a local Kubernetes cluster that:

- Runs on your laptop using Docker Desktop and `kind`
- Provides a CSI storage driver that supports `VolumeSnapshot`
- Has the VolumeSnapshot API (CRDs + controller) installed and ready
- Has a `VolumeSnapshotClass` annotated for use with Kasten

All subsequent workshops assume this environment is in place.

---

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) running (at least 8 GB RAM and 4 CPUs allocated)
- `kind` ≥ 0.20 — [install guide](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- `kubectl` — [install guide](https://kubernetes.io/docs/tasks/tools/)
- `helm` ≥ 3.12 — [install guide](https://helm.sh/docs/intro/install/)

---

## Step 1 — Create the Kind Cluster

The cluster needs to expose specific host paths so the CSI hostpath driver can provision volumes.

```bash
cat <<EOF | kind create cluster --name kasten-training --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraMounts:
  - hostPath: /tmp/csi-data-dir
    containerPath: /csi-data-dir
EOF
```

Verify the cluster is running:

```bash
kubectl cluster-info --context kind-kasten-training
kubectl get nodes
```

You should see one node in `Ready` state.

---

## Step 2 — Install the CSI Hostpath Driver

The [CSI Hostpath Driver](https://github.com/kubernetes-csi/csi-driver-host-path) is a reference implementation that supports `VolumeSnapshot`. It is used extensively in Kubernetes CSI testing and is ideal for local training.

```bash
# Clone the CSI driver repository
git clone https://github.com/kubernetes-csi/csi-driver-host-path.git
cd csi-driver-host-path

# Deploy the driver (tested against v1.13.x)
./deploy/kubernetes-latest/deploy.sh

cd ..
```

Wait for all pods to become ready:

```bash
kubectl wait pods -n default -l app=csi-hostpathplugin --for=condition=Ready --timeout=120s
```

Verify the StorageClass was created:

```bash
kubectl get storageclass
```

You should see `csi-hostpath-sc` listed. Make it the default:

```bash
kubectl patch storageclass csi-hostpath-sc \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# Remove default from any pre-existing standard/local-path class if present
kubectl patch storageclass standard \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' 2>/dev/null || true
```

---

## Step 3 — Install the VolumeSnapshot CRDs and Controller

Kind does not include the VolumeSnapshot API by default. Install it from the upstream snapshot controller repository.

```bash
# Install the VolumeSnapshot CRDs
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml

# Install the snapshot controller
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml
```

Wait for the snapshot controller to start:

```bash
kubectl wait pods -n kube-system -l app=snapshot-controller --for=condition=Ready --timeout=120s
```

---

## Step 4 — Create and Annotate the VolumeSnapshotClass

The CSI hostpath driver installs its own `VolumeSnapshotClass`. Verify it exists and annotate it for Kasten:

```bash
kubectl get volumesnapshotclass
```

You should see `csi-hostpath-snapclass`. Annotate it so Kasten's pre-flight checks recognise it:

```bash
kubectl annotate volumesnapshotclass csi-hostpath-snapclass \
  k10.kasten.io/is-snapshot-class="true"
```

---

## Validation Checkpoints

Run all of the following checks before moving to Workshop 1.

**1. Cluster is reachable:**
```bash
kubectl cluster-info
```
Expected: control plane URL shown, no errors.

**2. CSI driver pods are running:**
```bash
kubectl get pods -l app=csi-hostpathplugin
```
Expected: pod in `Running` state with all containers ready.

**3. Default StorageClass is `csi-hostpath-sc`:**
```bash
kubectl get storageclass
```
Expected: `csi-hostpath-sc` has `(default)` next to it.

**4. VolumeSnapshot CRDs are installed:**
```bash
kubectl get crd | grep snapshot
```
Expected: `volumesnapshots`, `volumesnapshotcontents`, and `volumesnapshotclasses` all appear.

**5. Snapshot controller is running:**
```bash
kubectl get pods -n kube-system -l app=snapshot-controller
```
Expected: pod in `Running` state.

**6. VolumeSnapshotClass is annotated:**
```bash
kubectl get volumesnapshotclass csi-hostpath-snapclass -o yaml | grep k10.kasten.io
```
Expected: `k10.kasten.io/is-snapshot-class: "true"` is present.

**7. End-to-end snapshot test (optional but recommended):**
```bash
# Create a PVC
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
  storageClassName: csi-hostpath-sc
EOF

# Wait for it to bind
kubectl wait pvc/test-pvc --for=jsonpath='{.status.phase}'=Bound --timeout=60s

# Create a snapshot
kubectl apply -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: test-snapshot
spec:
  volumeSnapshotClassName: csi-hostpath-snapclass
  source:
    persistentVolumeClaimName: test-pvc
EOF

kubectl wait volumesnapshot/test-snapshot --for=jsonpath='{.status.readyToUse}'=true --timeout=60s
echo "Snapshot test passed!"

# Clean up
kubectl delete volumesnapshot test-snapshot
kubectl delete pvc test-pvc
```

---

## Tips & References

- [kind Quick Start](https://kind.sigs.k8s.io/docs/user/quick-start/)
- [CSI Hostpath Driver](https://github.com/kubernetes-csi/csi-driver-host-path)
- [Kubernetes CSI VolumeSnapshot documentation](https://kubernetes.io/docs/concepts/storage/volume-snapshots/)
- [External Snapshotter (upstream CRDs + controller)](https://github.com/kubernetes-csi/external-snapshotter)
- Kasten pre-flight check tool: `kubectl kasten preflightchecks` — see Workshop 1 for details
- Docker Desktop RAM settings: Docker Desktop → Settings → Resources → Memory (set to at least 8 GB)
- If `kind create cluster` hangs, ensure Docker Desktop is running and has sufficient resources.
