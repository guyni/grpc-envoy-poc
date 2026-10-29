#!/usr/bin/env bash
# Create the local kind cluster this POC runs on, with Traefik ingress, cert-manager
# and the CA issuer. Idempotent: re-running reuses the cluster and re-applies the
# add-ons.
#
#   usage: ./scripts/00-cluster-up.sh [NAME] [--recreate] [--name NAME]
#
# NAME defaults to $CLUSTER_NAME (grpc-poc). Host ports default to 80 (HTTP) and
# 443 (HTTPS). If another local cluster already publishes them, override with
# HTTP_PORT/GRPC_PORT (e.g. 7080/7443), or point CLUSTER_NAME at that existing
# cluster and skip this script.
#
# The sequence (pinned cert-manager, wait for ready, CA issuer, pinned Traefik chart)
# follows launchpad-template's hack/setup.sh.
set -euo pipefail

RECREATE=0
CLUSTER_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --recreate) RECREATE=1; shift ;;
    --name)     CLUSTER_ARG="${2:?--name needs a value}"; shift 2 ;;
    -h|--help)  sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)         echo "unknown option: $1" >&2; exit 2 ;;
    *)          CLUSTER_ARG="$1"; shift ;;
  esac
done
[[ -n "$CLUSTER_ARG" ]] && export CLUSTER_NAME="$CLUSTER_ARG"

source "$(dirname "$0")/lib/env.sh"

mkdir -p "$OUT_DIR"
require docker kind kubectl helm curl

step() { echo; log "$*"; }
say()  { echo "  $*"; }

# ---------------------------------------------------------------------------
step "1/6  preflight"
# ---------------------------------------------------------------------------
docker info >/dev/null 2>&1 || die "docker is not running — start colima (or Docker Desktop) and re-run"
say "docker is responding"

# ---------------------------------------------------------------------------
step "2/6  kind cluster '$CLUSTER_NAME'"
# ---------------------------------------------------------------------------
# extraPortMappings are fixed at CREATE time, so the config is generated from the
# same variables the rest of the scripts use — no third place to drift.
KIND_CONFIG="$OUT_DIR/kind-cluster.yaml"
cat > "$KIND_CONFIG" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: ${HTTP_PORT}
        hostPort: ${HTTP_PORT}
        protocol: TCP
      - containerPort: ${GRPC_PORT}
        hostPort: ${GRPC_PORT}
        protocol: TCP
EOF

if [[ "$RECREATE" == 1 ]] && kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  say "--recreate: deleting cluster '$CLUSTER_NAME'"
  kind delete cluster --name "$CLUSTER_NAME"
fi

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  say "cluster exists — reusing it"
  for want in "$HTTP_PORT" "$GRPC_PORT"; do
    docker port "${CLUSTER_NAME}-control-plane" 2>/dev/null | grep -q ":${want}\$" \
      || die "cluster '$CLUSTER_NAME' does not publish host port ${want} — re-run with --recreate"
  done
  say "host ports ${HTTP_PORT} and ${GRPC_PORT} are published"
else
  # Only meaningful when we are about to bind them; a re-run against our own
  # cluster legitimately finds these ports in use by that cluster.
  for port in "$HTTP_PORT" "$GRPC_PORT"; do
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      die "host port ${port} is already in use — set HTTP_PORT/GRPC_PORT to free ports (another kind cluster?)"
    fi
  done
  say "host ports ${HTTP_PORT} and ${GRPC_PORT} are free"
  say "creating it (config in out/kind-cluster.yaml)"
  kind create cluster --name "$CLUSTER_NAME" --config "$KIND_CONFIG"
fi
$KUBECTL cluster-info >/dev/null || die "kubectl cannot reach cluster '$CLUSTER_NAME'"
# env.sh resolved the node IP before the cluster existed; refresh it now.
KIND_NODE_IP="$(node_ip)"
[[ -n "$KIND_NODE_IP" ]] || die "could not read the node IP of ${CLUSTER_NAME}-control-plane"
export KIND_NODE_IP
say "kubectl context: kind-${CLUSTER_NAME}, node IP ${KIND_NODE_IP}"

# ---------------------------------------------------------------------------
step "3/6  cert-manager ${CERT_MANAGER_VERSION}"
# ---------------------------------------------------------------------------
say "applying the pinned cert-manager manifest"
$KUBECTL apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml" >/dev/null \
  || die "cert-manager manifest did not apply"
# The webhook rejects Issuer/Certificate resources until it is serving, and says
# "connection refused" rather than "not ready" — wait, then retry the apply.
$KUBECTL -n cert-manager wait --for=condition=Available deployment --all --timeout=180s >/dev/null \
  || die "cert-manager deployments did not become Available"
say "cert-manager is Available"

for i in $(seq 1 30); do
  if $KUBECTL apply -f "$POC_ROOT/deploy/00-cluster-issuer.yaml" >/dev/null 2>&1; then break; fi
  sleep 2
  [[ $i == 30 ]] && die "the ClusterIssuers were refused for 60s — cert-manager webhook did not come up"
done
$KUBECTL -n cert-manager wait --for=condition=Ready certificate/launchpad-ca --timeout=60s >/dev/null \
  || die "the launchpad CA Certificate did not become Ready"
say "launchpad-ca-issuer can sign application certificates"

# ---------------------------------------------------------------------------
step "4/6  Traefik ${TRAEFIK_CHART_VERSION} on ${HTTP_PORT}/${GRPC_PORT}"
# ---------------------------------------------------------------------------
helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
helm repo update traefik >/dev/null
helm upgrade --install traefik traefik/traefik \
  --kube-context "kind-${CLUSTER_NAME}" \
  --namespace traefik --create-namespace \
  --version "$TRAEFIK_CHART_VERSION" \
  --set 'ports.web.hostPort='"$HTTP_PORT" \
  --set 'ports.websecure.hostPort='"$GRPC_PORT" \
  --set 'ports.web.redirections.entryPoint.to=websecure' \
  --set 'ports.web.redirections.entryPoint.scheme=https' \
  --set 'ports.web.redirections.entryPoint.permanent=true' \
  --set 'service.type=ClusterIP' \
  --set 'providers.kubernetesCRD.allowCrossNamespace=true' \
  --set-string 'nodeSelector.ingress-ready=true' \
  --wait --timeout 180s >/dev/null \
  || die "Traefik did not install — 'kubectl -n traefik describe pods' has the reason"
say "Traefik is running"

# ---------------------------------------------------------------------------
step "5/6  prove the ingress answers"
# ---------------------------------------------------------------------------
# An unknown Host on the websecure entrypoint must reach Traefik and 404. Anything
# else — connection refused, a TLS error — means the ports are not wired the way the
# scripts assume, and every later step would fail in a less obvious way.
code=""
for _ in $(seq 1 30); do
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 "https://127.0.0.1:${GRPC_PORT}/" 2>/dev/null || printf '000')
  [[ "$code" == 404 ]] && break
  sleep 1
done
[[ "$code" == 404 ]] || die "https://127.0.0.1:${GRPC_PORT}/ returned '${code}', expected Traefik's 404 — ingress not reachable"
say "https://127.0.0.1:${GRPC_PORT} reaches Traefik (404 for an unknown Host, as expected)"

# ---------------------------------------------------------------------------
step "6/6  summary"
# ---------------------------------------------------------------------------
{
  echo "cluster=${CLUSTER_NAME}"
  echo "context=kind-${CLUSTER_NAME}"
  echo "node_ip=${KIND_NODE_IP}"
  echo "http_port=${HTTP_PORT}"
  echo "grpc_port=${GRPC_PORT}"
  echo "cert_manager=${CERT_MANAGER_VERSION}"
  echo "traefik_chart=${TRAEFIK_CHART_VERSION}"
} | tee "$OUT_DIR/cluster-info.txt"

echo
say "next: ./scripts/20-deploy.sh && ./scripts/30-certs.sh && ./scripts/40-relay-up.sh"
say "host-side clients reach the ingress at ${GRPC_HOST}:${GRPC_PORT}"
say "containers on the 'kind' network reach it at ${KIND_NODE_IP}:${GRPC_PORT}"
