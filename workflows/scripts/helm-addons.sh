#!/usr/bin/env bash
# helm-addons.sh: install or upgrade the fleet add-ons as Helm releases on one cluster.
#
#   cert-manager (targets)   release cert-manager  jetstack/cert-manager            ns cert-manager
#   monitoring   (hub)       release kps           kube-prometheus-stack            ns monitoring
#                                                  + monitoring/standalone/hub (kubectl apply -k)
#   monitoring   (targets)   release kps           kube-prometheus-stack (agent)    ns monitoring
#                            release tpg-ksm       kube-state-metrics
#                                                  + monitoring/standalone/targets (kubectl apply -k)
#
# Used by tpg-aks-infra scripts/steps/45-helm-addons.sh (workstation, hub and targets)
# and by the tpg-helm-addons and tpg-day0 workflows (targets only).
#
# Usage:
#   helm-addons.sh --cluster NAME --role hub|target --components cert-manager,monitoring \
#     --fleet-dir DIR [--kubeconfig FILE] [--context CTX] [--remote-write-url URL] [--dry-run]
#
# Hub monitoring: Grafana reads its admin credentials from Secret monitoring/grafana-admin.
# The script creates it before the install when it is missing, with GRAFANA_ADMIN_PASSWORD
# from the environment or a generated 24-character password. The password is never
# written to a file. On success the hub run prints REMOTE_WRITE_URL=<url>.
# KPS_HUB_EXTRA_VALUES: optional comma-separated extra values files for the hub release,
# relative to --fleet-dir (for example monitoring/grafana/smtp/grafana-smtp-values.yaml).
set -euo pipefail

CERT_MANAGER_VERSION="v1.21.2"
KPS_VERSION="91.4.0"
KSM_VERSION="8.5.0"
JETSTACK_REPO="https://charts.jetstack.io"
PROM_REPO="https://prometheus-community.github.io/helm-charts"

CLUSTER="" ROLE="" COMPONENTS="" FLEET_DIR="" KUBECONFIG_FILE="" CONTEXT="" RW_URL="" DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster) CLUSTER="$2"; shift 2 ;;
    --role) ROLE="$2"; shift 2 ;;
    --components) COMPONENTS="$2"; shift 2 ;;
    --fleet-dir) FLEET_DIR="$2"; shift 2 ;;
    --kubeconfig) KUBECONFIG_FILE="$2"; shift 2 ;;
    --context) CONTEXT="$2"; shift 2 ;;
    --remote-write-url) RW_URL="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

say() { printf '[helm-addons %s] %s\n' "$CLUSTER" "$*" >&2; }
die() { say "ERROR: $*"; exit 1; }
[[ -n "$CLUSTER" && -n "$COMPONENTS" && -d "$FLEET_DIR" ]] || die "--cluster, --components and --fleet-dir are required"
[[ "$ROLE" == "hub" || "$ROLE" == "target" ]] || die "--role must be hub or target"
command -v helm >/dev/null || die "helm is required"

KARGS=(); HARGS=()
if [[ -n "$KUBECONFIG_FILE" ]]; then KARGS+=(--kubeconfig "$KUBECONFIG_FILE"); HARGS+=(--kubeconfig "$KUBECONFIG_FILE"); fi
if [[ -n "$CONTEXT" ]]; then KARGS+=(--context "$CONTEXT"); HARGS+=(--kube-context "$CONTEXT"); fi
k() { kubectl "${KARGS[@]}" "$@"; }
h() { helm "${HARGS[@]}" "$@"; }

release() {
  # release NAME CHART VERSION REPO NAMESPACE [helm args...]
  local name="$1" chart="$2" version="$3" repo="$4" ns="$5"
  shift 5
  if [[ "$DRY_RUN" -eq 1 ]]; then
    say "dry run: helm upgrade --install ${name} ${chart} ${version} -n ${ns}"
    h upgrade --install "$name" "$chart" --repo "$repo" --version "$version" -n "$ns" --create-namespace \
      --dry-run=server "$@" >/dev/null
    return
  fi
  say "helm upgrade --install ${name} (${chart} ${version}) in ${ns}"
  h upgrade --install "$name" "$chart" --repo "$repo" --version "$version" -n "$ns" --create-namespace \
    --wait --timeout 15m "$@" >/dev/null
  h status "$name" -n "$ns" -o json | jq -r '"  " + .name + " revision " + (.version | tostring) + " " + .info.status' >&2
}

not_helm_owned() {
  # not_helm_owned NAMESPACE KIND NAME RELEASE -> 0 when the object exists but another tool manages it
  local j
  j="$(k -n "$1" get "$2" "$3" -o json 2>/dev/null)" || return 1
  [[ "$(jq -r '.metadata.annotations["meta.helm.sh/release-name"] // ""' <<<"$j")" != "$4" ]]
}

cert_manager() {
  if not_helm_owned cert-manager deployment cert-manager cert-manager; then
    die "cert-manager/cert-manager exists but is not the Helm release cert-manager (for example an Argo CD Application). Remove that installation first."
  fi
  release cert-manager cert-manager "$CERT_MANAGER_VERSION" "$JETSTACK_REPO" cert-manager \
    --set crds.enabled=true
  [[ "$DRY_RUN" -eq 1 ]] || k -n cert-manager wait deploy --all --for=condition=Available --timeout=300s >/dev/null
}

grafana_admin_secret() {
  if k -n monitoring get secret grafana-admin >/dev/null 2>&1; then
    say "Secret monitoring/grafana-admin exists; keeping it"
    return
  fi
  local pw="${GRAFANA_ADMIN_PASSWORD:-}" src="GRAFANA_ADMIN_PASSWORD"
  if [[ -z "$pw" ]]; then
    pw="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true)"
    src="generated"
  fi
  [[ "${#pw}" -ge 12 ]] || die "the Grafana admin password must have at least 12 characters"
  if [[ "$DRY_RUN" -eq 1 ]]; then say "dry run: would create Secret monitoring/grafana-admin (${src} password)"; return; fi
  k create namespace monitoring --dry-run=client -o yaml | k apply -f - >/dev/null
  k -n monitoring create secret generic grafana-admin \
    --from-literal=admin-user=admin --from-literal=admin-password="$pw" >/dev/null
  say "created Secret monitoring/grafana-admin (${src} password). Read it with:"
  say "  kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d"
}

monitoring_hub() {
  if not_helm_owned monitoring deployment kps-grafana kps; then
    die "monitoring/kps-grafana exists but is not the Helm release kps (for example the old tpg-hub-monitoring Application). Remove it first."
  fi
  grafana_admin_secret
  local extra=() f
  for f in ${KPS_HUB_EXTRA_VALUES//,/ }; do
    [[ "$f" == /* ]] || f="$FLEET_DIR/$f"
    [[ -f "$f" ]] || die "KPS_HUB_EXTRA_VALUES file not found: $f"
    extra+=(-f "$f")
  done
  release kps kube-prometheus-stack "$KPS_VERSION" "$PROM_REPO" monitoring \
    -f "$FLEET_DIR/monitoring/standalone/hub/kps-values.yaml" \
    -f "$FLEET_DIR/monitoring/grafana/alerts/grafana-alerting-values.yaml" "${extra[@]}"
  [[ "$DRY_RUN" -eq 1 ]] && return
  k apply -k "$FLEET_DIR/monitoring/standalone/hub" >/dev/null
  say "applied monitoring/standalone/hub (dashboard, ServiceMonitor, PrometheusRule)"
  local ip=""
  for _ in $(seq 1 40); do
    ip="$(k -n monitoring get svc -o json | jq -r '
      [.items[] | select(.spec.type == "LoadBalancer" and (.metadata.labels.release // "") == "kps"
        and ([.spec.ports[].port] | index(9090)))][0].status.loadBalancer.ingress[0].ip // empty')"
    [[ -n "$ip" ]] && break
    sleep 15
  done
  [[ -n "$ip" ]] || die "hub Prometheus load balancer has no IP after 10 minutes"
  printf 'REMOTE_WRITE_URL=http://%s:9090/api/v1/write\n' "$ip"
}

monitoring_target() {
  [[ -n "$RW_URL" ]] || die "--remote-write-url is required for target monitoring (the hub Prometheus remote write URL)"
  if not_helm_owned monitoring deployment tpg-ksm tpg-ksm; then
    die "monitoring/tpg-ksm exists but is not the Helm release tpg-ksm (for example the tpg-monitoring-* Application). Remove it first."
  fi
  release kps kube-prometheus-stack "$KPS_VERSION" "$PROM_REPO" monitoring \
    -f "$FLEET_DIR/monitoring/standalone/targets/kps-values.yaml" \
    --set-string "prometheus.prometheusSpec.externalLabels.cluster=${CLUSTER}" \
    --set-json "prometheus.prometheusSpec.remoteWrite=[{\"url\":\"${RW_URL}\"}]"
  release tpg-ksm kube-state-metrics "$KSM_VERSION" "$PROM_REPO" monitoring \
    -f "$FLEET_DIR/monitoring/ksm/values.yaml" \
    --set prometheus.monitor.enabled=true
  [[ "$DRY_RUN" -eq 1 ]] && return
  k apply -k "$FLEET_DIR/monitoring/standalone/targets" -n monitoring >/dev/null
  say "applied monitoring/standalone/targets (PodMonitor, ServiceMonitors)"
}

for comp in ${COMPONENTS//,/ }; do
  case "${ROLE}/${comp}" in
    target/cert-manager) cert_manager ;;
    hub/cert-manager) say "cert-manager is not installed on the hub (no Postgres instances there); skipping" ;;
    hub/monitoring) monitoring_hub ;;
    target/monitoring) monitoring_target ;;
    *) die "unknown component ${comp}" ;;
  esac
done
say "done: ${COMPONENTS} (${ROLE})"
