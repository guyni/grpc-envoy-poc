#!/usr/bin/env bash
# Phase 3 — agent CA, per-agent client certificates, negative certificates and
# the relay's TLS directory (filesystem SDS layout).
set -euo pipefail
source "$(dirname "$0")/lib/env.sh"

COUNT="${AGENTS_CERTS:-1000}"
mkdir -p "$CERTS_DIR" "$BIN_DIR/host"

if [[ ! -x "$BIN_DIR/host/certgen" ]]; then
  go build -C "$POC_ROOT" -o "$BIN_DIR/host/certgen" ./cmd/certgen
fi
CG="$BIN_DIR/host/certgen"

if [[ ! -f "$CERTS_DIR/agent-ca/agent-ca.crt" ]]; then
  log "creating agent CA"
  "$CG" ca -out "$CERTS_DIR/agent-ca"
fi

if [[ ! -f "$CERTS_DIR/agents/agent-0000.crt" ]]; then
  log "issuing $COUNT agent certificates (cluster poc)"
  "$CG" agents -ca "$CERTS_DIR/agent-ca" -out "$CERTS_DIR/agents" -n "$COUNT" -cluster poc -ttl 168h
fi

log "issuing negative-test certificates"
"$CG" agents -ca "$CERTS_DIR/agent-ca" -out "$CERTS_DIR/agents-wrong-cluster" -n 1 -cluster prod-east -ttl 168h
"$CG" agents -ca "$CERTS_DIR/agent-ca" -out "$CERTS_DIR/agents-expired" -n 1 -cluster poc -expired
"$CG" agents -ca "$CERTS_DIR/agent-ca" -out "$CERTS_DIR/agents-foreign" -n 1 -cluster poc -ttl 168h -foreign

log "assembling the relay's versioned TLS directory"
V="$CERTS_DIR/relay/v1"
mkdir -p "$V"
[[ -f "$CERTS_DIR/relay-server.crt" ]] || { echo "missing $CERTS_DIR/relay-server.crt — run 20-deploy.sh first" >&2; exit 1; }
cp -f "$CERTS_DIR/relay-server.crt" "$V/relay-server.crt"
cp -f "$CERTS_DIR/relay-server.key" "$V/relay-server.key"
cp -f "$CERTS_DIR/agent-ca/agent-ca.crt" "$V/agent-ca.crt"
cp -f "$CERTS_DIR/launchpad-ca.crt" "$V/msgbroker-ca.crt"
chmod 0644 "$V"/*
# The SDS resources reference .../tls/current; point it at the assembled version.
ln -sfn v1 "$CERTS_DIR/relay/current"

log "verifying positive and negative certificates"
openssl verify -CAfile "$V/agent-ca.crt" "$CERTS_DIR/agents/agent-0000.crt"
openssl verify -CAfile "$V/agent-ca.crt" "$CERTS_DIR/agents-wrong-cluster/agent-0000.crt"
if openssl verify -CAfile "$V/agent-ca.crt" "$CERTS_DIR/agents-foreign/agent-0000.crt" >/dev/null 2>&1; then
  die "foreign certificate unexpectedly verified against the agent CA"
else
  echo "  foreign certificate correctly rejected"
fi
if openssl x509 -in "$CERTS_DIR/agents-expired/agent-0000.crt" -noout -checkend 0 >/dev/null 2>&1; then
  die "expired certificate is still valid"
else
  echo "  expired certificate correctly in the past"
fi
openssl x509 -in "$CERTS_DIR/agents/agent-0000.crt" -noout -ext subjectAltName | sed 's/^/  /'
