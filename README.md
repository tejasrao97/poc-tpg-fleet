# tpg-fleet

GitOps repository for the **Tanzu for Postgres on AKS GitOps POC**. Argo CD reads this repository to deploy the Tanzu for Postgres operator and Postgres instances to every target AKS cluster. Argo Workflows on the hub runs the ordered, gated Day 0 and Day 1 operations defined here.

The Azure infrastructure, the Argo installation and the cluster prerequisites live in the companion repository `tpg-aks-infra`.

## Pinned versions

| Component | Version | Where |
|---|---|---|
| Tanzu for Postgres operator chart | v4.5.0 | `clusters/fleet.yaml` (`clusters.<cluster>.operator.version`) |
| Argo CD / chart | v3.5.3 / 10.9.1 | `tpg-aks-infra/argo` |
| Argo Workflows / chart | v4.1.3 / 2.0.6 | `tpg-aks-infra/argo` |
| cert-manager chart | v1.21.2 | `workflows/scripts/helm-addons.sh` (Helm release `cert-manager`) |
| kube-state-metrics chart | 8.5.0 | `bootstrap/monitoring/azure`, `workflows/scripts/helm-addons.sh` (standalone) |
| kube-prometheus-stack chart | 91.4.0 | `workflows/scripts/helm-addons.sh` (Helm release `kps`, standalone) |
| Workflow tools image | `alpine/k8s:1.35.8` | `toolsImage` parameter of every WorkflowTemplate |
| Azure CLI image | `mcr.microsoft.com/azure-cli:2.90.0` | `azCliImage` parameter of `tpg-rotate-credential` |

## Repository layout

```text
tpg-fleet/
  bootstrap/
    project-tpg.yaml                 AppProject tpg
    app-hub-workflows.yaml           Hub Application for workflows/ (automated sync)
    appsets/                         platform, operator, instances (manual sync)
    monitoring/azure/                Option A: kube-state-metrics + azmonitoring monitors
  platform/base/                     StorageClass tpg-premium-retain (Premium ZRS, Retain)
  charts/tpg-instance/               Postgres + PostgresBackupLocation (Azure Blob)
  clusters/
    _template/cluster.yaml           cluster defaults for every cluster (maxReadReplicas, backup)
    _template/instance.yaml          instance defaults for every instance (sizes, HA, resources)
    fleet.yaml                       per cluster: operator.version, overrides, instances.<name> overrides
    deleted/<cluster>/<i>-<time>     instance entries removed by the delete workflows
  docs/
    workflow-commands.md             argo and argocd commands for every workflow, with examples
  workflows/
    kustomization.yaml               WorkflowTemplates, CronWorkflows, RBAC, tpg-scripts ConfigMap
    rbac.yaml                        ServiceAccount tpg-workflow
    scripts/                         step scripts mounted at /scripts (helm-addons.sh is also run by tpg-aks-infra)
    templates/                       tpg-lib, tpg-day0, tpg-upgrade, tpg-scale-instance, tpg-backup,
                                     tpg-restore-pitr, tpg-rotate-credential, tpg-delete-instance,
                                     tpg-delete-apps, tpg-helm-addons
    cron/                            tpg-backup-full (Sun 00:00 UTC), tpg-backup-diff (Mon-Sat 00:00 UTC)
  monitoring/
    ksm/values.yaml                  custom resource state metrics for Postgres, backups, restores
    azure/, standalone/              monitors, kube-prometheus-stack values, dashboard, PrometheusRules
    grafana/                         generate.py, Grafana alert rules, Azure import script, SMTP examples
    prometheus/                      Alertmanager SMTP example
  scripts/                           set-repo-url.sh, validate.sh
```

## One template for every cluster

There is no folder per cluster. Every cluster renders the same chart with the same two template files, and `clusters/fleet.yaml` holds only what differs:

```yaml
clusters:
  aks-tpg-poc-01:                  # registered cluster (Argo CD label tpg.fleet/managed=true)
    operator:
      version: v4.5.0              # required; tpg-day0 and tpg-upgrade write it
    cluster:
      maxReadReplicas: 5           # optional override of _template/cluster.yaml
    instances:
      orders-db:                   # namespace pg-orders-db, Application tpg-aks-tpg-poc-01-orders-db
        instance:
          postgresVersion: postgres-17.6
          highAvailability: {enabled: true, readReplicas: 2}
      billing-db:
        instance:
          postgresVersion: postgres-17.6
```

| Value | Source |
|---|---|
| Which clusters exist, and their wave | Cluster registration in `tpg-aks-infra` (Secret labels `tpg.fleet/managed`, `tpg.fleet/wave`) |
| Operator version, instances and their overrides | `clusters/fleet.yaml` |
| Defaults | `clusters/_template/cluster.yaml`, `clusters/_template/instance.yaml`, then `charts/tpg-instance/values.yaml` |
| `cluster.name`, backup container `pg-backups-<cluster>` | Set by the `tpg-instances` ApplicationSet |

The `tpg-operator` and `tpg-instances` ApplicationSets combine the registered clusters with `clusters/fleet.yaml` (matrix generator with a list generator per cluster). A registered cluster without an entry gets only `tpg-<cluster>-platform` until `tpg-day0` adds it. You normally never edit `fleet.yaml` by hand: the workflows write it, with `pushMode=direct` or `pushMode=pr`.

## Get started

1. Create an empty private GitHub repository named `tpg-fleet`.
2. Set the repository URL everywhere and push:

   ```bash
   ./scripts/set-repo-url.sh https://github.com/<your-org>/tpg-fleet.git
   git add -A && git commit -m "Set repository URL"
   git remote add origin https://github.com/<your-org>/tpg-fleet.git
   git push -u origin main
   ```

3. Review `clusters/_template/*.yaml`. The example `clusters/fleet.yaml` declares three clusters; replace it with `clusters: {}` if you want `tpg-day0` to add clusters from its inputs.
4. In `tpg-aks-infra`, run `scripts/run.sh` for your scenario (hub with or without Argo; clusters from Terraform or pre-created). Its `addons` step installs the Helm add-ons and its `bootstrap` step applies `bootstrap/`.

## How delivery works

- **ApplicationSets** generate one Application per cluster and component: `tpg-<cluster>-platform`, `-operator`, and `tpg-<cluster>-<instance>`. They carry the labels `tpg.fleet/cluster`, `tpg.fleet/wave` and `tpg.fleet/component`.
- **Helm releases** outside Argo CD: `cert-manager` on every target, and for standalone monitoring `kps` on the hub and `kps` + `tpg-ksm` on targets (`helm list -A`).
- **No automated sync** on those Applications. Workflows sync them through the Argo CD API as `workflow-bot`, cluster by cluster, canary first.
- **Databases are never pruned.** Postgres resources carry `Prune=false,Delete=false`, and the Postgres CR sets `persistentVolumeClaimPolicy: retain`.
- `tpg-hub-workflows` (templates, scripts, RBAC) and the Azure monitoring Applications use automated sync because they hold no data.

## Workflows

All workflows run in the `argo` namespace as `tpg-workflow`, write per-target results to the ConfigMap `tpg-run-<workflow-name>` (deleted with the workflow), and end with a report printed by the exit handler. When any target is `FAILED` or `TIMEOUT`, the report step fails so the run is flagged in the Argo UI and in the controller metrics.

Mandatory inputs have no default: the first step (`validate`) fails with the list of missing or invalid inputs and the registered cluster names. **[docs/workflow-commands.md](docs/workflow-commands.md) lists every input and several `argo submit` examples per workflow, plus the related `argocd` commands.**

| Workflow | Purpose | Mandatory inputs |
|---|---|---|
| `tpg-day0` | Write the inputs to `fleet.yaml`, pre-check, install cert-manager, deploy operator and instances in waves | `clusters`, `instances`, `highAvailability`, `operatorVersion`, `postgresVersion`, `pushMode` |
| `tpg-upgrade` | Upgrade the operator or Postgres instances in waves | `component`, `targetVersion`, `clusters`, `pushMode`, `instances` (postgres) |
| `tpg-scale-instance` | Set read replicas of one instance | `cluster`, `instance`, `replicas`, `pushMode` |
| `tpg-delete-apps` | Delete instances and/or the operator and its CRDs per cluster | `clusters`, `apps`, `confirm`, `dryRun`, `purgePvcs`, `purgeNamespace`, `pushMode` |
| `tpg-delete-instance` | Guarded delete of one instance | `cluster`, `instance`, `confirm` |
| `tpg-helm-addons` | cert-manager and standalone monitoring agent Helm releases on targets | `clusters` |
| `tpg-backup` | On-demand backups (CronWorkflows run it on a schedule) | none (`backupType`, `clusters` default) |
| `tpg-restore-pitr` | Point-in-time restore | `clusters`, `instance`, `targetTime` |
| `tpg-rotate-credential` | Rotate registry, storage or Git credentials | `secretType` |

### Day 0: deploy

```bash
# Dry run: fleet.yaml diff and pre-checks (operator, CRDs, same-named instances, versions)
argo submit -n argo --from workflowtemplate/tpg-day0 \
  -p clusters=all -p instances=orders-db -p highAvailability=true \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct -p dryRun=true --watch

# Deploy: wave 0 canary alone, then later waves in batches of maxParallel (2)
argo submit -n argo --from workflowtemplate/tpg-day0 \
  -p clusters=all -p instances=orders-db -p highAvailability=true \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct --watch
```

| Pre-check status | Meaning |
|---|---|
| `PASSED` | Nothing Tanzu Postgres related on the cluster |
| `MANAGED` | Existing objects are tracked by this Argo CD (safe re-run) |
| `BLOCKED` | Foreign operator, foreign CRDs, same-named instance, missing Postgres version, or unreachable. The cluster is not changed |

### Day 1: upgrade, scale, backup, restore, rotate

```bash
argo submit -n argo --from workflowtemplate/tpg-upgrade \
  -p component=operator -p targetVersion=v4.5.1 -p clusters=all -p pushMode=direct --watch
argo submit -n argo --from workflowtemplate/tpg-upgrade \
  -p component=postgres -p targetVersion=postgres-17.7 -p clusters=all -p instances=all -p pushMode=pr --watch
argo submit -n argo --from workflowtemplate/tpg-scale-instance \
  -p cluster=aks-tpg-poc-02 -p instance=orders-db -p replicas=2 -p pushMode=direct --watch
argo submit -n argo --from workflowtemplate/tpg-backup -p backupType=full -p clusters=aks-tpg-poc-01 --watch
argo submit -n argo --from workflowtemplate/tpg-restore-pitr \
  -p clusters=aks-tpg-poc-01 -p instance=orders-db -p targetTime=2026-09-15T08:30:00Z --watch
```

- **Upgrade:** minor or major is detected per instance; major needs `allowMajor=true` and pauses for `argo resume` before every batch after the canary. A full backup runs first (`preUpgradeBackup=true`).
- **Backups:** if the previous backup is still `Pending` or `Running`, the workflow waits 2 minutes and reports `SKIPPED_IN_PROGRESS`. Instances with `backupSchedule=none` are skipped by the CronWorkflows.
- **Credential rotation:** update the hub source Secret, then run `tpg-rotate-credential` with `secretType` `broadcom-registry`, `backup-storage` or `git-push`.

### Day 2: delete

```bash
# Plan, then run with dryRun=false
argo submit -n argo --from workflowtemplate/tpg-delete-apps \
  -p clusters=aks-tpg-poc-03 -p apps='{"aks-tpg-poc-03":["tpg-instances","tpg-operator"]}' \
  -p confirm=aks-tpg-poc-03 -p dryRun=true -p purgePvcs=false -p purgeNamespace=false -p pushMode=direct --watch
```

Instances leave `clusters/fleet.yaml` (a copy goes to `clusters/deleted/<cluster>/`), the Applications are removed without cascading (`preserveResourcesOnDeletion`), and the workflow deletes the objects in order. With `tpg-operator` it also deletes the operator and the `sql.tanzu.vmware.com` CRDs, refusing while other Postgres instances exist unless `force=true`. The backup repository is never deleted.

## Monitoring

| Option | Apply | Dashboard and alerts |
|---|---|---|
| A: Azure Monitor | `MONITORING_OPTION=azure` in `tpg-aks-infra/env.sh`, `enable_azure_monitor = true` in Terraform | `monitoring/grafana/import-azure-grafana.sh rg-tpgpoc amg-tpgpoc` |
| B: Standalone | `MONITORING_OPTION=standalone`; `tpg-aks-infra` step `addons` installs Helm release `kps` on the hub (creates Secret `monitoring/grafana-admin` first) and `kps` + `tpg-ksm` on targets with the hub remote write URL | Provisioned automatically (dashboard ConfigMap, `grafana.alerting` values) |

The dashboard **Tanzu Postgres Fleet** shows instances per cluster, healthy and unhealthy instances, ready and desired pod replicas, read replicas, backup and restore counts (succeeded, failed, in progress), backup workflow results, hours since the last successful backup, replication lag, WAL archive failures, connection usage, and active alerts.

Alert definitions live in `monitoring/grafana/generate.py`. After changing them, regenerate the Grafana provisioning values, the API payloads, the PrometheusRule and the dashboard:

```bash
python3 monitoring/grafana/generate.py
```

Email notifications are optional: see `monitoring/grafana/smtp/` (Grafana SMTP for both options) and `monitoring/prometheus/alertmanager-smtp-values.yaml` (Prometheus alerts through Alertmanager). For the standalone hub, pass them with `KPS_HUB_EXTRA_VALUES` to `tpg-aks-infra/scripts/run.sh --only addons`.

## Adding a cluster or an instance

- **Instance:** run `tpg-day0 -p clusters=<cluster> -p instances=<name> ...`. It adds the instance to `clusters/fleet.yaml` and deploys it.
- **Cluster:** create it with `tpg-aks-infra` (`target_cluster_count`) or add a pre-created cluster to `inventory/clusters.yaml` with `wave: 1` or higher, run `tpg-aks-infra/scripts/run.sh` again, then run `tpg-day0 -p clusters=<cluster> ...`. No file or folder is added by hand.

## Static validation

`scripts/validate.sh` runs the same checks used before delivery: `yamllint`, `shellcheck`, `kustomize build`, the `clusters/fleet.yaml` structure, `helm lint` and `helm template` of the instance chart for every `fleet.yaml` instance (with the values the ApplicationSet passes), `kubeconform` (Kubernetes, Argo and Prometheus Operator schemas from the CRDs catalog), and JSON parsing of the dashboard and alert payloads.

## Items to validate in the lab

The Tanzu for Postgres custom resources have no public JSON schema, so confirm these on the first lab cluster:

| # | Item | How |
|---|---|---|
| V1 | `spec.storage.azure` fields and `backup-storage` keys (`accountName`, `accountKey`) | `kubectl explain postgresbackuplocation.spec.storage.azure`, then one manual backup |
| V2 | Minor upgrades through `PostgresVersionUpgrade`, and whether the operator updates `spec.postgresVersion.name` | Upgrade a test instance by one minor version |
| V3 | Operator upgrade by Argo CD, including CRD updates and instance pod rollout | Run `tpg-upgrade -p component=operator` on the canary |
| V4 | In-place PITR with `pitr.type: time` on an existing instance | Restore a disposable instance with `inPlace=true` |
| V5 | kube-state-metrics timestamp gauges exported as unix seconds | `curl` the `tpg-ksm` metrics endpoint, grep `tanzu_postgres_` |
| V6 | postgres-exporter metric names used in alerts | Port-forward 9187 on a data pod and grep `pg_` |
| V7 | Argo Workflows custom metric names (`argo_workflows_tpg_*_total`) | `curl` the workflow controller metrics Service |
| V8 | `alpine/k8s:1.35.8` and `azure-cli:2.90.0` tags pullable from the hub | `kubectl run` a test pod with each image |
| V9 | Re-creating a deleted instance reattaches retained PVCs | Delete with defaults, then run `tpg-day0` for the instance again |
| V10 | `tpg-delete-apps` with `tpg-operator` removes all 7 `sql.tanzu.vmware.com` CRDs and leftover webhooks | Run on a lab cluster; `kubectl get crd,validatingwebhookconfigurations` |
| V11 | ApplicationSet matrix with `elementsYaml` renders one Application per `fleet.yaml` instance | `argocd appset get tpg-instances`; `argocd app list -l tpg.fleet/component=instance` |
| V12 | Pull request mode with the fine-grained PAT (Pull requests: Read and write) | `tpg-scale-instance -p pushMode=pr -p dryRun=false` on a test instance |
