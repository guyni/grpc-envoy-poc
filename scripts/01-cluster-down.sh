#!/usr/bin/env bash
# Delete the cluster this POC created, plus the host-side containers and TLS volume.
# Certificates and run artefacts under certs/ and out/ are left alone.
#
#   usage: ./scripts/01-cluster-down.sh [NAME] [--name NAME]
#
# NAME defaults to $CLUSTER_NAME (grpc-poc).
set -euo pipefail

CLUSTER_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)    CLUSTER_ARG="${2:?--name needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,7p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)        echo "unknown option: $1" >&2; exit 2 ;;
    *)         CLUSTER_ARG="$1"; shift ;;
  esac
done
[[ -n "$CLUSTER_ARG" ]] && export CLUSTER_NAME="$CLUSTER_ARG"

source "$(dirname "$0")/lib/env.sh"

log "removing relay and fault-injection containers"
docker rm -f poc-relay poc-faultns >/dev/null 2>&1 || true
docker volume rm "$TLS_VOLUME" >/dev/null 2>&1 || true

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "deleting kind cluster '$CLUSTER_NAME'"
  kind delete cluster --name "$CLUSTER_NAME"
else
  log "kind cluster '$CLUSTER_NAME' does not exist"
fi
