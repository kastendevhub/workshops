# Workshop 5 — Authentication & Authorization

**Based on Instruqt track: k10tt-rbac2 (Lab 5 — Veeam Kasten Training — Authentication & Authorization)**

---

## Goals

By the end of this workshop you will be able to:

- Configure **OpenID Connect (OIDC)** authentication for Kasten using Keycloak as the identity provider
- Verify the OIDC token flow using the OIDC Debugger
- Install Kasten with OIDC authentication enabled via Helm values
- Define custom Kubernetes **ClusterRoles** for Kasten access control
- Bind roles to users and groups from your OIDC provider
- Create **Policy Presets** to standardize backup SLAs
- Understand multi-tenancy using namespaced `RoleBindings`

---

## Authentication Methods Supported by Kasten

| Method | Multi-user | Enterprise ready |
|--------|-----------|-----------------|
| No auth (port-forward only) | No | No |
| Basic auth (`htpasswd`) | No | No |
| Kubernetes Token | Yes | Limited |
| LDAP / Active Directory | Yes | Yes |
| OpenID Connect (OIDC) | Yes | Yes |
| OpenShift OAuth | Yes | Yes |

For production multi-tenant clusters, **OIDC** or **LDAP** is recommended.

---

## Prerequisites

- Workshop 0 completed (cluster running with CSI + VolumeSnapshot)
- Docker and `docker-compose` or ability to run Keycloak as a container
- `kubectl`, `helm` installed
- MongoDB running in `app-1` and `app-2` namespaces (deploy below)

---

## Quick Resume

If you are returning to this workshop with the cluster already running, re-establish the service tunnels before continuing:

```bash
# Keycloak — http://localhost:8082
kubectl port-forward svc/keycloak -n keycloak 8082:80 &

# Kasten dashboard — http://localhost:8080/k10/ (OIDC login required)
kubectl --namespace kasten-io port-forward service/gateway 8080:80 &

# MinIO
kubectl port-forward svc/minio -n minio 9000:9000 &
mc alias set local http://localhost:9000 minioadmin minioadmin
```

---

## Step 1 — Deploy Keycloak

Keycloak is an open-source OIDC identity provider. Deploy it using the official image from `quay.io`:

> **Note:** The Bitnami Keycloak Helm chart images are no longer available via `docker.io/bitnami` (deprecated in 2025). Use the official Keycloak image from `quay.io/keycloak/keycloak` directly.

```bash
kubectl create namespace keycloak

cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
  namespace: keycloak
spec:
  replicas: 1
  selector:
    matchLabels:
      app: keycloak
  template:
    metadata:
      labels:
        app: keycloak
    spec:
      containers:
      - name: keycloak
        image: quay.io/keycloak/keycloak:24.0
        args: ["start-dev"]
        env:
        - name: KEYCLOAK_ADMIN
          value: kcadmin
        - name: KEYCLOAK_ADMIN_PASSWORD
          value: kcadmin
        - name: KC_HOSTNAME_STRICT
          value: "false"
        - name: KC_HTTP_ENABLED
          value: "true"
        - name: KC_HOSTNAME_URL
          value: "http://host.docker.internal:8082"
        - name: KC_HOSTNAME_ADMIN_URL
          value: "http://host.docker.internal:8082"
        ports:
        - containerPort: 8080
          name: http
---
apiVersion: v1
kind: Service
metadata:
  name: keycloak
  namespace: keycloak
spec:
  selector:
    app: keycloak
  ports:
  - port: 80
    targetPort: 8080
    nodePort: 32020
  type: NodePort
EOF

kubectl wait deployment/keycloak -n keycloak --for=condition=Available --timeout=180s
```

Port-forward for local access:
```bash
kubectl port-forward svc/keycloak -n keycloak 8082:80 &
```

Wait for Keycloak to start (it takes about 15 seconds):
```bash
until kubectl logs deployment/keycloak -n keycloak 2>/dev/null | grep -q "started in"; do sleep 3; done
echo "Keycloak ready"
```

Access Keycloak admin console at [http://localhost:8082/admin/](http://localhost:8082/admin/) using `kcadmin`/`kcadmin`.

> **Important:** Setting `KC_HOSTNAME_URL=http://host.docker.internal:8082` makes Keycloak issue tokens with an issuer that is reachable from both the browser (via port-forward on 8082) and Kasten pods (via Docker Desktop's `host.docker.internal`). Without this setting, the issuer URL will use whatever hostname the request was made with, creating a mismatch between the browser's redirect URL and Kasten's token validation.

> **Note:** Keycloak `start-dev` mode uses an **in-memory H2 database**. All realm configuration is lost if the pod restarts. For persistent Keycloak in a training environment, add `--set db.type=dev-file` or use a PostgreSQL database. In this workshop we rely on the pod staying running throughout the session.

---

## Step 2 — Configure Keycloak

### 2a. Create a Realm

1. In the Keycloak admin console, click **Create Realm**.
2. Name it `k10lab-realm`.
3. Click **Create**.

### 2b. Create Groups

Create four groups under `k10lab-realm`:

| Group Name |
|-----------|
| `idp-k10admins` |
| `idp-dbadmins` |
| `idp-app1devs` |
| `idp-app2devs` |

### 2c. Create Users

| Username | Password | Groups |
|----------|----------|--------|
| `lab-admin@k10.lab` | `password` | `idp-k10admins` |
| `db-admin@k10.lab` | `password` | `idp-dbadmins` |
| `dev-1@k10.lab` | `password` | `idp-app1devs`, `idp-app2devs` |
| `dev-2@k10.lab` | `password` | `idp-app2devs` |

Set password as non-temporary for each user. Also set **First name** and **Last name** for each user — Keycloak 24.x requires a complete profile (`firstName` + `lastName`) before allowing the `password` grant type. Without them, login will fail with "Account is not fully set up".

Also ensure **Email verified** is toggled on for each user.

### 2d. Create the Kasten Client

1. **Clients → Create Client**
2. Set **Client ID**: `Kasten`
3. Enable **Client authentication** (confidential)
4. Set **Valid Redirect URIs**: `*` (or your Kasten dashboard URL)
5. Save

### 2e. Add a Groups Mapper

So that group membership appears in the JWT:

1. In the `Kasten` client → **Client Scopes → Dedicated scope**
2. **Add Mapper → Group Membership**
3. Name: `groupmapper`
4. Token Claim Name: `groups`
5. Full group path: **Off**
6. Save

---

## Step 3 — Verify OIDC Authentication

Before installing Kasten, test the OIDC flow using the public [OIDC Debugger](https://oidcdebugger.com/):

1. Get the authorization endpoint:
   ```bash
   curl -s http://localhost:8082/realms/k10lab-realm/.well-known/openid-configuration \
     | jq -r '.authorization_endpoint'
   ```

2. Open [https://oidcdebugger.com/](https://oidcdebugger.com/)
3. Fill in:
   - **Authorize URI**: paste the output from above
   - **Client ID**: `Kasten`
   - **Response Type**: `id_token`
4. Click **Send Request**
5. Log in as `dev-1@k10.lab` / `password`
6. Verify the decoded **ID Token** contains a `groups` claim listing the user's groups.

---

## Step 4 — Deploy Sample Applications

```bash
# Deploy MongoDB in app-1 namespace
kubectl create namespace app-1
helm install mongo-app1 bitnami/mongodb \
  --namespace app-1 \
  --set architecture=standalone \
  --set persistence.size=1Gi \
  --wait

# Deploy MongoDB in app-2 namespace
kubectl create namespace app-2
helm install mongo-app2 bitnami/mongodb \
  --namespace app-2 \
  --set architecture=standalone \
  --set persistence.size=1Gi \
  --wait
```

---

## Step 5 — Install Kasten with OIDC

Reinstall (or upgrade) Kasten with OIDC parameters:

```bash
# The OIDC issuer must use host.docker.internal so it is reachable from both
# the browser (via port-forward 8082) and Kasten pods (Docker Desktop bridge).
OIDC_ISSUER="http://host.docker.internal:8082/realms/k10lab-realm"

# Get the Kasten client secret from Keycloak:
# Keycloak admin → Clients → Kasten → Credentials → Client Secret

OIDC_CLIENT_SECRET="<paste client secret from Keycloak>"

helm upgrade --install k10 kasten/k10 \
  --namespace kasten-io \
  --reuse-values \
  --set auth.oidcAuth.enabled=true \
  --set auth.oidcAuth.providerURL="${OIDC_ISSUER}" \
  --set "auth.oidcAuth.redirectURL=http://localhost:8080" \
  --set "auth.oidcAuth.scopes=groups profile email" \
  --set auth.oidcAuth.prompt=select_account \
  --set auth.oidcAuth.clientID=Kasten \
  --set auth.oidcAuth.clientSecret="${OIDC_CLIENT_SECRET}" \
  --set auth.oidcAuth.usernameClaim=email \
  --set auth.oidcAuth.groupClaim=groups \
  --wait
```

Open [http://localhost:8080/k10/](http://localhost:8080/k10/) — you should be redirected to the Keycloak login page.

Log in as `lab-admin@k10.lab` / `password`. The dashboard should load.

---

## Step 6 — Configure Kubernetes RBAC

Kasten uses standard Kubernetes `ClusterRole` and `RoleBinding` objects for access control. Kasten ships with built-in ClusterRoles:

| Kasten ClusterRole | Permissions |
|-------------------|------------|
| `k10-admin` | Full access to all Kasten APIs |
| `k10-basic` | Can create backups, restores, and policies within a namespace |
| `k10-config-view` | Read-only view of Kasten configuration |

> **Note:** `k10-ns-admin` no longer exists in Kasten 8.x. For namespace-scoped admin access, bind `k10-admin` using a namespaced `RoleBinding` (not a `ClusterRoleBinding`). This gives full Kasten admin rights within that namespace only.

### 6a. Grant admin access to the OIDC admin group

```bash
cat <<EOF | kubectl apply -f -
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: k10-idp-admins
subjects:
- kind: Group
  name: idp-k10admins
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: k10-admin
  apiGroup: rbac.authorization.k8s.io
EOF
```

### 6b. Grant app-1 namespace access to db-admins group

```bash
cat <<EOF | kubectl apply -f -
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: k10-dbadmin-app1
  namespace: app-1
subjects:
- kind: Group
  name: idp-dbadmins
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: k10-admin
  apiGroup: rbac.authorization.k8s.io
EOF
```

### 6c. Grant app-1 read-only access to dev-1

```bash
cat <<EOF | kubectl apply -f -
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: k10-dev1-app1
  namespace: app-1
subjects:
- kind: User
  name: dev-1@k10.lab
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: k10-basic
  apiGroup: rbac.authorization.k8s.io
EOF
```

---

## Step 7 — Create a Custom ClusterRole

For granular permissions, define a custom role:

```bash
cat <<EOF | kubectl apply -f -
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: k10-db-admin
  labels:
    rbac.kasten.io/aggregate-to-k10-admin: "true"
rules:
- apiGroups: ["config.kio.kasten.io"]
  resources: ["policies", "profiles"]
  verbs: ["get", "list", "create", "update", "delete"]
- apiGroups: ["actions.kio.kasten.io"]
  resources: ["backupactions", "restoreactions", "exportactions"]
  verbs: ["get", "list", "create"]
EOF
```

---

## Step 8 — Create Policy Presets

Policy Presets provide standardized backup SLA templates that users can apply without understanding the underlying policy configuration.

```bash
cat <<EOF | kubectl apply -f -
kind: PolicyPreset
apiVersion: config.kio.kasten.io/v1alpha1
metadata:
  name: gold-sla
  namespace: kasten-io
spec:
  comment: "Gold SLA: hourly backups, exported, 30-day retention"
  backup:
    frequency: "@hourly"
    retention:
      hourly: 24
      daily: 30
      weekly: 12
      monthly: 12
      yearly: 7
  export:
    frequency: "@hourly"
    profile:
      name: s3-local
      namespace: kasten-io
    exportData:
      enabled: true
    retention:
      hourly: 24
      daily: 30
---
kind: PolicyPreset
apiVersion: config.kio.kasten.io/v1alpha1
metadata:
  name: silver-sla
  namespace: kasten-io
spec:
  comment: "Silver SLA: daily backups, exported, 7-day retention"
  backup:
    frequency: "@daily"
    retention:
      daily: 7
      weekly: 4
      monthly: 12
      yearly: 7
  export:
    frequency: "@daily"
    profile:
      name: s3-local
      namespace: kasten-io
    exportData:
      enabled: true
    retention:
      daily: 7
      weekly: 4
EOF
```

Verify presets appear in the dashboard under **Policies → Presets**.

---

## Step 9 — Test Access Control

Log out and log back in as different users to verify access:

| User | Expected Kasten Access |
|------|----------------------|
| `lab-admin@k10.lab` | Full dashboard access, all namespaces |
| `db-admin@k10.lab` | Only `app-1` namespace visible, can create/manage policies |
| `dev-1@k10.lab` | Only `app-1` namespace visible, can trigger backups/restores |
| `dev-2@k10.lab` | No namespaces visible (no bindings) |

---

## Validation Checkpoints

| # | Check | Expected Result |
|---|-------|-----------------|
| 1 | Navigate to Kasten dashboard | Keycloak login page shown (OIDC redirect) |
| 2 | Login as `lab-admin@k10.lab` | Dashboard accessible, all namespaces visible |
| 3 | Login as `db-admin@k10.lab` | Only `app-1` visible |
| 4 | Login as `dev-1@k10.lab` | `app-1` visible, can trigger backups/restores |
| 5 | `kubectl get clusterrolebinding k10-idp-admins` | Binding exists |
| 6 | `kubectl get rolebinding -n app-1` | `k10-dbadmin-app1` and `k10-dev1-app1` exist |
| 7 | `kubectl get policypreset -n kasten-io` | `gold-sla` and `silver-sla` present |
| 8 | OIDC Debugger ID token | `groups` claim present with user's groups |

---

## This workshop has challenges

- **Bitnami Keycloak images are no longer available on docker.io (deprecated 2025).** The `helm install bitnami/keycloak` approach results in `ErrImagePull`. Use the official `quay.io/keycloak/keycloak:24.0` image with a custom Deployment and Service as shown in Step 1.
- **Keycloak URL changes (breaking).** Keycloak 17+ (Quarkus-based) removed the `/auth/` context path prefix. The admin console is at `/admin/` and the OIDC issuer is at `/realms/<realm>`. Older instructions referencing `/auth/admin/` or `/auth/realms/` will return 404.
- **The OIDC issuer URL must be reachable from both the browser and Kasten pods.** If `providerURL` uses `localhost`, Kasten pods cannot reach it. If it uses the Kubernetes ClusterIP DNS (e.g. `keycloak.keycloak.svc.cluster.local`), the browser cannot follow the OIDC redirect. Solution: configure Keycloak with `KC_HOSTNAME_URL=http://host.docker.internal:8082` — `host.docker.internal` resolves to the Docker Desktop host from inside containers (port-forwarded to 8082), and to the same host from the browser via `localhost:8082`. Set `providerURL=http://host.docker.internal:8082/realms/k10lab-realm`.
- **The `redirectURL` Helm value must be just the base URL.** Set `auth.oidcAuth.redirectURL=http://localhost:8080` (not `http://localhost:8080/k10/auth-svc/v0/oidc/redirect`). Kasten appends the path suffix automatically. Setting the full path produces a doubled URL like `.../oidc/redirect/k10/auth-svc/v0/oidc/redirect` which Keycloak rejects.
- **Keycloak 24.x requires `firstName` + `lastName` for the password grant type.** Users created without first/last name fail login with "Account is not fully set up" even with `requiredActions: []` and `emailVerified: true`. Always set `firstName`, `lastName`, and `emailVerified: true` when creating users.
- **`k10-ns-admin` does not exist in Kasten 8.x.** The role was removed. For namespace-scoped admin access, create a `RoleBinding` (not `ClusterRoleBinding`) referencing `k10-admin`. This grants full Kasten admin rights scoped to that namespace only.
- **`PolicyPreset` API changed in Kasten 8.x.** The top-level `frequency`, `retention`, and `actions` fields were replaced by nested `backup` and `export` sub-objects. The old format is rejected with "unknown field" errors.
- **Keycloak `start-dev` mode is stateless — all config is lost on pod restart.** If the Keycloak pod restarts, all realms/users/clients must be recreated. For training purposes this is acceptable, but be aware that a cluster node restart will wipe your OIDC configuration.
- **The OIDC Debugger ([https://oidcdebugger.com/](https://oidcdebugger.com/)) cannot reach `localhost:8082`.** The debugger performs the redirect from its cloud server, which cannot reach your local port-forward. Use it conceptually only, or expose Keycloak publicly via `ngrok http 8082`.

---

## Tips & References

- [Kasten Authentication documentation](https://docs.kasten.io/latest/access/authentication.html)
- [Kasten RBAC documentation](https://docs.kasten.io/latest/access/authorization.html)
- [Keycloak documentation](https://www.keycloak.org/documentation)
- [Illustrated guide to OIDC (Okta)](https://developer.okta.com/blog/2019/10/21/illustrated-guide-to-oauth-and-oidc)
- [Kubernetes RBAC overview](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- The `groupClaim` Helm parameter must match the Token Claim Name configured in Keycloak's group mapper (`groups` in this lab).
- `RoleBinding` (namespaced) vs `ClusterRoleBinding` (cluster-wide) is the key to multi-tenancy — use `RoleBinding` to restrict a user to a single application namespace.
- Policy Presets are visible to all users with Kasten dashboard access — they can select a preset when creating a policy without needing to understand retention math.
- Enterprise OIDC providers: **Okta**, **Entra ID** (Azure AD), **ADFS**, **Ping Identity** all work with Kasten using the same OIDC configuration pattern.
