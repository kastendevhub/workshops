# Workshop 6 — Air-Gapped Installation

**Based on Instruqt track: k10tt-ag (Lab 6 — Veeam Kasten Training — Air-Gapped Install)**

---

## Goals

By the end of this workshop you will be able to:

- Deploy an **NFS server** and mount an NFS share on a Kubernetes node
- Deploy a **private Docker Registry** with HTTP basic authentication
- Mirror Kasten container images into the private registry
- Install Kasten from the private registry (no Internet access required)
- Create an **NFS Location Profile** in Kasten
- Backup a MongoDB workload using the NFS-backed profile

---

## Air-Gapped Architecture

In secure or regulated environments, Kubernetes clusters may have **no outbound Internet access**. This creates two challenges:

1. **Container images** — where to pull them from
2. **Object storage for backups** — public cloud is inaccessible

This workshop addresses both:
- A **private registry** on a separate host serves all container images
- An **NFS server** acts as the backup location profile target

```
Internet-isolated cluster:
  ┌────────────────────────────────────┐
  │  Kubernetes (kind-kasten-training) │
  │  pulls images from ─────────────────────────▶ Private Registry (:5000)
  │  backs up to ───────────────────────────────▶ NFS Server (/nfs)
  └────────────────────────────────────┘
```

In this workshop we simulate the "infra" host with Docker containers and local mounts.

---

## Prerequisites

- Workshop 0 completed (kind cluster with CSI + VolumeSnapshot)
- Workshop 1 completed (MongoDB running in `mongodb` namespace with sample data)
- `docker` installed on your laptop
- `nfs-kernel-server` (Linux) or NFS server emulation available
  - On macOS, use Docker to run an NFS server container (instructions below)
- `helm`, `kubectl`, `jq` installed

---

## Part 1 — Deploy an NFS Server

### On Linux (native NFS server)

```bash
sudo apt-get update
sudo apt-get install -y nfs-kernel-server

sudo mkdir -p /nfs
sudo chown nobody:nogroup /nfs

# Export to the docker bridge network (kind uses 172.18.0.0/16 by default)
echo "/nfs 172.18.0.0/16(rw,sync,no_subtree_check,no_root_squash)" | sudo tee -a /etc/exports

sudo exportfs -a
sudo systemctl restart nfs-kernel-server
```

### On macOS (NFS server via Docker)

```bash
# Use a containerized NFS server
docker run -d \
  --name nfs-server \
  --privileged \
  -e NFS_EXPORT_0='/nfs *(rw,sync,no_subtree_check,no_root_squash)' \
  -v /tmp/nfs-data:/nfs \
  -p 2049:2049 \
  erichough/nfs-server

# Get the NFS server IP
NFS_SERVER_IP=$(docker inspect nfs-server --format '{{ .NetworkSettings.IPAddress }}')
echo "NFS server IP: $NFS_SERVER_IP"
```

### Test NFS from the kind node

```bash
# Exec into the kind control-plane container
docker exec -it kasten-training-control-plane bash

# Install NFS client
apt-get update && apt-get install -y nfs-common

# Mount the NFS share (replace NFS_SERVER_IP)
mkdir -p /mnt/nfs
mount <NFS_SERVER_IP>:/nfs /mnt/nfs

# Write a test file
echo "NFS works!" > /mnt/nfs/test
cat /mnt/nfs/test

# Unmount (we'll use a PV for Kasten)
umount /mnt/nfs
exit
```

---

## Part 2 — Create an NFS PersistentVolume for the NFS Profile

Kasten's NFS Location Profile uses a PVC. Create a PV backed by the NFS export:

```bash
NFS_SERVER_IP=<your-nfs-server-ip>

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: nfs-pv
spec:
  capacity:
    storage: 20Gi
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Retain
  nfs:
    path: /nfs
    server: ${NFS_SERVER_IP}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nfs-pvc
  namespace: kasten-io
spec:
  accessModes: [ReadWriteMany]
  resources:
    requests:
      storage: 20Gi
  volumeName: nfs-pv
EOF
```

Verify the PVC is bound:
```bash
kubectl get pvc nfs-pvc -n kasten-io
```

---

## Part 3 — Deploy a Private Docker Registry

```bash
# Create an auth file with bcrypt-hashed credentials
mkdir -p /tmp/registry-auth
docker run --entrypoint htpasswd httpd:2 \
  -Bbn testuser testpassword > /tmp/registry-auth/htpasswd

# Start the registry
docker run -d \
  --name private-registry \
  -p 5000:5000 \
  --restart always \
  -v /tmp/registry-auth:/auth \
  -e REGISTRY_AUTH=htpasswd \
  -e REGISTRY_AUTH_HTPASSWD_REALM="Registry Realm" \
  -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
  registry:2

# Verify it's running
docker ps --filter name=private-registry
```

Get the registry IP:
```bash
REGISTRY_IP=$(docker inspect private-registry --format '{{ .NetworkSettings.IPAddress }}')
echo "Registry IP: $REGISTRY_IP"
REGISTRY="${REGISTRY_IP}:5000"
```

Login to the registry:
```bash
docker login ${REGISTRY} -u testuser -p testpassword
```

---

## Part 4 — Configure the Kind Cluster to Use the Private Registry

Kind nodes need to know about the insecure private registry:

```bash
# Create a containerd registry config in the kind node
docker exec kasten-training-control-plane bash -c "
mkdir -p /etc/containerd/certs.d/${REGISTRY}
cat > /etc/containerd/certs.d/${REGISTRY}/hosts.toml << EOF
[host.\"http://${REGISTRY}\"]
  capabilities = [\"pull\", \"resolve\"]
  skip_verify = true
EOF
"

# Restart containerd in the kind node
docker exec kasten-training-control-plane systemctl restart containerd
```

Test with a sample image:
```bash
# Pull alpine on the host and push to private registry
docker pull alpine
docker tag alpine ${REGISTRY}/alpine
docker push ${REGISTRY}/alpine

# Create a pod using the private registry image
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: airgapped-test
spec:
  containers:
  - name: alpine
    image: ${REGISTRY}/alpine
    command: ["tail", "-f", "/dev/null"]
EOF

kubectl wait pod/airgapped-test --for=condition=Ready --timeout=60s
kubectl delete pod airgapped-test
```

---

## Part 5 — Mirror Kasten Images to the Private Registry

> **Note:** The `k10offline` tool was deprecated in Kasten 7.5.0 and replaced by `k10tools image`. The new tool ships as a container image — no binary download needed.

```bash
# Determine the Kasten version (same version used for the Helm install)
K10_VERSION=$(helm search repo kasten/k10 --output json | jq -r '.[0].app_version')
echo "Kasten version: $K10_VERSION"

# Use k10tools to copy all Kasten images to the private registry
# k10tools handles image discovery, pulling, retagging and pushing automatically
docker run --rm \
  gcr.io/kasten-images/k10tools:${K10_VERSION} \
  image copy \
  --registry ${REGISTRY} \
  --username testuser \
  --password testpassword \
  --insecure-registry
```

> **Alternative manual approach** — if you need to mirror images without running a container (fully air-gapped host):
> ```bash
> # List all images required by the current Kasten version
> docker run --rm gcr.io/kasten-images/k10tools:${K10_VERSION} image list
>
> # For each image in the list, pull, retag and push:
> docker pull gcr.io/kasten-images/executor:${K10_VERSION}
> docker tag gcr.io/kasten-images/executor:${K10_VERSION} ${REGISTRY}/executor:${K10_VERSION}
> docker push ${REGISTRY}/executor:${K10_VERSION}
> # ... (repeat for all images — the list changes with each release, so always use `image list`)
> ```

---

## Part 6 — Install Kasten from the Private Registry

```bash
helm repo add kasten https://charts.kasten.io/
helm repo update

kubectl create namespace kasten-io

helm install k10 kasten/k10 \
  --namespace kasten-io \
  --set global.airgapped.repository=${REGISTRY} \
  --set global.airgapped.image.pullSecret="" \
  --version ${K10_VERSION} \
  --wait
```

If the registry requires authentication, create an image pull secret first:

```bash
kubectl create secret docker-registry registry-secret \
  --namespace kasten-io \
  --docker-server=${REGISTRY} \
  --docker-username=testuser \
  --docker-password=testpassword

# Reference it in the helm install
helm install k10 kasten/k10 \
  --namespace kasten-io \
  --set global.airgapped.repository=${REGISTRY} \
  --set global.pullSecrets[0]=registry-secret \
  --version ${K10_VERSION} \
  --wait
```

Verify all Kasten pods start from the private registry:
```bash
kubectl get pods -n kasten-io -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' | sort -u
```

All image references should point to your `${REGISTRY}` address.

---

## Part 7 — Create an NFS Location Profile

```bash
cat <<EOF | kubectl apply -f -
kind: Profile
apiVersion: config.kio.kasten.io/v1alpha1
metadata:
  name: nfs-profile
  namespace: kasten-io
spec:
  locationSpec:
    fileStore:
      claimName: nfs-pvc
      subPath: kasten-backups
    type: FileStore
  type: Location
EOF
```

Validate the profile in the Kasten dashboard under **Settings → Location** — it should show a green checkmark.

---

## Part 8 — Backup MongoDB to NFS

In the Kasten dashboard:

1. **Policies → + Create New Policy**
2. Configure:
   - Name: `mongodb-nfs-backup`
   - Application: `mongodb` namespace
   - Backup Frequency: Hourly
   - Enable exports: ✓
   - Export Location Profile: `nfs-profile`
3. **Create → Run Once → Yes, Continue**

Monitor the policy run. After completion, verify backup files on the NFS server:

```bash
# Check NFS export directory
ls /tmp/nfs-data/kasten-backups/   # on macOS with docker NFS
# or
ls /nfs/kasten-backups/             # on Linux
```

You should see Kasten's encrypted backup artifacts.

---

## Validation Checkpoints

| # | Check | Expected Result |
|---|-------|-----------------|
| 1 | NFS test file: `cat /tmp/nfs-data/test` | `"NFS works!"` |
| 2 | Private registry: `docker ps --filter name=private-registry` | Container running |
| 3 | Registry push test: `docker push ${REGISTRY}/alpine` | Push successful |
| 4 | Kind node pulls from private registry | Pod `airgapped-test` reaches Ready state |
| 5 | `kubectl get pods -n kasten-io` | All Kasten pods Running/Completed |
| 6 | Kasten pod images: `kubectl get pods -n kasten-io -o jsonpath=...` | All images from private registry |
| 7 | `kubectl get profile nfs-profile -n kasten-io` | Profile exists |
| 8 | NFS backup: check `/nfs/kasten-backups/` | Backup artifacts present |

---

## This workshop has challenges

- **`k10offline` is deprecated (since Kasten 7.5.0).** Use `k10tools image copy` (a container image) instead, as shown in Part 5. If you find older instructions or scripts referencing `k10offline pull`, they will fail on Kasten 7.5.0+.
- **NFS on macOS via Docker has complex networking.** The `erichough/nfs-server` container runs in the Docker bridge network. The kind node containers run in the same bridge network and can reach NFS at the container's Docker IP — but only if the NFS server container started correctly with `--privileged`. Confirm with `docker logs nfs-server` and test the mount from inside the kind node as described in Part 1.
- **Configuring containerd in the kind node** requires exec-ing into the node container and writing a `hosts.toml` file manually. The exact path changed between kind/containerd versions. If the pod still fails to pull from your registry after `systemctl restart containerd`, verify the path with `ls /etc/containerd/certs.d/` inside the node container.
- **Image mirroring is slow on a laptop network.** Kasten has dozens of container images. `k10tools image copy` may take 10–20 minutes depending on your download speed. Plan for this before the session.
- **`k10tools image copy --insecure-registry`** is needed when the private registry uses HTTP (no TLS), which is the case in this workshop. In production, use a registry with a valid TLS certificate.

---

## Tips & References

- [Kasten air-gapped install documentation](https://docs.kasten.io/latest/install/advanced.html#airgapped-install)
- [k10tools image documentation](https://docs.kasten.io/latest/install/offline.html) — `k10tools` replaced `k10offline` in Kasten 7.5.0
- [Docker Registry deployment guide](https://docs.docker.com/registry/deploying/)
- [Kasten NFS Location Profile](https://docs.kasten.io/latest/usage/configuration.html#nfs-file-store)
- In production, the private registry would typically be secured with a valid TLS certificate (not `skip_verify`). Tools like JFrog Artifactory, Harbor, or AWS ECR are common enterprise choices.
- NFS requires the NFS client (`nfs-common` on Ubuntu/Debian) installed on **every Kubernetes node** — in a kind cluster this means installing it in each kind node container.
- The `k10offline` tool handles the entire image mirror process including all Kasten sub-components. Without it, you must manually identify and mirror every image referenced in the Kasten Helm chart, which changes with each release.
- Kasten's `global.airgapped.repository` Helm value prefixes **all** image references in the chart — you don't need to configure images individually.
