#!/usr/bin/env bash
# verify-storage-key.sh CONTAINER
# Runs in the azure-cli image. ACCOUNT_NAME and ACCOUNT_KEY come from the
# tpg-src-backup-storage Secret through secretKeyRef environment variables.
set -euo pipefail
exists="$(az storage container exists --name "$1" \
  --account-name "$ACCOUNT_NAME" --account-key "$ACCOUNT_KEY" --query exists -o tsv)"
if [[ "$exists" != "true" ]]; then
  echo "container $1 not accessible with the new key" >&2
  exit 1
fi
echo "container $1 accessible with the new key"
