# Workshop 7 — Monitoring & Alerting

**Based on Instruqt track: k10tt-mr (Lab 7 — Veeam Kasten Training — Monitoring & Alerting)**

---

## Goals

By the end of this workshop you will be able to:

- Access and query Kasten metrics from the built-in **Prometheus** instance
- Understand key Kasten metrics: `catalog_actions_count`, `catalog_persistent_volume_free_space_percent`
- Distinguish between `liveness="live"` and `liveness="retired"` metric labels
- Simulate a backup failure and observe metric changes
- Configure an **SMTP email contact point** in Grafana
- Create a custom **Grafana dashboard** with Kasten metrics
- Define **alert rules** that fire on backup failure or low catalog storage
- Create a self-driven alert for catalog PVC capacity

---

## Monitoring Architecture

```
Kasten microservices (catalog-svc, executor, datamover, ...)
     │
     │ /metrics endpoint
     ▼
Prometheus (embedded in kasten-io namespace)
     │
     ├──▶ Kasten Dashboard (built-in metric widgets)
     │
     └──▶ External Grafana (monitoring namespace — must be installed separately)
               │
               ├──▶ Custom dashboards
               └──▶ Alerting (email, Slack, PagerDuty, ...)
```

Prometheus is embedded in the Kasten Helm chart. **Grafana was removed from the Kasten chart in Kasten 7.5.0** and must be installed separately. This workshop installs Grafana into the `monitoring` namespace.

This workshop uses a **pull model**: Grafana reaches into the `kasten-io` namespace to scrape Prometheus directly. This works because Kasten's `prometheus-server` NetworkPolicy allows port 9090 from any namespace. In environments where the `kasten-io` namespace must be strictly isolated (no inbound connections from other namespaces), the **push model via `remote_write`** is the right architectural choice: Kasten's Prometheus pushes metrics out to a central backend, so no external namespace ever needs ingress access to `kasten-io`.

> **Other approaches:** This workshop covers the standalone Grafana pattern. The [Kasten Enterprise Blueprint monitoring-alerting repository](https://github.com/kastendevhub/enterprise-blueprint/tree/main/monitoring-alerting) documents three additional integration patterns for teams with existing monitoring infrastructure:
> - [**Community kube-prometheus-stack**](https://github.com/kastendevhub/enterprise-blueprint/blob/main/monitoring-alerting/community.md) — deploys the full kube-prometheus-stack with `AlertManagerConfig` resources for centralized alerting
> - [**OpenShift user workload monitoring**](https://github.com/kastendevhub/enterprise-blueprint/blob/main/monitoring-alerting/openshift.md) — integrates with OpenShift's built-in monitoring stack via `ServiceMonitor` objects
> - **Prometheus remote write** — pushes Kasten metrics out to a central backend; the preferred approach when `kasten-io` namespace isolation must be enforced and no inbound connections from other namespaces are permitted

---

## Prerequisites

- Workshop 0 completed (cluster running)
- Workshop 1 completed (Kasten + MinIO + MongoDB installed, `mongodb-backup` policy run at least once)
- Access to an SMTP server for email alerts (Gmail, Mailhog, or similar)
- `kubectl`, `curl`, `jq` installed
- OIDC may be enabled or disabled — this workshop connects Grafana **directly to the Prometheus service** (`prometheus-server.kasten-io.svc.cluster.local`, port 80), bypassing the Kasten gateway entirely, so OIDC authentication has no effect on metrics access.

---

## Quick Resume

If you are returning to this workshop with the cluster already running, re-establish the service tunnels before continuing:

```bash
# Kasten dashboard — http://localhost:8080/k10/
kubectl port-forward svc/gateway-nodeport -n kasten-io 8080:8000 &

# Prometheus — http://localhost:9090/k10/prometheus/graph
kubectl port-forward svc/prometheus-server -n kasten-io 9090:80 &

# MinIO
kubectl port-forward svc/minio -n minio 9000:9000 &
mc alias set local http://localhost:9000 minioadmin minioadmin

# Grafana (once deployed in Part 3) — http://localhost:3000
kubectl port-forward svc/grafana -n monitoring 3000:80 &
```

---

## Part 1 — Explore Available Metrics

### Access Prometheus

Port-forward directly to the Prometheus service — no gateway, no authentication required:

```bash
kubectl port-forward svc/prometheus-server -n kasten-io 9090:80 &
```

Open the Prometheus UI at [http://localhost:9090/k10/prometheus/graph](http://localhost:9090/k10/prometheus/graph).

> **Why `/k10/prometheus/` in the path?** Kasten's Prometheus is started with `--web.route-prefix=/k10/prometheus`, so it serves all its endpoints under that prefix regardless of how you reach it — through the gateway or directly via port-forward. The path is the same either way.

### Browse Scrape Targets

In Prometheus UI: **Status → Targets**

You should see targets for each Kasten microservice: `catalog-svc`, `executor`, `datamover`, `metering`, etc.

### Query Catalog Metrics via curl

With the port-forward running, query completed backup counts directly from your laptop — this metric always has data once at least one backup has run:

```bash
curl -s "http://localhost:9090/k10/prometheus/api/v1/query" \
  --data-urlencode 'query=catalog_actions_count{status="complete",type="backup"}' \
  | jq '.data.result[] | {namespace: .metric.namespace, policy: .metric.policy, value: .value[1]}'
```

Expected output:
```json
{
  "namespace": "mongodb",
  "policy": "mongodb-backup",
  "value": "3"
}
```

### PromQL Queries

Open the Prometheus expression browser at [http://localhost:9090/k10/prometheus/graph](http://localhost:9090/k10/prometheus/graph) and try these queries:

| Query | What it shows | Available |
|-------|--------------|-----------|
| `catalog_actions_count{policy="mongodb-backup",status="complete",type="backup"}` | Completed backups for the mongodb policy | Now |
| `catalog_persistent_volume_free_space_percent` | Catalog PVC free space as a percentage | Now |
| `catalog_actions_count{liveness="live",status="complete",type="export"}` | Available exported RestorePoints | Now |
| `catalog_actions_count{status="failed",type="backup"}` | All failed backup actions | After Part 2 |

> **Note:** The `status="failed"` metric only appears after at least one backup failure has occurred. If you query it now it returns an empty result — run Part 2 first.

Switch from **Table** to **Graph** view to see metric trends over time.

---

## Understanding Metric Liveness

The `liveness` label is critical for correct interpretation:

| `liveness` | Meaning |
|-----------|---------|
| `liveness="live"` | Currently available RestorePoints (affected by retention policy — this gauge goes **up and down**) |
| `liveness="retired"` | RestorePoints that were retired by retention. This counter only **increases** over time. |

Example: with an hourly policy retaining 24 hourly backups, you will see `liveness="live"` `catalog_actions_count` hover around 24, then drop back as older RestorePoints expire.

---

## Part 2 — Simulate a Backup Failure

Create a condition that will cause the next backup to fail:

```bash
# Remove the VolumeSnapshotClass annotation (Kasten can't find a snapshot class)
kubectl annotate volumesnapshotclass csi-hostpath-snapclass \
  k10.kasten.io/is-snapshot-class-

# Verify the annotation is removed
kubectl describe volumesnapshotclass csi-hostpath-snapclass | grep k10.kasten.io
```

Trigger a backup:
```bash
cat <<EOF | kubectl apply -f -
kind: RunAction
apiVersion: actions.kio.kasten.io/v1alpha1
metadata:
  name: mongodb-fail-test
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
```

Wait for the action to fail (it will retry 3 times), then query Prometheus:

```bash
# Query for failed backups
curl -s "http://localhost:9090/k10/prometheus/api/v1/query" \
  --data-urlencode 'query=catalog_actions_count{status="failed",type="backup"}' \
  | jq '.data.result[].value[1]'
```

The `status="failed"` count should have increased.

Re-enable the annotation after the test:
```bash
kubectl annotate volumesnapshotclass csi-hostpath-snapclass \
  k10.kasten.io/is-snapshot-class="true"
```

---

## Part 3 — Install External Grafana and Configure Email Alerts

> **Important:** Grafana was **removed from the Kasten Helm chart in Kasten 7.5.0**. It must be installed separately. Kasten's embedded Prometheus remains unchanged and continues to collect all metrics.

### Install External Grafana

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

kubectl create namespace monitoring

helm install grafana grafana/grafana \
  --namespace monitoring \
  --set persistence.enabled=false \
  --set service.type=NodePort \
  --set service.nodePort=32030 \
  --wait

# Port-forward for local access
kubectl port-forward svc/grafana -n monitoring 3000:80 &
echo "Grafana: http://localhost:3000"
```

Get the Grafana admin password:
```bash
kubectl get secret grafana -n monitoring \
  -o jsonpath="{.data.admin-password}" | base64 --decode
```

Open [http://localhost:3000](http://localhost:3000) and log in with username `admin` and the password above.

> **Note:** If you want to configure SMTP at install time, use the `grafana\.ini` key (with backslash-escaped dot — this is Helm's syntax for a key that literally contains a dot):
> ```bash
> helm install grafana grafana/grafana \
>   --namespace monitoring \
>   --set persistence.enabled=false \
>   --set service.type=NodePort \
>   --set service.nodePort=32030 \
>   --set 'grafana\.ini.smtp.enabled=true' \
>   --set 'grafana\.ini.smtp.host=mailhog.kasten-io.svc.cluster.local:1025' \
>   --set 'grafana\.ini.smtp.from_address=grafana@kasten.lab' \
>   --set 'grafana\.ini.smtp.skip_verify=true' \
>   --wait
> ```

### Connect Grafana to Kasten Prometheus

Connect Grafana directly to the Prometheus service (port 80), bypassing the Kasten gateway. This avoids any authentication issues (OIDC, basic auth) because Prometheus itself has no auth. Kasten's `prometheus-server` NetworkPolicy allows port 9090 (pod port) from any namespace, and the service exposes it on port 80.

1. In Grafana: **Connections → Data Sources → Add data source**
2. Select **Prometheus**
3. Set **URL** to: `http://prometheus-server.kasten-io.svc.cluster.local/k10/prometheus`
4. Click **Save & Test** — you should see "Successfully queried the Prometheus API"

> **Tip:** You can verify direct reachability from inside the cluster: `kubectl run --rm -it probe --image=curlimages/curl --restart=Never -n monitoring -- curl -s -o /dev/null -w '%{http_code}' http://prometheus-server.kasten-io.svc.cluster.local/k10/prometheus/-/healthy`

### 3a. Configure SMTP for Email Alerts

In production, use your SMTP server. For local testing, deploy **Mailhog** as a mail catcher:

```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mailhog
  namespace: kasten-io
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mailhog
  template:
    metadata:
      labels:
        app: mailhog
    spec:
      containers:
      - name: mailhog
        image: mailhog/mailhog
        ports:
        - containerPort: 1025
        - containerPort: 8025
---
apiVersion: v1
kind: Service
metadata:
  name: mailhog
  namespace: kasten-io
spec:
  selector:
    app: mailhog
  ports:
  - name: smtp
    port: 1025
    targetPort: 1025
  - name: web
    port: 8025
    targetPort: 8025
EOF

kubectl port-forward svc/mailhog -n kasten-io 8025:8025 &
echo "Mailhog UI: http://localhost:8025"
```

Configure Grafana SMTP via Helm upgrade. **Important:** use `'grafana\.ini.smtp.*'` (with the backslash-escaped dot) — using `grafana.ini.*` without the backslash creates the wrong YAML key structure and the settings are silently ignored:

```bash
helm upgrade grafana grafana/grafana \
  --namespace monitoring \
  --reuse-values \
  --set 'grafana\.ini.smtp.enabled=true' \
  --set 'grafana\.ini.smtp.host=mailhog.kasten-io.svc.cluster.local:1025' \
  --set 'grafana\.ini.smtp.from_address=grafana@kasten.lab' \
  --set 'grafana\.ini.smtp.from_name=Grafana' \
  --set 'grafana\.ini.smtp.skip_verify=true' \
  --wait
```

Verify SMTP settings took effect:
```bash
GRAFANA_PASSWORD=$(kubectl get secret grafana -n monitoring \
  -o jsonpath="{.data.admin-password}" | base64 --decode)
curl -s -u "admin:${GRAFANA_PASSWORD}" \
  http://localhost:3000/api/admin/settings | jq '.smtp.enabled'
# Expected: "true"
```

Create an email contact point via the Grafana UI or API:

```bash
curl -s -X POST "http://localhost:3000/api/v1/provisioning/contact-points" \
  -u "admin:${GRAFANA_PASSWORD}" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "email-alerts",
    "type": "email",
    "settings": {"addresses": "kasten-admin@kasten.lab"}
  }' | jq '{uid, name}'
```

Test the contact point sends to Mailhog:
```bash
curl -s -X POST \
  "http://localhost:3000/api/alertmanager/grafana/config/api/v1/receivers/test" \
  -u "admin:${GRAFANA_PASSWORD}" \
  -H "Content-Type: application/json" \
  -d '{
    "receivers": [{
      "name": "email-alerts",
      "grafana_managed_receiver_configs": [{
        "type": "email",
        "settings": {"addresses": "kasten-admin@kasten.lab"}
      }]
    }]
  }'

# Check Mailhog for the test email
curl -s http://localhost:8025/api/v2/messages | jq '.count'
# Expected: 1
```

---

## Part 4 — Create a Custom Grafana Dashboard

1. In Grafana, click **+ → Dashboard → + Add Visualization**
2. Select **Prometheus** as the data source
3. Add a panel for failed backups:
   - **Query:** `catalog_actions_count{status="failed",type="backup"}`
   - **Panel title:** `Failed Backup Actions`
   - **Visualization:** Stat or Time series

4. Add a second panel for available RestorePoints:
   - **Query:** `catalog_actions_count{liveness="live",status="complete",type="backup"}`
   - **Panel title:** `Available Backup RestorePoints`

5. Add a third panel for catalog PVC usage:
   - **Query:** `100 - catalog_persistent_volume_free_space_percent`
   - **Panel title:** `Catalog PVC Usage %`
   - **Thresholds:** Yellow at 70, Red at 90

6. Save the dashboard as `Kasten Overview`.

---

## Part 5 — Create an Alert Rule for Failed Backups

### 5a. Create via Grafana UI

1. In Grafana: **Alerting → Alert Rules → + New Alert Rule**
2. Configure:

| Field | Value |
|-------|-------|
| Rule name | `Kasten Backup Failure` |
| Folder | Create a new folder `Kasten Alerts` |
| Query (A) | `sum(catalog_actions_count{status="failed",type="backup"})` |
| Reduce (B) | `Last` |
| Threshold (C) | IS ABOVE `0` |
| Evaluation interval | `1m` |
| Pending period | `1m` |
| Contact point | `email-alerts` |
| Summary | `Kasten backup failures detected` |
| Description | `One or more Kasten backup actions have failed.` |

3. Save the rule.

> **Why `sum(...)` and not `increase(...)`?** `catalog_actions_count` is a **gauge** (not a Prometheus counter), so `increase()` is not appropriate. The failed count is cumulative — once a failure is recorded, the gauge never decreases for that status. Use `sum(...) > 0` to alert whenever any failure exists in the current Prometheus scrape.

### 5b. Create via kubectl/API (alternative)

```bash
GRAFANA_PASSWORD=$(kubectl get secret grafana -n monitoring \
  -o jsonpath="{.data.admin-password}" | base64 --decode)
DS_UID=$(curl -s -u "admin:${GRAFANA_PASSWORD}" \
  http://localhost:3000/api/datasources/name/Kasten-Prometheus | jq -r '.uid')
FOLDER_UID=$(curl -s -X POST "http://localhost:3000/api/folders" \
  -u "admin:${GRAFANA_PASSWORD}" \
  -H "Content-Type: application/json" \
  -d '{"title": "Kasten Alerts"}' | jq -r '.uid')

curl -s -X PUT \
  "http://localhost:3000/api/v1/provisioning/folder/${FOLDER_UID}/rule-groups/kasten-alerts" \
  -u "admin:${GRAFANA_PASSWORD}" \
  -H "Content-Type: application/json" \
  -d "{
    \"title\": \"kasten-alerts\",
    \"interval\": 60,
    \"rules\": [{
      \"title\": \"Kasten Backup Failure\",
      \"condition\": \"C\",
      \"data\": [
        {\"refId\":\"A\",\"relativeTimeRange\":{\"from\":600,\"to\":0},
         \"datasourceUid\":\"${DS_UID}\",
         \"model\":{\"expr\":\"sum(catalog_actions_count{type=\\\"backup\\\",status=\\\"failed\\\"})\",\"refId\":\"A\",\"range\":true}},
        {\"refId\":\"B\",\"datasourceUid\":\"__expr__\",
         \"model\":{\"type\":\"reduce\",\"refId\":\"B\",\"expression\":\"A\",\"reducer\":\"last\"}},
        {\"refId\":\"C\",\"datasourceUid\":\"__expr__\",
         \"model\":{\"type\":\"threshold\",\"refId\":\"C\",
                    \"conditions\":[{\"evaluator\":{\"type\":\"gt\",\"params\":[0]}}],
                    \"expression\":\"B\"}}
      ],
      \"noDataState\": \"OK\",
      \"execErrState\": \"Error\",
      \"for\": \"1m\",
      \"labels\": {\"severity\": \"critical\"},
      \"annotations\": {
        \"summary\": \"Kasten backup failures detected\",
        \"description\": \"One or more Kasten backup actions have failed.\"
      },
      \"notification_settings\": {\"receiver\": \"email-alerts\"}
    }]
  }" | jq '.title'
```

> **Note:** The rule-group `PUT` API requires `interval` to be set (in seconds, divisible by 10). The per-rule API (`POST /api/v1/provisioning/alert-rules`) returns an error "interval should be non-zero" if you forget this — use the rule-group endpoint instead.

### 5c. Test the alert

```bash
# Remove snapshot class annotation to cause backup failure
kubectl annotate volumesnapshotclass csi-hostpath-snapclass \
  k10.kasten.io/is-snapshot-class-

# Trigger a backup (will fail because no snapshot class is registered)
cat <<EOF | kubectl apply -f -
kind: RunAction
apiVersion: actions.kio.kasten.io/v1alpha1
metadata:
  name: alert-test-run
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

# Wait ~2 minutes for Prometheus to scrape and Grafana to evaluate the rule
# Check Mailhog for the alert email
curl -s http://localhost:8025/api/v2/messages | jq '[.items[].Content.Headers.Subject[0]]'

# Restore the snapshot class annotation
kubectl annotate volumesnapshotclass csi-hostpath-snapclass \
  k10.kasten.io/is-snapshot-class="true"
```

---

## Part 6 — Self-Driven Challenge: Catalog PVC Capacity Alert

Create an alert that fires when the Kasten catalog PVC is more than 50% full.

**Metric to use:** `catalog_persistent_volume_free_space_percent`

**Goal:** Alert when free space falls below 50% (i.e., used > 50%).

Hints:
- Free space metric returns a value between 0 and 100
- You want to alert when `catalog_persistent_volume_free_space_percent < 50`
- Use a meaningful alert message including the current free space percentage

```bash
# Check current catalog PVC usage
curl -s "http://localhost:9090/k10/prometheus/api/v1/query" \
  --data-urlencode 'query=catalog_persistent_volume_free_space_percent' \
  | jq '.data.result'
```

---

## Validation Checkpoints

| # | Check | Expected Result |
|---|-------|-----------------|
| 1 | Prometheus targets: Status → Targets | `catalog-svc` and other Kasten services listed |
| 2 | PromQL query: `catalog_actions_count{status="complete",type="backup"}` | Non-zero result after at least one successful backup |
| 3 | After failure simulation: `catalog_actions_count{status="failed"}` | Count increased |
| 4 | Grafana accessible at `http://localhost:3000` (external install) | Login succeeds |
| 5 | Mailhog test email | Email received in Mailhog at [http://localhost:8025](http://localhost:8025) |
| 6 | Custom dashboard | At least 3 panels showing backup and catalog metrics |
| 7 | Alert rule created | Rule appears in **Alerting → Alert Rules** |
| 8 | Alert fires after backup failure | Email received in Mailhog with failure details |
| 9 | Catalog PVC alert (challenge) | Alert rule for `catalog_persistent_volume_free_space_percent < 50` exists |

---

## This workshop has challenges

- **Grafana is no longer embedded in Kasten (removed in 7.5.0).** You must install it separately (see Part 3). Any older instruction referencing `http://localhost:8080/k10/grafana` will return 404 on Kasten 7.5.0+. All Grafana steps in this workshop use the external Grafana at `http://localhost:3000`.
- **Always use the direct Prometheus URL — not the gateway — for both Grafana and curl queries.** The gateway strips the `/k10/prometheus` prefix before forwarding to Prometheus internally. But Prometheus is started with `--web.route-prefix=/k10/prometheus`, so it expects that prefix on every request. When the gateway removes it, Prometheus receives a path it does not serve and returns an empty result with no error — a silent failure that is very hard to diagnose. Direct access on port 9090 keeps the full path intact. Additionally, the gateway enforces OIDC or basic auth and returns HTTP 401 when authentication is enabled.
- **NetworkPolicy does not block cross-namespace Prometheus access.** Kasten's `prometheus-server` NetworkPolicy allows ingress on port 9090 from all sources (no `from` selector), so Grafana in the `monitoring` namespace can reach Prometheus in `kasten-io` without any additional NetworkPolicy.
- **The `grafana\.ini.smtp.*` Helm set keys require a backslash-escaped dot.** The Grafana chart stores all INI config under a key literally named `grafana.ini` (with a dot). In Helm `--set` syntax, a dot means nested key, so you must escape it: `--set 'grafana\.ini.smtp.enabled=true'`. Without the backslash, `--set grafana.ini.smtp.enabled=true` creates a `grafana > ini > smtp` nested structure which the chart ignores silently — `curl .../api/admin/settings | jq '.smtp.enabled'` returns `"false"` even though `helm get values` shows the setting.
- **Grafana alert rules require an `interval` set on the rule group.** The per-rule POST API (`/api/v1/provisioning/alert-rules`) rejects rules with `interval: 0` with "interval (0s) should be non-zero and divided exactly by scheduler interval: 10". Use the rule-group PUT API (`/api/v1/provisioning/folder/<uid>/rule-groups/<group>`) which lets you set `interval` at the group level — this is the only API path that works without a pre-existing group.
- **The `catalog_actions_count` is a gauge, not a counter.** Using `increase()` on it will give misleading results. The failed-action count is cumulative and never decreases for `status="failed"`. Use `sum(catalog_actions_count{status="failed"}) > 0` as the alert condition. The alert will remain firing as long as any historical failure exists — which is intentional: Kasten failures must be acknowledged and resolved, not aged out.
- **Mailhog is no longer maintained** (archived on GitHub). It works for local testing, but consider [Mailpit](https://mailpit.axllent.org/) as a modern replacement. Both accept SMTP on port 1025 so the Grafana contact point configuration is the same.

---

## Tips & References

- [Kasten monitoring documentation](https://docs.kasten.io/latest/operating/monitoring.html)
- [Prometheus PromQL documentation](https://prometheus.io/docs/prometheus/latest/querying/basics/)
- [Grafana alerting documentation](https://grafana.com/docs/grafana/latest/alerting/)
- [Mailhog](https://github.com/mailhog/MailHog) — a simple local SMTP server for development/testing (archived; [Mailpit](https://mailpit.axllent.org/) is a maintained alternative with the same SMTP interface)
- Key Kasten metric families:
  - `catalog_actions_count` — tracks backup, export, import, restore action counts
  - `catalog_persistent_volume_free_space_percent` — catalog database PVC health
  - `action_backup_ended_overall` — aggregate counters for ended backup states
- By default, Kasten's Prometheus retains 30 days of metrics in 8 GiB of storage. Adjust via Helm: `--set prometheus.server.retention=60d --set prometheus.server.persistentVolume.size=20Gi`
- Grafana alert routing: the **Notification Policy** tree routes alerts to contact points based on label matchers. The default root policy catches all unmatched alerts — set your email contact point there to receive all Kasten alerts.
- Grafana supports Slack, PagerDuty, OpsGenie, Teams, and webhook contact points in addition to email — production environments should use an on-call integration.
- `catalog_actions_count{status="failed"}` is a gauge that accumulates total failures and never resets to zero. `sum(...) > 0` fires as long as any failure is recorded. This is intentional — Kasten failure metrics persist until Kasten is restarted so operators cannot miss them.
