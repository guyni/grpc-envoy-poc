#!/usr/bin/env bash
# Run agents through the *Traefik* relay and sample the three observation points.
# usage: 46-run-traefik-relay.sh [agents] [duration-seconds] [name]
set -euo pipefail
source "$(dirname "$0")/lib/env.sh"

AGENTS="${1:-10}"
SECS="${2:-20}"
NAME="${3:-traefik-relay}"
RELAY_METRICS_PORT="${TRAEFIK_RELAY_METRICS_PORT:-9902}"

"$POC_ROOT/scripts/45-relay-traefik-up.sh" >/dev/null 2>&1 || die "Traefik relay failed to start"
RELAY_IP=$(cat "$OUT_DIR/relay-ip.txt")

RUN_DIR="$OUT_DIR/runs/$(date +%Y%m%dT%H%M%S)-$NAME"
mkdir -p "$RUN_DIR"

$KUBECTL -n traefik port-forward deploy/traefik "${TRAEFIK_METRICS_PORT}:9100" >/dev/null 2>&1 &
PF_PID=$!
sleep 2

log "resetting the backend"
$KUBECTL -n "$NAMESPACE" rollout restart deploy/msgbroker >/dev/null
$KUBECTL -n "$NAMESPACE" rollout status deploy/msgbroker --timeout=120s >/dev/null
sleep 2

echo "ts,relay_open_conns,ingress_open_conns,pod_accepted,pod_streams" > "$RUN_DIR/samples.csv"
(
  for _ in $(seq 1 "$SECS"); do
    r=$(curl -fsS "http://127.0.0.1:${RELAY_METRICS_PORT}/metrics" 2>/dev/null \
      | awk 'index($1,"traefik_open_connections{")==1 && index($0,"entrypoint=\"relay\"") {print $2; exit}')
    i=$(curl -fsS "http://127.0.0.1:${TRAEFIK_METRICS_PORT}/metrics" 2>/dev/null \
      | awk 'index($1,"traefik_open_connections{")==1 && index($0,"entrypoint=\"websecure\"") {print $2; exit}')
    st=$($KUBECTL -n "$NAMESPACE" exec deploy/msgbroker -- wget -qO- http://127.0.0.1:9090/stats 2>/dev/null || true)
    c=$(printf '%s' "$st" | jq -r '.accepted_conns // 0' 2>/dev/null)
    s=$(printf '%s' "$st" | jq -r '.streams_active // 0' 2>/dev/null)
    echo "$(date +%s),${r:-0},${i:-0},${c:-0},${s:-0}" >> "$RUN_DIR/samples.csv"
    sleep 1
  done
) &
SAMPLER_PID=$!

log "running $AGENTS agents for ${SECS}s through the Traefik relay"
docker run --rm -i --network kind --add-host "relay.localtest.me:${RELAY_IP}" --entrypoint sh \
  -v "$CERTS_DIR:/certs:ro" "$TOOLS_IMAGE" -c \
  "POC_JWT_SECRET=\$(cat /certs/jwt-secret); export POC_JWT_SECRET
   exec /usr/local/bin/agent -target relay.localtest.me:${RELAY_PORT} -ca /certs/launchpad-ca.crt \
     -cert-dir /certs/agents -agents $AGENTS -duration ${SECS}s -heartbeat 30s -heartbeat-timeout 90s" \
  > "$RUN_DIR/agent.json" 2> "$RUN_DIR/agent.err" || true

wait "$SAMPLER_PID" 2>/dev/null || true
kill "$PF_PID" 2>/dev/null || true

sed -n '/^{/,$p' "$RUN_DIR/agent.json" > "$RUN_DIR/summary.json"
awk -F, 'NR>1{if($2>a)a=$2; if($3>b)b=$3; if($4>c)c=$4; if($5>d)d=$5}
  END{printf "peak_relay_open_conns=%d\npeak_ingress_open_conns=%d\npeak_pod_accepted=%d\npeak_pod_streams=%d\n",a,b,c,d}' \
  "$RUN_DIR/samples.csv" > "$RUN_DIR/peaks.txt"
cat "$RUN_DIR/peaks.txt"
jq -r '{agents,connects,reconnects,commands,acks,mismatches,agents_with_errors,command_latency_p50_ms,command_latency_p99_ms}' "$RUN_DIR/summary.json" 2>/dev/null || true
echo "$RUN_DIR" > "$OUT_DIR/last-run.txt"
