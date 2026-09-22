# Iroh ownership simplification

Baseline: uncommitted Iroh-only migration; preserve unrelated changes.

Stages: (1) endpoint lifecycle recovery and bounded admission; (2) compose central control and native sessions, local project readiness; (3) native app connector and separate initialization/dial budgets; (4) regression and native integration gates.

Invariants: authenticated leases, E2E, generation fences, host-owned stream IDs, checkout authorization, bounded queues, and no command replay remain mandatory. No deployment, stack restart, commit or push.

Verification and unresolved qualification will be appended as work completes.

## Implementation

- Added a generation-fenced endpoint lifecycle with single-flight creation/retirement, transient retry (1s base, 30s cap, equal jitter), terminal blocking and idempotent shutdown. Unsettled native operations retain their resource slots.
- Native admission runs concurrently with four pending slots and the existing active-session limit; duplicate authenticated identities are reserved before first-stream setup. Authorization requests include token acquisition in their deadline.
- NativeHostConnection composes CentralControlClient, NativePeerSessions and EndpointLifecycle. PeerSessionOwner receives a native payload sink. Native project readiness and host-owned stream IDs are local; the central protocol has no payload adapter or stream registration.
- PeerConnector returns PeerLink directly. PeerConnectionAttempt replaces selection; cancellation is distinct from failure and cannot accumulate native dials. Shared initialization (30s) and connect/first-stream (15s) have separate provisional deadlines.
- Central retries and token minting progress independently of payload attempts. Native success cannot reset central supersession accounting. Changed central coordinates are reconciled without relying on payload failure. Central routing errors cannot mutate native project delivery state.

## Verification (2026-09-22)

- Wire: typecheck passed; 115 tests passed.
- Central relay: typecheck passed; 167 tests passed, including signed authentication, epoch replacement, account-scoped presence/revocation, encrypted push delivery, and 1008 rejection of binary and retired stream-registration frames.
- Bridge: typecheck passed. The full suite reached 4,846 passed and 16 skipped with seven unrelated hook/terminal timing failures; those seven passed in an isolated rerun with the inherited `ANTGRID_RUN_ID` removed. Migration fixture repairs passed their focused 70-test rerun, so the broad run is not recorded as clean.
- Web: production build passed; 658 tests passed.
- Flutter: analysis passed. The full suite reached 4,194 passed and two skipped with one stale fanout enrollment fixture; after requiring an authenticated native enrollment, its focused two-test rerun passed. The connection/provider regression group passed 57 tests. The font-token scan passed through Git Bash; the npm wrapper selected unavailable WSL bash on this machine.
- Dart relay client: analysis passed; 273 tests passed. The Dart evaluation client analysis passed and has no `package:test` dev dependency or test target.
- Evaluations: TypeScript typecheck passed. Migrated native fixture/host, central outage, restart, file, terminal and two-machine switch/reverse-direction groups passed. One two-machine notification-queue row retains the independently reproducible session-bus timing failure; browser-preview rows remain pre-skipped.
- Native host smoke passed with real loopback Iroh and E2E: two projects on one connection, managed-checkout Git, terminal input/frame acknowledgements, central outage survival and remote-access-off shutdown.
- Real HTTP/OAuth/Prisma authorization passed 25 assertions covering enrollment, inventory, rotation, reuse denial, revocation and outbox creation. The real-backend native-host gate passed two projects, central outage and revocation (about 19.9 seconds via snapshot refresh). The trusted-TLS relay authorization gate passed 11 assertions; it does not qualify native QUIC payloads through a forced relay.

- Cross-language Dart–Bun interop passed using the existing compiled app `irohdart_ffi.dll`: production `iroh_quic` app binding against `@number0/iroh`, two projects, central outage, terminal I/O, managed-checkout Git and remote-access shutdown. The explicit peer-resume gate passed three fresh native/E2E cycles while retaining both project bindings; observed direct-loopback recovery was about 33–40 ms and is not a WAN or mobile performance claim.

## Unqualified / unchanged

- Forced-relay native QUIC, blocked-UDP/WAN transitions, physical-device background/resume, desktop sleep/wake and comparative performance remain unqualified.
- No live Aspire restart, production deployment, secrets/DNS change, commit or push was performed.
- Existing unrelated `.gitignore` and `preview_element_picker_script.dart` edits were preserved.
