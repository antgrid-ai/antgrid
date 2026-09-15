# Resume / multi-project smoke investigation — September 15, 2026

## Active objective

User asked to investigate issues after opening several projects in the Android
emulator under `bun run aspire:all`, verify Netwatch, then dig deeper into the
E2E recovery delay. After persisting the initial findings, the user said proceed.
Continue implementation and verification; no commit or deployment requested for
these follow-up fixes. Branch is `antgrid/iroh-migration`, migration commit
`e9a11452`; follow-up changes are uncommitted in this shared checkout.

Workspace: `C:/Users/Admin/.antgrid/wt/antgrid-public-ceb1/mellow-jetty-a5e7`.
Windows PowerShell; do not create another worktree. No subagents used for this
investigation. Preserve all existing uncommitted follow-up changes.

## Confirmed findings

1. Local PostgreSQL `localhost:5432/antgrid` lacked migration
   `20260914000000_peer_endpoints`. Relay authentication succeeded, but backend
   authorization and peers returned HTTP 500 / Prisma P2021 (missing
   `peer_authorization_policies`). Applied the additive migration through
   `bun run --filter antgrid-web migrate`. No reset or deletion. Database also
   has migrations from other branches; they were left untouched. Authorization,
   enrollment and peers subsequently return 200.
2. `peerRuntimeProvider` watched `connectionTokenMinterProvider.future`.
   Post-sign-in and resume invalidate the minter; this disposed the runtime
   retained by existing machine connections. Changed the minter dependency to
   `ref.read`, retaining `ref.watch` for the enrollment record. Regression tests
   verify minter invalidation preserves runtime identity and enrollment
   invalidation still replaces it.
3. Initial coordinate resolution used the cached machine key while fresh
   inventory was loading. Fresh authorization rejected the stale key. Changed
   `ConnectionCoordsResolver.resolve` to await the current inventory future
   (existing bounded timeout) if loading/missing, retaining cached fallback only
   when inventory fails. Authoritative lease must still confirm that key.
   Added a delayed-inventory regression test.
4. Improved diagnostics: supervisor console messages include rung/error and
   block reason; `PeerSelectionFailure.toString()` includes code/terminal flag;
   selection distinguishes missing peer, key mismatch, disposal after selection,
   and authorization change during selection.
5. Restarted Aspire `app-windows` once after migration so the host retried its
   failed startup enrollment. Emulator E2E established. ADB Home/foreground
   subsequently re-established fresh E2E successfully after the runtime fix.

## Current deeper issue and patch

User then opened three remote projects and several agent terminals. Live host
logs showed repeated `Failed to open sealed frame` and Netwatch recorded
`decrypt-failed` with `sessions: 0, pending: 0` — these are missing receive
contexts, not evidence of malformed ciphertext or a wrong cipher key.

Desktop AppShell resume calls local host `POST /peer-resume`. In
`bridge/src/peer/iroh-relay-client.ts`, `noteResume()` calls `lease.resume()`.
Lease invalidation synchronously erases E2E sessions/queues. Native peer
connections close, but WebSocket peers previously kept a live central socket
with no immediate loss signal. Phone kept sending until E2E liveness expired
and it re-handshook. One observed burst followed desktop resume at
04:35:24/28 UTC, rejected frames at 04:35:33–04:36:13, recovery at 04:36:34.
Earlier similar recovery at 04:33:32. Backend authorization stayed HTTP 200.

Current uncommitted patch:

- `bridge/src/peer/iroh-relay-client.ts`: lease invalidation delegates to new
  `invalidatePeerConnections(reason)`. Capture whether established/pending/
  authorized hello peers used WebSocket, synchronously drop all peer state,
  close central WS with code 1012 when a WS peer was affected (except final
  close), record `peer:authorization-invalidated` lifecycle diagnostic. Existing
  central offline/online transitions should promptly trigger app fresh E2E.
  Native-only invalidation does not churn central. Resume native close reason
  is connection-lost rather than unauthorized; other invalidations remain
  unauthorized. Fresh admission still requires authoritative lease.
- `bridge/tests/iroh-relay-client.test.ts`: verifies WS close is immediate while
  fresh authorization is unresolved, admission map and lease are cleared, and
  native-only resume closes peer without central churn.

This patch has NOT been loaded into the live host. It now passes an isolated
real-host, real-relay, real-Dart-client WebSocket evaluation (authorization is a
fixture). Three consecutive resumes recovered file traffic on both existing
project streams in 1.53 seconds or less, including a deliberate 1.5-second wait
for central reconnect jitter. This is an upper bound, not measured handshake
latency. The same app socket survived and total relay connections returned to two.

The evaluation initially failed because the Dart eval CLI omitted the machine
ID when connecting. `RelayService` correctly ignores presence for an unspecified
machine. Threaded that ID through `DartAppClient.connect`, `setupDartTestEnv` and
the Dart CLI connect command, matching production's existing setup. The real
test is `evals/tests/gate-peer-resume.test.ts`, invoked with
`bun run --filter antgrid-evals test:evals:peer-resume`.

Also fixed `MachineSession._onPeerRestart`: cancel pending RPCs with
`E_SESSION_DOWN` and discard queued input before recovery. A lost reply has an
unknown outcome and queued actions must not carry into the replacement session.
Ordinary live rekeys still retain their queues and make-before-break keys.
The new Dart regression covers pending action failure and queued input disposal.
The user has active projects/terminals; avoid casually restarting their host.
Prefer an isolated real-host/relay evaluation first, using existing eval
fixtures (same checkout, no extra worktree). If live restart is needed, explain
its effect on terminals before doing it. Do not claim the recovery fix complete
until real WS peer offline/online drives prompt fresh E2E and hydration.

## Verification status

Earlier app fixes:

- `flutter test -j 2 test/providers/peer_runtime_provider_test.dart
  test/providers/agent_transport_coords_retry_test.dart
  test/providers/relay_connection_supervisor_test.dart`: 17 passed.
- `flutter analyze --no-pub`: no issues, 93.4 seconds.
- Logs: `.tmp/iroh-emulator-fix-tests.log`,
  `.tmp/iroh-emulator-fix-analysis.log`.

Current bridge patch:

- `bun run --filter antgrid-bridge test tests/iroh-relay-client.test.ts
  tests/peer-authorization-lease.test.ts`: 16 passed, 59 assertions.
- `git diff --check`: passed.
- Bridge typecheck passed after correcting a test-double cast; eval typecheck
  passed as well.
- Real WebSocket resume gate: passed, three cycles / two project streams.
- Dart rekey and flow-control suites: 22 passed. Standard `dart test` attempted
  pub.dev access and failed in the sandbox; used the already-resolved package
  config and cached test runner directly, without dependency changes:
  `dart --packages=.dart_tool/package_config.json
  C:/Users/Admin/AppData/Local/Pub/Cache/hosted/pub.dev/test-1.31.1/bin/test.dart
  -j 2 test/machine_session_rekey_test.dart test/machine_session_flow_control_test.dart`
  from `packages/antgrid_relay_client`.
- Flutter analysis after the shared-client change passed with no issues (23.7s).
  The Windows batch startup wrapper was stuck on its startup lock; stopped only
  that invocation and ran the cached `flutter_tools.snapshot analyze --no-pub`
  using the SDK's Dart executable. SDK cache access required escalation.
- Direct Dart analysis of `packages/antgrid_relay_client` and
  `packages/antgrid_eval_client` passed with no issues. No checks remain running.
- Live host/emulator qualification still requires loading the changes; do not
  restart the user's active host casually. Physical/native-path qualification
  remains separate. Root lockfiles untouched.

## Netwatch verification

`C:/Users/Admin/.antgrid-dev/netwatch.log` last changed September 12. It is
optional desktop file capture controlled by `ANTGRID_NETWATCH`, not the bridge
ring and not a phone log. Phone logs cannot use hostDir's filesystem path.

Bridge live ring and mobile capture work:

```
bun bridge/src/index.ts watch --dir C:/Users/Admin/.antgrid-dev --no-follow --json --limit 1000
bun bridge/src/index.ts watch --dir C:/Users/Admin/.antgrid-dev --remote --json --limit 0 --export .tmp/netwatch-project-live.jsonl
```

Saved snapshot `.tmp/netwatch-project-snapshot.jsonl`: 845 sealed, 51 control,
18 decrypt-failed drops, 10 handshake records. Live sample received app-origin
events, paired at least 12 encrypted frame IDs across endpoints, zero drops at
the checked point. Capture is metadata-only; bodies were never enabled.
Temporary capture PID 14396 was stopped using scoped taskkill after Ctrl-C and
PowerShell Stop-Process did not stop it. Explicit `netwatch:remote enabled:false`
returned success afterward. Capture is OFF; no watcher remains intentionally.
Helper `.tmp/disarm-smoke-netwatch.ts` posts via existing `postControl` without
printing host token. Do not print host.json or credentials.

## Other observed issues (not yet investigated/fixed)

- Claude terminal `f8fc8613-390a-4056-8423-a56eaf3acdd5` resumed and exited code 1.
- Antigravity cert-cache priming PowerShell timed out; spawn continued.
- Emulator push initialization / Play Store update-service failures and glyph
  fallbacks appeared. Do not conflate these with relay authorization.
- Host endpoint startup failure currently needs a later explicit retry/restart;
  `noteResume()` refreshes lease but does not rerun initial enrollment.

## Live environment / useful commands

Aspire directory: `aspire/`, resources `web`, `relay`, `app-windows`, `app-android`.
`aspire logs <resource> --tail 30 --timestamps --non-interactive --nologo` works;
CLI needs sandbox escalation because it writes `~/.aspire/logs`.
`aspire resource app-windows restart --non-interactive --nologo` restarts desktop
app AND its host/terminals; do not use as a harmless log probe.

Host latest PID observed 19088, control port 59766; read current host.json in code
instead of assuming these remain current. Logs at
`C:/Users/Admin/.antgrid-dev/{host.log,app.log}`. Web 8787, relay 3000,
LAN 192.168.31.45. Mode is default WebSocket, not Iroh qualification.

Android emulator `emulator-5554`, package `ai.radhaai.antgrid`, activity
`.MainActivity`, app PID observed 3658. User explicitly authorized ADB control.
ADB: `C:/Users/Admin/AppData/Local/Android/sdk/platform-tools/adb.exe`.
UI XML snapshot `.tmp/antgrid-smoke-ui.xml` (stale after more project activity).
Use XML parsing to select useful content-desc fields rather than outputting
the whole one-line XML. ADB private logs contain no app.log because mobile
hostDir does not point into its writable app directory.

Flutter launcher local control port stored at `aspire/.flutter-control-android`;
POST `/restart` performs Dart hot restart, `/reload` hot reload. These don't
rebuild native plugin binaries. A Windows hot restart does not replace host.

Flutter SDK: `C:/Users/Admin/Downloads/flutter`; direct Dart SDK exe avoids
startup script for formatting. Set PUB_CACHE to workspace
`.tmp/iroh-qualification/pub-cache` for CLI gates. Run Dart/Flutter analysis
serially. Running app processes exist; do not kill unrelated MCP Dart servers.

Earlier Windows build repair installed normal user rustup/stable and VS 18 ATL.
Full debug build passed with bundled Iroh DLL. Documentation changes from that
repair are still uncommitted in DEVELOPMENT.md and
`docs/iroh-packaging-review.md`. No generated binaries staged.

## Latest Android follow-up

See docs/iroh-smoke-2026-09-15.md for the completed Android investigation, lease/lifecycle fixes, tests and three live emulator cycles. Android now has the latest code loaded by hot restart; Windows host was not restarted. No validation commands or capture monitors remain intentionally running. New edits: AppShell lifecycle callback, its widget regression, shared transport authorization lease and its tests. All remain uncommitted.

## Follow-up commit and user validation

The user reported successful validation after two minutes backgrounded on September 15. No additional timing measurements or logs were supplied for that run. This commit includes the Windows setup documentation, emulator connection and host/Android resume fixes, regression tests and investigation records. Earlier uncommitted-status notes are historical. Token minting still has no explicit HTTP request timeout; longer sleep, network-transition, physical-device and native Iroh qualification remain open. No production preference was enabled.
