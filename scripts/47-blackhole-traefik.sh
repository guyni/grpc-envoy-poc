#!/usr/bin/env bash
# Blackhole the Traefik relay's upstream leg and observe detection/recovery.
# Mirrors the Envoy blackhole scenario: 5 agents, DROP both directions to the
# ingress at t=20 s, restore at t=130 s, sample msgbroker streams every second.
set -euo pipefail
source "$(dirname "$0")/lib/env.sh"

DUR=160
INJECT=20
RESTORE=130
SIDECAR=poc-faultns

"$POC_ROOT/scripts/45-relay-traefik-up.sh" >/dev/null 2>&1 || die "relay failed"
RELAY_IP=$(cat "$OUT_DIR/relay-ip.txt")
DIR="$OUT_DIR/faults/traefik-blackhole"
mkdir -p "$DIR"

$KUBECTL -n "$NAMESPACE" rollout restart deploy/msgbroker >/dev/null
$KUBECTL -n "$NAMESPACE" rollout status deploy/msgbroker --timeout=120s >/dev/null
sleep 2

docker rm -f poc-load-tbh >/dev/null 2>&1 || true
docker run -d --name poc-load-tbh --network kind --add-host "relay.localtest.me:${RELAY_IP}" \
  -v "$CERTS_DIR:/certs:ro" --entrypoint sh "$TOOLS_IMAGE" -c \
  "POC_JWT_SECRET=\$(cat /certs/jwt-secret); export POC_JWT_SECRET
   exec /usr/local/bin/agent -target relay.localtest.me:${RELAY_PORT} -ca /certs/launchpad-ca.crt \
     -cert-dir /certs/agents -agents 5 -duration ${DUR}s -heartbeat 5s -heartbeat-timeout 15s -log-level debug" \
  >/dev/null

echo "ts,pod_streams,pod_sessions,relay_open_conns" > "$DIR/samples.csv"
INJECTED=0
RESTORED=0
START=$(date +%s)
while :; do
  NOW=$(( $(date +%s) - START ))
  (( NOW < DUR )) || break
  if (( NOW >= INJECT && INJECTED == 0 )); then
    docker rm -f "$SIDECAR" >/dev/null 2>&1 || true
    docker run -d --name "$SIDECAR" --network "container:poc-relay-traefik" --cap-add NET_ADMIN \
      alpine:3.20 sh -c 'apk add -q iptables iproute2 >/dev/null 2>&1; sleep infinity' >/dev/null
    sleep 2
    docker exec "$SIDECAR" iptables -A OUTPUT -d "$KIND_NODE_IP" -p tcp --dport "$GRPC_PORT" -j DROP
    docker exec "$SIDECAR" iptables -A INPUT -s "$KIND_NODE_IP" -p tcp --sport "$GRPC_PORT" -j DROP
    echo "[$(date +%T)] injected blackhole at t=${NOW}s"
    INJECTED=1
  fi
  if (( RESTORE > 0 && NOW >= RESTORE && RESTORED == 0 )); then
    docker exec "$SIDECAR" iptables -D OUTPUT -d "$KIND_NODE_IP" -p tcp --dport "$GRPC_PORT" -j DROP || true
    docker exec "$SIDECAR" iptables -D INPUT -s "$KIND_NODE_IP" -p tcp --sport "$GRPC_PORT" -j DROP || true
    echo "[$(date +%T)] restored at t=${NOW}s"
    RESTORED=1
  fi
  ST=$($KUBECTL -n "$NAMESPACE" exec deploy/msgbroker -- wget -qO- http://127.0.0.1:9090/stats 2>/dev/null || true)
  S=$(printf '%s' "$ST" | jq -r '.streams_active // 0' 2>/dev/null)
  SE=$(printf '%s' "$ST" | jq -r '.sessions_active // 0' 2>/dev/null)
  RC=$(curl -fsS "http://127.0.0.1:9902/metrics" 2>/dev/null \
    | awk 'index($1,"traefik_open_connections{")==1 && index($0,"entrypoint=\"relay\"") {print $2; exit}')
  echo "$NOW,${S:-0},${SE:-0},${RC:-0}" >> "$DIR/samples.csv"
  sleep 1
done

docker logs poc-load-tbh > "$DIR/agent.log" 2>&1 || true
docker rm -f poc-load-tbh "$SIDECAR" >/dev/null 2>&1 || true
sed -n '/^{/,$p' "$DIR/agent.log" > "$DIR/summary.json"
jq -r '{agents,connects,reconnects,agents_with_errors}' "$DIR/summary.json" 2>/dev/null || true
awk -F, 'NR>1{if($2>p)p=$2} END{print "peak_pod_streams=" p}' "$DIR/samples.csv"
echo "samples: $DIR/samples.csv"
