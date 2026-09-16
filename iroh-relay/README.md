# Antgrid Iroh relay

ELv2 service embedding published upstream `iroh-relay` **1.2.0**, without a fork.
This is an implementation under qualification, not an authorization to deploy
or enable client preference. Cargo dependencies and the Rust compiler are pinned
by `Cargo.lock` and `rust-toolchain.toml`.

## Security boundary

The public listener terminates TLS on port 443 (the sole exception is the
local-development `devInsecureHttp` mode below), negotiates the upstream relay
WebSocket protocol and invokes upstream signed-challenge authentication. It
passes the authenticated endpoint to the backend's HMAC-authenticated
`/internal/peer-admission` route, including its explicitly configured approved
relay origin. Backend requests use random correlated IDs, a two-second total
deadline, redirect rejection and a 4 KiB response limit. Denial, malformed
responses, identity mismatch, overload and unavailable authorization fail closed.

Each admitted connection holds a lease expiring no later than 60 seconds from
monotonic request start. Refreshes run every 20 seconds and recheck both the
previous and replacement deadline while holding the admission locks. This
implementation conservatively closes the account on refresh failure; it does
not extend a lease during an outage.

Each account has its own upstream `Clients` registry. Policy invalidation swaps
the whole registry and invalidates every pending/admitted account connection.
Raw socket reads/writes/flushes and WebSocket operations share the generation
guard. Administration acknowledgement is ordered after invalidation under that
guard. Bytes already accepted by the kernel before revocation cannot be recalled;
queued application or TLS buffers cannot be flushed after the fence. Retiring
all account destinations also cancels packets queued from a revoked source in a
different client's actor. The collateral reconnect of otherwise eligible peers
is deliberate. Clients must establish fresh sessions without command replay.

An administration event also fences in-flight backend responses whose account
was not known yet. Local policy high-water marks are retained in a bounded account
table. Reaching `maxAccounts` rejects new accounts/admin updates (503 retries)
rather than evicting tombstones. Increase that explicitly after load measurement;
restarting clears local state but also all connections and requires fresh backend
admission.

Global raw connections, concurrent backend requests, accounts, account connections
and duplicate endpoint connections are bounded. Raw connection permits survive
TLS/HTTP/authentication and are released only when transport ownership ends.
HTTP headers are capped at 8 KiB, WebSocket messages/frames at 1 MiB, per-client
upstream message/packet queues at 64 records and writes at two seconds. Token
budgets use upstream `Bucket`; overload closes a connection. Reads reserve bounded
chunks, and partial writes can conservatively consume more budget than the bytes
actually delivered. This is a protective traffic ceiling, not exact billing.

## Configuration and operation

Copy `config.example.json` into an operator-protected file and replace both
secrets. `admissionSecret` is the backend's `RELAY_INTERNAL_SECRET`.
`adminSecret` matches this relay's private `PEER_POLICY_TARGETS` outbox target.
Do not send either secret to clients. The public `relayUrl` must appear exactly
in the backend's approved `IROH_RELAY_URLS`. No public fallback/discovery defaults
are added by this service.

Mount the TLS certificate chain and private key read-only. Configuration and TLS
certificates are loaded at process start; rotate by draining/restarting instances
with fresh admission rather than mutating files mid-connection. Operator DNS,
trusted certificates, private routing and secrets remain external actions.

### `devInsecureHttp` (local development only)

A local stack has no DNS name resolving to the developer's machine and no
publicly trusted certificate, and the pinned client bindings expose no custom-CA
surface, so a private CA cannot substitute for one. `devInsecureHttp: true`
serves the same relay protocol over cleartext instead. It requires `relayUrl` to
carry the `http` scheme, refuses a `tlsCert`/`tlsKey` pairing and lifts the
port-443 pin; the advertised scheme and the wire actually served come from that
one flag, so no configuration can advertise `https` while answering in the
clear. Both `listen` and the `relayUrl` host are confined to loopback or a
private range — a LAN address is allowed because a phone or emulator has to
reach the stack, `0.0.0.0` and a public address are not — which keeps "local
development only" a property this file enforces rather than one that emerges
from what every peer happens to refuse. Everything else — signed-challenge authentication, HMAC admission, leases,
fences and byte budgets — is the same code path. The process prints a
`relay_insecure_http` event at startup. Every peer that dials such an origin has
to opt in on its own side as well, so setting this alone makes nothing accept a
plaintext relay. Upstream's own relay binary exposes the same escape hatch as
`--dev`.

```sh
cargo build --locked --release -j 2
./target/release/antgrid-iroh-relay /config/relay.json
./target/release/antgrid-iroh-relay --healthcheck /config/relay.json
```

The admin listener is required to bind loopback. Expose it only through a private
sidecar/network namespace to the backend and monitoring system, never the public
ingress. It supports:

- `GET /healthz`: process liveness.
- `GET /readyz`: a valid authoritative backend response within 30 seconds.
  A signed probe for the unregistered all-zero endpoint runs every 10 seconds;
  a correctly correlated denial proves backend reachability without admission.
- `GET /metrics`: Prometheus text, metadata only.
- `POST /internal/disconnect`: HMAC SHA-256 `x-antgrid-signature` over exact JSON
  `{ "userId": "...", "generation": "decimal", "issuedAt": milliseconds }`.
  Body limit 4 KiB; timestamp freshness 30 seconds. Success means the dispatch
  fence is active; it does not claim remote peers have observed socket closure.

Public `/ping` and `/generate_204` return probe responses over the same wire as
the relay protocol itself. The private
interface has its own connection cap and request deadline. A 503 outbox response
must remain pending and retry; do not manually mark delivery complete.

## Metrics

Counters: `antgrid_iroh_admissions_total`, `antgrid_iroh_rejections_total`,
`antgrid_iroh_invalidations_total`. Gauges: `antgrid_iroh_connections`,
`antgrid_iroh_pending_admissions`, `antgrid_iroh_accounts`,
`antgrid_iroh_backend_ready`.

`antgrid_iroh_account_{rx,tx}_transport_bytes_total{user_id}` records cumulative
authenticated-account transport bytes. Live endpoint series use
`antgrid_iroh_endpoint_{rx,tx}_transport_bytes_total{user_id,endpoint_id}`; series
can disappear/reset as endpoints disconnect/reconnect. Series count is bounded
by configured account/connection capacity. Final endpoint usage is also emitted
as a metadata-only JSON log on disconnect. Keep log collection draining and
retain those records if per-endpoint lifetime accounting is required.

Byte counters measure TCP/TLS transport bytes, including framing/handshake
overhead, not decrypted payloads. CPU/RSS and process-level traffic are external
container/process metrics. Metrics and usage logs must remain private; they reveal
account/endpoint metadata. There are no payload labels or packet logging.

## Container build

`Dockerfile` pins the official registry manifest-index digests of the
`rust:1.98.1-bookworm` builder and `debian:bookworm-slim` runtime. Overrides must
retain reviewed immutable digests.

```sh
docker build -t antgrid-iroh-relay .
```

Run read-only, as the configured non-root user, with a bounded memory/PID limit
and read-only config/cert mounts. Arrange port-443 bind permission in the
container network namespace. Publish only 443; the admin listener stays in the
private namespace. The container build and deployment have not been executed in
this Windows qualification environment; image signature verification and Linux
runtime dependencies remain container qualification gates.

## Checks and limits of evidence

```sh
cargo test --locked -j 2
# Separate graph is necessary: Cargo cannot unify exact compatible-major
# iroh-relay 1.0.0 and 1.2.0 as aliases in one dependency graph.
cargo build --locked -j 2 --manifest-path compat-client/Cargo.toml
ANTGRID_LEGACY_RELAY_CLIENT="$PWD/compat-client/target/debug/antgrid-relay-compat-client" \
  cargo test --locked -j 2 --test tls_relay -- --nocapture
```

A cleartext gate drives the same two upstream relay clients through a
`devInsecureHttp` listener over `http://`, asserting a datagram is relayed,
that a second account sees nothing, that an endpoint the backend does not know
is refused and that admission stays HMAC-authenticated with TLS off. A separate
configuration gate asserts the flag's pairings. Neither weakens the default: a
stock configuration is still refused without a certificate and off port 443.

The fence tests cover stale admission, duplicate bind/endpoint limits, table
capacity, raw write/flush denial, blocked-writer wakeup, expiry and permit release.
The TLS gate uses actual upstream relay clients and a locally generated trusted
certificate with an explicit CA root, preserving certificate verification. It
checks packet routing, account isolation, signed administrative disconnection
and cancelled destination writes while upstream packets are queued. Its backend
admission responder is controlled; the real HTTP backend route has its own
integration gate.

The optional compatibility executable pins `iroh-relay`, `iroh-base` and
`iroh-dns` 1.0.0, matching the Flutter plugin's committed Rust graph at those
protocol boundaries. Its separate lockfile is not the complete native plugin
dependency graph. This checks relay protocol compatibility, not the JS/Dart
binding's TLS configuration or full QUIC/native forced-relay behavior.

The additional real-backend gate builds with
`cargo build --locked -j 2 --example real_backend_gate`, then runs from the
repository root with `bun run --filter antgrid-evals test:evals:iroh-relay-authorization`.
It passed actual device OAuth enrollment, HMAC admission, trusted TLS packets,
unknown endpoint rejection and backend revocation closing both connections
within 60 seconds. Its empty outbox target list isolates the lease-refresh
backstop; it does not simulate successful push delivery.

Still required before release: full native forced-relay connections,
physical client platforms, Linux container
execution, cold-start/rotation races under load, distributed outbox delivery,
outage/resume/network changes and the specified performance sample sizes.
