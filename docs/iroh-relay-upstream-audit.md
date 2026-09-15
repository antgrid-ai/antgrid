# Iroh relay upstream audit

Audited 2026-09-14. **Release qualification remains incomplete.** The stock
embedding does not establish the required admission/revocation fence. The
supported low-level composition identified below is now implemented in
[`iroh-relay/`](../iroh-relay/README.md), using published upstream 1.2.0 without
a fork. Locked builds and local trusted-TLS tests pass, including upstream
1.0.0 client protocol compatibility and queued destination write revocation.
This removes the earlier missing-hook implementation blocker; it does not
qualify native forced-relay clients, deployment or production load behavior.

## Version evidence

The cached prototype uses `@number0/iroh` 1.1.0 and `iroh_quic` 1.0.3 with FRB
2.12.0. The cached Dart Rust manifest specifies `iroh = "1.0"` and
`iroh-base = "1.0"`, which are ranges, not resolved relay pins. No relay
Cargo.lock is supplied by the prototype. This audit explicitly examines upstream
tag **v1.0.3**; it does not claim this is the native artifacts' resolved version.
Resolve and integrity-pin the actual crate graph before building a service.

Local evidence: `.tmp/iroh-qualification/js/package/package.json` and
`.tmp/iroh-qualification/packages_iroh_quic_rust_Cargo.toml`.

## Supported APIs and their limits

`AccessControl::on_connect(&ClientRequest)` is asynchronous and returns `Access`.
`ClientRequest::endpoint_id()` is authenticated by the relay handshake;
`connection_id()` distinguishes duplicate connections. `on_disconnect` is
synchronous and receives that connection ID. An implementation can impose a
two-second backend timeout, deny overload through nonblocking permit acquisition,
and retain a permit until disconnect. These are application responsibilities.

`Server::spawn(ServerConfig)` embeds the service; `Server::relay_service()` exposes
runtime control. `TlsConfig::new` and `CertConfig::Manual` support TLS with an
explicit HTTPS bind address. Configure 443 and provide operator-managed certs.
The defaults must be overridden: `RelayConfig::new` permits everyone and disables
TLS. `Limits::accept_conn_limit` and `accept_conn_burst` are explicitly
unimplemented. `ClientRateLimit` supports inbound bytes/second and burst limits.
[Pinned server source](https://raw.githubusercontent.com/n0-computer/iroh/v1.0.3/iroh-relay/src/server.rs).

`RelayService::clients()` exposes the registry. Its accept path awaits
`authorize_with`, then constructs the stream and calls `Clients::register`.
There is no public callback at registration or frame dispatch on this path.
`RelayService::handle_connection` permits an application-owned listener with a
TLS/HTTP establishment timeout. That timeout ends at WebSocket establishment;
it is not a backend authorization timeout or a lifetime lease.
`RelayService::set_client_rate_limit` updates existing and future connections.
[Pinned HTTP embedding source](https://raw.githubusercontent.com/n0-computer/iroh/v1.0.3/iroh-relay/src/server/http_server.rs).

`Clients::disconnect(endpoint_id, Some(connection_id))` targets one registered
connection; `None` targets all registered duplicates. It returns false for an
absent match and initiates asynchronous shutdown. It neither records a tombstone
nor cancels a future registration. `Clients::register` is public, whereas packet
routing and unregister are component-private. Duplicate clients remain retained,
and an older connection can become active when its replacement closes.
[Pinned registry source](https://raw.githubusercontent.com/n0-computer/iroh/v1.0.3/iroh-relay/src/server/clients.rs).

Public `client::Config<S>` exposes queue capacity and write timeout, allowing a
lower-level integration to choose bounded queues. The actor and its cancellation
token are private. Its task starts during `Client::new`, before the caller has
finished registry insertion; merely locking an application registration table
does not demonstrate that dispatch is fenced.
[Pinned client source](https://raw.githubusercontent.com/n0-computer/iroh/v1.0.3/iroh-relay/src/server/client.rs).

Upstream metrics include aggregate sent/received payload byte counters, drops,
connection counts and rate-limit counters. They provide no endpoint/account
labels or lifecycle byte-accounting callback. Admission callbacks can account
for connections, but cannot attribute traffic bytes. Such accounting needs an
audited supported stream wrapper or upstream instrumentation, not an estimate
from aggregate deltas.
[Pinned metrics source](https://raw.githubusercontent.com/n0-computer/iroh/v1.0.3/iroh-relay/src/server/metrics.rs).

## Required race qualification

The following is a source-derived interleaving, **not an executed reproduction**:

1. Endpoint E passes backend admission at generation G.
2. The admission future returns Allow; upstream has not registered E yet.
3. Revocation advances the application policy and calls disconnect(E).
4. Disconnect finds no registered connection and returns false.
5. The already-authorized accept path registers E and starts dispatch.

A periodic disconnect retry can shorten the window, but does not prove the
required synchronous admission/dispatch fence. The same issue applies to expiry
while admission is pending. A backend generation check inside `on_connect` alone
does not fix the gap after that callback returns.

Before implementation, demonstrate an upstream-supported composition that holds
a cancellable authorization guard through registration and checks it before
inbound/outbound dispatch. Also demonstrate lifetime permits spanning raw socket,
upgrade and registered connection ownership; the high-level connection-limit
fields cannot provide this. Low-level `Clients::register` plus generic stream
types are promising, but this audit has **not verified** a complete authenticated
handshake/HTTP composition without replacing upstream protocol internals.
If that composition is unavailable, request upstream hooks or pin a later
upstream release that supplies them. Do not fork or relax the requirement.

## Handoff and exact checks

Changed file: this document only. No runtime code, lockfile, container or service
configuration was created because the required security boundary is unresolved.

- Read cached manifests with PowerShell `Get-Content`: versions above confirmed.
- Browsed the pinned upstream source files linked above: API/source review only.
- `Get-Command cargo,rustc -ErrorAction SilentlyContinue`: neither found on PATH.
- `docker version --format '{{.Server.Version}}'`: failed; Docker engine pipe
  absent (also reported denied access to user Docker configuration).
- Direct `Invoke-WebRequest` to upstream: network connection failed. Browser
  research retrieved the linked source; several handshake module URLs were
  unavailable, so lower-level composition remains unverified.
- No Rust compilation, Cargo resolution, container execution, active-disconnect
  race test, traffic accounting test or staging relay exercise was run.

Next owner must resolve the race and accounting hooks, install/use a working
Rust toolchain, produce a real pinned Cargo.lock, then implement backend timeout,
monotonic 60-second leases, authenticated private administration, resource bounds,
health/readiness and payload-free usage telemetry. Client relay maps must contain
only backend-approved environment URLs; relay server configuration alone cannot
disable public discovery in clients. DNS, TLS certificates, secrets and deployment
remain operator actions. WebSocket remains the production default.

## Tooling checkpoint after client integration

An isolated Rust toolchain was subsequently installed under
`.tmp/iroh-rust-toolchain` for the Windows Flutter plugin build (rustc1.98.1).
It successfully built the pinned upstream native DLL. This removes the local
Rust-tooling obstacle recorded in the historical audit, but does not resolve
the relay admission/dispatch race, accounting hooks, or container qualification.
No self-hosted relay service or Cargo.lock was fabricated from that client build.

## Newer upstream review: published 1.2.0

On 2026-09-14 the direct docs.rs latest page resolved to **1.2.0**, despite stale
search results showing 1.0.3. Crates.io reports publication on 2026-09-09. The
published archive was downloaded to `.tmp/iroh-relay-1.2.0.crate`, extracted for
read-only review, and matched crates.io checksum
`beb2294a9749d6a25fd7cd8bcf0fccd932f20716d4f967d85d3f23c7135ae6a2`.
Its `.cargo_vcs_info.json` records commit
`17c0612f80f78f5288e97b818b1360ae6ea0a51a`.
[Published release metadata](https://crates.io/api/v1/crates/iroh-relay/1.2.0),
[module documentation](https://docs.rs/iroh-relay/1.2.0/iroh_relay/server/index.html).

The high-level service still calls `authorize_with(...).await` before
`Clients::register`; registration starts its actor before registry insertion.
Disconnect remains asynchronous and affects registered connections only.
Acceptance rate/burst fields remain explicitly unimplemented. Upgrading the
stock embedding therefore does not resolve the identified race or bounds.
[HTTP path](https://github.com/n0-computer/iroh/blob/17c0612f80f78f5288e97b818b1360ae6ea0a51a/iroh-relay/src/server/http_server.rs),
[registry](https://github.com/n0-computer/iroh/blob/17c0612f80f78f5288e97b818b1360ae6ea0a51a/iroh-relay/src/server/clients.rs),
[limits](https://github.com/n0-computer/iroh/blob/17c0612f80f78f5288e97b818b1360ae6ea0a51a/iroh-relay/src/server.rs).

### Verified public composition surface

The downloaded source establishes these public APIs, without copying the
authenticated protocol implementation:

1. `protos::handshake::serverside(&mut io, client_auth_header)` accepts an
   implementation of `BytesStreamSink + ExportKeyingMaterial` and returns
   `SuccessfulAuthentication` with the verified `client_key`.
2. `ClientRequest::new` and
   `SuccessfulAuthentication::authorize_with` complete authorization using the
   callback and return `OnDisconnectGuard`; `authorize_if` is also public.
3. `RelayedStream::new(custom_stream, key_cache)` and
   `client::Config::new(guard, stream, protocol_version)` accept a custom
   WebSocket byte stream. Config exposes queue capacity and write timeout.
4. `Clients::register(config, metrics)` retains the upstream client actor and
   packet router. A custom HTTP/TLS accept loop can own resource permits before
   handshake and transfer them into its stream's lifetime.

[Handshake API](https://github.com/n0-computer/iroh/blob/17c0612f80f78f5288e97b818b1360ae6ea0a51a/iroh-relay/src/protos/handshake.rs),
[byte stream trait](https://github.com/n0-computer/iroh/blob/17c0612f80f78f5288e97b818b1360ae6ea0a51a/iroh-relay/src/protos/streams.rs),
[stream constructor](https://github.com/n0-computer/iroh/blob/17c0612f80f78f5288e97b818b1360ae6ea0a51a/iroh-relay/src/server/streams.rs),
[actor configuration](https://github.com/n0-computer/iroh/blob/17c0612f80f78f5288e97b818b1360ae6ea0a51a/iroh-relay/src/server/client.rs).

These are real public extension points. The private upstream `WsBytesFramed`
adapter is not required if the service supplies its own standard WebSocket
adapter implementing the documented trait. The private high-level
`serve_connection` helper does not by itself rule out low-level composition.

### Candidate fence requiring implementation qualification

An account-scoped `Clients` registry plus an account-wide generation guard is
a plausible conservative design. After upstream authentication, bind the stream
to authoritative endpoint/account identity and a monotonic deadline. Hold a
generation fence through final admission/registration; gate actual raw I/O and
WebSocket sink/stream operations, including flushes, using the same guard. A
revocation invalidates the account generation and cancels every pending and
registered connection for that account before acknowledging administration.
This deliberately disconnects otherwise eligible peers in that account too.

Account-wide invalidation matters: disconnecting only the revoked sender does
not purge its packets already queued in another client's actor. The relay
message enums are public, but `from_bytes`/`to_bytes` are crate-private, so a
byte wrapper cannot simply call a public typed decoder to identify queued source
packets. A per-account registry and shared generation can invalidate all those
destinations without reimplementing relay packet codecs.
[Message codec visibility](https://github.com/n0-computer/iroh/blob/17c0612f80f78f5288e97b818b1360ae6ea0a51a/iroh-relay/src/protos/relay.rs).

The wrapper can attribute transport bytes to its authenticated endpoint/account;
this includes framing overhead and must not be mislabeled as payload bytes.
Stock metrics remain aggregate. Raw-connection, pending-auth and admitted-client
permits must be independently bounded; admitted permits alone cannot bound idle
TLS or WebSocket handshakes. The low-level public `Bucket` may supply byte-rate
budgeting, while the stock `RateLimited` wrapper is private.
[Metrics](https://github.com/n0-computer/iroh/blob/17c0612f80f78f5288e97b818b1360ae6ea0a51a/iroh-relay/src/server/metrics.rs).

### Implementation evidence

The service now compiles against these public APIs. Four fence tests cover stale
admission generations, duplicate bind/endpoint limits, retained account capacity,
write/flush rejection, blocked-writer wakeup, expiry and permit release. A real
TLS test exercises upstream authenticated relay clients, account isolation,
signed administration, and queued destination writes held below TLS then revoked
before release. No destination bytes are written after that fence.

A separate locked client graph pins `iroh-relay`, `iroh-base` and `iroh-dns`
1.0.0, matching those entries in the published `iroh_flutter` 1.0.3 Cargo.lock.
Its authenticated opaque packet transfer against the 1.2.0 service passed with
an explicit trusted test CA; certificate validation remains enabled. This is
protocol compatibility evidence, not execution of either native binding.

The service enforces two-second backend admission, monotonic leases bounded by
60 seconds, generation checks through raw I/O, independent raw/pending/account
limits, and bounded upstream queues. Its backend responder in the TLS test is
controlled. Combined real-backend/relay admission, native QUIC forced-relay
connections, Linux container execution, large-scale race/resource tests and
platform/performance qualification remain outstanding. See the service
[handoff](../iroh-relay/HANDOFF.md) for exact checks and limitations.
