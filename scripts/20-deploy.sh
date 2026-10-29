#!/usr/bin/env bash
# Phase 1 — cross-compile, build the tools image, deploy msgbroker, smoke test.
set -euo pipefail
source "$(dirname "$0")/lib/env.sh"

mkdir -p "$BIN_DIR" "$CERTS_DIR" "$OUT_DIR"

log "cross-compiling for linux/arm64"
for cmd in msgbroker agent certgen; do
  CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -C "$POC_ROOT" -o "$BIN_DIR/$cmd" "./cmd/$cmd"
done

log "building host binaries (for tokens, certs and local runs)"
mkdir -p "$BIN_DIR/host"
for cmd in agent certgen; do
  go build -C "$POC_ROOT" -o "$BIN_DIR/host/$cmd" "./cmd/$cmd"
done

log "building image $TOOLS_IMAGE"
docker build -q -t "$TOOLS_IMAGE" -f "$POC_ROOT/deploy/Dockerfile.tools" "$POC_ROOT"
kind load docker-image "$TOOLS_IMAGE" --name "$CLUSTER_NAME"

ensure_namespace

log "issuing certificates (cert-manager CA issuer)"
$KUBECTL apply -f "$POC_ROOT/deploy/10-certs.yaml"
for i in $(seq 1 60); do
  if $KUBECTL -n "$NAMESPACE" get secret grpc-poc-tls >/dev/null 2>&1 \
    && $KUBECTL -n "$NAMESPACE" get secret relay-poc-tls >/dev/null 2>&1; then
    break
  fi
  sleep 2
  [[ $i == 60 ]] && die "certificates did not become Ready — is cert-manager running? (scripts/00-cluster-up.sh)"
done
$KUBECTL -n "$NAMESPACE" get certificate

log "materialising secrets and trust bundles"
if [[ ! -f "$CERTS_DIR/jwt-secret" ]]; then
  "$BIN_DIR/host/certgen" secret -out "$CERTS_DIR/jwt-secret"
fi
$KUBECTL -n "$NAMESPACE" create secret generic poc-jwt \
  --from-file=jwt-secret="$CERTS_DIR/jwt-secret" \
  --dry-run=client -o yaml | $KUBECTL apply -f -

# Trust bundle for the ingress: the CA that signs both server certificates.
$KUBECTL -n cert-manager get secret launchpad-ca-tls -o jsonpath='{.data.tls\.crt}' \
  | base64 -d > "$CERTS_DIR/launchpad-ca.crt"
[[ -s "$CERTS_DIR/launchpad-ca.crt" ]] \
  || die "could not read launchpad-ca-tls from the cluster — run scripts/00-cluster-up.sh first"

# Traefik's ServersTransport reads the CA from a Secret's tls.crt key.
# (Kept for the optional TLS-backend variant; the default path is h2c.)
$KUBECTL -n "$NAMESPACE" create secret generic poc-ca-bundle \
  --from-file=tls.crt="$CERTS_DIR/launchpad-ca.crt" \
  --dry-run=client -o yaml | $KUBECTL apply -f -

log "removing superseded objects from earlier attempts"
$KUBECTL -n "$NAMESPACE" delete ingress msgbroker grpc-ref-core --ignore-not-found
$KUBECTL -n "$NAMESPACE" delete deployment example-math --ignore-not-found
$KUBECTL -n "$NAMESPACE" delete service example-math --ignore-not-found
$KUBECTL -n "$NAMESPACE" delete serverstransport grpc-poc-transport --ignore-not-found

# Server certificate for the relay, and the CA bundle the relay trusts.
$KUBECTL -n "$NAMESPACE" get secret relay-poc-tls -o jsonpath='{.data.tls\.crt}' \
  | base64 -d > "$CERTS_DIR/relay-server.crt"
$KUBECTL -n "$NAMESPACE" get secret relay-poc-tls -o jsonpath='{.data.tls\.key}' \
  | base64 -d > "$CERTS_DIR/relay-server.key"

log "applying manifests"
$KUBECTL apply -f "$POC_ROOT/deploy/20-msgbroker.yaml"
$KUBECTL -n "$NAMESPACE" rollout status deploy/msgbroker --timeout=120s

log "direct smoke test (NodePort, plaintext) from the kind network"
run_kindnet --entrypoint sh -i -v "$CERTS_DIR/jwt-secret:/secret:ro" "$TOOLS_IMAGE" -c \
  'POC_JWT_SECRET=$(cat /secret); export POC_JWT_SECRET
   exec /usr/local/bin/agent -target '"$KIND_NODE_IP"':30051 -plaintext -agents 3 -duration 8s \
     -heartbeat 1s -heartbeat-timeout 5s -log-level warn' > "$OUT_DIR/20-smoke-direct.json"

jq -r '{agents,connects,commands,acks,mismatches}' "$OUT_DIR/20-smoke-direct.json"

log "through-ingress smoke test (${GRPC_ENDPOINT})"
docker run --rm -i --network kind \
  --add-host "${GRPC_HOST}:${KIND_NODE_IP}" --entrypoint sh \
  -v "$CERTS_DIR:/certs:ro" "$TOOLS_IMAGE" -c \
  'POC_JWT_SECRET=$(cat /certs/jwt-secret); export POC_JWT_SECRET
   exec /usr/local/bin/agent -target '"$GRPC_HOST:$GRPC_PORT"' -ca /certs/launchpad-ca.crt \
     -agents 3 -duration 8s -heartbeat 1s -heartbeat-timeout 5s -log-level warn' \
  > "$OUT_DIR/20-smoke-ingress.json" || true

jq -r '{agents,connects,commands,acks,mismatches,agents_with_errors}' "$OUT_DIR/20-smoke-ingress.json" 2>/dev/null \
  || warn "ingress smoke test produced no summary (see $OUT_DIR/20-smoke-ingress.json)"
