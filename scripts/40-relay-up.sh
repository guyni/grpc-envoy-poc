#!/usr/bin/env bash
# Phase 4 — validate the Envoy config with the pinned binary, then run the relay.
set -euo pipefail
source "$(dirname "$0")/lib/env.sh"

CERTS_DIR_RELAY="$CERTS_DIR/relay"
[[ -f "$CERTS_DIR_RELAY/current/relay-server.crt" ]] || die "run 30-certs.sh first"
# Docker silently creates missing bind-mount sources as empty directories, which
# hides a stale path. Check first.
[[ -f "$POC_ROOT/envoy/envoy.yaml.tmpl" ]] || die "missing $POC_ROOT/envoy/envoy.yaml.tmpl"
[[ -d "$POC_ROOT/envoy/sds" ]] || die "missing $POC_ROOT/envoy/sds"

# The upstream port follows whichever cluster we target; render the config so the
# committed template stays free of laptop-specific numbers.
RENDERED_ENVOY="$OUT_DIR/envoy.yaml"
sed "s|__GRPC_PORT__|${GRPC_PORT}|g" "$POC_ROOT/envoy/envoy.yaml.tmpl" > "$RENDERED_ENVOY"
grep -q "port_value: ${GRPC_PORT}" "$RENDERED_ENVOY" \
  || die "rendered Envoy config has no upstream port ${GRPC_PORT}"

docker volume create "$TLS_VOLUME" >/dev/null
docker run --rm -v "$TLS_VOLUME:/tls" -v "$CERTS_DIR_RELAY:/src:ro" alpine:3.20 \
  sh -c 'rm -rf /tls/* && cp -a /src/. /tls/ && chmod 0644 /tls/*/*'

ENVOY_MOUNTS=(
  -v "$RENDERED_ENVOY:/etc/envoy/envoy.yaml:ro"
  -v "$POC_ROOT/envoy/sds:/etc/envoy/sds:ro"
  -v "$TLS_VOLUME:/etc/envoy/tls:ro"
)

log "pulling $ENVOY_IMAGE and recording its digest"
docker pull -q "$ENVOY_IMAGE" >/dev/null
docker image inspect "$ENVOY_IMAGE" --format '  digest={{index .RepoDigests 0}}' | tee "$OUT_DIR/envoy-image.txt"

log "validating the configuration"
# --mode validate cannot resolve filesystem SDS references (the secrets are
# dynamic), so that one error is expected and everything else must pass.
if docker run --rm "${ENVOY_MOUNTS[@]}" --entrypoint envoy "$ENVOY_IMAGE" \
  -c /etc/envoy/envoy.yaml --mode validate > "$OUT_DIR/envoy-validate.txt" 2>&1; then
  echo "  configuration valid"
elif grep -q 'Unknown static certificate' "$OUT_DIR/envoy-validate.txt"; then
  warn "validate stopped at filesystem SDS references (known limitation); continuing"
  echo "  (full output: $OUT_DIR/envoy-validate.txt)"
else
  tail -20 "$OUT_DIR/envoy-validate.txt"
  if grep -q 'inotify' "$OUT_DIR/envoy-validate.txt"; then
    warn "Envoy could not create an inotify instance for the SDS watcher."
    warn "On colima, raise the VM limit and retry:"
    warn "  colima ssh -- sudo sysctl -w fs.inotify.max_user_instances=1024"
  fi
  die "envoy configuration is invalid"
fi

log "starting the relay"
docker rm -f poc-relay >/dev/null 2>&1 || true
docker run -d --name poc-relay \
  --network kind \
  --add-host "${GRPC_HOST}:${KIND_NODE_IP}" \
  -p "${RELAY_PORT}:8443" \
  -p 127.0.0.1:9901:9901 \
  "${ENVOY_MOUNTS[@]}" \
  "$ENVOY_IMAGE" -c /etc/envoy/envoy.yaml --concurrency "$ENVOY_CONCURRENCY" >/dev/null

for i in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:9901/ready >/dev/null 2>&1; then
    echo "  relay ready"
    break
  fi
  sleep 1
  [[ $i -eq 30 ]] && { docker logs poc-relay --tail=40; die "relay did not become ready"; }
done

RELAY_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' poc-relay)"
echo "  relay container IP: $RELAY_IP"
echo "$RELAY_IP" > "$OUT_DIR/relay-ip.txt"

log "relay stats baseline"
"$POC_ROOT/scripts/lib/stats.sh" envoy | head -20
