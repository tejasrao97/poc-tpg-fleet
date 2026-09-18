#!/usr/bin/env bash
# rotate-cluster.sh WORKFLOW_NAME CLUSTER SECRET_TYPE
# Replace a credential on one target cluster from its hub source Secret and verify it.
#   broadcom-registry: regsecret in tanzu-postgres-operator and every tpg.fleet/managed namespace
#   backup-storage:    backup-storage in every pg-* managed namespace
# Records result.<cluster> UPDATED | FAILED | SKIPPED. Exits 1 on FAILED.
WF="$1"; C="$2"; TYPE="$3"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh

key="result.${C}"
fail() { record "$key" FAILED "$1" "${2:-}"; exit 1; }
if ! use_cluster "$C" || ! tk get --raw=/readyz >/dev/null 2>&1; then
  record "$key" SKIPPED UNREACHABLE; exit 0
fi
mapfile -t NSS < <(tk get namespace -l tpg.fleet/managed=true -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
[[ "${#NSS[@]}" -gt 0 ]] || { record "$key" SKIPPED NO_MANAGED_NAMESPACES; exit 0; }

case "$TYPE" in
  broadcom-registry)
    REGISTRY="$(setting registryHost)"
    U="$(secret_val tpg-src-broadcom-registry username)"
    P="$(secret_val tpg-src-broadcom-registry password)"
    for ns in "${NSS[@]}"; do
      tk -n "$ns" create secret docker-registry regsecret --docker-server="https://${REGISTRY}/" \
        --docker-username="$U" --docker-password="$P" --dry-run=client -o yaml | tk apply -f - >/dev/null \
        || fail UPDATE_FAILED "$ns/regsecret"
    done
    image="$(tk -n tanzu-postgres-operator get deploy -l app=postgres-operator \
      -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null || true)"
    [[ -n "$image" ]] || fail VERIFY_FAILED "operator Deployment not found for pull test"
    pod="tpg-pull-check-$(date +%s)"
    tk -n tanzu-postgres-operator run "$pod" --image="$image" --restart=Never \
      --image-pull-policy=Always \
      --overrides='{"apiVersion":"v1","spec":{"imagePullSecrets":[{"name":"regsecret"}],"tolerations":[{"operator":"Exists"}]}}' \
      --command -- sh -c "exit 0" >/dev/null || fail VERIFY_FAILED "could not create pull-check pod"
    result=""
    for _ in $(seq 1 30); do
      waiting="$(tk -n tanzu-postgres-operator get pod "$pod" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
      pulled="$(tk -n tanzu-postgres-operator get pod "$pod" -o jsonpath='{.status.containerStatuses[0].imageID}' 2>/dev/null || true)"
      if [[ "$waiting" == "ErrImagePull" || "$waiting" == "ImagePullBackOff" ]]; then result="pull-failed"; break; fi
      if [[ -n "$pulled" ]]; then result="pulled"; break; fi
      sleep 5
    done
    tk -n tanzu-postgres-operator delete pod "$pod" --wait=false >/dev/null 2>&1 || true
    [[ "$result" == "pulled" ]] || fail VERIFY_FAILED "image pull with the new token: ${result:-timeout}"
    record "$key" UPDATED "" "regsecret updated in ${#NSS[@]} namespaces, image pull verified"
    ;;
  backup-storage)
    A="$(secret_val tpg-src-backup-storage accountName)"
    K="$(secret_val tpg-src-backup-storage accountKey)"
    count=0
    for ns in "${NSS[@]}"; do
      [[ "$ns" == pg-* ]] || continue
      tk -n "$ns" create secret generic backup-storage --from-literal=accountName="$A" \
        --from-literal=accountKey="$K" --dry-run=client -o yaml | tk apply -f - >/dev/null \
        || fail UPDATE_FAILED "$ns/backup-storage"
      rv="$(tk -n "$ns" get secret backup-storage -o jsonpath='{.metadata.resourceVersion}')"
      for bl in $(tk -n "$ns" get postgresbackuplocation -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        okk=""
        for _ in $(seq 1 30); do
          cur="$(tk -n "$ns" get postgresbackuplocation "$bl" -o jsonpath='{.status.currentSecretResourceVersion}' 2>/dev/null || true)"
          [[ "$cur" == "$rv" ]] && { okk=1; break; }
          sleep 10
        done
        [[ -n "$okk" ]] || fail VERIFY_FAILED "$ns/$bl did not pick up Secret resourceVersion $rv"
      done
      count=$((count + 1))
    done
    record "$key" UPDATED "" "backup-storage updated in ${count} namespaces, backup locations reconciled"
    ;;
  *) fail INVALID_SECRET_TYPE "$TYPE" ;;
esac
