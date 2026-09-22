# Iroh ownership simplification

Baseline: uncommitted Iroh-only migration; preserve unrelated changes.

Stages: (1) endpoint lifecycle recovery and bounded admission; (2) compose central control and native sessions, local project readiness; (3) native app connector and separate initialization/dial budgets; (4) regression and native integration gates.

Invariants: authenticated leases, E2E, generation fences, host-owned stream IDs, checkout authorization, bounded queues, and no command replay remain mandatory. No deployment, stack restart, commit or push.

Verification and unresolved qualification will be appended as work completes.

## Implementation

- Added a generation-fenced endpoint lifecycle with single-flight creation/retirement, transient retry (1s base, 30s cap, equal jitter), terminal blocking and idempotent shutdown. Unsettled native operations retain their resource slots.
- Native admission runs concurrently with four pending slots and the existing active-session limit; duplicate authenticated identities are reserved before first-stream setup. Authorization requests include token acquisition in their deadline.
- NativeHostConnection composes CentralControlClient, NativePeerSessions and EndpointLifecycle. PeerSessionOwner receives a payload sink; only the legacy evaluation adapter registers WebSocket streams. Native project readiness is local.
- PeerConnector returns PeerLink directly. PeerConnectionAttempt replaces selection; cancellation is distinct from failure and cannot accumulate native dials. Shared initialization (30s) and connect/first-stream (15s) have separate provisional deadlines.
- Central retries and token minting progress independently of payload attempts. Native success cannot reset central supersession accounting. Changed central coordinates are reconciled without relying on payload failure. Central routing errors cannot mutate native project delivery state.

## Verification (2026-09-22)

- Bridge typecheck: passed. Focused bridge lifecycle, native admission, central authentication/watchdog/backoff, credit/scheduler, enrollment and lease regressions: 72 passed.
- Full bridge suite: 4,846 passed, 16 skipped, 7 failed, one associated unhandled terminal timeout. Six failures inherited ANTGRID_RUN_ID into hook subprocess fixtures; all seven failures passed in an isolated rerun (43 tests) with that variable removed from the test process only. The broad run is not recorded as a clean pass.
- Flutter targeted connection/provider/session regressions: 90 passed. Flutter analysis: passed, including final central-routing isolation cleanup.
- Pure Dart transport: 21 tests passed; analysis passed.
- Real native host smoke and Dart–Bun native interop passed: two projects on one connection, real E2E, central outage, terminal I/O, checkout Git, remote-access-off.
- Explicit real-backend host authorization gate passed: HTTP/OAuth/Prisma enrollment, native direct-loopback E2E, two projects, central outage and device revocation. Revocation was observed on the periodic snapshot refresh (approximately 20s); this does not qualify live outbox delivery.

Commands use workspace scripts: antgrid-bridge typecheck/test/qualify:iroh-host/qualify:iroh-interop and antgrid-evals test:evals:iroh-host-authorization. Flutter and Dart checks were serial, using the direct SDK executable and existing qualification PUB_CACHE. Logs are under .tmp/iroh-simplification-* (local, ignored).

## Unqualified / unchanged

- No live Aspire restart or interactive Windows/Android test was performed. Two-minute background/resume, relay outages, blocked UDP, physical mobile/Apple targets and WAN/network transitions require live qualification.
- Forced-relay path evidence and cold/warm direct-versus-relay comparative performance remain outstanding. Direct-loopback smoke is not relay qualification; provisional deadlines are not performance results.
- No deployment, secrets/DNS change, commit or push. Existing unrelated .gitignore and preview_element_picker_script.dart edits were preserved.

### Final gates

- Final Flutter analysis and pure-Dart transport analysis: no issues. Native Dart transport tests: 21 passed.
- Final central-routing isolation regression: 6 passed. Final bridge endpoint/admission regression: 19 passed (including bounded pending admissions and late cleanup after shutdown).
- Migrated the obsolete WebSocket-based peer-resume evaluation to the native cross-binding harness. The explicit peer-resume gate passed three host-resume cycles while central control remained unavailable: fresh native/E2E sessions, both host-owned stream IDs preserved, newly written file content retrieved, shared app endpoint retained. Observed direct-loopback recovery was approximately 36–45ms; this is not a WAN or mobile background performance claim.
- Final bridge typecheck after the native resume script changes: passed (exit 0). Git diff whitespace check: passed.
