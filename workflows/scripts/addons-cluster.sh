#!/usr/bin/env bash
# addons-cluster.sh WORKFLOW_NAME CLUSTER COMPONENTS DRY_RUN [RESULT_KEY]
# Install or upgrade the Helm add-on releases on one target cluster with helm-addons.sh.
# COMPONENTS: auto (cert-manager, plus monitoring when tpg-settings monitoringOption is
# standalone) or a comma-separated list of cert-manager and monitoring.
# MONITORING_OPTION in the environment overrides tpg-settings monitoringOption.
WF="$1"; C="$2"; COMPONENTS="$3"; DRY="${4:-false}"; KEY="${5:-result.${C}}"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh

fail() { record "$KEY" FAILED "$1" "${2:-}"; exit 1; }
use_cluster "$C" || fail NOT_REGISTERED
option="${MONITORING_OPTION:-}"; [[ -n "$option" ]] || option="$(setting monitoringOption)"; option="${option:-none}"
if [[ "$COMPONENTS" == "auto" ]]; then
  COMPONENTS="cert-manager"
  [[ "$option" == "standalone" ]] && COMPONENTS="cert-manager,monitoring"
fi
args=(--cluster "$C" --role target --components "$COMPONENTS" --kubeconfig "/tmp/kube/${C}")
if [[ ",${COMPONENTS}," == *",monitoring,"* ]]; then
  url="$(setting hubPrometheusRemoteWriteUrl)"
  [[ -n "$url" ]] || fail NO_REMOTE_WRITE_URL "tpg-settings hubPrometheusRemoteWriteUrl is empty: run tpg-aks-infra scripts/run.sh --only addons first"
  args+=(--remote-write-url "$url")
fi
[[ "$DRY" == "true" ]] && args+=(--dry-run)
git_clone "$WORK/repo"
args+=(--fleet-dir "$WORK/repo")
if ! bash /scripts/helm-addons.sh "${args[@]}"; then
  fail HELM_RELEASE_FAILED "$COMPONENTS"
fi
releases="$(helm --kubeconfig "/tmp/kube/${C}" list -A -o json 2>/dev/null \
  | jq -r '[.[] | select(.name == "cert-manager" or .name == "kps" or .name == "tpg-ksm") | .name + "@" + .chart + "(" + .status + ")"] | join(" ")' || true)"
if [[ "$DRY" == "true" ]]; then
  record "$KEY" SUCCEEDED DRY_RUN "$COMPONENTS"
else
  record "$KEY" SUCCEEDED "" "${releases:-$COMPONENTS}"
fi
