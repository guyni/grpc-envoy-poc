#!/usr/bin/env bash
# Phase 0 — verify the environment this POC depends on.
set -euo pipefail
source "$(dirname "$0")/lib/env.sh"

mkdir -p "$OUT_DIR"
REPORT="$OUT_DIR/00-preflight.txt"
exec > >(tee "$REPORT") 2>&1

log "Phase 0 preflight"

require docker kubectl kind go protoc grpcurl openssl jq

log "tool versions"
for c in docker kubectl kind go protoc grpcurl openssl jq; do
  printf '  %-10s %s\n' "$c" "$(command -v "$c")"
done
go version
protoc --version
kind version

log "colima"
if ! docker info >/dev/null 2>&1; then
  die "docker is not reachable (colima stopped?) — run: colima start"
fi
docker info --format '  server={{.ServerVersion}} arch={{.Architecture}}'

log "kind cluster"
kind get clusters
$KUBECTL get nodes -o wide

log "ingress (Traefik)"
$KUBECTL -n traefik get deploy traefik -o jsonpath='  image={.spec.template.spec.containers[0].image}{"\n"}'
$KUBECTL get ingressclass
curl -sk -o /dev/null -w "  host :${GRPC_PORT} -> %{http_code}\n" --max-time 5 "https://127.0.0.1:${GRPC_PORT}/"

log "port mapping on the kind node"
docker inspect "${CLUSTER_NAME}-control-plane" --format '  {{json .NetworkSettings.Ports}}{{"\n"}}'

log "container -> ingress reachability"
run_kindnet alpine:3.20 sh -c "
  nc -z -w 3 ${KIND_NODE_IP} ${GRPC_PORT} && echo '  ${KIND_NODE_IP}:${GRPC_PORT} OK' || echo '  ${KIND_NODE_IP}:${GRPC_PORT} FAILED'
  wget -q -S -O /dev/null --no-check-certificate --header='Host: ${GATE_HOST}' https://${GATE_HOST}:${GRPC_PORT}/ 2>&1 | head -1
"

log "cert-manager"
$KUBECTL get clusterissuer launchpad-ca-issuer -o jsonpath='  issuer={.metadata.name} ready={.status.conditions[?(@.type=="Ready")].status}{"\n"}'

log "fault-injection prerequisites (NET_ADMIN sidecar sharing a netns)"
docker run --rm --cap-add NET_ADMIN alpine:3.20 sh -c 'apk add -q iproute2 iptables >/dev/null 2>&1; iptables -L -n >/dev/null && echo "  iptables OK"; ss -h >/dev/null && echo "  ss OK"' \
  || warn "NET_ADMIN tooling unavailable — Phase 6 kernel-level tests may be limited"

log "images"
for img in "$ENVOY_IMAGE" alpine:3.20; do
  docker manifest inspect "$img" >/dev/null 2>&1 && echo "  $img OK" || echo "  $img FAILED"
done

log "namespace"
ensure_namespace
$KUBECTL get ns "$NAMESPACE"

log "preflight written to $REPORT"
