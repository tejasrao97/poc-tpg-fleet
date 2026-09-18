#!/usr/bin/env bash
# Shared functions for tpg workflow steps. Sourced by every step script.
# Runs in the tools image (alpine/k8s): bash, kubectl, jq, yq (v4), git, curl.
# Hub operations use the pod ServiceAccount (tpg-workflow); target operations
# use the kubeconfig-<cluster> Secret through tk().

set -euo pipefail

ARGO_NS="argo"
ARGOCD_URL="${ARGOCD_URL:-https://argocd-server.argocd.svc.cluster.local}"
WORK="/tmp/work"
mkdir -p "$WORK"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# ----------------------------------------------------------------- settings
setting() {
  kubectl -n "$ARGO_NS" get configmap tpg-settings -o json | jq -r --arg k "$1" '.data[$k] // empty'
}

secret_val() {
  kubectl -n "$ARGO_NS" get secret "$1" -o json | jq -r --arg k "$2" '.data[$k] // empty' | base64 -d
}

# ----------------------------------------------------------------- run results
# Every step records one result per target in ConfigMap tpg-run-<workflow>.
run_cm() { printf 'tpg-run-%s' "$WF"; }

record() {
  # record KEY STATUS [REASON] [DETAIL] [PREVIOUS]
  local key="$1" status="$2" reason="${3:-}" detail="${4:-}" previous="${5:-}" value patch
  value="$(jq -cn --arg s "$status" --arg r "$reason" --arg d "$detail" --arg p "$previous" \
    --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{status:$s, reason:$r, detail:$d, previous:$p, time:$t}')"
  patch="$(jq -cn --arg k "$key" --arg v "$value" '{data: {($k): $v}}')"
  kubectl -n "$ARGO_NS" patch configmap "$(run_cm)" --type merge -p "$patch" >/dev/null
  printf '%s' "$status" > /tmp/result
  log "RESULT ${key} ${status} ${reason} ${detail}"
}

record_status() {
  kubectl -n "$ARGO_NS" get configmap "$(run_cm)" -o json \
    | jq -r --arg k "$1" '(.data[$k] // "{}") | fromjson | .status // ""'
}

run_data() {
  kubectl -n "$ARGO_NS" get configmap "$(run_cm)" -o json | jq -r --arg k "$1" '.data[$k] // empty'
}

# ----------------------------------------------------------------- clusters
use_cluster() {
  CLUSTER="$1"
  mkdir -p /tmp/kube
  secret_val "kubeconfig-${CLUSTER}" config > "/tmp/kube/${CLUSTER}"
  chmod 600 "/tmp/kube/${CLUSTER}"
  [[ -s "/tmp/kube/${CLUSTER}" ]] || { log "kubeconfig-${CLUSTER} not found"; return 1; }
}

tk() { kubectl --kubeconfig "/tmp/kube/${CLUSTER}" --request-timeout=60s "$@"; }

inventory_cluster() {
  # inventory_cluster NAME -> JSON object for the cluster from the run inventory
  run_data inventory | jq -c --arg c "$1" '.[] | select(.name == $c)'
}

inventory_instances() {
  run_data inventory | jq -r --arg c "$1" '.[] | select(.name == $c) | .instances[].name'
}

# ----------------------------------------------------------------- Argo CD API
argocd_token() { secret_val argocd-workflow-token token; }

acd() {
  # acd METHOD PATH [JSON_BODY]
  local method="$1" path="$2" body="${3:-}"
  local args=(-sk --fail-with-body -X "$method" -H "Authorization: Bearer $(argocd_token)")
  if [[ -n "$body" ]]; then
    args+=(-H 'Content-Type: application/json' -d "$body")
  fi
  curl "${args[@]}" "${ARGOCD_URL}${path}"
}

app_list() {
  # app_list SELECTOR -> application names
  curl -sk --fail-with-body -G -H "Authorization: Bearer $(argocd_token)" \
    --data-urlencode "selector=$1" "${ARGOCD_URL}/api/v1/applications" \
    | jq -r '.items[]?.metadata.name'
}

app_exists() { acd GET "/api/v1/applications/$1" >/dev/null 2>&1; }

app_refresh() { acd GET "/api/v1/applications/$1?refresh=hard" >/dev/null; }

appset_refresh() {
  # Ask the ApplicationSet controller to re-read Git now instead of waiting for the poll.
  kubectl -n argocd annotate applicationset "$1" \
    argocd.argoproj.io/application-set-refresh=true --overwrite >/dev/null
}

app_sync() {
  local app="$1" i
  local body='{"prune":false,"retryStrategy":{"limit":3,"backoff":{"duration":"10s","factor":2,"maxDuration":"3m"}}}'
  for i in 1 2 3 4 5 6; do
    if acd POST "/api/v1/applications/${app}/sync" "$body" >/dev/null 2>&1; then
      log "sync requested for ${app}"
      return 0
    fi
    log "sync request for ${app} rejected (attempt ${i}), another operation may be running"
    sleep 20
  done
  return 1
}

app_wait() {
  # app_wait APP TIMEOUT_SECONDS -> 0 when Synced and Healthy with no running operation
  local app="$1" timeout="$2" start j op sync health
  start="$(date +%s)"
  while true; do
    j="$(acd GET "/api/v1/applications/${app}" 2>/dev/null || echo '{}')"
    op="$(jq -r '.status.operationState.phase // ""' <<<"$j")"
    sync="$(jq -r '.status.sync.status // ""' <<<"$j")"
    health="$(jq -r '.status.health.status // ""' <<<"$j")"
    case "$op" in
      Failed|Error)
        log "${app}: sync operation ${op}: $(jq -r '.status.operationState.message // ""' <<<"$j")"
        return 1 ;;
    esac
    if [[ "$op" != "Running" && "$sync" == "Synced" && "$health" == "Healthy" ]]; then
      log "${app}: Synced/Healthy"
      return 0
    fi
    if (( $(date +%s) - start > timeout )); then
      log "${app}: timeout (operation=${op} sync=${sync} health=${health})"
      return 2
    fi
    sleep 15
  done
}

app_target_revision() {
  acd GET "/api/v1/applications/$1" | jq -r '.spec.source.targetRevision // ""'
}

# ----------------------------------------------------------------- Git
git_clone() {
  local dest="$1" url rev user token auth
  url="$(setting fleetRepoURL)"
  rev="$(setting fleetRevision)"
  user="$(secret_val tpg-git-push username)"
  token="$(secret_val tpg-git-push token)"
  auth="$(printf '%s:%s' "$user" "$token" | base64 | tr -d '\n')"
  rm -rf "$dest"
  git -c credential.helper= -c "http.extraHeader=Authorization: Basic ${auth}" \
    clone --quiet --depth 50 --branch "$rev" "$url" "$dest"
  git -C "$dest" config http.extraHeader "Authorization: Basic ${auth}"
  git -C "$dest" config credential.helper ""
  git -C "$dest" config user.name "tpg-workflow"
  git -C "$dest" config user.email "tpg-workflow@users.noreply.github.com"
}

git_commit_push() {
  # git_commit_push REPO_DIR MESSAGE FILE... -> 0 when published or nothing to commit
  # PUSH_MODE=direct (default): push to the fleet revision, rebasing on conflicts.
  # PUSH_MODE=pr: push a branch, open a GitHub pull request and wait until it is
  # merged (PR_TIMEOUT_SECONDS, default 3600); a closed pull request fails.
  local dir="$1" msg="$2" rev i
  shift 2
  rev="$(setting fleetRevision)"
  if [[ "${FLEET_CLONE:-}" == "$dir" && -d "$WORK/fleet" ]]; then
    fleet_flush "$dir"
  fi
  git -C "$dir" add -- "$@"
  if git -C "$dir" diff --cached --quiet; then
    log "no Git change needed"
    return 0
  fi
  if [[ "${PUSH_MODE:-direct}" == "pr" ]]; then
    git_publish_pr "$dir" "$msg" "$rev"
    return
  fi
  git -C "$dir" commit --quiet -m "$msg"
  for i in 1 2 3 4 5; do
    if git -C "$dir" push --quiet origin "HEAD:${rev}"; then
      log "pushed: ${msg}"
      return 0
    fi
    log "push rejected (attempt ${i}), rebasing"
    git -C "$dir" pull --quiet --rebase origin "$rev"
  done
  return 1
}

github_repo() {
  # owner/repo from the fleet repository URL (https://github.com/<owner>/<repo>.git)
  setting fleetRepoURL | sed -E 's#^https?://[^/]+/##; s#\.git$##; s#/$##'
}

github_api() {
  # github_api METHOD PATH [JSON_BODY]
  local base token args
  base="$(setting githubApiUrl)"; base="${base:-https://api.github.com}"
  token="$(secret_val tpg-git-push token)"
  args=(-sS --fail-with-body -X "$1" -H "Authorization: Bearer ${token}"
        -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
  [[ -z "${3:-}" ]] || args+=(-H 'Content-Type: application/json' -d "$3")
  curl "${args[@]}" "${base}$2"
}

git_publish_pr() {
  # git_publish_pr REPO_DIR MESSAGE BASE_REVISION: commit staged changes to a branch,
  # open a pull request and wait for it to be merged, then fast-forward the clone.
  local dir="$1" msg="$2" rev="$3" branch repo pr number url state merged start timeout
  timeout="${PR_TIMEOUT_SECONDS:-3600}"
  branch="tpg/${WF:-manual}-$(date -u +%Y%m%d%H%M%S)-${RANDOM}"
  repo="$(github_repo)"
  git -C "$dir" checkout --quiet -b "$branch"
  git -C "$dir" commit --quiet -m "$msg"
  git -C "$dir" push --quiet origin "HEAD:refs/heads/${branch}" || { log "push of branch ${branch} failed"; return 1; }
  pr="$(github_api POST "/repos/${repo}/pulls" "$(jq -cn --arg t "$msg" --arg h "$branch" --arg b "$rev" \
    --arg body "Opened by Argo Workflow ${WF:-manual}. The workflow continues when this pull request is merged." \
    '{title:$t, head:$h, base:$b, body:$body}')")" || { log "could not open a pull request: ${pr:-}"; return 1; }
  number="$(jq -r '.number' <<<"$pr")"; url="$(jq -r '.html_url' <<<"$pr")"
  log "pull request #${number} opened: ${url}; waiting up to ${timeout}s for the merge"
  printf '%s' "$url" > /tmp/pull-request
  start="$(date +%s)"
  while true; do
    pr="$(github_api GET "/repos/${repo}/pulls/${number}" 2>/dev/null || echo '{}')"
    state="$(jq -r '.state // ""' <<<"$pr")"; merged="$(jq -r '.merged // false' <<<"$pr")"
    if [[ "$merged" == "true" ]]; then
      log "pull request #${number} merged"
      break
    fi
    if [[ "$state" == "closed" ]]; then
      log "pull request #${number} was closed without merging"
      return 1
    fi
    if (( $(date +%s) - start > timeout )); then
      log "pull request #${number} not merged after ${timeout}s"
      return 1
    fi
    sleep 30
  done
  git -C "$dir" fetch --quiet origin "$rev"
  git -C "$dir" checkout --quiet -B "$rev" "origin/${rev}"
  if [[ "${FLEET_CLONE:-}" == "$dir" && -d "$WORK/fleet" ]]; then
    fleet_materialize "$dir"
  fi
}

# ----------------------------------------------------------------- fleet (clusters/fleet.yaml)
# clusters/_template/cluster.yaml   cluster defaults
# clusters/_template/instance.yaml  instance defaults
# clusters/fleet.yaml               clusters.<cluster>.{operator,cluster,backup,instances.<instance>}
FLEET_REL="clusters/fleet.yaml"
TEMPLATE_CLUSTER_REL="clusters/_template/cluster.yaml"
TEMPLATE_INSTANCE_REL="clusters/_template/instance.yaml"

registered_clusters() {
  # Clusters registered by tpg-aks-infra (Secret argo/kubeconfig-<cluster>), one per line
  kubectl -n "$ARGO_NS" get secret -l tpg.fleet/cluster -o json \
    | jq -r '.items[].metadata.labels["tpg.fleet/cluster"]' | sort -u
}

registered_wave() {
  # registered_wave CLUSTER -> tpg.fleet/wave label of argo/kubeconfig-<cluster> (default 1)
  local w
  w="$(kubectl -n "$ARGO_NS" get secret "kubeconfig-$1" -o json 2>/dev/null \
    | jq -r '.metadata.labels["tpg.fleet/wave"] // ""')"
  [[ "$w" =~ ^[0-9]+$ ]] && printf '%s' "$w" || printf '1'
}

fleet_has_cluster() { C="$2" yq -e '.clusters | has(strenv(C))' "$1/$FLEET_REL" >/dev/null 2>&1; }       # REPO CLUSTER
fleet_has_instance() { C="$2" I="$3" yq -e '.clusters[strenv(C)].instances | has(strenv(I))' "$1/$FLEET_REL" >/dev/null 2>&1; }  # REPO CLUSTER INSTANCE
fleet_clusters() { yq -r '.clusters // {} | keys | .[]' "$1/$FLEET_REL"; }                               # REPO
fleet_instances() { C="$2" yq -r '.clusters[strenv(C)].instances // {} | keys | .[]' "$1/$FLEET_REL"; }   # REPO CLUSTER

fleet_cluster_value() {
  # fleet_cluster_value REPO CLUSTER YQ_PATH DEFAULT -> fleet.yaml override, else _template/cluster.yaml, else DEFAULT
  local v
  # select(. != null) instead of // so that an explicit false is kept
  v="$(C="$2" yq -r ".clusters[strenv(C)]$3 | select(. != null)" "$1/$FLEET_REL")"
  [[ -n "$v" && "$v" != "null" ]] || v="$(yq -r "$3 | select(. != null)" "$1/$TEMPLATE_CLUSTER_REL")"
  [[ -n "$v" && "$v" != "null" ]] || v="$4"
  printf '%s' "$v"
}

fleet_instance_value() {
  # fleet_instance_value REPO CLUSTER INSTANCE YQ_PATH DEFAULT -> instance override, else _template/instance.yaml, else DEFAULT
  local v
  v="$(C="$2" I="$3" yq -r ".clusters[strenv(C)].instances[strenv(I)]$4 | select(. != null)" "$1/$FLEET_REL")"
  [[ -n "$v" && "$v" != "null" ]] || v="$(yq -r "$4 | select(. != null)" "$1/$TEMPLATE_INSTANCE_REL")"
  [[ -n "$v" && "$v" != "null" ]] || v="$5"
  printf '%s' "$v"
}

fleet_materialize() {
  # fleet_materialize REPO: write every instance entry to $WORK/fleet/<cluster>/<instance>.yaml
  # in the chart values layout (instance.name and backup.container filled in). Scripts edit
  # those files with yq; git_commit_push writes changed or new files back into fleet.yaml.
  local repo="$1" f="$1/$FLEET_REL" c i
  FLEET_CLONE="$repo"
  rm -rf "$WORK/fleet" "$WORK/fleet.orig"
  mkdir -p "$WORK/fleet"
  for c in $(fleet_clusters "$repo"); do
    mkdir -p "$WORK/fleet/$c"
    for i in $(fleet_instances "$repo" "$c"); do
      C="$c" I="$i" yq '(.clusters[strenv(C)].instances[strenv(I)] // {})
        | .instance.name = strenv(I)
        | .backup.container = (.backup.container // ("pg-backups-" + strenv(C)))' "$f" > "$WORK/fleet/$c/$i.yaml"
    done
  done
  cp -r "$WORK/fleet" "$WORK/fleet.orig"
}

fleet_flush() {
  # fleet_flush REPO: copy edited or new materialized instance files back into fleet.yaml
  local repo="$1" f="$1/$FLEET_REL" p c i
  for p in "$WORK"/fleet/*/*.yaml; do
    [[ -f "$p" ]] || continue
    c="$(basename "$(dirname "$p")")"; i="$(basename "$p" .yaml)"
    cmp -s "$p" "$WORK/fleet.orig/$c/$i.yaml" 2>/dev/null && continue
    C="$c" I="$i" P="$p" yq -i '.clusters[strenv(C)].instances[strenv(I)] = (load(strenv(P)) | del(.instance.name))' "$f"
    mkdir -p "$WORK/fleet.orig/$c"
    cp "$p" "$WORK/fleet.orig/$c/$i.yaml"
    log "fleet.yaml: updated ${c}/${i}"
  done
}

# ----------------------------------------------------------------- Postgres helpers
pg_state() { tk -n "pg-$1" get postgres "$1" -o jsonpath='{.status.currentState}' 2>/dev/null || true; }

pg_wait_running() {
  # pg_wait_running INSTANCE TIMEOUT_SECONDS
  local inst="$1" timeout="$2" start s
  start="$(date +%s)"
  while true; do
    s="$(pg_state "$inst")"
    [[ "$s" == "Running" ]] && return 0
    if (( $(date +%s) - start > timeout )); then
      log "${inst}: currentState=${s:-none} after ${timeout}s"
      return 1
    fi
    sleep 20
  done
}

sts_ready() {
  # sts_ready INSTANCE -> 0 when readyReplicas equals spec.replicas
  local j
  j="$(tk -n "pg-$1" get statefulset "$1" -o json 2>/dev/null || echo '{}')"
  jq -e '(.spec.replicas // -1) == (.status.readyReplicas // -2)' <<<"$j" >/dev/null
}

sts_wait_ready() {
  local inst="$1" timeout="$2" start
  start="$(date +%s)"
  until sts_ready "$inst"; do
    if (( $(date +%s) - start > timeout )); then
      return 1
    fi
    sleep 15
  done
}

latest_cr() {
  # latest_cr KIND NAMESPACE JQ_FILTER -> newest matching object as JSON, or empty
  tk -n "$2" get "$1" -o json 2>/dev/null \
    | jq -c "[.items[] | select($3)] | sort_by(.metadata.creationTimestamp) | last // empty"
}

major_of() { sed -E 's/^[^0-9]*([0-9]+).*/\1/' <<<"$1"; }

# ----------------------------------------------------------------- instance operations
busy_operations() {
  # busy_operations INSTANCE -> kinds with an unfinished operation (empty when idle)
  local ns="pg-$1" kind n
  for kind in postgresbackup postgresrestore postgresversionupgrade; do
    n="$(tk -n "$ns" get "$kind" -o json 2>/dev/null \
      | jq -r '[.items[] | select((.status.phase // "") | test("^(Succeeded|Failed|PreCheckFailed)$") | not)] | length')"
    [[ "${n:-0}" -eq 0 ]] || printf '%s ' "$kind"
  done
}

sync_instance_app() {
  # sync_instance_app CLUSTER INSTANCE TIMEOUT: refresh, sync and wait (creates the
  # Application first when the instance file is new)
  local app="tpg-$1-$2" timeout="$3" i
  if ! app_exists "$app"; then
    appset_refresh tpg-instances
    for i in $(seq 1 40); do
      app_exists "$app" && break
      sleep 15
    done
    app_exists "$app" || { log "${app} was not generated"; return 3; }
  fi
  app_refresh "$app"
  app_sync "$app" || return 1
  app_wait "$app" "$timeout"
}

# ----------------------------------------------------------------- input parameters
norm_operator_version() {
  # 4.5.0 | v4.5.0 -> v4.5.0 (operator chart OCI tag)
  local v="${1#v}"
  printf 'v%s' "$v"
}

norm_postgres_version() {
  # 17.6 | postgres-17.6 -> postgres-17.6 (PostgresVersion name)
  local v="${1#postgres-}"
  printf 'postgres-%s' "$v"
}

split_list() {
  # split_list "a, b,,c" -> one trimmed item per line
  tr ',' '\n' <<<"$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true
}
