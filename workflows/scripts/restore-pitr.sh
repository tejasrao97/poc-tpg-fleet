#!/usr/bin/env bash
# restore-pitr.sh WORKFLOW_NAME CLUSTER INSTANCE TARGET_TIME IN_PLACE CONFIRM BEST_EFFORT TIMEOUT_SECONDS
# Point-in-time restore with PostgresRestore pitr.type=time (design decision D17).
# Default target: new instance <instance>-pitr-<yyyymmddhhmm> in the same namespace.
# Guard: previous restore still in progress -> wait 2 minutes -> SKIPPED_IN_PROGRESS.
WF="$1"; C="$2"; I="$3"; T="$4"; INPLACE="$5"; CONFIRM="$6"; BEST="$7"; TIMEOUT="$8"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh

key="result.${C}"
NS="pg-${I}"
fail() { record "$key" FAILED "$1" "${2:-}"; exit 0; }

[[ "$T" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || fail INVALID_TIMESTAMP "$T"
target_epoch="$(jq -rn --arg t "$T" '$t | fromdateiso8601')"
(( target_epoch < $(date +%s) )) || fail INVALID_TIMESTAMP "targetTime is in the future"
if [[ "$INPLACE" == "true" && "$CONFIRM" != "$I" ]]; then
  fail CONFIRMATION_MISMATCH "confirmInPlace must equal ${I}"
fi

use_cluster "$C" || fail NOT_REGISTERED
tk -n "$NS" get postgres "$I" >/dev/null 2>&1 || fail INSTANCE_NOT_FOUND "$NS/$I"

oldest="$(tk -n "$NS" get postgresbackup -o json | jq -r --arg i "$I" '
  [.items[] | select(.spec.sourceInstance.name == $i and .spec.type == "full" and .status.phase == "Succeeded" and .status.timeStarted != null)
   | .status.timeStarted | fromdateiso8601] | min // empty')"
[[ -n "$oldest" ]] || fail NO_FULL_BACKUP "no Succeeded full backup for ${I}"
(( target_epoch > oldest )) || fail OUTSIDE_RECOVERY_WINDOW "targetTime is older than the oldest full backup"

if [[ "$INPLACE" == "true" ]]; then TARGET_NAME="$I"; else TARGET_NAME="${I}-pitr-$(date -u -d "@${target_epoch}" +%Y%m%d%H%M)"; fi

in_progress() {
  local r
  r="$(latest_cr postgresrestore "$NS" ".spec.targetInstance.name == \"${TARGET_NAME}\" or .spec.targetInstance.name == \"${I}\"")"
  [[ -n "$r" ]] || return 1
  case "$(jq -r '.status.phase // ""' <<<"$r")" in
    Succeeded|Failed) return 1 ;;
    *) printf '%s' "$r"; return 0 ;;
  esac
}
if in_progress >/dev/null; then
  log "previous restore still in progress, waiting 2 minutes"
  sleep 120
  if R="$(in_progress)"; then
    record "$key" SKIPPED_IN_PROGRESS "" "$(jq -r '.metadata.name + " phase " + (.status.phase // "Pending")' <<<"$R")"
    exit 0
  fi
fi

if [[ "$INPLACE" != "true" ]] && tk -n "$NS" get postgres "$TARGET_NAME" >/dev/null 2>&1; then
  fail TARGET_EXISTS "$NS/$TARGET_NAME"
fi

BL="$(tk -n "$NS" get postgres "$I" -o jsonpath='{.spec.backupLocation.name}')"
STANZA="$(tk -n "$NS" get postgres "$I" -o jsonpath='{.status.stanzaName}')"
PGV="$(tk -n "$NS" get postgres "$I" -o jsonpath='{.spec.postgresVersion.name}')"
[[ -n "$BL" && -n "$STANZA" ]] || fail BACKUP_LOCATION_NOT_INITIALIZED

NAME="${TARGET_NAME}-restore-$(date -u +%Y%m%d%H%M%S)"
if [[ "$INPLACE" == "true" ]]; then
  TARGET_SPEC=""
else
  TARGET_SPEC="$(printf '    spec:\n      postgresVersion:\n        name: %s\n' "$PGV")"
fi

log "creating PostgresRestore ${NS}/${NAME} -> ${TARGET_NAME} at ${T}"
tk -n "$NS" apply -f - >/dev/null <<YAML || fail CREATE_FAILED
apiVersion: sql.tanzu.vmware.com/v1
kind: PostgresRestore
metadata:
  name: ${NAME}
  labels:
    tpg.fleet/workflow: ${WF}
spec:
  targetInstance:
    name: ${TARGET_NAME}
${TARGET_SPEC}
  pitr:
    type: time
    timestamp: "${T}"
    bestEffort: ${BEST}
    sourceBackupLocation:
      name: ${BL}
      stanzaName: ${STANZA}
YAML

start="$(date +%s)"
while true; do
  j="$(tk -n "$NS" get postgresrestore "$NAME" -o json 2>/dev/null || echo '{}')"
  phase="$(jq -r '.status.phase // ""' <<<"$j")"
  case "$phase" in
    Succeeded) break ;;
    Failed) fail RESTORE_FAILED "$(tk -n "$NS" describe postgresrestore "$NAME" | tail -n 15 | tr '\n' ' ')" ;;
  esac
  if (( $(date +%s) - start > TIMEOUT )); then
    record "$key" TIMEOUT "" "${NAME} phase=${phase:-none}"
    exit 0
  fi
  sleep 30
done

pg_wait_running "$TARGET_NAME" 1800 || fail TARGET_NOT_RUNNING "$TARGET_NAME"
sts_wait_ready "$TARGET_NAME" 1800 || fail TARGET_REPLICAS_NOT_READY "$TARGET_NAME"
note=""
[[ "$INPLACE" != "true" ]] && note=" (not managed by Argo CD: add a values file to keep it, or delete it after validation)"
record "$key" SUCCEEDED "" "restored ${NS}/${TARGET_NAME} to ${T}${note}"
