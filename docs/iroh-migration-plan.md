> Current decision: remote payloads use Iroh only. Earlier references below to
> WebSocket payload defaults, rollout modes and fallback are superseded. The
> central WebSocket remains for discovery, presence and revocation.

# Iroh migration implementation plan

Source: user-approved implementation plan, 2026-09-14. This branch implements
the migration; staging qualification gates release, not implementation.

## Decisions

- Retain authenticated central WebSocket inventory, presence and revocation.
  Move payloads to Iroh with temporary WebSocket fallback; WebSocket is default.
- Upstream-only bindings, starting at prototype pins. Unsupported required hooks
  block release. Preserve application E2E, authorization and checkout routing.
- One endpoint per process/enrollment, one app-initiated machine connection,
  ALPN `antgrid/peer/1`, one bidirectional stream, unsigned big-endian four-byte
  route-frame lengths. Reject extra streams and bound records and queues.
- Separate endpoint keys per enrollment and distinct desktop/bridge identities.
- Drop Intel macOS outright; no universal transition or old-client migration.
- Deployment, DNS and production secrets remain operator actions.
- Parent owns contracts, integration, root locks and final verification. At most
  three bounded implementation agents concurrently, disjoint ownership, no new
  worktrees. Each writes a disk handoff with files, decisions, checks and gaps.

## Wave 1: contracts and transport separation

Define Flutter-free Apache PeerLink interfaces for routed frames, bounded async
send outcomes, lifecycle, typed failures, close and injectable diagnostics.
Separate control presence, payload state and path state. MachineSession and both
handshake drivers consume it; WebSocket adapts behind it. Feature interfaces stay
unchanged. Extract bridge peer E2E, fragmentation, scheduling, credits and
liveness from RelayClient, retaining central authentication and WS duties there.
Host owns stream IDs; local readiness differs from WS registration admission.
Iroh retains remote source semantics, never LocalListener's loopback exemption.
Preserve transcript bytes, confirmation, make-before-break rekey, bounded receive
contexts and control priority. ELv2 implementations belong in ELv2 components;
create a Flutter-free ELv2 Dart package for app and CLI native transport.
Gate existing WebSocket/project/E2E behavior before native selection.

## Wave 2: enrollment, authorization and relay

Freeze API contracts then parallelize backend, client leases/keys and Rust relay.
Device-linked globally unique endpoint IDs, monotonic decimal-string generations,
history/revocation timestamps, one active registration per enrollment. Strict JWT
authentication resolves azp to active OAuth credential and checks device/account.
Device-authenticated challenge/register/snapshot routes under account/devices/me.
Random single-use two-minute challenge; device and endpoint signatures over the
same domain-separated challenge/account/device/endpoint/expected-generation bytes;
TS/Dart vectors. Atomic challenge consumption/rotation prevents replay, stale
concurrent rotation and endpoint reuse. Inventories optionally advertise endpoint
registrations and authenticated capabilities. Snapshots return local entitlement,
eligible peer keys/registrations, approved relays and policy generation.
Authorization changes increment policy and transactionally enqueue retryable
account revocation and disconnect requests to every configured Iroh relay.

Persistent keys use secure/protected stores. Fresh authorization on connect,
restart/resume; serialized refresh every 20 seconds while active, maximum lease
60 seconds from monotonic request start; stale request/enrollment/policy rejected.
Enforce on upgraded WS too; legacy WS remains discoverable. Expiry, denial,
rotation/revocation immediately block admission/dispatch, cancel queues, close
sessions and erase keys. Recheck at dequeue/inbound dispatch. Keep account trust,
remote-access switch, seenProjects, isSafeProjectId and checkout capability gates.

ELv2 Rust relay embeds pinned upstream iroh-relay with Cargo.lock/container.
Backend-authenticated admission fails closed in two seconds. Private authenticated
disconnect, generation fences, active revalidation within 60 seconds, bounded
admissions/connections/traffic, health/readiness, payload-free metrics and usage.
TLS/443 and explicit environment relays; no public relay fallback. Audit upstream
admission/disconnect hooks and races; missing hooks are release blockers.

## Wave 3: integration and packaging

Parallel bridge, Dart/app, packaging/operations after stable Wave 2 contracts.
Validate authenticated endpoint, destination and record lengths before allocation.
Modes websocket, iroh-preferred, test-only iroh-only. Five-second selection budget;
E2E starts only on selected link. Generation fence callbacks/dials/writes; dispose
late peers without destroying shared endpoint. Keep selection until reconnect;
denial/revocation/protocol failure never fall back. ConnectionSupervisor alone
retries. Central loss/presence/path changes preserve healthy leased Iroh sessions.
Peer failure requires fresh E2E/hydration; pending commands fail unknown outcome,
never replay keystrokes or non-idempotent operations. Share native implementation
with CLI; FRB runtime disposal is process-final. Pin/verify native artifacts;
Windows/Linux x64, Apple Silicon and existing mobile targets. Remove Intel and
universal assembly across builds, artifacts, downloads and updater metadata.

## Verification and delivery

Serial Dart/Flutter analysis and CLI gates; workspace scripts only; E2E explicit.
Test vectors/record fragmentation/coalescing/malformed lengths/extra streams,
queues/cancellation/credits/rekey/stale generations; real multi-peer/project host,
checkout and all feature services; device binding/impersonation/replay/rotation,
entitlement/revocation/lease races; fallback/mixed versions/late connects, central
and relay outage, blocked UDP, transitions, background/resume and reconnects.
Compile Bun/Dart, package Flutter and qualify physical platforms. Unavailable
hardware/infrastructure is unqualified. No auth bypass, duplicate command,
unbounded queue or native crash is acceptable.

Compare identical workloads, >=100 connections and >=1000 input samples/profile:
>=95% lower steady-state direct-capable server payload bytes, lower direct-WAN
interactive p95, <=10% startup/forced-relay p95 regression, <=1 percentage-point
success reduction. Instrument request/control auth/discovery/native/E2E/project/
usable terminal latency, path bytes, fallback reason, CPU/memory, never payloads.
Deliver deployment config/container/health/dashboards/smoke/runbook; update actual
architecture/protocol/qualification/handoff. Staging additive backend first.
Production internal, 1%, 10%, 50%, 100% with passing gates and 48 healthy hours
each. Rollback disables preference/reconnects without replay; retain DB fields.
Legacy payload removal later: two qualified releases and 14 days of >=50% lower
server bytes, <1% fallback and supported compatibility. Keep central WebSocket.
