#!/usr/bin/env bash
# Collect point-in-time gauges from Envoy admin and the msgbroker stats endpoint.
# Usage: stats.sh envoy|msgbroker|both [outfile]
set -euo pipefail
source "$(dirname "$0")/env.sh"

target="${1:-both}"
outfile="${2:-}"

envoy_stats() {
  local base=http://127.0.0.1:9901
  # Envoy names listener stats by address, not by configured name.
  local lp
  lp=$(curl -fsS "$base/stats?filter=ssl" 2>/dev/null | grep -oE '^listener\..*\.ssl\.' | head -1 | sed 's/\.ssl\.$//')
  lp=${lp:-listener.0.0.0.0_8443}
  local keys=(
    http.agent_relay.downstream_cx_active
    http.agent_relay.downstream_cx_total
    http.agent_relay.downstream_rq_active
    http.agent_relay.downstream_rq_total
    "$lp.downstream_cx_active"
    "$lp.downstream_cx_total"
    "$lp.ssl.fail_verify_no_cert"
    "$lp.ssl.fail_verify_san"
    "$lp.ssl.fail_verify_error"
    "$lp.ssl.connection_error"
    "$lp.ssl.handshake"
    cluster.msgbroker.upstream_cx_active
    cluster.msgbroker.upstream_cx_total
    cluster.msgbroker.upstream_rq_active
    cluster.msgbroker.upstream_rq_total
    cluster.msgbroker.upstream_cx_connect_fail
    cluster.msgbroker.upstream_cx_overflow
    cluster.msgbroker.upstream_rq_pending_overflow
    cluster.msgbroker.upstream_cx_destroy_with_active_rq
    cluster.msgbroker.ssl.handshake
    cluster.msgbroker.ssl.fail_verify_error
    cluster.msgbroker.ssl.fail_verify_san
    server.memory_allocated
    server.memory_heap_size
    server.live
  )
  curl -fsS "$base/stats" | awk -v keys="${keys[*]}" '
    BEGIN { n = split(keys, k, " ") }
    { name = $1; sub(/:$/, "", name); for (i = 1; i <= n; i++) if (name == k[i]) print }
  ' | sort
}

msgbroker_stats() {
  $KUBECTL -n "$NAMESPACE" exec deploy/msgbroker -- wget -qO- http://127.0.0.1:9090/stats
}

case "$target" in
  envoy) envoy_stats ;;
  msgbroker) msgbroker_stats ;;
  both)
    {
      echo "--- envoy ---"
      envoy_stats
      echo "--- msgbroker ---"
      msgbroker_stats
    } ;;
  *) die "unknown target: $target" ;;
esac | if [[ -n "$outfile" ]]; then tee "$outfile"; else cat; fi
