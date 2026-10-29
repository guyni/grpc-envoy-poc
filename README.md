# grpc-envoy-poc

An executable proof of concept for
[`docs/grpc_envoy_design_proposal.md`](docs/grpc_envoy_design_proposal.md): an Envoy relay
that carries many independently authenticated bidirectional gRPC streams from node agents
over a small pool of upstream HTTP/2 connections to a msgbroker gRPC service.

Built and measured on a MacBook against a pre-existing shared kind cluster
(`*.localtest.me` hostnames, Traefik ingress).

## Result in one paragraph

The mechanism works: 1000 simulated agents held authenticated bidi streams over 5 pooled
upstream connections, per-RPC tokens survived pooling, no command crossed between agents,
and every bad-credential case failed closed. **But the ingress already pools** — Traefik
holds a single TCP socket to msgbroker regardless of agent count — so with fewer than ~250
concurrent streams (the real target clusters run fewer than 10 agents) the relay adds a hop
and a failure domain without reducing sockets. Full numbers, findings and the two untested
corners are in [`docs/poc_results.md`](docs/poc_results.md).

## Repository layout

```
docs/                     proposal, plan, results, manual testing guide
proto/                    msgbroker.v1 bidi contract
gen/                      generated gRPC stubs (checked in)
cmd/msgbroker/            service under test
cmd/agent/                simulated node agent + load generator
cmd/certgen/              agent CA, leaf certs, negative certs, JWTs
internal/                 auth, server, client, stats
deploy/                   cluster issuer, namespace, certs, msgbroker, gate manifests, Dockerfiles
envoy/                    relay config template + filesystem SDS resources
scripts/                  cluster up/down → preflight → build → deploy → certs → relay → tests
reference/                vendored MIT example (Phase 1 gate only, own module)
```

`bin/`, `certs/` and `out/` are generated and git-ignored.

## Prerequisites

- colima running (`colima start`) with docker
- kind, kubectl, helm, curl, go 1.26+, protoc, grpcurl, openssl, jq

The cluster is created by `scripts/00-cluster-up.sh`: a kind cluster named `grpc-poc`
with pinned cert-manager (v1.16.2) and its CA `ClusterIssuer/launchpad-ca-issuer`, plus
Traefik (chart 33.2.1) published on the canonical host ports **80/443**.

If another local cluster already publishes 80/443, override the ports
(`HTTP_PORT=7080 GRPC_PORT=7443`) or point `CLUSTER_NAME` at that existing cluster —
the manifests are identical.

`scripts/00-preflight.sh` verifies the environment and writes `out/00-preflight.txt`.

## Quickstart

```bash
colima start

./scripts/00-cluster-up.sh     # kind + cert-manager + CA issuer + Traefik (idempotent)
                               # takes an optional cluster name: 00-cluster-up.sh my-cluster
./scripts/00-preflight.sh      # environment checks
./scripts/20-deploy.sh         # cross-compile, build image, deploy msgbroker, smoke P1+P2
./scripts/30-certs.sh          # agent CA, 1000 leaf certs, negative certs
./scripts/40-relay-up.sh       # validate and start the Envoy relay (container)

./scripts/50-run-path.sh --path p2 --agents 5 --duration 20s
./scripts/01-cluster-down.sh   # teardown (cluster + relay containers), same optional name
```

If you create a cluster under a different name, use it consistently — every other script
reads `CLUSTER_NAME`, so either export it or prefix each command:

```bash
export CLUSTER_NAME=my-cluster
```

`50-run-path.sh` samples sockets every second and prints peaks plus the agent summary;
each run lands in `out/runs/<timestamp>-<label>/`.

## Measurement paths

The comparison is **p1 vs p2**: the same agents, with and without the relay.

| Path | Client dials | Connections into `:443` — the measurement |
| --- | --- | --- |
| `p1` | `grpc.localtest.me:443` (Traefik) | **= agents** |
| `p2` | `relay.localtest.me:8443` (Envoy mTLS) | **= relay pool (1)** |

Sockets at msgbroker are deliberately *not* the headline metric: Traefik already collapses
the backend to one connection at every agent count (measured), so it answers "has the
bottleneck moved?" rather than "did the relay work?". The relay's effect is on the public
endpoint — and because the ingress already pools, at fewer than ~250 streams the relay adds
a hop without reducing backend sockets.

A direct-to-pod probe over the NodePort — bypassing Traefik entirely — still runs inside
`20-deploy.sh` as a deployment smoke check, but it is not a measurement path.

`50-run-path.sh` records `traefik_open_connections{entrypoint="websecure"}` from Traefik's
metrics, so "connections into 443" is measured rather than inferred from the agent count.

The relay runs with `--concurrency 1` by default: Envoy keeps one connection pool per
worker, so one worker means one pooled upstream connection. Set `ENVOY_CONCURRENCY=2` to
compare against the proposal's two-worker sizing.

Both paths hit the same `msgbroker` deployment. The relay runs as a container on the `kind`
docker network, so it sits on the Linux kernel and `TCP_USER_TIMEOUT` is real.

### How the connection counts are obtained

| Question | Signal | Source |
| --- | --- | --- |
| Connections into `:443` | `traefik_open_connections{entrypoint="websecure",protocol="TCP"}` | Traefik `/metrics` on pod port 9100, port-forwarded by the runner to `127.0.0.1:19100` |
| Connections into the relay | `http.agent_relay.downstream_cx_active` | relay admin `127.0.0.1:9901/stats` |
| Relay → `:443` | `cluster.msgbroker.upstream_cx_active` | relay admin `127.0.0.1:9901/stats` |
| Sockets at the service | `accepted_conns`, `open_conns`, `streams_active` | msgbroker `/stats` on pod port 9090 |

Query the ingress side by hand while a run is in flight:

```bash
kubectl --context kind-grpc-poc -n traefik port-forward deploy/traefik 19100:9100 &
curl -s http://127.0.0.1:19100/metrics | grep 'traefik_open_connections{entrypoint="websecure"'
```

Two caveats: the gauge is sampled once per second, so it can lag a ramp-up by one sample;
and `lsof` on macOS shows the VM's port-forward proxy sockets, not per-agent ones — an
OS-level cross-check is `docker exec grpc-poc-control-plane ss -tn '( sport = :443 )'`.

## Test suites

```bash
./scripts/60-auth-matrix.sh                                   # 12 credential/isolation cases
./scripts/70-faults.sh upstream-reset app-hang relay-restart blackhole
```

Each writes its evidence under `out/`. Hand-testing recipes (single agent, grpcurl,
live socket watch, fault injection) are in [`docs/manual_testing.md`](docs/manual_testing.md).

## Known limitations

- One-direction packet loss, a 24 h soak, and a real control-plane host with systemd and
  host networking during a Kubernetes outage were not exercised.
- The relay always shows at least two upstream connections: one per busy Envoy worker.

## Notes on the cluster

`scripts/00-cluster-up.sh` creates a dedicated cluster (`grpc-poc`) so this POC does not
depend on anything else on the laptop. If you point it at an existing shared cluster instead, stay in namespace `grpc-poc`; `lp-e2e`, `keycloak` and the `user-*`
namespaces belong to another POC.

Ingress routing uses `*.localtest.me` (resolves to 127.0.0.1) and must be an
`IngressRoute` with the **named** service port — a numeric port returns 503 and the
core-Ingress `serversscheme: h2c` annotation does not take effect on this Traefik version.

The relay's config is a template (`envoy/envoy.yaml.tmpl`); `40-relay-up.sh` renders it
with the active `GRPC_PORT` into `out/envoy.yaml`, so the committed file carries no
laptop-specific port.


## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `host port 80 is already in use` | Another cluster publishes it. Override `HTTP_PORT`/`GRPC_PORT`, or stop the other cluster. |
| Envoy exits with `inotify_fd_ >= 0` | The VM's inotify instances are exhausted (colima, several clusters): `colima ssh -- sudo sysctl -w fs.inotify.max_user_instances=1024`. |
| `503` from the ingress with a numeric port | Use the **named** service port in the `IngressRoute` (see above). |
| `certificates did not become Ready` | cert-manager is missing or not ready — run `scripts/00-cluster-up.sh`. |

## Teardown

```bash
./scripts/01-cluster-down.sh   # deletes the cluster, relay/sidecar, TLS volume
```

Manual equivalent, if you prefer to keep the cluster:

```bash
docker rm -f poc-relay poc-faultns
kubectl -n grpc-poc delete all,ingressroute --all
kubectl -n grpc-poc delete certificate grpc-poc-tls relay-poc-tls relay-poc-tls-v2
kubectl delete ns grpc-poc
```
