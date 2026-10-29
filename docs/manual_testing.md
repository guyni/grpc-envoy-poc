# Manual testing

Everything below is copy-paste from the repo root on the Mac. The stack is already deployed
(`msgbroker` in namespace `grpc-poc`, relay container `poc-relay`) on the cluster created by
`./scripts/00-cluster-up.sh`: **`kind-grpc-poc`**, ingress on host ports **80/443**.
If you run against another cluster, substitute its context and port (`GRPC_PORT`).

```bash
cd grpc-envoy-poc                 # the repo root
```

## 0. Is the stack up?

```bash
curl -s http://127.0.0.1:9901/ready; echo          # expect: LIVE
kubectl --context kind-grpc-poc -n grpc-poc get pods
```

If the relay is missing: `./scripts/40-relay-up.sh`.
If the pod is missing: `./scripts/20-deploy.sh`.

## 1. Run one real agent against the relay

The agent mints its own token; it needs the CA and its client certificate.

```bash
POC_JWT_SECRET=$(cat certs/jwt-secret) ./bin/host/agent \
  -target relay.localtest.me:8443 \
  -ca certs/launchpad-ca.crt \
  -cert-dir certs/agents \
  -agents 1 -duration 60s -heartbeat 5s -heartbeat-timeout 20s \
  -log-level info
```

It prints a JSON summary at the end (`connects`, `commands`, `acks`, `mismatches`,
latencies). `-log-level debug` additionally logs every reconnect with its reason.

## 2. Watch what that does to sockets, live

In a second terminal (macOS has no `watch`, so loop):

```bash
while true; do
  date +%T
  curl -s http://127.0.0.1:9901/stats | grep -E \
    'http.agent_relay.downstream_cx_active|cluster.msgbroker.upstream_cx_active|cluster.msgbroker.upstream_rq_active'
  kubectl --context kind-grpc-poc -n grpc-poc exec deploy/msgbroker -- \
    wget -qO- http://127.0.0.1:9090/stats | jq -c '{streams_active,sessions_active,commands_acked}'
  sleep 2
done
```

Expected with one agent: relay `downstream_cx_active: 1`, `upstream_cx_active: 1` (one worker; 2 with `ENVOY_CONCURRENCY=2`),
`upstream_rq_active: 1`; pod `streams_active: 1`, `sessions_active: 1`, and
`commands_acked` climbing by one every 5 s.

Add the ingress view — the number of connections Traefik accepted on `:443`:

```bash
kubectl --context kind-grpc-poc -n traefik port-forward deploy/traefik 19100:9100 &
curl -s http://127.0.0.1:19100/metrics | grep 'traefik_open_connections{entrypoint="websecure"'
```

With agents hitting `grpc.localtest.me:443` directly this equals the agent count (it is
measured, not inferred). With agents going through the relay it stays at the relay's pool
size — 1 with the default single worker. `lsof` on macOS cannot show this, because the
connections terminate in the VM's port-forward proxy; for an OS-level cross-check use
`docker exec grpc-poc-control-plane ss -tn '( sport = :443 )'`.

Ten agents instead of one: `-agents 10` → downstream 10, pod streams 10, upstream still
1–2. That is the whole pooling argument in one line.

## 3. Raw gRPC without our client (grpcurl)

```bash
TOKEN=$(./bin/host/certgen token -secret-file certs/jwt-secret -node agent-0000)

printf '%s\n' \
 '{"nodeId":"agent-0000","clusterId":"poc","hello":{"nodeId":"agent-0000","clusterId":"poc","agentVersion":"manual"}}' \
 '{"nodeId":"agent-0000","clusterId":"poc","heartbeat":{"sentUnixNano":1}}' \
 | grpcurl -cacert certs/launchpad-ca.crt \
     -cert certs/agents/agent-0000.crt -key certs/agents/agent-0000.key \
     -import-path proto -proto msgbroker/v1/msgbroker.proto \
     -H "authorization: Bearer $TOKEN" -d @ \
     relay.localtest.me:8443 msgbroker.v1.MsgBroker/Connect
```

You should get a `welcome` with a `sessionId` and `generation`.

## 4. The other measurement path, and the deploy probe

`p1` — direct through the ingress (no client certificate; the ingress terminates TLS):

```bash
POC_JWT_SECRET=$(cat certs/jwt-secret) ./bin/host/agent \
  -target grpc.localtest.me:443 -ca certs/launchpad-ca.crt \
  -agents 10 -duration 30s -heartbeat 5s -heartbeat-timeout 20s
```

The direct-to-pod probe (NodePort, plaintext) is a deployment check, not a measurement
path. The node IP is discovered when the cluster is created:

```bash
NODE_IP=$(sed -n 's/^node_ip=//p' out/cluster-info.txt)
POC_JWT_SECRET=$(cat certs/jwt-secret) ./bin/host/agent \
  -target "$NODE_IP":30051 -plaintext -agents 10 -duration 30s
```

The NodePort lives on the kind docker network, not on the Mac's loopback, so if the
command above is refused, run it in a container instead:

```bash
docker run --rm --network kind --entrypoint sh -v "$PWD/certs:/certs:ro" poc-tools:dev -c \
 'POC_JWT_SECRET=$(cat /certs/jwt-secret); export POC_JWT_SECRET
  exec /usr/local/bin/agent -target '"$NODE_IP"':30051 -plaintext -agents 10 -duration 30s'
```

## 5. Watch it reject bad credentials

```bash
# wrong cluster: certificate is valid but its SAN says cluster prod-east
POC_JWT_SECRET=$(cat certs/jwt-secret) ./bin/host/agent \
  -target relay.localtest.me:8443 -ca certs/launchpad-ca.crt \
  -cert-dir certs/agents-wrong-cluster -agents 1 -duration 5s -log-level debug
# expect: tls: unknown certificate

# no client certificate at all
POC_JWT_SECRET=$(cat certs/jwt-secret) ./bin/host/agent \
  -target relay.localtest.me:8443 -ca certs/launchpad-ca.crt -agents 1 -duration 5s -log-level debug
# expect: tls: certificate required

# forged token (valid cert, signature not from the server's secret)
POC_JWT_SECRET=$(cat certs/jwt-secret) ./bin/host/agent \
  -target relay.localtest.me:8443 -ca certs/launchpad-ca.crt \
  -cert-dir certs/agents -agents 1 -duration 5s -token-mode forged -log-level debug
# expect: Unauthenticated: signature mismatch; server auth_failures{"signature":N}
```

Check the server's view afterwards:

```bash
kubectl --context kind-grpc-poc -n grpc-poc exec deploy/msgbroker -- \
  wget -qO- http://127.0.0.1:9090/stats | jq '.auth_failures'
```

## 6. Inject a fault by hand

**Hung application, healthy transport** (the case HTTP/2 PING cannot see):

```bash
kubectl --context kind-grpc-poc -n grpc-poc exec deploy/msgbroker -- \
  wget -qO- 'http://127.0.0.1:9090/debug/hang?on=1'
# ... run an agent with -heartbeat 3s -heartbeat-timeout 10s and watch it reconnect ...
kubectl --context kind-grpc-poc -n grpc-poc exec deploy/msgbroker -- \
  wget -qO- 'http://127.0.0.1:9090/debug/hang?on=0'
```

**Reset one pooled upstream connection** (needs a sidecar sharing the relay's netns):

```bash
docker run -d --name poc-faultns --network container:poc-relay --cap-add NET_ADMIN \
  alpine:3.20 sh -c 'apk add -q iptables iproute2 >/dev/null 2>&1; sleep infinity'
docker exec poc-faultns ss -K dst 172.18.0.2 dport = 443
```

**Complete silent blackhole** (no RST, no ICMP), then restore:

```bash
docker exec poc-faultns iptables -A OUTPUT -d 172.18.0.2 -p tcp --dport 443 -j DROP
docker exec poc-faultns iptables -A INPUT  -s 172.18.0.2 -p tcp --sport 443 -j DROP
# wait: agents stop within ~41 s (40 s TCP_USER_TIMEOUT), not at the 60 s PING
docker exec poc-faultns iptables -D OUTPUT -d 172.18.0.2 -p tcp --dport 443 -j DROP
docker exec poc-faultns iptables -D INPUT  -s 172.18.0.2 -p tcp --sport 443 -j DROP
```

**Restart the relay** and watch agents reconnect:

```bash
docker restart poc-relay
```

## 7. Tear down

```bash
docker rm -f poc-relay poc-faultns
kubectl --context kind-grpc-poc -n grpc-poc delete all,ingressroute --all
```

Other namespaces (`lp-e2e`, `keycloak`, `user-*`) belong to a different POC — leave them.
