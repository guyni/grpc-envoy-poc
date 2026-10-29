#!/usr/bin/env bash
# Phase 6 — failure injection at realistic scale (5 agents).
#
# Injection happens in a NET_ADMIN sidecar that shares the relay's network
# namespace, so rules affect only the relay and no VM-wide config is needed.
#
# Scenarios: upstream-reset, app-hang, relay-restart, blackhole
# usage: 70-faults.sh [scenario ...]
set -euo pipefail
source "$(dirname "$0")/lib/env.sh"

OUT="$OUT_DIR/faults"
mkdir -p "$OUT"
AGENTS="${FAULT_AGENTS:-5}"
SIDECAR=poc-faultns

poc_value() {
  $KUBECTL -n "$NAMESPACE" exec deploy/msgbroker -- wget -qO- http://127.0.0.1:9090/stats 2>/dev/null \
    | jq -r ".$1 // 0"
}
poc_json() {
  $KUBECTL -n "$NAMESPACE" exec deploy/msgbroker -- wget -qO- http://127.0.0.1:9090/stats 2>/dev/null
}
# akv <key> — read a value from "key: value" stats lines on stdin
akv() {
  awk -v k="$1" '{n=$1; sub(/:$/,"",n); if(n==k) print $2}'
}
envoy_value() {
  curl -fsS http://127.0.0.1:9901/stats 2>/dev/null | akv "$1"
}

start_sidecar() {
  docker rm -f "$SIDECAR" >/dev/null 2>&1 || true
  docker run -d --name "$SIDECAR" --network "container:poc-relay" --cap-add NET_ADMIN \
    alpine:3.20 sh -c 'apk add -q iptables iproute2 >/dev/null 2>&1; sleep infinity' >/dev/null
  for _ in $(seq 1 40); do
    docker exec "$SIDECAR" iptables -L -n >/dev/null 2>&1 && break
    sleep 0.5
  done
}

reset_all() {
  "$POC_ROOT/scripts/40-relay-up.sh" >/dev/null 2>&1
  start_sidecar
  $KUBECTL -n "$NAMESPACE" rollout restart deploy/msgbroker >/dev/null
  $KUBECTL -n "$NAMESPACE" rollout status deploy/msgbroker --timeout=120s >/dev/null
  sleep 3
}

# scenario <name> <duration-seconds> <inject-at> <restore-at|0> <inject-cmd> <restore-cmd> [agent flags] [detect: streams|rq]
scenario() {
  local name="$1" dur="$2" inject_at="$3" restore_at="$4" inject="$5" restore="$6"
  local extra="${7:-}" detect="${8:-streams}"
  local dir="$OUT/$name"; mkdir -p "$dir"
  local relay_ip; relay_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' poc-relay)

  reset_all
  local load=poc-load-$name
  docker rm -f "$load" >/dev/null 2>&1 || true
  docker run -d --name "$load" --network kind --add-host "${RELAY_HOST}:${relay_ip}" \
    -v "$CERTS_DIR:/certs:ro" --entrypoint sh "$TOOLS_IMAGE" -c \
    "POC_JWT_SECRET=\$(cat /certs/jwt-secret); export POC_JWT_SECRET
     exec /usr/local/bin/agent -target ${RELAY_HOST}:${RELAY_PORT} -ca /certs/launchpad-ca.crt \
       -cert-dir /certs/agents -agents $AGENTS -duration ${dur}s ${extra}" >/dev/null

  : > "$dir/samples.csv"
  echo "ts,poc_streams_active,poc_sessions_active,envoy_downstream_cx,envoy_upstream_cx,envoy_upstream_rq_active" >> "$dir/samples.csv"
  local start_ts; start_ts=$(date +%s)
  local injected=0 restored=0 now
  while :; do
    now=$(( $(date +%s) - start_ts ))
    (( now < dur )) || break
    # Schedule on wall-clock seconds and fire on the first tick at or after
    # the deadline, so a slow sampling tick cannot skip an event.
    if (( now >= inject_at && injected == 0 )); then
      echo "  [$name] injecting at t=${now}s: $inject" | tee -a "$dir/log.txt"
      eval "$inject" >>"$dir/log.txt" 2>&1 || true
      injected=1
    fi
    if (( restore_at > 0 && now >= restore_at && restored == 0 )); then
      echo "  [$name] restoring at t=${now}s" | tee -a "$dir/log.txt"
      eval "$restore" >>"$dir/log.txt" 2>&1 || true
      restored=1
    fi
    # One request per source per tick, parsed locally.
    local ev pv sa se dc uc rq
    ev=$(curl -fsS http://127.0.0.1:9901/stats 2>/dev/null || true)
    dc=$(printf '%s\n' "$ev" | akv http.agent_relay.downstream_cx_active)
    uc=$(printf '%s\n' "$ev" | akv cluster.msgbroker.upstream_cx_active)
    rq=$(printf '%s\n' "$ev" | akv cluster.msgbroker.upstream_rq_active)
    pv=$(poc_json 2>/dev/null || true)
    sa=$(printf '%s' "$pv" | jq -r '.streams_active // 0' 2>/dev/null)
    se=$(printf '%s' "$pv" | jq -r '.sessions_active // 0' 2>/dev/null)
    printf '%s,%s,%s,%s,%s,%s\n' "$now" "${sa:-0}" "${se:-0}" "${dc:-0}" "${uc:-0}" "${rq:-0}" >> "$dir/samples.csv"
    sleep 1
  done

  docker logs "$load" > "$dir/agent.log" 2>&1 || true
  docker rm -f "$load" >/dev/null 2>&1 || true
  sed -n '/^{/,$p' "$dir/agent.log" > "$dir/summary.json"
  jq -r '. as $s | {agents,connects,reconnects,mismatches,agents_with_errors}' "$dir/summary.json" 2>/dev/null \
    | jq -c . | tee -a "$dir/log.txt"

  # detection = first second after injection where the signal falls below 50%
  # of its peak; recovery = first second after that back at >= 90% of peak.
  # The signal is the pod's active streams, except for the app-hang case where
  # clients reconnect continuously (keeping Envoy's request gauge flat), so the signal
  # is the server's session count dropping as the heartbeat timeout fires.
  awk -F, -v inject="$inject_at" -v restore="$restore_at" -v dir="$dir" -v detect="$detect" '
    NR>1 {
      sig = (detect=="rq") ? $6 : (detect=="sessions" ? $3 : $2)
      rows[NR]=$0
      if (sig>peak) peak=sig
      if ($1>=inject && !det && peak>0 && sig < peak*0.5) det=$1
      # When a restore happens, recovery only counts after it.
      if (det && !rec && sig >= peak*0.9 && (restore==0 || $1>=restore)) rec=$1
    }
    END {
      printf "peak_%s=%d detected_at=%s recovered_at=%s\n", detect, peak,
        (det?det"s":"none"), (rec?rec"s":"none")
    }' "$dir/samples.csv" > "$dir/result.txt"
  cat "$dir/result.txt"
}

kill_loads() { docker ps -aq --filter 'name=poc-load-' | xargs -r docker rm -f >/dev/null 2>&1 || true; }

run_reset() {
  scenario upstream-reset 45 15 0 \
    "docker exec $SIDECAR ss -K dst ${KIND_NODE_IP} dport = ${GRPC_PORT}" "true"
}
run_hang() {
  scenario app-hang 70 20 40 \
    "$KUBECTL -n $NAMESPACE exec deploy/msgbroker -- wget -qO- 'http://127.0.0.1:9090/debug/hang?on=1'" \
    "$KUBECTL -n $NAMESPACE exec deploy/msgbroker -- wget -qO- 'http://127.0.0.1:9090/debug/hang?on=0'" \
    "-heartbeat 3s -heartbeat-timeout 10s" sessions
}
run_relay_restart() {
  scenario relay-restart 45 15 0 \
    "docker restart poc-relay >/dev/null" "true"
}
run_blackhole() {
  scenario blackhole 210 20 130 \
    "docker exec $SIDECAR iptables -A OUTPUT -d ${KIND_NODE_IP} -p tcp --dport ${GRPC_PORT} -j DROP;
     docker exec $SIDECAR iptables -A INPUT -s ${KIND_NODE_IP} -p tcp --sport ${GRPC_PORT} -j DROP" \
    "docker exec $SIDECAR iptables -D OUTPUT -d ${KIND_NODE_IP} -p tcp --dport ${GRPC_PORT} -j DROP;
     docker exec $SIDECAR iptables -D INPUT -s ${KIND_NODE_IP} -p tcp --sport ${GRPC_PORT} -j DROP"
}

trap kill_loads EXIT
which=${*:-upstream-reset app-hang relay-restart blackhole}
for s in $which; do
  case "$s" in
    upstream-reset) run_reset ;;
    app-hang) run_hang ;;
    relay-restart) run_relay_restart ;;
    blackhole) run_blackhole ;;
    *) die "unknown scenario: $s" ;;
  esac
done
log "fault results under $OUT"
