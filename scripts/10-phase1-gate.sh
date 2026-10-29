#!/usr/bin/env bash
# Phase 1 — build the gate image and deploy the vendored example behind Traefik.
set -euo pipefail
source "$(dirname "$0")/lib/env.sh"

mkdir -p "$BIN_DIR" "$OUT_DIR"

log "cross-compiling the example for linux/arm64"
(
  cd "$POC_ROOT/reference/go-grpc-bidirectional-streaming-example"
  CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o "$BIN_DIR/example-server" ./src/server
  CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o "$BIN_DIR/example-client" ./src/client
)

log "building image $EXAMPLE_IMAGE"
docker build -q -t "$EXAMPLE_IMAGE" -f "$POC_ROOT/deploy/Dockerfile.example" "$POC_ROOT"

log "loading image into kind"
kind load docker-image "$EXAMPLE_IMAGE" --name "$CLUSTER_NAME"

log "applying manifests"
$KUBECTL apply -f "$POC_ROOT/deploy/00-namespace.yaml"
$KUBECTL apply -f "$POC_ROOT/deploy/10-certs.yaml"
$KUBECTL apply -f "$POC_ROOT/deploy/15-gate.yaml"

log "waiting for certificate"
for i in $(seq 1 60); do
  if $KUBECTL -n "$NAMESPACE" get secret grpc-poc-tls >/dev/null 2>&1; then
    echo "  secret grpc-poc-tls present"
    break
  fi
  sleep 2
done
$KUBECTL -n "$NAMESPACE" get certificate

log "waiting for deployment"
$KUBECTL -n "$NAMESPACE" rollout status deploy/example-math --timeout=120s

log "gate: bidi gRPC through Traefik (${GATE_HOST}:${GRPC_PORT})"
# *.localtest.me resolves to 127.0.0.1, so the host-side grpcurl reaches Traefik directly.
# grpcurl reads newline-delimited JSON objects from stdin with -d @ (bidi streaming).
printf '%s\n' '{"num":1}' '{"num":5}' '{"num":3}' '{"num":9}' \
  | grpcurl -insecure -import-path "$POC_ROOT/reference/go-grpc-bidirectional-streaming-example/src/proto" \
      -proto math.proto -d @ "${GATE_HOST}:${GRPC_PORT}" protobuf.Math/Max
