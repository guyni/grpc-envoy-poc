# POC results — Envoy relay for msgbroker bidirectional gRPC

Results for [`grpc_envoy_design_proposal.md`](grpc_envoy_design_proposal.md), recorded
2026-10-29 on the dedicated cluster created by `scripts/00-cluster-up.sh`:

| | |
| --- | --- |
| Cluster | `grpc-poc` (kind, k8s v1.29.2, single control-plane node, `ingress-ready=true`) |
| Ingress | Traefik helm chart 33.2.1, entrypoints published on host ports 80/443 |
| Certificates | cert-manager v1.16.2, self-signed root → `launchpad-ca` → `launchpad-ca-issuer` |
| Relay | `envoyproxy/envoy:v1.32-latest`, container on the `kind` network, one worker |
| Client | grpc-go v1.85.0 |

Every number below comes from the runs in `../out/`.

---

## 1. Verdict

The relay does what the proposal says, measured at the metric that matters: **TCP connections
into the public endpoint `grpc.localtest.me:443`**.

Every number in the last two columns is a count of **TCP connections into the gRPC endpoint
`grpc.localtest.me:443`** — measured from Traefik's `websecure` entrypoint, not inferred from
the agent count. "Relay upstream pool" is the same quantity seen from Envoy's side.

| Agents | Relay pool (1 worker) | P1 — no relay: conns into `grpc.localtest.me:443` | P2 — relay: conns into `grpc.localtest.me:443` |
| --- | --- | --- | --- |
| 5 | 1 | **5** | **1** |
| 10 | 1 | **10** | **1** |
| 200 | 1 | **200** | **1** |
| 1000 | 4 | **1000** | **4** |

Without the relay the endpoint holds one connection per agent; with it the endpoint holds
the relay's pool — 1 while streams stay under the negotiated cap, 4 at 1000 agents
(`ceil(1000/250)`). With `ENVOY_CONCURRENCY=2` the pool is 2 at 5–200 agents and 5 at 1000.

Two things temper that result:

- **The ingress already pools the backend.** Traefik holds a single TCP connection to
  msgbroker at every agent count on both paths. So the relay reduces the endpoint's
  connections, but does not reduce what msgbroker sees — and at fewer than ~250 streams
  (the realistic fleet is under 10 agents) it adds a hop for no backend benefit.
- **The relay adds latency in this environment.** p99 through the relay measured 1–4 ms at
  5–200 agents and 2–8 ms at 1000, against 1.0–1.3 ms direct. Run-to-run variance at 1000
  agents was as large as the gap between worker settings, and an earlier 9 ms observation
  did not reproduce. Treat these loopback numbers as an order of magnitude, not an SLO.

Streams are unchanged at every size and every command was acked with zero cross-agent
deliveries.

---

## 2. What was built

| Component | Where | Notes |
| --- | --- | --- |
| `msgbroker.v1.MsgBroker/Connect` | `../cmd/msgbroker` | synthetic stand-in: one long-lived bidi stream per agent, commands, acks, heartbeats, echo, session generations |
| Ingress exposure | `../deploy/20-msgbroker.yaml` | Traefik `IngressRoute`, TLS at the edge, h2c to the pod |
| Agent client | `../cmd/agent` | per-agent `ClientConn`, per-agent cert, per-RPC token, heartbeat watchdog, jittered reconnect |
| Certificate tooling | `../cmd/certgen` | agent CA, per-agent SPIFFE URI SANs, negative certificates, JWTs |
| Relay | `../envoy/envoy.yaml.tmpl` + `../envoy/sds/` | adapted from proposal §5, filesystem SDS, one worker |
| Harness | `../scripts/` | cluster up/down, preflight, build, deploy, certs, relay, path runner, auth matrix, faults |

---

## 3. Connections into the public endpoint

Every figure is `traefik_open_connections{entrypoint="websecure"}`, port-forwarded from
Traefik's metrics and sampled every second — measured, not inferred from the agent count
(the query and its caveats are in the README, "How the connection counts are obtained").

| Agents | Path | Connections into `:443` | Relay upstream | Active streams | Commands/acks | Reconnects | Mismatches |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 5 | P1 | **5** | – | 5 | 10/10 | 0 | 0 |
| 5 | P2 | **1** | 1 | 5 | 10/10 | 0 | 0 |
| 10 | P1 | **10** | – | 10 | 20/20 | 0 | 0 |
| 10 | P2 | **1** | 1 | 10 | 20/20 | 0 | 0 |
| 200 | P1 | **200** | – | 200 | 1400/1400 | 0 | 0 |
| 200 | P2 | **1** | 1 | 200 | 1400/1400 | 0 | 0 |
| 1000 | P1 | **1000** | – | 1000 | 8000/8000 | 0 | 0 |
| 1000 | P2 | **4** | 4 | 1000 | 8000/8000 | 0 | 0 |

Command latency (loopback), p50 / p99 in ms. P2 is shown for both worker settings because
the relay's `--concurrency` is a latency knob, not just a pool size:

| Agents | P1 direct | P2, 1 worker | P2, 2 workers |
| --- | --- | --- | --- |
| 5 | 0.31 / 1.05 | 2.18 / 2.41 | 0.75 / 1.00 |
| 10 | 0.65 / 1.89 | 3.10 / 4.42 | 0.98 / 2.41 |
| 200 | 0.33 / 0.98 | 0.54 / 2.05 | 0.35 / 3.40 |
| 1000 | 0.29 / 1.28 | 0.35 / 2.12–2.82 † | 0.34 / 2.32–7.40 † |

† range across two runs. At 1000 agents the spread between repeats (≈1–5 ms) is larger than
the difference between one and two workers, so this POC does not claim a worker-count effect.
What is consistent is that the relay adds roughly 1–3 ms to p99 versus a direct connection,
and that these are single-host loopback numbers: they isolate relay cost, not WAN behaviour.

### Effective stream cap

Traefik advertises ~250 concurrent streams per connection. With one Envoy worker: one
connection up to 200 agents, four at 1000 — exactly `ceil(1000/250)`. Envoy's configured 1024
cannot override the peer's advertised cap (proposal §4).

Envoy's own documentation describes both halves: HTTP/2 pooling
["multiplexes multiple requests over a single connection"](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/connection_pooling),
opening more connections only when the stream limit is reached and marking a full connection
"busy until a stream is available"; the limit itself is configured through
[upstream HTTP/2 protocol options](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/upstreams/http/v3/http_protocol_options.proto).
There is no gRPC-specific multiplexing setting — gRPC clusters
[share the same connection pooling mechanism](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/other_protocols/grpc)
as the rest of the data plane.

Note what the documentation does and does not claim. It describes the mechanism: streams are
multiplexed onto a connection, and "new connections are established anytime there is a pending
request" — there is no pool-size setting. A *smaller* number of upstream connections is an
emergent consequence of multiplexing, the peer's stream cap and the worker count; Envoy does
not document a connection-reduction feature. The evidence for the reduction is the measurement
in §3, not an upstream promise.

### Backend sockets (context, not the metric)

msgbroker itself sees **one** accepted connection on both paths at every agent count: that is
Traefik's own pooling, present before the relay. It is recorded in `../out/runs/*/peaks.txt`
but it answers "has the bottleneck moved?", not "did the relay work?". P1 runs stop the relay
container first, because Envoy keeps one idle pooled connection after its clients leave
(`idle_timeout: 0s`) and it would otherwise count against the endpoint.

---

## 4. Authentication and isolation

`../out/auth-matrix/results.md`. Every case ran one agent for 10 s against the relay.

| Case | Result |
| --- | --- |
| positive control | connects, 1 stream, 1 ack |
| no client certificate | rejected at the handshake (`fail_verify_no_cert`) |
| wrong cluster SAN (`prod-east`) | `tls: unknown certificate`, `fail_verify_san` |
| expired certificate | `tls: expired certificate`, `fail_verify_error` |
| untrusted (foreign) CA | `tls: unknown certificate authority`, `fail_verify_error` |
| missing token | `Unauthenticated: missing authorization metadata` |
| expired token | `Unauthenticated: expired` |
| forged signature | `Unauthenticated: signature mismatch` |
| wrong audience | `Unauthenticated: audience not accepted` |
| wrong issuer | `Unauthenticated: issuer not accepted` |
| token without cluster/node | `Unauthenticated: cluster/node claims required` |
| Hello identity ≠ token identity | `PermissionDenied: hello identity … does not match token …` |

No RPC reached a registered session in any negative case.

---

## 5. Failure and recovery (5 agents)

Sampled every second; detection is a fall below 50 % of the pre-fault signal, recovery a
return to ≥90 %. Full samples under `../out/faults/`.

| Event | Injection | Detection | Recovery |
| --- | --- | --- | --- |
| Upstream TCP reset (`ss -K`) | at t=15 s | immediate | **3 s** |
| Relay restart | at t≈15 s | immediate | **2 s** |
| Application hang, transport healthy | at t=20 s | **12 s** (client heartbeat timeout 10 s) | **4 s** after release |
| Complete silent blackhole | at t=20 s | **41 s** (40 s `TCP_USER_TIMEOUT`) | **26 s** after the path was restored |

The app-hang case is the one the proposal insists on separating from a blackhole: with the
handlers stalled, TCP and HTTP/2 stay healthy, so only the application heartbeat detects it;
Envoy's PING does not. For the blackhole, detection came from `TCP_USER_TIMEOUT`, not from
the 60 s HTTP/2 PING.

---

## 6. Findings that differ from the proposal

1. **Traefik needs the named service port.** An `IngressRoute` with a numeric port produced
   `503` (no servers); with the named port it works.
2. **The core-Ingress annotation path does not work here.** `service.serversscheme: h2c`
   yielded `500/502 "missing HTTP content-type"`; the `IngressRoute` CRD with `scheme: h2c`
   works.
3. **The ingress already pools the backend.** One Traefik→pod TCP connection carries every
   gRPC stream at every tested size, on both paths.
4. **Envoy v1.32 rejects two settings from §5.** `stream_flush_timeout` is not a known HCM
   field, and `resource_api_version: V3` is rejected by the YAML parser (the relay runs with
   `AUTO`, which resolves to V3).
5. **`--mode validate` cannot resolve filesystem SDS**, so a clean validate does not prove
   the secrets load; readiness plus handshake tests do.
6. **`LOGICAL_DNS` needs the getaddrinfo resolver** here: c-ares ignores `/etc/hosts`, and
   `localtest.me` resolves publicly to 127.0.0.1, which inside a container is itself.
7. **The pool is per worker.** One worker is one connection — 1 at 5/10/200 agents — and it
   grows to `ceil(streams / advertised cap)` when a connection saturates (4 at 1000).
8. **A live stream is not a live session.** If the application stalls while `Hello` is in
   flight, the handler swallows it: the stream stays open, heartbeats can resume later, but
   the agent is never registered and receives no commands. The first app-hang run recovered
   only 2 of 5 sessions that way. The agent now requires `Welcome` within its heartbeat
   timeout and reconnects otherwise; recovery is 5/5.

---

## 7. What this POC does not prove

- A real control-plane host with systemd, host DNS and host networking during a Kubernetes
  outage. The relay runs as a container on this laptop.
- Linux kernel behaviour on the real endpoint host (the relay does run on the Linux kernel
  inside colima, so `TCP_USER_TIMEOUT` is exercised on the relay side only).
- Multi-relay or multi-cluster capacity, real msgbroker routing/persistence, production
  token issuance, CRL distribution, or agent certificate renewal.
- A 24-hour soak. The longest run was 1000 agents for 60 s.
- The one-direction-loss failure case; only a complete blackhole was measured.
- Latency beyond same-host loopback.

---

## 8. Reproduce

```bash
cd grpc-envoy-poc                  # the repo root
./scripts/00-cluster-up.sh         # kind + cert-manager + CA issuer + Traefik (80/443)
./scripts/00-preflight.sh          # environment checks
./scripts/20-deploy.sh             # build, deploy msgbroker, direct + ingress smokes
./scripts/30-certs.sh              # agent CA + 1000 leaf certs + negatives
./scripts/40-relay-up.sh           # validate and start the relay
./scripts/50-run-path.sh --path p1 --agents 10 --duration 20s   # without relay
./scripts/50-run-path.sh --path p2 --agents 10 --duration 20s   # via relay
./scripts/60-auth-matrix.sh
./scripts/70-faults.sh upstream-reset app-hang relay-restart blackhole
```

---

## 9. Against the proposal's pilot acceptance criteria (§9)

| Proposal criterion | POC status |
| --- | --- |
| All synthetic agents hold an independently authenticated bidi call | Met — 1000 agents, 1000 concurrent sessions, 8 000 commands acked in a 45 s run |
| Steady-state TCP connections into the public endpoint ≥10× below the direct baseline | Met from 10 agents up — 10→1 at 10 agents, 200→1, 1000→4; at 5 agents it is 5→1 |
| Application pod socket budget | N/A here — the ingress, not the relay, determines backend sockets (1 on both paths) |
| No cross-agent command delivery | Met — 0 mismatches in every run |
| ≥99 % recover within 120 s after a pooled TCP reset | Met — 5/5 streams back 3 s after the reset |
| ≥99 % recover within 120 s of restoring relay/network availability | Met — relay restart 2 s; blackhole 26 s after the path returned |
| Record detection and recovery separately for the four failure cases | Three measured; one-direction loss not measured |
| Validate the pinned build, h2 negotiation, mTLS, token forwarding, SAN validation | Met, with the config deltas in §6 |

The substantive gap is one-direction packet loss, which needs a kernel-level traffic pattern
this laptop setup does not reproduce.

---

## 10. References

Official Envoy documentation checked 2026-10-29. Pin links to the release you deploy; the
`latest` docs can describe development versions.

1. [Connection pooling](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/connection_pooling) —
   HTTP/2 pooling multiplexes many requests over one connection, bounded by
   `max_concurrent_streams`; with no limit "this will be only a single connection".
2. [gRPC architecture overview](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/other_protocols/grpc) —
   only its connection-management sentence is relevant here: gRPC services are ordinary
   clusters that share the data plane's pooling mechanism. The bridging and transcoding
   filters described on the same page (gRPC-JSON, gRPC-Web, …) are **not** used by this relay;
   the path is native gRPC over HTTP/2 end to end.
3. [Upstream HTTP protocol options](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/upstreams/http/v3/http_protocol_options.proto) —
   where `explicit_http_config.http2_protocol_options.max_concurrent_streams` is set
   (`../envoy/envoy.yaml.tmpl`).
4. [HTTP protocol and HTTP/2 settings](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/core/v3/protocol.proto) —
   stream limits and keepalive policy for the pinned build.
5. [Filesystem SDS](https://www.envoyproxy.io/docs/envoy/latest/configuration/security/secret) —
   how the relay loads its TLS material from `/etc/envoy/sds`.
6. [Circuit breakers](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/cluster/v3/circuit_breaker.proto) —
   `max_connections` / `max_pending_requests` / `max_requests` bound the pool; they are safety
   ceilings, not a desired pool size.
