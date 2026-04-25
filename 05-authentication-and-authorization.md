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
| AWS IAM (EKS) | Yes | Yes |
| OpenShift OAuth | Yes | Yes |

For production multi-tenant clusters, **OIDC** or **LDAP** is recommended.

---

## Prerequisites

- Workshop 0 completed (cluster running with CSI + VolumeSnapshot)
- Docker and `docker-compose` or ability to run Keycloak as a container
- `kubectl`, `helm` installed
- MongoDB running in `app-1` and `app-2` namespaces (deploy below)

---

## Step 1 — Deploy Keycloak

Keycloak is an open-source OIDC identity provider. Deploy it locally:

```bash
# Create namespace and deploy Keycloak via Helm
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

kubectl create namespace keycloak

helm install keycloak bitnami/keycloak \
  --namespace keycloak \
  --set auth.adminUser=kcadmin \
  --set auth.adminPassword=kcadmin \
  --set service.type=NodePort \
  --set service.nodePorts.http=32020 \
  --wait
```

Port-forward for local access:
```bash
kubectl port-forward svc/keycloak -n keycloak 8082:80 &
```

Access Keycloak admin console at [http://localhost:8082/admin/](http://localhost:8082/admin/) using `kcadmin`/`kcadmin`.

> **Note:** Keycloak 17+ (Quarkus-based) removed the `/auth/` context path prefix. The admin console is now at `/admin/`, not `/auth/admin/`. All older URLs with `/auth/` will return 404.

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

Set password as non-temporary for each user.

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
  --version 13.6.7 \
  --wait

# Deploy MongoDB in app-2 namespace
kubectl create namespace app-2
helm install mongo-app2 bitnami/mongodb \
  --namespace app-2 \
  --set architecture=standalone \
  --set persistence.size=1Gi \
  --version 13.6.7 \
  --wait
```

---

## Step 5 — Install Kasten with OIDC

Reinstall (or upgrade) Kasten with OIDC parameters:

```bash
# Get Keycloak OIDC configuration
OIDC_ISSUER="http://localhost:8082/realms/k10lab-realm"

# Get the Kasten client secret from Keycloak:
# Keycloak admin → Clients → Kasten → Credentials → Client Secret

OIDC_CLIENT_SECRET="<paste client secret from Keycloak>"

helm upgrade --install k10 kasten/k10 \
  --namespace kasten-io \
  --set auth.oidcAuth.enabled=true \
  --set auth.oidcAuth.providerURL="${OIDC_ISSUER}" \
  --set auth.oidcAuth.redirectURL="http://localhost:8080/k10/auth-svc/v0/oidc/redirect" \
  --set auth.oidcAuth.scopes="groups profile email" \
  --set auth.oidcAuth.prompt="select_account" \
  --set auth.oidcAuth.clientID="Kasten" \
  --set auth.oidcAuth.clientSecret="${OIDC_CLIENT_SECRET}" \
  --set auth.oidcAuth.usernameClaim="email" \
  --set auth.oidcAuth.groupClaim="groups" \
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
| `k10-basic` | Read-only access |
| `k10-ns-admin` | Manage policies and restores for a specific namespace |

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
  name: k10-ns-admin
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
  frequency: "@hourly"
  retention:
    hourly: 24
    daily: 30
    weekly: 12
    monthly: 12
    yearly: 7
  actions:
  - action: backup
  - action: export
    exportParameters:
      frequency: "@hourly"
      exportData:
        enabled: true
    retention: {}
---
kind: PolicyPreset
apiVersion: config.kio.kasten.io/v1alpha1
metadata:
  name: silver-sla
  namespace: kasten-io
spec:
  comment: "Silver SLA: daily backups, exported, 7-day retention"
  frequency: "@daily"
  retention:
    daily: 7
    weekly: 4
    monthly: 12
    yearly: 7
  actions:
  - action: backup
  - action: export
    exportParameters:
      frequency: "@daily"
      exportData:
        enabled: true
    retention: {}
EOF
```

Verify presets appear in the dashboard under **Policies → Presets**.

---

## Step 9 — Test Access Control

Log out and log back in as different users to verify access:

| User | Expected Kasten Access |
|------|----------------------|
| `lab-admin@k10.lab` | Full dashboard access, all namespaces |
| `db-admin@k10.lab` | Only `app-1` namespace visible, can create policies |
| `dev-1@k10.lab` | Only `app-1` namespace visible, read-only |
| `dev-2@k10.lab` | No namespaces visible (no bindings) |

---

## Validation Checkpoints

| # | Check | Expected Result |
|---|-------|-----------------|
| 1 | Navigate to Kasten dashboard | Keycloak login page shown (OIDC redirect) |
| 2 | Login as `lab-admin@k10.lab` | Dashboard accessible, all namespaces visible |
| 3 | Login as `db-admin@k10.lab` | Only `app-1` visible |
| 4 | Login as `dev-1@k10.lab` | `app-1` visible, read-only (no create buttons) |
| 5 | `kubectl get clusterrolebinding k10-idp-admins` | Binding exists |
| 6 | `kubectl get rolebinding -n app-1` | `k10-dbadmin-app1` and `k10-dev1-app1` exist |
| 7 | `kubectl get policypreset -n kasten-io` | `gold-sla` and `silver-sla` present |
| 8 | OIDC Debugger ID token | `groups` claim present with user's groups |

---

## This workshop has challenges

- **Keycloak URL changes (breaking).** The current Bitnami Keycloak chart uses Keycloak 17+ (Quarkus-based), which removed the `/auth/` path prefix. The admin console is at `/admin/` and the OIDC issuer is at `/realms/<realm>`. Any older instruction referencing `/auth/admin/` or `/auth/realms/` will produce a 404. All URLs in this workshop have been updated accordingly.
- **The OIDC Debugger ([https://oidcdebugger.com/](https://oidcdebugger.com/)) cannot reach `localhost:8082`.** The OIDC Debugger performs the authorization redirect from its own cloud server, which cannot reach your laptop's port-forwarded Keycloak. Use the debugger only to understand the flow conceptually, or test with `curl` directly as shown. As a workaround, you can use a local tunnel tool (e.g. `ngrok http 8082`) to expose your local Keycloak publicly, then use that URL in the debugger.
- **Keycloak startup can be slow** on resource-constrained laptops. The Bitnami chart uses resource limits by default. If the Keycloak pod stays in `0/1 Running` with readiness probe failures, wait up to 5 minutes or increase Docker Desktop memory.
- **OIDC redirect URL must match exactly.** The `redirectURL` in the Helm upgrade command must match what is registered as a Valid Redirect URI in Keycloak. Even a trailing slash difference will cause the OIDC flow to fail with an "invalid redirect_uri" error. If you see this error, double-check both the Helm value and the Keycloak client configuration.

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
