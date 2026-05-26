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

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed and running (see Windows note below)
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) v0.20+
- [kubectl](https://kubernetes.io/docs/tasks/tools/) v1.27+
- [Helm](https://helm.sh/docs/intro/install/) v3.12+
- At least 12 GB RAM and 8 CPU cores available to Docker

### Windows users

Docker Desktop on Windows has been reported to cause issues with kind. The recommended approach is to use **Docker Engine inside WSL2** instead.

1. [Install WSL2](https://learn.microsoft.com/en-us/windows/wsl/install) with Ubuntu, then [install Docker Engine](https://docs.docker.com/engine/install/ubuntu/) inside the WSL2 distro (not Docker Desktop).

2. Create or edit `C:\Users\<YourUsername>\.wslconfig` with the following content:

   ```ini
   [wsl2]
   kernelCommandLine = cgroup_no_v1=all
   memory=12GB
   processors=8
   ```

   The `cgroup_no_v1=all` option forces cgroup v2, which Kubernetes 1.25+ requires. If you are on WSL 2.5.1 or later, cgroup v2 is enabled by default and this line may not be necessary.

3. Restart WSL for the settings to take effect:

   ```powershell
   wsl --shutdown
   ```

   Then reopen your WSL terminal. All subsequent commands in these workshops should be run inside that WSL2 terminal.

4. Install `kind`, `kubectl`, and `helm` inside WSL2 following the standard Linux instructions.

## Recommended Order

Complete Workshop 0 first. Workshops 1–3 build on each other and should be done in sequence. Workshops 4–7 are largely independent but assume Workshop 1 context is understood.
