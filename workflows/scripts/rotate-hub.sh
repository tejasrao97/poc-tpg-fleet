#!/usr/bin/env bash
# rotate-hub.sh WORKFLOW_NAME SECRET_TYPE
# Hub side of credential rotation.
#   broadcom-registry: update Argo CD repository Secret repo-tanzu-postgres-oci, verify connection
#   git-push:          verify tpg-git-push can read and write-authenticate against the fleet repo
WF="$1"; TYPE="$2"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh

key="result.hub"
fail() { record "$key" FAILED "$1" "${2:-}"; exit 1; }

case "$TYPE" in
  broadcom-registry)
    U="$(secret_val tpg-src-broadcom-registry username)"
    P="$(secret_val tpg-src-broadcom-registry password)"
    patch="$(jq -cn --arg u "$U" --arg p "$P" '{stringData: {username: $u, password: $p}}')"
    kubectl -n argocd patch secret repo-tanzu-postgres-oci --type merge -p "$patch" >/dev/null \
      || fail UPDATE_FAILED "argocd/repo-tanzu-postgres-oci"
    host="$(setting registryHost)"
    sleep 20
    state="$(acd GET "/api/v1/repositories?forceRefresh=true" \
      | jq -r --arg h "$host" '.items[] | select(.repo == $h) | .connectionState.status' | head -n1)"
    [[ "$state" == "Successful" ]] || fail VERIFY_FAILED "Argo CD connection state for ${host}: ${state:-unknown}"
    record "$key" UPDATED "" "repo-tanzu-postgres-oci updated, Argo CD connection Successful"
    ;;
  git-push)
    git_clone "$WORK/repo" || fail VERIFY_FAILED "clone with tpg-git-push failed"
    git -C "$WORK/repo" push --dry-run --quiet origin "HEAD:$(setting fleetRevision)" \
      || fail VERIFY_FAILED "push authentication failed"
    record "$key" UPDATED "" "tpg-git-push verified (clone and push dry-run)"
    ;;
  backup-storage)
    record "$key" SKIPPED NOT_APPLICABLE "no hub Secret consumes the storage key"
    ;;
  *) fail INVALID_SECRET_TYPE "$TYPE" ;;
esac
