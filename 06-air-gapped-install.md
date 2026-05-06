# Workshop 6 — Air-Gapped Installation

**Based on Instruqt track: k10tt-ag (Lab 6 — Veeam Kasten Training — Air-Gapped Install)**

---

## Goals

By the end of this workshop you will be able to:

- Deploy a **standalone MinIO container** outside the cluster as an air-gapped object store
- Deploy a **private Docker Registry** with HTTP basic authentication
- Mirror Kasten container images into the private registry using `k10tools`
- Install Kasten from the private registry (no Internet access required)
- Create an **S3-compatible Location Profile** in Kasten pointing to the external MinIO
- Backup a MongoDB workload using the external MinIO profile

---

## Air-Gapped Architecture

In secure or regulated environments, Kubernetes clusters may have **no outbound Internet access**. This creates two challenges:

1. **Container images** — where to pull them from
2. **Object storage for backups** — public cloud is inaccessible

This workshop addresses both:
- A **private registry** running as a Docker container on the host serves all container images
- A **standalone MinIO** running as a Docker container on the host acts as an on-prem S3-compatible object store for backups

```
Internet-isolated cluster:
  ┌────────────────────────────────────────┐
  │  Kubernetes (kind-kasten-training)     │
  │  pulls images from ───────────────────────────▶ Private Registry (host:5000)
  │  backs up to ─────────────────────────────────▶ External MinIO (host:9100)
  └────────────────────────────────────────┘
                   │ Docker bridge (172.18.0.1)
             Docker Desktop host
```

Both services run as Docker containers on your laptop, reachable from kind nodes via the Docker bridge gateway IP (`172.18.0.1`).

---

## Prerequisites

- Workshop 0 completed (kind cluster with CSI + VolumeSnapshot)
- Workshop 1 completed (MongoDB running in `mongodb` namespace with sample data)
- `docker` and `mc` (MinIO client) installed on your laptop
- `helm`, `kubectl`, `jq` installed

---

## Quick Resume

If you are returning to this workshop with the cluster already running, restart the external MinIO container and re-establish the Kasten tunnel:

```bash
# External MinIO (Docker container on the host) — restart if stopped
docker start airgapped-minio

# Kasten dashboard — http://localhost:8080/k10/
kubectl --namespace kasten-io port-forward service/gateway 8080:80 &

# mc alias for external MinIO
mc alias set airgapped http://localhost:9100 airgapadmin airgapadmin
```

---

## Step 1 — Identify the Host IP Reachable from Kind Nodes

Kind nodes communicate with Docker containers on the host via the Docker bridge gateway:

```bash
# Get the gateway IP of the kind Docker network
GATEWAY_IP=$(docker inspect kasten-training-control-plane \
  --format '{{ (index .NetworkSettings.Networks "kind").Gateway }}')
echo "Host gateway IP (reachable from kind): $GATEWAY_IP"
# Typically: 172.18.0.1
```

All Docker containers you start on the host with `-p <port>:<port>` are reachable from kind nodes at `${GATEWAY_IP}:<port>`.

---

## Step 2 — Deploy an External MinIO as Object Store

Run a standalone MinIO container on your laptop, bound to all interfaces:

```bash
docker rm -f airgapped-minio 2>/dev/null || true

docker run -d \
  --name airgapped-minio \
  -p 9100:9000 \
  -p 9101:9001 \
  -e MINIO_ROOT_USER=airgapadmin \
  -e MINIO_ROOT_PASSWORD=airgapadmin \
  -v /tmp/airgapped-minio-data:/data \
  quay.io/minio/minio server /data --console-address ":9001"
```

Create the backup bucket:

```bash
# Port-forward to localhost for mc configuration
mc alias set airgapped http://localhost:9100 airgapadmin airgapadmin
mc mb airgapped/airgapped-bucket
mc ls airgapped/
```

Verify reachability from inside the kind cluster:

```bash
kubectl run test-minio --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s -o /dev/null -w "%{http_code}" \
  "http://${GATEWAY_IP}:9100/minio/health/live"
# Expected: 200
```

---

## Step 3 — Deploy a Private Docker Registry

```bash
# Create auth directory with bcrypt-hashed credentials
mkdir -p /tmp/registry-auth
docker run --entrypoint htpasswd httpd:2 \
  -Bbn testuser testpassword > /tmp/registry-auth/htpasswd

# Start the registry (port 5000 on all interfaces)
docker rm -f private-registry 2>/dev/null || true
docker run -d \
  --name private-registry \
  -p 5000:5000 \
  --restart always \
  -v /tmp/registry-auth:/auth \
  -e REGISTRY_AUTH=htpasswd \
  -e "REGISTRY_AUTH_HTPASSWD_REALM=Registry Realm" \
  -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
  registry:2
```

Test the registry:

```bash
# From the Docker Desktop host, use localhost:5000
# (Docker Desktop treats localhost as an insecure registry; 172.18.0.1 requires daemon config)
docker login localhost:5000 -u testuser -p testpassword

docker pull alpine
docker tag alpine localhost:5000/alpine
docker push localhost:5000/alpine
```

> **Note:** `localhost:5000` and `${GATEWAY_IP}:5000` refer to the **same registry**. Docker Desktop on the host uses `localhost:5000` (always allowed as insecure). Kind nodes use `${GATEWAY_IP}:5000` (the Docker bridge gateway IP). The `hosts.toml` + `imagePullSecret` in the kind containerd config enables pulling from the `${GATEWAY_IP}:5000` address.

---

## Step 4 — Configure Kind to Trust the Private Registry

Containerd in the kind node needs two things: `config_path` set so per-registry `hosts.toml` files are read, and a `hosts.toml` declaring the registry as HTTP-capable. Authentication is handled separately by the Kasten Helm chart in Step 6.

```bash
# 1. Enable certs.d in the kind node's containerd config
docker exec kasten-training-control-plane bash -c "
cat >> /etc/containerd/config.toml << 'EOF'

[plugins.\"io.containerd.grpc.v1.cri\".registry]
  config_path = \"/etc/containerd/certs.d\"
EOF
"

# 2. Write the per-registry hosts.toml (HTTP + skip TLS verify)
docker exec kasten-training-control-plane bash -c "
mkdir -p /etc/containerd/certs.d/${GATEWAY_IP}:5000
cat > /etc/containerd/certs.d/${GATEWAY_IP}:5000/hosts.toml << TOML
[host.\"http://${GATEWAY_IP}:5000\"]
  capabilities = [\"pull\", \"resolve\"]
  skip_verify = true
TOML
"

# 3. Restart containerd to apply changes
docker exec kasten-training-control-plane systemctl restart containerd
sleep 5
```

Create an image pull secret in the `default` namespace for the test pod in the next step:

```bash
kubectl create secret docker-registry registry-secret \
  --namespace default \
  --docker-server=${GATEWAY_IP}:5000 \
  --docker-username=testuser \
  --docker-password=testpassword
```

Test that the kind node can pull from the private registry:

```bash
cat <<EOF | kubectl apply -n default -f -
apiVersion: v1
kind: Pod
metadata:
  name: airgapped-test
  namespace: default
spec:
  imagePullSecrets:
  - name: registry-secret
  containers:
  - name: alpine
    image: ${GATEWAY_IP}:5000/alpine
    command: ["tail", "-f", "/dev/null"]
EOF

kubectl wait pod/airgapped-test -n default --for=condition=Ready --timeout=60s
kubectl delete pod airgapped-test -n default
kubectl delete secret registry-secret -n default
```

---

## Step 5 — Mirror Kasten Images to the Private Registry

`k10tools image copy` handles image discovery, pulling, retagging, and pushing:

```bash
K10_VERSION=$(helm search repo kasten/k10 --output json | jq -r '.[0].app_version')
echo "Kasten version: $K10_VERSION"

# Copy all Kasten images to the private registry
# This may take 10-20 minutes depending on your connection
docker run --rm \
  gcr.io/kasten-images/k10tools:${K10_VERSION} \
  image copy \
  --dst-registry ${GATEWAY_IP}:5000 \
  --dst-username testuser \
  --dst-password testpassword \
  --dst-registry-insecure
```

> **Note:** This pulls all Kasten images from `gcr.io/kasten-images` and pushes them to your private registry. The list of images changes with each release — always use `k10tools image copy` rather than maintaining a manual image list.

Verify that images were pushed. The registry is bound to `${GATEWAY_IP}:5000` — a Docker bridge IP that is not directly reachable from the Mac terminal on Docker Desktop. Run the check from inside a container on the same `kind` network:

```bash
docker run --rm --network kind curlimages/curl:latest \
  -sk -u testuser:testpassword \
  "http://${GATEWAY_IP}:5000/v2/_catalog" | jq '.repositories | length'
# Expected: several dozen images
```

---

## Step 6 — Install or Upgrade Kasten from the Private Registry

Moving to a private registry does not require uninstalling Kasten — that would destroy all restore points and policies stored in the catalog. Use `helm upgrade` instead: it restarts pods with the new image source while preserving all Kasten state.

> **Why `helm upgrade --install` and not `helm uninstall` + `helm install`?** Uninstalling Kasten deletes the `kasten-io` namespace and with it the catalog PVC — all restore point metadata is lost. `helm upgrade` only replaces the running pods and updates the Helm release values; the catalog PVC and all its data are untouched. Use uninstall only if you explicitly want a clean slate (e.g. the DR exercise in Workshop 3).

Kasten's Helm chart handles private registry authentication via `secrets.dockerConfig` and `global.imagePullSecret`. The chart creates a secret named `k10-ecr` from the base64-encoded Docker config and injects it as `imagePullSecrets` into every pod spec automatically. The secret name `k10-ecr` is fixed by the chart — do not change it.

Build a Docker config file with the registry credentials and pass it to Helm:

```bash
GATEWAY_IP=$(docker inspect kasten-training-control-plane \
  --format '{{ (index .NetworkSettings.Networks "kind").Gateway }}')
K10_VERSION=$(helm search repo kasten/k10 --output json | jq -r '.[0].app_version')

# Build a Docker config with inline credentials.
# On macOS, Docker Desktop stores credentials in the system keychain rather than
# ~/.docker/config.json, so create the config file explicitly.
REGISTRY_AUTH=$(echo -n "testuser:testpassword" | base64)
cat > /tmp/registry-config.json << EOF
{
  "auths": {
    "${GATEWAY_IP}:5000": {
      "auth": "${REGISTRY_AUTH}"
    }
  }
}
EOF

helm upgrade --install k10 kasten/k10 \
  --namespace kasten-io \
  --reuse-values \
  --set "global.airgapped.repository=${GATEWAY_IP}:5000" \
  --set "secrets.dockerConfig=$(base64 < /tmp/registry-config.json | tr -d '\n')" \
  --set "global.imagePullSecret=k10-ecr" \
  --version "${K10_VERSION}" \
  --wait --timeout=600s
```

Verify all pods pull from the private registry:

```bash
kubectl get pods -n kasten-io -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' | sort -u | head -5
# All images should reference ${GATEWAY_IP}:5000
```

---

## Step 7 — Create a Location Profile for External MinIO

```bash
kubectl create secret generic k10secret-airgapped -n kasten-io \
  --from-literal=aws_access_key_id=airgapadmin \
  --from-literal=aws_secret_access_key=airgapadmin

cat <<EOF | kubectl apply -f -
kind: Profile
apiVersion: config.kio.kasten.io/v1alpha1
metadata:
  name: airgapped-s3
  namespace: kasten-io
spec:
  locationSpec:
    credential:
      secret:
        apiVersion: v1
        kind: Secret
        name: k10secret-airgapped
        namespace: kasten-io
      secretType: AwsAccessKey
    objectStore:
      endpoint: http://${GATEWAY_IP}:9100
      name: airgapped-bucket
      objectStoreType: S3
      pathType: Directory
      region: us-east-1
    type: ObjectStore
  type: Location
EOF
```

Verify the profile status:

```bash
kubectl get profile airgapped-s3 -n kasten-io -o jsonpath='{.status.validation}'
# Expected: Success
```

---

## Step 8 — Backup MongoDB to External MinIO

In the Kasten dashboard:

1. **Policies → + Create New Policy**
2. Configure:
   - Name: `mongodb-airgapped-backup`
   - Application: `mongodb` namespace
   - Backup Frequency: Hourly
   - Enable exports: ✓
   - Export Location Profile: `airgapped-s3`
3. **Create → Run Once → Yes, Continue**

Via `kubectl`:

```bash
cat <<EOF | kubectl apply -f -
kind: Policy
apiVersion: config.kio.kasten.io/v1alpha1
metadata:
  name: mongodb-airgapped-backup
  namespace: kasten-io
spec:
  frequency: "@hourly"
  retention:
    hourly: 24
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
        name: airgapped-s3
        namespace: kasten-io
      exportData:
        enabled: true
    retention: {}
EOF

cat <<EOF | kubectl apply -f -
kind: RunAction
apiVersion: actions.kio.kasten.io/v1alpha1
metadata:
  name: airgapped-backup-run-1
  namespace: kasten-io
  labels:
    k10.kasten.io/policyName: mongodb-airgapped-backup
    k10.kasten.io/policyNamespace: kasten-io
spec:
  subject:
    apiVersion: config.kio.kasten.io/v1alpha1
    kind: Policy
    name: mongodb-airgapped-backup
    namespace: kasten-io
EOF

kubectl get runaction airgapped-backup-run-1 -n kasten-io
```

After completion, verify backup artifacts in MinIO:

```bash
mc ls airgapped/airgapped-bucket/ --recursive | head -10
```

---

## Validation Checkpoints

| # | Check | Expected Result |
|---|-------|-----------------|
| 1 | External MinIO reachable from kind | `curl` returns 200 from `http://${GATEWAY_IP}:9100/minio/health/live` |
| 2 | Private registry running | `docker ps --filter name=private-registry` shows running |
| 3 | Registry push test | `docker push localhost:5000/alpine` succeeds (use `localhost:5000` from host; kind sees it as `${GATEWAY_IP}:5000`) |
| 4 | Kind node pulls from private registry | Pod `airgapped-test` reaches Ready state |
| 5 | `kubectl get pods -n kasten-io` | All Kasten pods Running/Completed, images from private registry |
| 6 | `kubectl get profile airgapped-s3 -n kasten-io` | Profile validation: Success |
| 7 | After backup: `mc ls airgapped/airgapped-bucket/` | Backup artifacts present |

---

## This workshop has challenges

- **The private registry must be reachable from both the host and kind nodes.** Bind the registry to `0.0.0.0:5000` (the default for `docker run -p 5000:5000`). From the host, access it at `localhost:5000`. From kind nodes, access it at `${GATEWAY_IP}:5000` (Docker bridge gateway). These are two different URLs for the same service.
- **Containerd `certs.d` requires `config_path` to be set explicitly.** Writing a `hosts.toml` into `/etc/containerd/certs.d/<registry>/hosts.toml` is not enough on its own — containerd only reads it if `config_path = "/etc/containerd/certs.d"` is also set under `[plugins."io.containerd.grpc.v1.cri".registry]` in `config.toml`. Without this, containerd ignores the `hosts.toml` and tries HTTPS, producing "http: server gave HTTP response to HTTPS client".
- **Do not use `global.pullSecrets` for private registry auth with Kasten.** The correct parameters are `secrets.dockerConfig` (base64-encoded Docker config) and `global.imagePullSecret=k10-ecr`. The chart creates the `k10-ecr` secret itself and injects it into all pod specs. `global.pullSecrets` is ignored for this purpose.
- **On macOS, `~/.docker/config.json` may not contain actual credentials.** Docker Desktop stores credentials in the macOS keychain (`"credsStore": "desktop"`) rather than the config file. Always build the Docker config explicitly with inline `auth` credentials as shown in Step 6 rather than relying on `~/.docker/config.json`.
- **The `k10-ecr` secret name is fixed by the Helm chart.** Do not attempt to use a different name for `global.imagePullSecret`.
- **`k10tools image copy` takes 10–20 minutes** due to the number of Kasten component images. Plan for this before the session. Re-runs are fast because Docker caches pulled layers.
- **`k10tools image copy --insecure-registry`** is required when the private registry uses HTTP (no TLS). In production, use a registry with a valid TLS certificate.
- **NFS on macOS Docker Desktop is not supported.** The Docker Desktop VM does not have the NFS kernel module, so `rpc.nfsd` containers (`erichough/nfs-server`, `itsthenetwork/nfs-server-alpine`) always fail with "does not support NFS export". This workshop uses MinIO instead of NFS for the backup location — MinIO is simpler, cross-platform, and equally representative of air-gapped S3 storage.
- **Image mirroring is version-specific.** The image list in `k10tools image copy` changes with each Kasten release. Always use the same `${K10_VERSION}` for both `k10tools image copy` and `helm install --version`. Mismatched versions cause pods to fail with `ImagePullBackOff`.

---

## Tips & References

- [Kasten air-gapped install documentation](https://docs.kasten.io/latest/install/advanced.html#airgapped-install)
- [k10tools image documentation](https://docs.kasten.io/latest/install/offline.html)
- [Docker Registry deployment guide](https://docs.docker.com/registry/deploying/)
- [MinIO Docker Quickstart](https://min.io/docs/minio/container/index.html)
- In production, the private registry would be JFrog Artifactory, Harbor, AWS ECR, or Azure ACR — all work with `k10tools image copy` by specifying the appropriate `--registry` value.
- Kasten's `global.airgapped.repository` Helm value prefixes **all** image references in the chart — you don't need to configure images individually.
- Private registry credentials are passed to Kasten via `secrets.dockerConfig` (base64 Docker config) + `global.imagePullSecret=k10-ecr`. The chart creates the `k10-ecr` secret and injects it into all pod specs. See the [Kasten air-gapped credentials documentation](https://docs.kasten.io/latest/install/offline#providing-credentials-if-local-container-repository-is-private).
