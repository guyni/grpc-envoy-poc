#!/usr/bin/env bash
# Rebuild the linux binaries and refresh the image in the kind cluster.
set -euo pipefail
source "$(dirname "$0")/lib/env.sh"

mkdir -p "$BIN_DIR" "$BIN_DIR/host"
for cmd in msgbroker agent certgen; do
  CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -C "$POC_ROOT" -o "$BIN_DIR/$cmd" "./cmd/$cmd"
done
for cmd in agent certgen; do
  go build -C "$POC_ROOT" -o "$BIN_DIR/host/$cmd" "./cmd/$cmd"
done
docker build -q -t "$TOOLS_IMAGE" -f "$POC_ROOT/deploy/Dockerfile.tools" "$POC_ROOT"
kind load docker-image "$TOOLS_IMAGE" --name "$CLUSTER_NAME"
$KUBECTL -n "$NAMESPACE" rollout restart deploy/msgbroker >/dev/null
$KUBECTL -n "$NAMESPACE" rollout status deploy/msgbroker --timeout=120s
log "rebuilt and reloaded $TOOLS_IMAGE"
