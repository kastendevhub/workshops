# Veeam Kasten Training Workshops

This directory contains self-paced workshop guides for Veeam Kasten (K10) data protection training, converted from the Instruqt platform to run on your own laptop.

## Workshop Series

| # | Workshop | Topics |
|---|----------|--------|
| 0 | [Kubernetes Environment Setup](00-kubernetes-environment-setup.md) | Kind cluster, CSI storage, VolumeSnapshot API — **required before all others** |
| 1 | [Getting Started](01-getting-started.md) | Install Kasten, configure MinIO, backup/restore MongoDB |
| 2 | [Data Consistency](02-data-consistency.md) | CSI snapshots, Kanister Blueprints, logical/consistent/generic backups |
| 3 | [Disaster Recovery](03-disaster-recovery.md) | Label policies, Kasten DR, catalog recovery to a new cluster |
| 4 | [Multi-Cluster & Application Mobility](04-multi-cluster-and-mobility.md) | Multi-cluster manager, application migration, transforms |
| 5 | [Authentication & Authorization](05-authentication-and-authorization.md) | OIDC with Keycloak, Kubernetes RBAC, Policy Presets |
| 6 | [Air-Gapped Install](06-air-gapped-install.md) | NFS storage, private registry, offline Kasten deployment |
| 7 | [Monitoring & Alerting](07-monitoring-and-alerting.md) | Prometheus metrics, Grafana dashboards, email alerts |

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed and running
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) v0.20+
- [kubectl](https://kubernetes.io/docs/tasks/tools/) v1.27+
- [Helm](https://helm.sh/docs/intro/install/) v3.12+
- At least 8 GB RAM and 4 CPU cores available to Docker Desktop

## Recommended Order

Complete Workshop 0 first. Workshops 1–3 build on each other and should be done in sequence. Workshops 4–7 are largely independent but assume Workshop 1 context is understood.
