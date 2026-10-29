#!/usr/bin/env bash
# Phase 5 — agent mTLS and per-RPC token enforcement matrix.
#
# Every case runs one agent for 6s against the relay (except the positive
# control, which proves the harness itself works). Expected outcome is that
# nothing reaches a registered session unless the case is the control.
set -euo pipefail
source "$(dirname "$0")/lib/env.sh"

OUT="$OUT_DIR/auth-matrix"
mkdir -p "$OUT"
RESULT="$OUT/results.md"
: > "$RESULT"

envoy_value() {
  curl -fsS http://127.0.0.1:9901/stats 2>/dev/null | awk -v k="$1" '{n=$1; sub(/:$/,"",n); if(n==k) print $2}'
}
poc_json() {
  $KUBECTL -n "$NAMESPACE" exec deploy/msgbroker -- wget -qO- http://127.0.0.1:9090/stats 2>/dev/null
}

reset_stack() {
  "$POC_ROOT/scripts/40-relay-up.sh" >/dev/null 2>&1
  $KUBECTL -n "$NAMESPACE" rollout restart deploy/msgbroker >/dev/null
  $KUBECTL -n "$NAMESPACE" rollout status deploy/msgbroker --timeout=120s >/dev/null
  sleep 3
}

RELAY_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' poc-relay)"
LPREFIX="$(curl -fsS 'http://127.0.0.1:9901/stats?filter=ssl' 2>/dev/null | grep -oE '^listener\..*\.ssl\.' | head -1 | sed 's/\.ssl\.$//')"
LPREFIX="${LPREFIX:-listener.0.0.0.0_8443}"

ssl_counters() {
  local f=/tmp/poc-ssl.$$
  curl -fsS http://127.0.0.1:9901/stats > "$f" 2>/dev/null || true
  printf 'no_cert=%s san=%s verify=%s' \
    "$(awk -v k="$LPREFIX.ssl.fail_verify_no_cert" '{n=$1; sub(/:$/,"",n); if(n==k) print $2}' "$f")" \
    "$(awk -v k="$LPREFIX.ssl.fail_verify_san" '{n=$1; sub(/:$/,"",n); if(n==k) print $2}' "$f")" \
    "$(awk -v k="$LPREFIX.ssl.fail_verify_error" '{n=$1; sub(/:$/,"",n); if(n==k) print $2}' "$f")"
  rm -f "$f"
}

# run_case <name> <cert-dir|-> <token-mode> [extra agent flags...]
run_case() {
  local name="$1" certdir="$2" mode="$3"; shift 3
  local extra=("$@")
  local cflags=()
  [[ "$certdir" != "-" ]] && cflags=(-cert-dir "/certs/$certdir")

  reset_stack
  local before_ssl; before_ssl=$(ssl_counters)
  local tmp; tmp=$(mktemp -d)

  docker run --rm -i --network kind --add-host "${RELAY_HOST}:${RELAY_IP}" --entrypoint sh \
    -v "$CERTS_DIR:/certs:ro" "$TOOLS_IMAGE" -c \
    "POC_JWT_SECRET=\$(cat /certs/jwt-secret); export POC_JWT_SECRET
     /usr/local/bin/agent -target ${RELAY_HOST}:${RELAY_PORT} -ca /certs/launchpad-ca.crt \
       ${cflags[*]} -agents 1 -duration 10s -token-mode ${mode} ${extra[*]:-} -log-level debug" \
    > "$tmp/out" 2> "$tmp/err" || true

  local err connects
  err=$(grep -m1 'session ended' "$tmp/err" | sed 's/.*err="//; s/\\n.*//; s/" sleep=.*//' || true)
  [[ -z "$err" ]] && err=$(grep -m1 -iE 'error|handshake|certificate' "$tmp/err" | head -c 160 || true)
  connects=$(sed -n '/^{/,$p' "$tmp/out" | jq -r '.connects // 0' 2>/dev/null || echo 0)

  local stats streams acked authfail after_ssl
  stats=$(poc_json)
  streams=$(echo "$stats" | jq -r '.streams_total // 0')
  acked=$(echo "$stats" | jq -r '.commands_acked // 0')
  authfail=$(echo "$stats" | jq -c '.auth_failures // {}')
  after_ssl=$(ssl_counters)

  printf '| %s | %s | %s | %s | %s |\n' \
    "$name" "${err:-<none>}" "connects=$connects streams=$streams acks=$acked" "$authfail" \
    "${after_ssl}"
  rm -rf "$tmp"
}

{
  echo "| case | observed client error | server state | auth_failures | envoy ssl errors |"
  echo "| --- | --- | --- | --- | --- |"
  run_case "positive control" "agents" "normal"
  run_case "no client certificate" "-" "normal"
  run_case "wrong cluster SAN" "agents-wrong-cluster" "normal"
  run_case "expired certificate" "agents-expired" "normal"
  run_case "untrusted (foreign) CA" "agents-foreign" "normal"
  run_case "missing token" "agents" "missing"
  run_case "expired token" "agents" "expired"
  run_case "forged signature" "agents" "forged"
  run_case "wrong audience" "agents" "wrongaud"
  run_case "wrong issuer" "agents" "wrongiss"
  run_case "token without identity" "agents" "noidentity"
  run_case "hello identity mismatch" "agents" "normal" "-hello-node" "agent-9999"
} | tee -a "$RESULT"

log "matrix written to $RESULT"
