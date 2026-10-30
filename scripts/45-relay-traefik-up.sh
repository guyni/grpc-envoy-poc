#!/usr/bin/env bash
# Start the Traefik relay (alternative to scripts/40-relay-up.sh).
# Same listener (relay.localtest.me:8443), same TLS volume, same client contract.
set -euo pipefail
source "$(dirname "$0")/lib/env.sh"

NAME=poc-relay-traefik
IMAGE="${TRAEFIK_RELAY_IMAGE:-traefik:v3.2.2}"
METRICS_PORT="${TRAEFIK_RELAY_METRICS_PORT:-9902}"

require docker
[[ -f "$POC_ROOT/relay-traefik/static.yaml" ]] || die "missing relay-traefik/static.yaml"
[[ -f "$CERTS_DIR/relay/current/relay-server.crt" ]] || die "run 30-certs.sh first"

log "stopping the Envoy relay (one relay at a time on :${RELAY_PORT})"
docker rm -f poc-relay poc-faultns >/dev/null 2>&1 || true

log "seeding the TLS volume"
docker volume create "$TLS_VOLUME" >/dev/null
docker run --rm -v "$TLS_VOLUME:/tls" -v "$CERTS_DIR/relay:/src:ro" alpine:3.20 \
  sh -c 'rm -rf /tls/* && cp -a /src/. /tls/ && chmod 0644 /tls/*/*'

log "pulling $IMAGE"
docker pull -q "$IMAGE" >/dev/null

log "starting the Traefik relay"
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" \
  --network kind \
  --add-host "${GRPC_HOST}:${KIND_NODE_IP}" \
  -p "${RELAY_PORT}:8443" \
  -p "127.0.0.1:${METRICS_PORT}:9100" \
  -v "$POC_ROOT/relay-traefik/static.yaml:/etc/traefik/traefik.yaml:ro" \
  -v "$POC_ROOT/relay-traefik/dynamic.yaml:/etc/traefik/dynamic.yaml:ro" \
  -v "$TLS_VOLUME:/tls:ro" \
  "$IMAGE" --configFile=/etc/traefik/traefik.yaml >/dev/null

for i in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${METRICS_PORT}/metrics" >/dev/null 2>&1; then
    echo "  relay ready"
    break
  fi
  sleep 1
  [[ $i -eq 30 ]] && { docker logs "$NAME" --tail=30; die "Traefik relay did not become ready"; }
done

IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$NAME")
echo "  relay container IP: $IP"
echo "$IP" > "$OUT_DIR/relay-ip.txt"

log "relay metrics baseline"
curl -fsS "http://127.0.0.1:${METRICS_PORT}/metrics" 2>/dev/null \
  | grep -E '^traefik_open_connections' | head -5
