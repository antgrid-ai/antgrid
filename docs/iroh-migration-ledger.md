# Iroh migration task ledger

Plan: [approved scope](iroh-migration-plan.md). Historical prototype and review detail remain in Git. Status refers to production implementation, not prototype smoke.

| Work | Status | Evidence |
| --- | --- | --- |
| Save plan / inspect existing boundaries | Complete | Plan saved; existing changes preserved |
| Dart PeerLink / WebSocket separation | Implemented | Full package tests: 296 passed; analysis clean |
| Bridge reusable peer-session owner | Implemented | Full bridge: 4,840 passed, 16 skipped, one scan timeout; isolated entitlement rerun: 13 passed; typecheck clean |
| Wave 1 regression gate | Component gates passed | Dart terminal E2E: 6 passed; full eval sweep completed, fixture corrections verified separately |
| Endpoint enrollment / policy / outbox | Implemented, staging unqualified | Full web: 661 passed; real HTTP authorization gate: 25 assertions; combined real backend/native host revocation gate passed |
| Protected keys / authoritative leases | Implemented | Native Dart: 15 passed, analysis clean; restored secure records and missing enrollment fail closed; desktop resume fences host leases |
| Upstream relay hooks / Rust service | Implemented, staging unqualified | Locked upstream 1.2.0 service; six fence/accounting tests and actual TLS routing/disconnect test passed, including older 1.0.0 protocol compatibility; combined real backend/service gate passed 11 assertions |
| Native host/app integration / selection | Implemented | Source and compiled HostServer/native/E2E smoke passed terminal input/output, frame ACKs, managed-checkout Git, two projects, central outage and immediate remote-access-off |
| Packaging / Apple Silicon / operations | Partially verified | Flutter-built Windows native DLL passed compiled Dart smoke; full Windows debug app build passed after Rust PATH and Visual Studio ATL setup; CI/monitoring YAML and Compose config parse; Docker daemon/physical builds unavailable |
| Final local gates | Component gates passed; full E2E not clean | Wire 119 passed; relay 193 passed; Flutter 4,208 passed, two skipped, analysis clean; original full E2E sweep: 106 passed, 28 skipped, 20 failures; 13 fixture regressions corrected/rechecked; installed-agent follow-up below; clean full-sweep verification remains outstanding |
| Physical/staging/security/performance qualification | Unqualified | Operator infrastructure and physical platforms required |

Final bounded checks: site build and browser contracts passed (38 passed, two
skipped), with its frozen lockfile unchanged. Relay byte accounting now serializes
recording with identity binding, preventing pre-authentication bytes from being
counted twice. Anonymous rejected traffic remains unattributed; admitted traffic
includes pre-authentication transport overhead. Concurrent binding and completed
connection totals are covered by the final seven-test Rust gate.

## Installed-agent follow-up — 2026-09-15

All six previously failing installed-agent scenarios passed focused runs with
authorized access to the installed authenticated CLIs: Codex four tests/19
assertions and Claude two tests/18 assertions. No production driver changes were
needed. The restricted environment reproduced the Claude failures; subprocess
diagnostics did not distinguish credential access from network access.

Chat collectors now honor the full bounded turn deadline and surface driver
errors. Claude response evidence requires an assistant message, rather than the
echoed user prompt. Dedicated Claude/Codex workspace scripts support focused
reruns: `test:evals:claude` and `test:evals:codex` in the eval workspace.

Envelope vector regeneration produced identical bytes and its five schema tests
passed (37 assertions). The migration was subsequently committed in `e9a11452`; this ledger does not
record a post-commit rerun of the committed/git-clean guard. These focused checks do not constitute a new full
E2E sweep.

Final verification after collector edits: `bun run --filter antgrid-evals
test:evals:codex` passed four tests/19 assertions in 27.90 seconds;
`bun run --filter antgrid-evals typecheck` exited zero, including the Claude
changes. `git diff --check` passed.

## September 15 — Aspire Android emulator smoke recovery

The local `antgrid` database was missing `20260914000000_peer_endpoints`.
Applied it with the web workspace migration script; authorization, endpoint
enrollment and peer inventory then returned HTTP 200. Restarted `app-windows`
so the host could retry its startup enrollment after the schema repair.

Fixed the app runtime's dependency on token-minter invalidation: resume and
post-sign-in token refresh no longer dispose an enrollment runtime retained by
machine connections. Initial coordinate resolution now waits for an in-flight
inventory load before comparing the machine key with a fresh authorization
snapshot. Cached keys still require authoritative confirmation. Console
diagnostics now include the failed rung and peer-selection reason.

The three focused provider/connection suites passed 17 tests, and
`flutter analyze --no-pub` reported no issues. Aspire and host logs confirmed
the emulator established an E2E session. An ADB Home/foreground cycle triggered
fresh authorization and another confirmed E2E establishment without the previous
disposed-runtime failure. This is local WebSocket smoke evidence, not native
Iroh or forced-relay qualification.

The subsequent multi-project smoke exposed a host-resume notification gap:
WebSocket E2E keys were erased while the central carrier remained connected,
leaving the phone waiting for liveness recovery. The verified fix is described below.

## Resume recovery follow-up — September 15

- Host lease invalidation now signals affected WebSocket peers through central
  disconnect/reconnect, while native-only sessions avoid central churn.
- Real host/relay/Dart resume gate passes three cycles with two project streams
  responding within 1.53 seconds (includes a deliberate 1.5-second settle wait).
- Fixed eval CLI machine-scoped presence wiring; pending actions fail and queued
  input is discarded on peer restart. Bridge focused suites, bridge/eval
  typechecks and Dart rekey/flow-control suites pass. Flutter analysis reports
  no issues after the shared-client change.
- Resume fixes were committed in `7a86e6dd`; live desktop host sleep/wake remains unqualified.

### Android resume follow-up � September 15

Removed duplicate foreground authorization invalidation and fixed admission joining a pre-resume lease request. Reproduced both lease races before the fix. Verified 15 pure-Dart tests, 19 Flutter tests, both analysis gates and three live emulator resume cycles (2.754-3.256 seconds to E2E). Android hot restart only; host terminals kept running. Evidence remains in ignored `.tmp/android-resume-validation*` artifacts. These changes are committed in `7a86e6dd`; longer sleep and native qualification remain open.

## Follow-up commit and user validation

The user reported successful validation after two minutes backgrounded on September 15. No additional timing measurements or logs were supplied for that run. This commit includes the Windows setup documentation, emulator connection and host/Android resume fixes, regression tests and investigation records. Earlier uncommitted-status notes are historical. The token HTTP deadline is addressed below; longer sleep, network-transition, physical-device and native Iroh qualification remain open. No production preference was enabled.

## Authentication timeout fixes - September 15

App token minting, inventory, sign-in/session calls and device operations now
use a 15-second HTTP deadline covering headers and body, with request abortion.
Bridge token minting has the same bound. Late timed-out responses cannot update
tokens or invoke bridge revocation callbacks. Bridge maintenance also ignores
renewal completion after stop. Both maintenance loops retry mint directly after
30 seconds on failure instead of adding another TTL-based delay.

Device mutation timeouts retain their existing error contracts and never
trigger automatic replay. A timeout does not establish whether the server
applied the mutation; reconcile account state before retrying.

Verification: 100 focused Flutter tests and 13 bridge OAuth tests passed.
Full serial Flutter analysis, bridge typecheck and `git diff --check` passed.
Coverage includes stalled headers/body, late responses, retry timing, sign-out
cleanup and device timeout/no-replay. These timeout changes have not been loaded
into the running Aspire instances.

## Remaining release blockers

WebSocket remains the default. No production preference or deployment is enabled.
The current native binding lacks verified typed close causes, precise path-byte
telemetry and explicit zeroization of upstream-owned key copies. Unknown native
failures remain terminal. Apple bundled-only native loading still needs a
supported verified path or upstream API. Endpoint history forbids seed reuse
following revocation; reseeding/re-enrollment UX needs lifecycle qualification.

Real Dart/app plus bridge QUIC/E2E over direct WAN and the self-hosted forced relay,
physical mobile and remaining desktop packages, signed artifact verification,
container deployment, resource/race workloads and performance acceptance remain
unqualified. Local TLS relay packet gates and fixture-controlled native host
smokes do not establish those results. Lifecycle telemetry still needs dedicated
central authentication/discovery, E2E, project-binding, usable-terminal, CPU,
memory and path-byte measurements. Outbox retention and billing invalidation
load also need operational qualification. See the [qualification record](iroh-qualification.md),
[relay README](../iroh-relay/README.md) and [operations guide](iroh-operations.md).

Temporary agent handoffs and dated investigation logs were consolidated into
this ledger. Historical detail remains in Git history; local capture artifacts
remain ignored rather than becoming permanent repository documentation.

## Documentation consolidation - September 15

Retained the approved plan, this task ledger, qualification record and operations
guide. Consolidated current security, packaging and relay evidence in qualification;
removed superseded reviews and the redundant relay handoff. Detailed historical
reviews remain in Git at `9ed88a01`. The service README owns relay design and commands.
This documentation cleanup does not advance any runtime or release gate.

## Aspire native smoke selection - September 15

`aspire:all` now requests test-only Iroh without payload fallback. Aspire forwards
the mode into both Flutter builds and the desktop bridge, and requires explicit
`IROH_RELAY_URLS` for web. TypeScript compilation passed. A trusted, reachable
Iroh relay is not available yet; running instances have not been restarted.
This is launcher preparation, not native connection evidence. Production and
other default launch paths remain WebSocket. See the Aspire README for setup.

## Ops deployment review - September 15

Read antgrid-ai/antgrid-ops development through the authenticated GitHub API.
The existing rollout uses one VM, Compose blue/green web+relay stacks and a
long-lived Caddy edge with automatic public TLS on 443. A single deployment
can include the Iroh service; no process merge is necessary. Required changes:
publish the Rust image from the app repo using its own Docker build context;
add it and private administration to ops Compose; extend health/rollback gates;
configure backend approved origins and revocation delivery to every live colour.
Caddy already owns host 443, so the standalone Iroh port-publishing template
cannot be used unchanged. Decide and qualify TLS upstream trust and certificate
renewal, plus Iroh routing (/relay, /ping, /generate_204). Existing relay hostname
can potentially route those paths separately from central /ws; full native
proxy interoperability remains untested. Public TLS termination alone does not
replace the current Rust TLS listener. Blue/green peers must not remain split
across independent registries; qualify deliberate reconnect/drain and rollback
without command replay. A deployed staging relay authorizes against staging,
not local Aspire enrollment, unless a separate dev backend route is configured.
No ops files, infrastructure, secrets or deployments were modified.

## Local shared relay gateway implementation - September 15

Aspire native mode now starts the locked Rust relay on loopback 443 and a
Node HTTPS gateway on 3000, with central WS on 3001 and private administration
on 9000. Both apps receive one shared HTTPS base URL; web receives that same
approved origin, admission secret and both revocation targets. Ignored runtime
configuration is generated at startup. A publicly trusted certificate and DNS
name resolving to this PC remain prerequisites: inspected pinned native source
uses embedded roots, and binding APIs do not expose custom CA configuration.
No CA bypass or binding fork was introduced. Gateway integration checks passed
HTTP routing, both upgrade paths, private-path denial and untrusted upstream
TLS rejection with a test-process-only CA. Aspire TypeScript compilation passed.
The actual Aspire native stack and Windows/emulator Iroh connection have NOT run;
no usable hostname/certificate has been supplied. No running apps were restarted.

## Cross-binding interop gate - September 15

The product ships two different Iroh implementations: the app binds `iroh_quic`
1.0.3 through FRB, the bridge binds `@number0/iroh` 1.1.0. Every automated
native gate bound `@number0/iroh` on both ends, and the Dart native smoke bound
`iroh_quic` on both ends, so no gate covered the pairing that actually ships.
The retired prototype did cross it at the same version pair, but deliberately
used adapter transports and a WebSocket shim rather than the production ones.

`qualify:iroh-interop` closes that: a real `NativeEndpointOwner`/`IrohPeerLink`
driving unchanged `MachineSession`/`AppSessionHandshaker` against a real
`IrohRelayClient` host. The host fixture is now shared by both smokes
(`bridge/scripts/iroh-smoke-fixture.ts`); `qualify:iroh-host` keeps its previous
assertions and its recorded output is unchanged.

The gate found one production-wiring defect the same-binding gates cannot see.
`IrohPeerLink` rejects an inbound record whose route `to` is not its
`localDeviceId`, and the host addresses the app by its machine-scoped relay slot
(`relaySlotId`), not the bare device id. The TS gate reads records without
checking `to`, so it never exercised that path. The app role now dials with the
slot id while the handshake keeps binding the bare id, matching `PeerRuntime`.

Executed: interop gate passed with two projects, managed-worktree Git, terminal
input and frames, central outage and remote-access-off closing the native link;
`qualify:iroh-host` re-passed with identical output; bridge typecheck, package
`dart analyze`, 17 package tests and the Dart-to-Dart native smoke passed.
Loopback with relays disabled, fixture authorization, and the prebuilt CLI
library rather than the Flutter source build. WAN, forced relay, Flutter-built
libraries and performance acceptance remain unqualified.
