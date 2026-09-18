# Workflow command reference

Every tpg operation is an Argo Workflows `WorkflowTemplate` in the `argo` namespace on the hub. You start a run with the **argo CLI** (`argo submit --from workflowtemplate/<name>`). Argo CD does not start workflows: the workflows call the Argo CD API to refresh and sync Applications. The **argocd CLI** commands at the end of this page show the same sync steps, for manual runs and troubleshooting.

Mandatory inputs have no default. A run without them fails in its first step (`validate`) and lists every missing or invalid input, including the registered cluster names.

## Contents

1. [Set up the CLIs](#1-set-up-the-clis)
2. [Common inputs and conventions](#2-common-inputs-and-conventions)
3. [tpg-day0](#3-tpg-day0)
4. [tpg-upgrade](#4-tpg-upgrade)
5. [tpg-scale-instance](#5-tpg-scale-instance)
6. [tpg-delete-apps](#6-tpg-delete-apps)
7. [tpg-delete-instance](#7-tpg-delete-instance)
8. [tpg-helm-addons](#8-tpg-helm-addons)
9. [tpg-backup](#9-tpg-backup)
10. [tpg-restore-pitr](#10-tpg-restore-pitr)
11. [tpg-rotate-credential](#11-tpg-rotate-credential)
12. [Follow, approve, stop and clean up runs](#12-follow-approve-stop-and-clean-up-runs)
13. [argocd CLI: the sync steps behind the workflows](#13-argocd-cli-the-sync-steps-behind-the-workflows)

---

## 1. Set up the CLIs

```bash
# Kubeconfig written by tpg-aks-infra/scripts/run.sh (context aks-tpg-hub)
export KUBECONFIG=~/src/tpg-aks-infra/.work/kubeconfig
export ARGO_NAMESPACE=argo            # every command below then works without -n argo

argo version
argo template list
```

To use the Argo Workflows server instead of the Kubernetes API (for example from a laptop without cluster access), see `tpg-aks-infra/docs/README-argo-on-aks.md` and set `ARGO_SERVER`, `ARGO_HTTP1=true`, `ARGO_SECURE=true` and `ARGO_TOKEN`.

```bash
# argocd CLI against the hub (port-forward works without a public UI)
kubectl --context aks-tpg-hub -n argocd port-forward svc/argocd-server 18080:443 >/dev/null 2>&1 &
argocd login localhost:18080 --username admin --insecure --grpc-web \
  --password "$(kubectl --context aks-tpg-hub -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
```

## 2. Common inputs and conventions

| Input | Values | Used by |
|---|---|---|
| `clusters` | `aks-tpg-poc-01,aks-tpg-poc-02` or `all` (every registered cluster) | day0, upgrade, delete-apps, helm-addons, backup, restore |
| `cluster` | One registered cluster | scale, delete-instance |
| `pushMode` | `direct`: push the `clusters/fleet.yaml` change to the fleet branch. `pr`: push a branch, open a GitHub pull request and continue once it is merged (`prTimeoutSeconds`, default 3600) | day0, upgrade, scale, delete-apps, delete-instance |
| `dryRun` | `true`: validate and record the plan; change nothing | day0, upgrade, scale, delete-apps, helm-addons |
| Operator version | `v4.5.0` (`4.5.0` is accepted) | day0 `operatorVersion`, upgrade `targetVersion` |
| Postgres version | `postgres-17.6` (`17.6` is accepted); must exist in `kubectl get postgresversion` | day0 `postgresVersion`, upgrade `targetVersion` |

- Put values that contain commas, spaces or JSON in single quotes.
- `-p name=value` sets one input. `--parameter-file inputs.yaml` reads several from a file (examples in each section).
- `--watch` follows the run in the terminal. Without it, the command prints the workflow name.
- `--name` or `--generate-name` sets the workflow name, which is also the results ConfigMap `tpg-run-<name>`.
- Every run ends with a report (exit handler). `argo logs @latest -c main | sed -n '/tpg run report/,$p'` prints it again.

---

## 3. tpg-day0

Writes the inputs to `clusters/fleet.yaml`, pre-checks every selected cluster, installs cert-manager (and the standalone monitoring agent) as Helm releases, then syncs the operator and instance Applications: wave 0 alone first, then the other waves in batches of `maxParallel`.

| Input | Mandatory | Default | Description |
|---|---|---|---|
| `clusters` | yes | | Registered clusters or `all` |
| `instances` | yes | | Instances to deploy on every selected cluster (namespace `pg-<instance>`) |
| `highAvailability` | yes | | `true` (primary and standby, plus `readReplicas`) or `false` (single node) |
| `operatorVersion` | yes | | Operator chart version |
| `postgresVersion` | yes | | PostgresVersion name |
| `pushMode` | yes | | `direct` or `pr` |
| `readReplicas` | no | `1` | Read replicas when `highAvailability=true` (0 to `maxReadReplicas`, default 3) |
| `storageSize`, `walStorageSize` | no | template (`20Gi`, `10Gi`) | Volume sizes |
| `storageClass` | no | template (`tpg-premium-retain`) | StorageClass |
| `cpu`, `memory` | no | template (requests 1/2Gi, limits 2/4Gi) | Request and limit per Postgres pod |
| `backupSchedule` | no | `fleet` | `fleet`: included in `tpg-backup-full` and `tpg-backup-diff`; `none`: excluded |
| `installAddons` | no | `true` | Install or upgrade cert-manager (and the standalone monitoring agent) |
| `monitoringOption` | no | `tpg-settings` | Override: `none`, `azure`, `standalone` |
| `maxParallel` | no | `2` | Clusters per batch after the canary |
| `dryRun` | no | `false` | Show the `fleet.yaml` change and run the pre-check only |
| `syncTimeoutSeconds`, `prTimeoutSeconds` | no | `1800`, `3600` | Timeouts |

A version that differs from one already declared in `fleet.yaml` fails the run (`FLEET_CONFLICT`): use `tpg-upgrade` for that.

```bash
# 1. Dry run on every registered cluster: validation, fleet.yaml diff, pre-check
argo submit --from workflowtemplate/tpg-day0 \
  -p clusters=all -p instances=orders-db -p highAvailability=true \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 \
  -p pushMode=direct -p dryRun=true --watch

# 2. Deploy orders-db with HA and 2 read replicas on all clusters, direct push
argo submit --from workflowtemplate/tpg-day0 \
  -p clusters=all -p instances=orders-db -p highAvailability=true -p readReplicas=2 \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct --watch

# 3. Two single-node instances on one new cluster, sized, reviewed through a pull request
argo submit --from workflowtemplate/tpg-day0 \
  -p clusters=aks-tpg-poc-04 -p instances=billing-db,reporting-db -p highAvailability=false \
  -p operatorVersion=4.5.0 -p postgresVersion=17.6 \
  -p storageSize=100Gi -p walStorageSize=20Gi -p cpu=2 -p memory=8Gi \
  -p pushMode=pr -p prTimeoutSeconds=7200 --watch

# 4. Lab instance excluded from scheduled backups; cert-manager already installed
argo submit --from workflowtemplate/tpg-day0 \
  -p clusters=aks-tpg-poc-03 -p instances=scratch-db -p highAvailability=false \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct \
  -p backupSchedule=none -p installAddons=false --watch

# 5. Three batches of 3 clusters after the canary, longer sync timeout
argo submit --from workflowtemplate/tpg-day0 \
  -p clusters=all -p instances=orders-db -p highAvailability=true \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct \
  -p maxParallel=3 -p syncTimeoutSeconds=3600 --watch
```

With a parameter file:

```yaml
# day0-orders.yaml
clusters: aks-tpg-poc-01,aks-tpg-poc-02,aks-tpg-poc-03
instances: orders-db
highAvailability: "true"
readReplicas: "1"
operatorVersion: v4.5.0
postgresVersion: postgres-17.6
pushMode: direct
```

```bash
argo submit --from workflowtemplate/tpg-day0 --parameter-file day0-orders.yaml --watch
```

---

## 4. tpg-upgrade

Upgrades the operator (`component=operator`) or Postgres instances (`component=postgres`), canary first, and writes the new version to `clusters/fleet.yaml`.

| Input | Mandatory | Default | Description |
|---|---|---|---|
| `component` | yes | | `operator` or `postgres` |
| `targetVersion` | yes | | Operator: `v4.5.1`; Postgres: `postgres-17.6` |
| `clusters` | yes | | Registered clusters or `all` |
| `pushMode` | yes | | `direct` or `pr` |
| `instances` | yes for `postgres` | | Instances or `all`; not allowed for `operator` |
| `preUpgradeBackup` | no | `true` | Full backup of each affected instance first |
| `allowMajor` | no | `false` | Allow major Postgres upgrades; pauses for approval before every batch after the canary |
| `maxParallel` | no | `1` | Clusters per batch after the canary |
| `dryRun` | no | `false` | Record the planned upgrade (minor or major, current and target) per target |
| `timeoutSeconds`, `prTimeoutSeconds` | no | `1800`, `3600` | Per cluster (operator) or per instance (Postgres) |

Minor or major is detected per instance. Downgrades fail. Instances not selected are reported as `SKIPPED_NOT_SELECTED`.

```bash
# 1. Operator: dry run on all clusters
argo submit --from workflowtemplate/tpg-upgrade \
  -p component=operator -p targetVersion=v4.5.1 -p clusters=all -p pushMode=direct -p dryRun=true --watch

# 2. Operator: canary cluster only, through a pull request
argo submit --from workflowtemplate/tpg-upgrade \
  -p component=operator -p targetVersion=v4.5.1 -p clusters=aks-tpg-poc-01 -p pushMode=pr --watch

# 3. Operator: remaining clusters two at a time, without pre-upgrade backups
argo submit --from workflowtemplate/tpg-upgrade \
  -p component=operator -p targetVersion=v4.5.1 -p clusters=aks-tpg-poc-02,aks-tpg-poc-03 \
  -p pushMode=direct -p maxParallel=2 -p preUpgradeBackup=false --watch

# 4. Postgres minor upgrade of every instance on every cluster
argo submit --from workflowtemplate/tpg-upgrade \
  -p component=postgres -p targetVersion=postgres-16.10 -p clusters=all -p instances=all \
  -p pushMode=direct --watch

# 5. Postgres major upgrade of orders-db, with approval between batches
argo submit --from workflowtemplate/tpg-upgrade \
  -p component=postgres -p targetVersion=postgres-17.6 -p clusters=all -p instances=orders-db \
  -p allowMajor=true -p pushMode=pr -p timeoutSeconds=7200 --watch
argo resume @latest          # approve the next batch after checking the canary

# 6. Postgres minor upgrade of two instances on one cluster
argo submit --from workflowtemplate/tpg-upgrade \
  -p component=postgres -p targetVersion=17.7 -p clusters=aks-tpg-poc-02 \
  -p instances='orders-db,billing-db' -p pushMode=direct --watch
```

---

## 5. tpg-scale-instance

Sets the read replica count of one instance in `clusters/fleet.yaml`, syncs and verifies it.

| Input | Mandatory | Default | Description |
|---|---|---|---|
| `cluster` | yes | | One registered cluster |
| `instance` | yes | | Instance declared for that cluster |
| `replicas` | yes | | Read replicas, 0 to `maxReadReplicas` |
| `pushMode` | yes | | `direct` or `pr` |
| `enableHAIfNeeded` | no | `true` | `replicas > 0` on an instance without HA: turn HA on (`true`) or fail (`false`) |
| `dryRun` | no | `false` | Record the change only |
| `timeoutSeconds`, `prTimeoutSeconds` | no | `900`, `3600` | Timeouts |

`replicas=0` removes the read replicas and keeps high availability as declared.

```bash
# 1. Scale out to 2 read replicas
argo submit --from workflowtemplate/tpg-scale-instance \
  -p cluster=aks-tpg-poc-02 -p instance=orders-db -p replicas=2 -p pushMode=direct --watch

# 2. Dry run of scaling to 3
argo submit --from workflowtemplate/tpg-scale-instance \
  -p cluster=aks-tpg-poc-01 -p instance=billing-db -p replicas=3 -p pushMode=direct -p dryRun=true --watch

# 3. Scale in to 0 read replicas through a pull request
argo submit --from workflowtemplate/tpg-scale-instance \
  -p cluster=aks-tpg-poc-01 -p instance=orders-db -p replicas=0 -p pushMode=pr --watch

# 4. Refuse to turn HA on for a single-node instance
argo submit --from workflowtemplate/tpg-scale-instance \
  -p cluster=aks-tpg-poc-04 -p instance=reporting-db -p replicas=1 \
  -p enableHAIfNeeded=false -p pushMode=direct --watch
```

---

## 6. tpg-delete-apps

Deletes Tanzu Postgres applications per cluster: Postgres instances (`tpg-instances`) and the operator with its CRDs (`tpg-operator`). Deleting the operator removes these CRDs: `postgres`, `postgresbackups`, `postgresbackuplocations`, `postgresbackupschedules`, `postgresrestores`, `postgresversions` and `postgresversionupgrades` (all `.sql.tanzu.vmware.com`).

| Input | Mandatory | Default | Description |
|---|---|---|---|
| `clusters` | yes | | Registered clusters to clean up |
| `apps` | yes | | JSON map: cluster to list of `tpg-instances`, `tpg-instances:<i>[,<i>]`, `tpg-operator`. Every cluster in `clusters` needs an entry |
| `confirm` | yes | | Repeat the `clusters` value |
| `dryRun` | yes | `true` | `true` records the plan; `false` deletes |
| `purgePvcs` | yes | | `true` deletes PVCs and Azure disks; `false` keeps them |
| `purgeNamespace` | yes | | `true` deletes `pg-<instance>` (needs `purgePvcs=true`); `false` keeps it |
| `pushMode` | yes | | `direct` or `pr` |
| `force` | no | `false` | With `tpg-operator`: also delete Postgres instances not listed, and do not wait for running backups or restores |
| `finalBackup` | no | `true` | `true`, `false` or `required` (fail when the instance is not Running) |
| `timeoutSeconds`, `prTimeoutSeconds` | no | `1800`, `3600` | Timeouts |

Order per cluster: instances (final backup, `fleet.yaml` removal, Application removal without cascade, Postgres objects, optional PVC and namespace purge), remaining Tanzu Postgres custom resources, operator (`fleet.yaml`, Application, leftover cluster-scoped objects, namespace `tanzu-postgres-operator`), CRDs. The Azure Blob backup repository is never deleted.

```bash
# 1. Plan (dry run) a full clean-up of two clusters
argo submit --from workflowtemplate/tpg-delete-apps \
  -p clusters=aks-tpg-poc-03,aks-tpg-poc-04 \
  -p apps='{"aks-tpg-poc-03":["tpg-instances","tpg-operator"],"aks-tpg-poc-04":["tpg-instances","tpg-operator"]}' \
  -p confirm=aks-tpg-poc-03,aks-tpg-poc-04 \
  -p dryRun=true -p purgePvcs=false -p purgeNamespace=false -p pushMode=direct --watch

# 2. Run it: remove everything, including volumes and namespaces
argo submit --from workflowtemplate/tpg-delete-apps \
  -p clusters=aks-tpg-poc-03,aks-tpg-poc-04 \
  -p apps='{"aks-tpg-poc-03":["tpg-instances","tpg-operator"],"aks-tpg-poc-04":["tpg-instances","tpg-operator"]}' \
  -p confirm=aks-tpg-poc-03,aks-tpg-poc-04 \
  -p dryRun=false -p purgePvcs=true -p purgeNamespace=true -p pushMode=direct --watch

# 3. Different applications per cluster: one instance on 01, all instances on 02 (keep volumes)
argo submit --from workflowtemplate/tpg-delete-apps \
  -p clusters=aks-tpg-poc-01,aks-tpg-poc-02 \
  -p apps='{"aks-tpg-poc-01":["tpg-instances:billing-db"],"aks-tpg-poc-02":["tpg-instances"]}' \
  -p confirm=aks-tpg-poc-01,aks-tpg-poc-02 \
  -p dryRun=false -p purgePvcs=false -p purgeNamespace=false -p pushMode=pr --watch

# 4. Operator only, forcing removal of instances created outside Git, no final backups
argo submit --from workflowtemplate/tpg-delete-apps \
  -p clusters=aks-tpg-poc-04 -p apps='{"aks-tpg-poc-04":["tpg-operator"]}' -p confirm=aks-tpg-poc-04 \
  -p dryRun=false -p purgePvcs=true -p purgeNamespace=true -p pushMode=direct \
  -p force=true -p finalBackup=false --watch
```

With a parameter file (easier for JSON):

```yaml
# delete-lab.yaml
clusters: aks-tpg-poc-03
apps: '{"aks-tpg-poc-03": ["tpg-instances:scratch-db,test-db", "tpg-operator"]}'
confirm: aks-tpg-poc-03
dryRun: "false"
purgePvcs: "true"
purgeNamespace: "true"
pushMode: direct
```

```bash
argo submit --from workflowtemplate/tpg-delete-apps --parameter-file delete-lab.yaml --watch
```

---

## 7. tpg-delete-instance

Guarded delete of one instance (the per-instance step that `tpg-delete-apps` uses).

```bash
# 1. Delete billing-db, keep volumes and namespace
argo submit --from workflowtemplate/tpg-delete-instance \
  -p cluster=aks-tpg-poc-01 -p instance=billing-db -p confirm=billing-db --watch

# 2. Require a final backup, purge volumes and namespace, through a pull request
argo submit --from workflowtemplate/tpg-delete-instance \
  -p cluster=aks-tpg-poc-02 -p instance=orders-db -p confirm=orders-db \
  -p finalBackup=required -p purgePvcs=true -p purgeNamespace=true -p pushMode=pr --watch
```

---

## 8. tpg-helm-addons

Installs or upgrades the Helm releases on target clusters: `cert-manager`, and for the standalone monitoring option `kps` (Prometheus agent) and `tpg-ksm`. The hub `kps` release is installed by `tpg-aks-infra/scripts/run.sh --only addons`.

| Input | Mandatory | Default | Description |
|---|---|---|---|
| `clusters` | yes | | Registered clusters or `all` |
| `components` | no | `auto` | `auto`, `cert-manager`, `monitoring` or `cert-manager,monitoring` |
| `dryRun` | no | `false` | `helm upgrade --install --dry-run=server` |

```bash
# 1. Everything the monitoring option needs, on every cluster
argo submit --from workflowtemplate/tpg-helm-addons -p clusters=all --watch

# 2. cert-manager only on a new cluster
argo submit --from workflowtemplate/tpg-helm-addons -p clusters=aks-tpg-poc-04 -p components=cert-manager --watch

# 3. Dry run of the monitoring agent upgrade on two clusters
argo submit --from workflowtemplate/tpg-helm-addons \
  -p clusters=aks-tpg-poc-01,aks-tpg-poc-02 -p components=monitoring -p dryRun=true --watch
```

---

## 9. tpg-backup

```bash
# 1. Full backup of every instance on every cluster
argo submit --from workflowtemplate/tpg-backup -p backupType=full -p clusters=all --watch

# 2. Differential backup on one cluster
argo submit --from workflowtemplate/tpg-backup -p backupType=differential -p clusters=aks-tpg-poc-01 --watch

# 3. Same selection as the CronWorkflows (skips backupSchedule=none instances)
argo submit --from workflowtemplate/tpg-backup -p backupType=full -p clusters=all -p scheduledOnly=true --watch

# Run a CronWorkflow now
argo cron list
argo submit --from cronwf/tpg-backup-full --watch
```

---

## 10. tpg-restore-pitr

| Input | Mandatory | Default |
|---|---|---|
| `clusters` | yes | |
| `instance` | yes | |
| `targetTime` | yes | |
| `inPlace` | no | `false` |
| `confirmInPlace` | with `inPlace=true` | |
| `bestEffort` | no | `false` |
| `restoreTimeoutSeconds` | no | `7200` |

```bash
# 1. Restore to a new instance orders-db-pitr-<yyyymmddhhmm> on one cluster
argo submit --from workflowtemplate/tpg-restore-pitr \
  -p clusters=aks-tpg-poc-01 -p instance=orders-db -p targetTime=2026-09-15T08:30:00Z --watch

# 2. Same restore on two clusters
argo submit --from workflowtemplate/tpg-restore-pitr \
  -p clusters=aks-tpg-poc-01,aks-tpg-poc-02 -p instance=orders-db -p targetTime=2026-09-15T08:30:00Z --watch

# 3. In place (destructive)
argo submit --from workflowtemplate/tpg-restore-pitr \
  -p clusters=aks-tpg-poc-01 -p instance=orders-db -p targetTime=2026-09-15T08:30:00Z \
  -p inPlace=true -p confirmInPlace=orders-db --watch
```

---

## 11. tpg-rotate-credential

```bash
# Update the hub source Secret first, then:
argo submit --from workflowtemplate/tpg-rotate-credential -p secretType=broadcom-registry --watch
argo submit --from workflowtemplate/tpg-rotate-credential -p secretType=backup-storage --watch
argo submit --from workflowtemplate/tpg-rotate-credential -p secretType=git-push --watch
```

---

## 12. Follow, approve, stop and clean up runs

```bash
argo list                                   # runs with status and duration
argo list --running
argo list -l workflows.argoproj.io/workflow-template=tpg-day0
argo get @latest                            # step tree of the newest run
argo watch @latest
argo logs @latest --follow
argo logs <workflow> -c main | sed -n '/tpg run report/,$p'
kubectl -n argo get configmap tpg-run-<workflow> -o yaml   # raw results per target

argo resume <workflow>                      # approve a suspended step (tpg-upgrade allowMajor=true)
argo suspend <workflow>
argo stop <workflow>                        # run exit handlers (report), then stop
argo terminate <workflow>                   # stop immediately, no exit handler
argo retry <workflow>                       # rerun failed steps
argo resubmit <workflow> --memoized         # new run with the same inputs
argo delete <workflow>                      # also deletes tpg-run-<workflow>
argo delete --older 7d
```

---

## 13. argocd CLI: the sync steps behind the workflows

The workflows call the Argo CD API as `workflow-bot`. Use these commands to inspect what a workflow did or to repeat a step by hand. Applications: `tpg-<cluster>-platform`, `tpg-<cluster>-operator`, `tpg-<cluster>-<instance>`, `tpg-hub-workflows`.

```bash
# What exists and its state
argocd app list -l tpg.fleet/cluster=aks-tpg-poc-01
argocd app list -l tpg.fleet/component=operator
argocd app get tpg-aks-tpg-poc-01-orders-db --show-operation
argocd appset get tpg-instances
argocd cluster list

# Hub workflows (templates, scripts, RBAC) after a change in Git
argocd app get tpg-hub-workflows --refresh
argocd app sync tpg-hub-workflows && argocd app wait tpg-hub-workflows --health --timeout 300

# Regenerate Applications right after a fleet.yaml commit (same as the workflows)
kubectl -n argocd annotate applicationset tpg-instances argocd.argoproj.io/application-set-refresh=true --overwrite
kubectl -n argocd annotate applicationset tpg-operator argocd.argoproj.io/application-set-refresh=true --overwrite

# Day 0 sync order for one cluster (platform, operator, instances)
argocd app sync tpg-aks-tpg-poc-01-platform && argocd app wait tpg-aks-tpg-poc-01-platform --health --timeout 1800
argocd app sync tpg-aks-tpg-poc-01-operator && argocd app wait tpg-aks-tpg-poc-01-operator --health --timeout 1800
argocd app sync -l tpg.fleet/cluster=aks-tpg-poc-01,tpg.fleet/component=instance
argocd app wait -l tpg.fleet/cluster=aks-tpg-poc-01,tpg.fleet/component=instance --health --timeout 1800

# Operator upgrade check: the rendered chart version after the fleet.yaml commit
argocd app get tpg-aks-tpg-poc-01-operator -o json | jq -r '.spec.source.targetRevision'
argocd app diff tpg-aks-tpg-poc-01-operator

# Scale check: the Postgres spec Argo CD will apply
argocd app manifests tpg-aks-tpg-poc-02-orders-db --source git | yq 'select(.kind == "Postgres") | .spec.highAvailability'
argocd app sync tpg-aks-tpg-poc-02-orders-db --resource sql.tanzu.vmware.com:Postgres:orders-db

# Troubleshooting a failed sync
argocd app get tpg-aks-tpg-poc-01-orders-db --hard-refresh
argocd app history tpg-aks-tpg-poc-01-orders-db
argocd app terminate-op tpg-aks-tpg-poc-01-orders-db
argocd repo list
```

Do not run `argocd app delete` with cascade on instance Applications: the delete workflows remove them without cascading and delete database objects in order.
