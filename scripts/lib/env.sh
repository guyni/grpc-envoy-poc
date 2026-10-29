#!/usr/bin/env bash
# Shared settings and helpers for the POC scripts.
set -euo pipefail

# This file lives at <repo>/scripts/lib/env.sh; the module root is the repo root.
export POC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT="$POC_ROOT"

export NAMESPACE="${NAMESPACE:-grpc-poc}"
# The cluster this repo creates (scripts/00-cluster-up.sh). Defaults are the
# canonical ports 80/443. Override HTTP_PORT/GRPC_PORT (e.g. 7080/7443) if another
# local cluster already publishes them; point CLUSTER_NAME at an existing cluster
# and set the ports to its published ports to run against it instead.
export CLUSTER_NAME="${CLUSTER_NAME:-grpc-poc}"
export HTTP_PORT="${HTTP_PORT:-80}"
export GRPC_PORT="${GRPC_PORT:-443}"

node_ip() {
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
    "${CLUSTER_NAME}-control-plane" 2>/dev/null || true
}
# Resolved at source time; empty before the cluster exists.
export KIND_NODE_IP="${KIND_NODE_IP:-$(node_ip)}"
export KIND_NODE_IP="${KIND_NODE_IP:-172.18.0.2}"

export GRPC_HOST="${GRPC_HOST:-grpc.localtest.me}"
export GRPC_ENDPOINT="${GRPC_ENDPOINT:-${GRPC_HOST}:${GRPC_PORT}}"
export GATE_HOST="${GATE_HOST:-grpc-ref.localtest.me}"
export RELAY_HOST="${RELAY_HOST:-relay.localtest.me}"
export RELAY_PORT="${RELAY_PORT:-8443}"
export ENVOY_IMAGE="${ENVOY_IMAGE:-envoyproxy/envoy:v1.32-latest}"
# Envoy maintains one connection pool per worker. 1 worker => 1 pooled upstream
# connection (until streams exceed the peer's advertised stream cap). The proposal's
# sizing example uses 2; override with ENVOY_CONCURRENCY=2 to compare.
export ENVOY_CONCURRENCY="${ENVOY_CONCURRENCY:-1}"
export TRAEFIK_METRICS_PORT="${TRAEFIK_METRICS_PORT:-19100}"
export TOOLS_IMAGE="${TOOLS_IMAGE:-poc-tools:dev}"
export EXAMPLE_IMAGE="${EXAMPLE_IMAGE:-poc-example:dev}"

# Pinned local-environment versions (same pins the launchpad-template uses).
export CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.16.2}"
export TRAEFIK_CHART_VERSION="${TRAEFIK_CHART_VERSION:-33.2.1}"

export CERTS_DIR="$POC_ROOT/certs"
export OUT_DIR="$POC_ROOT/out"
export BIN_DIR="$POC_ROOT/bin"
# The relay's TLS directory lives in a VM-local docker volume, not a macOS bind
# mount: filesystem events from a bind mount do not reach Envoy's SDS watcher.
export TLS_VOLUME="${TLS_VOLUME:-poc-relay-tls}"

export KUBECTL="kubectl --context kind-${CLUSTER_NAME}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

require() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
  done
}

ensure_namespace() {
  $KUBECTL get ns "$NAMESPACE" >/dev/null 2>&1 || $KUBECTL create ns "$NAMESPACE"
}

wait_for_deploy() {
  local name="$1" timeout="${2:-180}"
  $KUBECTL -n "$NAMESPACE" rollout status "deploy/$name" --timeout="${timeout}s"
}

# run a throwaway container on the kind docker network
run_kindnet() {
  docker run --rm --network kind \
    --add-host "${GRPC_HOST}:${KIND_NODE_IP}" \
    --add-host "${GATE_HOST}:${KIND_NODE_IP}" \
    "$@"
}
