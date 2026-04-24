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
     └──▶ Grafana (embedded in kasten-io namespace)
               │
               ├──▶ Custom dashboards
               └──▶ Alerting (email, Slack, PagerDuty, ...)
```

Both Prometheus and Grafana are deployed as part of the Kasten Helm chart and require no additional installation.

---

## Prerequisites

- Workshop 0 completed (cluster running)
- Workshop 1 completed (Kasten + MinIO + MongoDB installed, `mongodb-backup` policy run at least once)
- Access to an SMTP server for email alerts (Gmail, Mailhog, or similar)
- `kubectl`, `curl`, `jq` installed

---

## Part 1 — Explore Available Metrics

### Access Prometheus

Kasten's embedded Prometheus is accessible through the Kasten gateway:

```bash
# Port-forward the Kasten gateway
kubectl port-forward svc/gateway-nodeport -n kasten-io 8080:8000 &

# Open in browser:
# http://localhost:8080/k10/prometheus/graph
echo "Prometheus: http://localhost:8080/k10/prometheus/graph"
```

### Browse Scrape Targets

In Prometheus UI: **Status → Targets**

You should see targets for each Kasten microservice: `catalog-svc`, `executor`, `datamover`, `metering`, etc.

### Query Catalog Metrics via curl

```bash
kubectl run catalog-metrics -n kasten-io \
  --rm --restart=Never -it \
  --image=curlimages/curl \
  -- curl http://catalog-svc.kasten-io.svc.cluster.local:8000/metrics 2>/dev/null \
  | grep -A3 "catalog_actions_count"
```

Expected output:
```
# HELP catalog_actions_count Number of actions
# TYPE catalog_actions_count gauge
catalog_actions_count{liveness="live",namespace="mongodb",policy="mongodb-backup",status="complete",type="backup"} 1
catalog_actions_count{liveness="live",namespace="mongodb",policy="mongodb-backup",status="pending",type="backup"} 0
catalog_actions_count{liveness="live",namespace="mongodb",policy="mongodb-backup",status="running",type="backup"} 0
```

### PromQL Queries

Open the Prometheus expression browser at [http://localhost:8080/k10/prometheus/graph](http://localhost:8080/k10/prometheus/graph) and try these queries:

| Query | What it shows |
|-------|--------------|
| `catalog_actions_count{policy="mongodb-backup",status="complete",type="backup"}` | Completed backups for the mongodb policy |
| `catalog_actions_count{status="failed",type="backup"}` | All failed backup actions |
| `catalog_persistent_volume_free_space_percent` | Catalog PVC free space as a percentage |
| `catalog_actions_count{liveness="live",status="complete",type="export"}` | Available exported RestorePoints |

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
curl -s "http://localhost:8080/k10/prometheus/api/v1/query" \
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

## Part 3 — Access Grafana and Configure Email Alerts

### Access Grafana

Grafana is embedded in the Kasten gateway:

```bash
echo "Grafana: http://localhost:8080/k10/grafana"
```

Default credentials:
```
Username: admin
Password: admin
```

> **Note:** To get the Grafana admin password from the Kasten secret:
> ```bash
> kubectl get secret k10-grafana -n kasten-io \
>   -o jsonpath="{.data.admin-password}" | base64 --decode
> ```

### 3a. Configure SMTP for Email Alerts

In production, use your SMTP server. For local testing, use **Mailhog**:

```bash
# Deploy Mailhog as a local mail catcher
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
        - containerPort: 1025  # SMTP
        - containerPort: 8025  # Web UI
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

In Grafana:
1. **Alerting → Contact Points → + New Contact Point**
2. Name: `email-alerts`
3. Type: **Email**
4. Address: `test@example.com`
5. Click **Test** to send a test email
6. Check [http://localhost:8025](http://localhost:8025) for the received test email
7. **Save Contact Point**

Set as the default contact point:
- **Alerting → Notification Policies → Edit** the default policy → set contact point to `email-alerts`

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

1. In Grafana: **Alerting → Alert Rules → + New Alert Rule**
2. Configure:

| Field | Value |
|-------|-------|
| Rule name | `Failed Backup Alert` |
| Query | `increase(catalog_actions_count{status="failed",type="backup"}[5m])` |
| Condition | IS ABOVE `0` |
| Evaluation group | Create or select a group |
| Pending period | `0s` (fire immediately) |
| Contact point | `email-alerts` |
| Summary | `Kasten backup failure detected` |
| Description | `Policy: {{ $labels.policy }}, Namespace: {{ $labels.namespace }}` |

3. Save the rule.

4. Test by triggering another backup failure (remove the VolumeSnapshotClass annotation again and run a policy):
   ```bash
   kubectl annotate volumesnapshotclass csi-hostpath-snapclass k10.kasten.io/is-snapshot-class-
   # Run a backup (will fail)
   # Wait a few minutes
   # Check Mailhog for the alert email
   # Re-enable: kubectl annotate volumesnapshotclass csi-hostpath-snapclass k10.kasten.io/is-snapshot-class="true"
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
curl -s "http://localhost:8080/k10/prometheus/api/v1/query" \
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
| 4 | Grafana accessible at `/k10/grafana` | Login succeeds |
| 5 | Mailhog test email | Email received in Mailhog at [http://localhost:8025](http://localhost:8025) |
| 6 | Custom dashboard | At least 3 panels showing backup and catalog metrics |
| 7 | Alert rule created | Rule appears in **Alerting → Alert Rules** |
| 8 | Alert fires after backup failure | Email received in Mailhog with failure details |
| 9 | Catalog PVC alert (challenge) | Alert rule for `catalog_persistent_volume_free_space_percent < 50` exists |

---

## Tips & References

- [Kasten monitoring documentation](https://docs.kasten.io/latest/operating/monitoring.html)
- [Prometheus PromQL documentation](https://prometheus.io/docs/prometheus/latest/querying/basics/)
- [Grafana alerting documentation](https://grafana.com/docs/grafana/latest/alerting/)
- [Mailhog](https://github.com/mailhog/MailHog) — a simple local SMTP server for development/testing
- Key Kasten metric families:
  - `catalog_actions_count` — tracks backup, export, import, restore action counts
  - `catalog_persistent_volume_free_space_percent` — catalog database PVC health
  - `action_backup_ended_overall` — aggregate counters for ended backup states
- By default, Kasten's Prometheus retains 30 days of metrics in 8 GiB of storage. Adjust via Helm: `--set prometheus.server.retention=60d --set prometheus.server.persistentVolume.size=20Gi`
- Grafana alert routing: the **Notification Policy** tree routes alerts to contact points based on label matchers. The default root policy catches all unmatched alerts — set your email contact point there to receive all Kasten alerts.
- Grafana supports Slack, PagerDuty, OpsGenie, Teams, and webhook contact points in addition to email — production environments should use an on-call integration.
- `increase(metric[5m])` calculates the increase in a counter over the last 5 minutes — useful for detecting new failures without alerting on cumulative historical counts.
