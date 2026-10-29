# Provenance

This directory is a copy of an upstream example, kept here so the POC is self-contained.

| | |
| --- | --- |
| Upstream | `ssh://git@github.com/pahanini/go-grpc-bidirectional-streaming-example.git` |
| Commit | `cc6111af44bec5a2cb2352da0cc882d1e8508c75` (2021-10-27) |
| License | MIT, see `LICENSE` |
| Copied | 2026-10-28 |

## Deliberate changes from upstream

1. **`src/server/server.go:13`** — `atype server struct` → `type server struct`. Upstream does not compile
   as-is (`syntax error: non-declaration statement outside function body`); this is a one-token typo fix.
2. **`.gitignore`** — upstream ignored `*.pb.go`, which would drop the generated stubs that make this copy
   self-contained. It now ignores only build outputs.
3. **Not copied**: the checked-in 11 MB `client` binary, `Makefile.bak` (identical backup), and the
   upstream `.git` directory.

## Role in this POC

Reference only — it is **not** the service under test and is not built by the `poc/` Go module (nested
module, excluded from `go build ./...`).

Its one real use: an optional fast check in Phase 1 that plain bidirectional gRPC survives the Traefik
`h2c` path before we invest in our own harness. It carries no auth, no long-lived session semantics and
no server-push, so it proves transport only — see `docs/poc_plan.md` §5 for why the real harness is custom.

Build it with:

```bash
cd poc/reference/go-grpc-bidirectional-streaming-example
go build -o /tmp/poc-example-server ./src/server
go build -o /tmp/poc-example-client ./src/client
```

The server listens on `:50005` with plaintext h2c; the client dials `:50005` and completes a 10-message
bidi exchange in about two seconds.
