# Iroh migration implementation handoff

Checkpoint: 2026-09-14. Branch implementation and local verification are recorded
below. WebSocket remains the default. No deployment, DNS or secrets
were changed. This file supersedes the earlier prototype-only handoff.

## Intent and boundaries

The full approved plan is [saved here](iroh-migration-plan.md); ongoing gates are
in the [ledger](iroh-migration-ledger.md). Do not create another worktree. Apache
interfaces remain in `antgrid_relay_client` and `antgrid-wire`; native transport,
enrollment and leases are in the new ELv2 `antgrid_peer_transport` package.
The Windows prototype is historical evidence, not production authorization.
Intel macOS is removed without a universal transition, as requested.

## Implemented branch behavior

- Dart `PeerLink` separates central control from payload state and native path.
  WebSocket adapts behind it. `MachineSession` and both E2E handshake drivers use
  the interface, with asynchronous send outcomes and authorization checks.
- Bridge `PeerSessionOwner` extracts E2E, fragmentation, rekey, flow control,
  liveness and stream scheduling. Host-assigned stream readiness is separate
  from WebSocket admission. Native routes preserve remote command authorization,
  the remote-access switch, project catalog and checkout routing.
- Strict credential-to-device OAuth binding, dual-signed single-use endpoint
  challenges, atomic generation/history rotation, inventories and authoritative
  authorization snapshots are implemented with Prisma migrations. BetterAuth's
  serialized metadata form is validated by the shared credential parser.
- Policy mutation triggers write transactional outbox events. A bounded worker
  signs delivery to central control and configured private Iroh administration
  targets, retries partial failure, and retains pending work without a central
  target. Central relay broadcasts account-scoped generation invalidation.
- App secure records hold distinct per-enrollment endpoint seeds and bootstrap
  the bridge. Both upgraded WebSocket and native payload sessions use monotonic
  authorization leases, synchronous dispatch fences and generation checks.
  Restored records persist an endpoint seed before use, and missing enrollment
  fails closed. Desktop resume also fences the existing local bridge's sessions
  before refreshing its authoritative lease.
- Pinned upstream native endpoints carry length-prefixed route records on one
  bidirectional ALPN stream. App selection is generation-fenced and precedes E2E.
  The app supervisor owns retry and independent central restoration; native
  project sessions survive central outages while their lease remains valid.
- Desktop packaging uses Apple Silicon macOS artifacts and updater feed names.
  Flutter uses upstream `iroh_flutter`; standalone Dart uses the same ELv2
  adapter. Native dependencies and root/package lockfiles are pinned.
- The self-hosted Rust relay composes upstream 1.2.0 authentication, routing and
  traffic controls. Account-scoped registries and raw-I/O generation fences
  invalidate queued packets across all affected destinations. Private signed
  admission/disconnect APIs, bounded resources, readiness, metrics, immutable
  container bases and monitoring examples accompany it.

Component handoffs: [Dart](iroh-handoff-dart.md),
[backend](iroh-handoff-backend.md), [relay service](../iroh-relay/HANDOFF.md),
[security review](iroh-integration-review.md).
Read component `CLAUDE.md` instructions before editing. Agents share this checkout;
no competing Dart/Flutter commands, including analyzer startup.

## Evidence and limits

The full Apache Dart package passed 296 tests and analysis. The native Dart
package passed 15 tests and analysis, including TS/Dart enrollment transcript
signatures. Wire passed 119 tests and typecheck; central relay passed 193 tests
and typecheck. Targeted backend security passed 31 tests; real HTTP enrollment
against BetterAuth/PostgreSQL passed 25 assertions and found a metadata binding
bug that was fixed. Full backend tests passed 661 tests including the internal
relay admission route. Backend/eval typechecks pass.

Actual Windows source and compiled HostServer/native/E2E smoke tests passed:
projects attached without WebSocket admission remain usable on one native pair,
file reads continue after central loss, terminal input produces acknowledged
frames, managed-checkout Git routes correctly, and remote-access-off closes admission.
Those smokes use fixture backend/control authorization. A combined real HTTP
backend/native HostServer gate also passed, including actual device revocation
closing the native session at its next refresh (19.95 seconds). Central welcome
remains a fixture in that gate. The compiled production Dart adapter loaded the
actual Flutter-built Windows DLL and passed native echo, malformed length,
extra-stream and revoked-send scenarios.

The latest full bridge run passed 4,840 tests with 16 skips and one filesystem
scan timeout; that suite passed all 13 tests on isolated rerun. Typecheck passed.
The final full Flutter run passed 4,208 tests with two skips; analysis is clean.
Dart terminal evaluations passed all six scenarios after their
harness subscribed to the advertised terminal-frame protocol. The full eval
sweep finished with 106 passed, 28 skipped and 20 failures. Thirteen fixture
regressions were corrected and rechecked: secure promotion enrollment, modern
terminal subscriptions, fresh E2E after switch changes, and handler entitlement
and completion evidence. A 2026-09-15 follow-up passed all six installed
Claude/Codex scenarios with authorized access to the authenticated CLIs. Their
collectors now honor the full turn deadline, surface driver errors and require
assistant-role evidence for Claude's response. Eval typecheck passed. The guard
requiring generated vectors to be committed remains outstanding; regeneration
matches the fixture byte-for-byte and its five schema checks pass. No new clean
full E2E sweep is claimed. Exact subsequent results belong in the ledger.

The site build and browser contracts passed with 38 tests and two skips; its
frozen lockfile stayed unchanged. Final whitespace checks passed.

## Release and implementation gaps

The Rust service passed six fence/accounting tests and a real TLS packet/admission/
disconnection test, including queued-write cancellation and concurrent identity
binding without double-counting transport bytes. A separately locked
upstream 1.0.0 client also exchanged packets with it, matching the Flutter plugin's
protocol-boundary versions. The combined real HTTP backend/service gate passed
11 assertions: actual endpoint enrollment, signed admission, trusted TLS packets,
unknown endpoint denial and revocation closing both account connections within
60 seconds, with reconnect refused. This is not qualification of full JS/Dart
QUIC forced-relay traffic.

The pinned bindings also lack a verified typed native close taxonomy, precise
path-byte telemetry, and explicit zeroization APIs for retained private key
copies. Unknown native failures are terminal so they cannot hide authorization
or protocol rejection behind fallback. This can require explicit retry on a
network failure and is a release blocker, not qualified lifecycle behavior.

The Windows Flutter native library built successfully; the full application
build is blocked by missing Visual Studio ATL headers (`atlstr.h`). Other Flutter
platform builds, physical mobile, direct/forced-relay WAN, comprehensive feature
workloads and performance thresholds remain unqualified. The Docker daemon is
unavailable here, so the immutable-base container is not locally built. Monitoring
JSON/YAML parses, but live dashboard/alert validation and cohort promotion depend
on staging infrastructure. The
[operations guide](iroh-operations.md) records staging configuration, smoke
commands and promotion/rollback criteria; it does not claim deployment occurred.
