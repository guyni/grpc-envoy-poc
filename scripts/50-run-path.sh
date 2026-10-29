#!/usr/bin/env bash
# Run a load against one of the two measurement paths and sample stats.
#
#   p1  direct-to-ingress  (Traefik TLS -> h2c pod)    — current state: N conns into :443
#   p2  via-relay          (Envoy mTLS -> Traefik)     — the proposal: pool-sized conns
#
# Connections into :443 are measured from Traefik's metrics, not inferred. The direct-to-pod
# probe (NodePort) is a deployment check, not a path; see scripts/20-deploy.sh.
#
# usage: 50-run-path.sh --path p1|p2 --agents N --duration 10m [--name label] [-- <extra agent flags>]
set -euo pipefail
source "$(dirname "$0")/lib/env.sh"

path="" agents=10 duration="60s" name=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --path) path="$2"; shift 2 ;;
    --agents) agents="$2"; shift 2 ;;
    --duration) duration="$2"; shift 2 ;;
    --name) name="$2"; shift 2 ;;
    --) shift; break ;;
    *) die "unknown argument: $1" ;;
  esac
done
extra=("$@")
[[ -n "$path" ]] || die "--path is required"

relay_ip=""
case "$path" in
  p1)
    # Measure without the relay. Its pooled upstream connection survives after
    # clients leave (Envoy keeps idle connections), and would add +1 to Traefik's
    # websecure gauge.
    docker rm -f poc-relay poc-faultns >/dev/null 2>&1 || true
    target="${GRPC_HOST}:${GRPC_PORT}"; tlsargs=(-ca /certs/launchpad-ca.crt); hosts=(--add-host "${GRPC_HOST}:${KIND_NODE_IP}")
    ;;
  p2)
    # Recreate (not restart) the relay so its bind mounts are re-resolved from
    # the current repo layout, and so Envoy's gauges start from zero (pooled
    # upstream connections persist after clients leave).
    "$POC_ROOT/scripts/40-relay-up.sh" >/dev/null 2>&1 || die "relay failed to start"
    for _ in $(seq 1 40); do
      curl -fsS http://127.0.0.1:9901/ready >/dev/null 2>&1 && break
      sleep 0.5
    done
    relay_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' poc-relay)"
    echo "$relay_ip" > "$OUT_DIR/relay-ip.txt"
    target="${RELAY_HOST}:${RELAY_PORT}"
    tlsargs=(-ca /certs/launchpad-ca.crt -cert-dir /certs/agents)
    hosts=(--add-host "${RELAY_HOST}:${relay_ip}")
    ;;
  *) die "unknown path: $path (p1 = direct to ingress, p2 = via relay)" ;;
esac

stamp="$(date +%Y%m%dT%H%M%S)"
label="${name:-$path}"
RUN_DIR="$OUT_DIR/runs/${stamp}-${label}"
mkdir -p "$RUN_DIR"
{
  echo "path=$path"
  echo "target=$target"
  echo "agents=$agents"
  echo "duration=$duration"
  echo "extra=${extra[*]:-}"
  echo "envoy_image=$(cat "$OUT_DIR/envoy-image.txt" 2>/dev/null || echo none)"
} > "$RUN_DIR/meta.txt"

envoy_value() {
  curl -fsS http://127.0.0.1:9901/stats 2>/dev/null | awk -v k="$1" '{n=$1; sub(/:$/,"",n); if(n==k) print $2}'
}
poc_value() {
  local v
  v=$($KUBECTL -n "$NAMESPACE" exec deploy/msgbroker -- wget -qO- http://127.0.0.1:9090/stats 2>/dev/null \
      | jq -r ".$1 // 0" 2>/dev/null) || v=0
  printf '%s' "${v:-0}"
}

# Traefik exposes the number of open connections per entrypoint. That is the
# "connections into 127.0.0.1:443" figure — measured, not inferred from agent count.
TRAEFIK_PF_PID=""
traefik_metrics_up() {
  curl -fsS "http://127.0.0.1:${TRAEFIK_METRICS_PORT}/metrics" >/dev/null 2>&1
}
start_traefik_metrics() {
  traefik_metrics_up && return 0
  $KUBECTL -n traefik port-forward deploy/traefik "${TRAEFIK_METRICS_PORT}:9100" >/dev/null 2>&1 &
  TRAEFIK_PF_PID=$!
  for _ in $(seq 1 20); do
    traefik_metrics_up && return 0
    sleep 0.5
  done
  return 1
}
traefik_open_conns() {
  local v
  v=$(curl -fsS "http://127.0.0.1:${TRAEFIK_METRICS_PORT}/metrics" 2>/dev/null \
    | awk -v e="$1" 'index($1,"traefik_open_connections{")==1 && index($0,"entrypoint=\"" e "\"") {print $2; exit}') || v=0
  printf '%s' "${v:-0}"
}

SAMPLES="$RUN_DIR/stats-samples.csv"
echo "ts,envoy_downstream_cx_active,envoy_downstream_cx_total,envoy_upstream_cx_active,envoy_upstream_cx_total,envoy_upstream_rq_active,poc_accepted_conns,poc_open_conns,poc_streams_active,poc_sessions_active,poc_fences,traefik_websecure_open_connections" > "$SAMPLES"

sampler() {
  # A single failed scrape (pod restarting, port-forward blip) must not end the
  # loop: every call below is already coalesced to 0 on failure, but keep the
  # shell from exiting on any stray non-zero status.
  set +e
  while [[ -f "$RUN_DIR/.sampling" ]]; do
    local dd dt du ut rq ca co sa se fe tc
    dd=$(envoy_value http.agent_relay.downstream_cx_active); dd=${dd:-0}
    dt=$(envoy_value http.agent_relay.downstream_cx_total); dt=${dt:-0}
    du=$(envoy_value cluster.msgbroker.upstream_cx_active); du=${du:-0}
    ut=$(envoy_value cluster.msgbroker.upstream_cx_total); ut=${ut:-0}
    rq=$(envoy_value cluster.msgbroker.upstream_rq_active); rq=${rq:-0}
    ca=$(poc_value accepted_conns); ca=${ca:-0}
    co=$(poc_value open_conns); co=${co:-0}
    sa=$(poc_value streams_active); sa=${sa:-0}
    se=$(poc_value sessions_active); se=${se:-0}
    fe=$(poc_value fences); fe=${fe:-0}
    tc=$(traefik_open_conns websecure); tc=${tc:-0}
    echo "$(date +%s),$dd,$dt,$du,$ut,$rq,$ca,$co,$sa,$se,$fe,$tc" >> "$SAMPLES"
    sleep 1
  done
}

log "resetting the backend so its counters describe only this run"
$KUBECTL -n "$NAMESPACE" rollout restart deploy/msgbroker >/dev/null
$KUBECTL -n "$NAMESPACE" rollout status deploy/msgbroker --timeout=120s >/dev/null
sleep 2

if start_traefik_metrics; then
  echo "  traefik metrics on 127.0.0.1:${TRAEFIK_METRICS_PORT}"
else
  warn "traefik metrics unavailable — ingress connection columns will read 0"
fi

touch "$RUN_DIR/.sampling"
sampler &
SAMPLER_PID=$!
log "running $path: $agents agents for $duration -> $RUN_DIR"
agent_cmd="/usr/local/bin/agent -target $target ${tlsargs[*]} -agents $agents -duration $duration -heartbeat 30s -heartbeat-timeout 90s ${extra[*]:-}"
set +e
docker run --rm -i --network kind "${hosts[@]}" --entrypoint sh \
  -v "$CERTS_DIR:/certs:ro" "$TOOLS_IMAGE" \
  -c "POC_JWT_SECRET=\$(cat /certs/jwt-secret); export POC_JWT_SECRET; exec $agent_cmd" \
  > "$RUN_DIR/agent-stdout.txt" 2> "$RUN_DIR/agent-stderr.txt"
run_rc=$?
set -e

rm -f "$RUN_DIR/.sampling"
wait "$SAMPLER_PID" 2>/dev/null || true
if [[ -n "$TRAEFIK_PF_PID" ]]; then kill "$TRAEFIK_PF_PID" 2>/dev/null || true; fi

if [[ $run_rc -ne 0 ]]; then
  warn "agent exited $run_rc; see $RUN_DIR/agent-stderr.txt"
fi
# The summary is the JSON object printed last.
sed -n '/^{/,$p' "$RUN_DIR/agent-stdout.txt" > "$RUN_DIR/summary.json"
jq -e . "$RUN_DIR/summary.json" >/dev/null 2>&1 || warn "no parsable summary in agent-stdout.txt"

# Peak gauges are what matter for capacity claims.
awk -F, 'NR>1 {
  if ($2>m2) m2=$2; if ($4>m4) m4=$4; if ($6>m6) m6=$6;
  if ($7>m7) m7=$7; if ($8>m8) m8=$8; if ($9>m9) m9=$9; if ($10>m10) m10=$10;
  if ($12>m12) m12=$12;
  n++
} END {
  printf "samples=%d\npeak_envoy_downstream_cx_active=%d\npeak_envoy_upstream_cx_active=%d\npeak_envoy_upstream_rq_active=%d\npeak_poc_accepted_conns=%d\npeak_poc_open_conns=%d\npeak_poc_streams_active=%d\npeak_poc_sessions_active=%d\npeak_traefik_websecure_open_connections=%d\n", n, m2, m4, m6, m7, m8, m9, m10, m12
}' "$SAMPLES" > "$RUN_DIR/peaks.txt"
cat "$RUN_DIR/peaks.txt"
echo "--- summary ---"
jq -r '{agents,connects,reconnects,commands,acks,mismatches,agents_with_errors,command_latency_p50_ms,command_latency_p99_ms}' "$RUN_DIR/summary.json" 2>/dev/null || true
echo "$RUN_DIR" > "$OUT_DIR/last-run.txt"
