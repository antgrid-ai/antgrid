# Stage A, wave A8: QUIC liveness, one app ping, per-stream RPC timeout recovery

This is the frozen contract for four parallel implementers: **bridge-src**, **bridge-tests**, **dart+app**
and **evals**. Each part builds against the names and shapes below. Nobody may rename or reshape anything
pinned here without the controller's say. If your part needs something this file does not provide, report it
as `outOfScopeNeeds`. Do not invent it.

A8 stops duplicating at the application layer the liveness QUIC already provides, and keeps the one check
QUIC cannot make:
- the bridge's ping loop goes. It answers `ping` with `pong` as before, and QUIC idle is what tells it a
  peer is dead;
- the app's ping stays. Its one job is to detect a bridge whose event loop is wedged while its QUIC stack
  still acks;
- an RPC timeout no longer closes the whole link. Three consecutive timeouts on one project stream reset and
  reopen **that stream only**;
- the snapshot pull becomes one request with one generous deadline, where it used to be three attempts with
  doubling timeouts;
- `countsTowardHealth`, the drop reason `no-e2e-session` and the word "rekey" (where it means
  re-establishment) are removed.

Sources:
- `stage-A-waves.md` §1.1 ("Binding constraints");
- the owner decisions in `ledger.md`;
- the A4/A5 contracts (project streams, reconnect resync, the seams pattern);
- the A7 contract (format and ownership pattern);
- the iroh/noq sources vendored in the local cargo registry and the two published bindings (below).

HEAD at authoring time is `63b1dca3`. ALPN stays `antgrid/peer/2` and `FRAME_VERSION` stays `0x04`: no
wire record changes shape, and Stages B and A ship as one release that was never published.

Evidence labels: **EXECUTED** means I ran it in this session. **READ** means I read the source and did not
run it.

## 0. Rules for every part

- Edit only the files your part owns (§12). Report anything else in `outOfScopeNeeds`.
- Never `git stash`, `checkout`, `reset` or `restore`.
- Bun tests per workspace only (`bun run --filter <name> test`), never bare `bun test` at the root. Send
  full-suite runs to a file and grep it for `(fail)`.
- CLAUDE.md applies:
  - comments say WHY and carry no change narration;
  - no comment may mention "A8", "was", "no longer", "used to", "rekey", the deleted bridge ping loop or the
    deleted retry chain;
  - the "Adding a message type" checklist runs in reverse for anything removed. A8 removes **no
    `AbMessage` type**: `ping` and `pong` stay in `AbMessageSchema`, `KNOWN_TYPES` and the Dart session-frame
    set, and they stay session-stream frames.
- Binding constraints (spec §1.1), unchanged:
  - every write is at most 256 KiB (`STREAM_RECORD_SLICE_BYTES` / `kPeerStreamSliceBytes`);
  - the bridge calls `setPriority` once, before the first write;
  - never await `stopped()` or `receivedReset()`;
  - `authorized()` is checked per record;
  - a Dart stream is invisible until its first write;
  - a dropped noq `SendStream` FINs, so **every Dart error path calls `reset()` explicitly**. A8 adds one new
    Dart error path, the project-stream health reset (§6.3), and it calls `reset()`.
- Security invariants, none weakened. A8 touches none of them, and nothing in A8 may move them:
  - `remoteFrameAllowed` inbound;
  - `mayDeliver` outbound and `mayDeliverTo` on every send;
  - `seenProjects` (`projectCataloged`) + `isSafeProjectId`;
  - `mayAcceptFrom` at open (`checkoutRouting`);
  - **a stream open never opens or promotes a core.** A health-reset reopen is an ordinary project-stream
    open, admitted exactly like any other (A4 admission order, unchanged).
- Loopback liveness is unchanged: `bridge/src/local-listener.ts` and `local_transport.dart` have no ping and
  no timeout-close code today (READ), and A8 adds none.
- Known red that is not yours:
  - the bridge suite's six stale-runId fixtures: `index-hook-subcommand` ×1, `plugin/antigravity-post-title`
    ×3 and `plugin/opencode-notify` ×2;
  - under load, the git-branches "stash pop" test and the git-sync "already up to date" test can time out.
  - Anything else red is real.
- **Proving a test.** Every new or rewritten test is proven by breaking the mechanism it guards and then
  restoring it. Each implementer lists the break used, per test, in their report.
  - Where A8 changes behaviour, the test must **also** fail against the pre-A8 code. §9 marks these
    **[fails-on-old]**.
  - Some tests pin behaviour A8 keeps: the pong answer, `closed()` retiring a peer, the app ping. These
    cannot fail on the old code by construction, so the break is the whole proof. §9 marks these
    **[break-only]** and names the break.

## 1. Decisions A8 makes

- **D-A8-1. The QUIC timing is recorded as named constants, not set.** Neither binding can set it.
  - Findings:
    - **READ.** The bridge binding is `@number0/iroh` 1.1.0 (napi), whose `Cargo.toml` depends on `iroh = "1.0.0"`.
      - `EndpointOptions` has only `bindAddr`, `secretKey` and `alpns`.
      - `EndpointBuilder` has no transport-config setter, and neither does `Connection`.
      - The bridge builds with `Endpoint.builder().applyMinimal().secretKey().alpns([PEER_ALPN]).relayMode(...).bind()`.
    - **READ.** The app binding is `iroh_quic` 1.0.3, whose `Cargo.lock` pins iroh 1.0.0 and noq 1.0.0.
      - `Endpoint.bind`/`bindWithAddressLookup` take only `secretKey`, `alpns` and `relayMode`.
      - The Rust side calls `IrohEndpoint::builder(presets::N0)` with no transport config.
      - `Connection` has no setter.
      - The app binds in `packages/antgrid_peer_transport/lib/src/iroh_peer_link.dart`.
    - **READ.** The iroh 1.0.0 `QuicTransportConfig` defaults (`src/endpoint/quic.rs`, `src/socket.rs`):
      - `keep_alive_interval = HEARTBEAT_INTERVAL` = 5 s;
      - path keep-alive 5 s;
      - path idle 15 s (30 s on a relay path);
      - the connection `max_idle_timeout` is noq's default, `VarInt(30_000)` = 30 s
        (`noq-proto-1.0.0/src/config/transport.rs`);
      - the negotiated idle timeout is the minimum of both sides' values.

      Both sides therefore run keep-alive 5 s and idle 30 s.
    - **EXECUTED** (scratchpad `idle-parent.ts`/`idle-child.ts`, two napi endpoints, `applyMinimal`,
      `RelayMode.disabled()`, loopback):
      - a SIGKILLed peer: the survivor's `conn.closed()` resolved after 29,127 ms with reason "timed out";
      - an idle but live peer: stayed open for 65,008 ms, so keep-alive holds an idle connection;
      - **trap:** a napi `Endpoint`/`Connection` that the JS side no longer references is collected by GC
        and stops sending without a CONNECTION_CLOSE. The survivor saw "timed out" after 29,103 ms. Any
        eval process that must stay alive has to retain its endpoint and connection references.
  - The owner ruled out forks. The task asks for values "set explicitly", but they cannot be set, so the
    constants record the defaults both bindings apply, one place per side, mirrored by hand and pinned by
    the transport vectors (§5). **Flagged to the owner in the ledger row:** if either binding later exposes
    a transport config, set these values there and delete the "recorded, not set" wording.
  - Detection is no later than today's path.
    - **Bridge side.** The old ping (20 s silence, 2 missed pongs: 40–60 s) could never beat the 30 s QUIC
      idle close for a dead peer. QUIC idle was already the mechanism that fired. The bridge ping only ever
      fired for an app that was wedged but still acking.
    - **App side.** The ping is unchanged (D-A8-3).
    - **A briefly backgrounded phone.** It meets exactly the QUIC idle it met before, so removing the bridge
      ping adds no flap. On resume, the app's own ping check sees silence with `_missedPongs == 0`, so it
      sends a ping rather than closing.
- **D-A8-2. The bridge learns that an app is dead only through `connection.closed()`.** That handler already
  exists (`native-host-connection.ts`, `acceptPeer`):
  `void connection.closed().then(() => { if (this.nativePeers.get(peerId) === peer) this.retirePeer(peerId, "connection-lost"); })`.
  It stays exactly as it is. `retirePeer` drops the terminal, tunnel, upload and project registries, closes
  the connection, aborts the session writer, calls `super.dropSession`, and records `peer:native-retired`
  with `detail.reason = "connection-lost"`. A wedged-but-acking app is not the bridge's problem: the app
  holds no state the bridge needs, and its own supervisor restarts it.
- **D-A8-3. The app ping is unchanged in behaviour.**
  - `kPingSilenceSeconds = 20` and `kMaxMissedPongs = 2` stay (about 60–80 s to close).
  - `_lastRecv` stays fed by **session-stream frames only**. Project, terminal, tunnel and upload records
    must never refresh it, because a bridge wedged in its session handling can still be pushing from other
    loops.
  - The app still answers an inbound `ping` with `pong`.
  - The doc on the constants and on `_checkLiveness` says the ping's only job: detecting a bridge whose event
    loop is wedged while its QUIC stack still acks. QUIC idle covers a dead one.
- **D-A8-4. RPC timeouts are counted per project stream, and recovery resets only that stream (§6.3).**
  - Only a `StreamTransport` with a `projectId` counts.
  - The control transport (session stream) counts nothing: its only connection-level escape is the ping.
  - `MachineSession.notifyRpcResult`, `_consecutiveTimeouts` and `_kConsecutiveTimeoutsToClose` are deleted.
- **D-A8-5. One snapshot pull (§6.4).**
  - One `state.snapshot` request goes out per (re)establishment, bind or `refreshDurableState` call.
  - It has one deadline, `MachineSession.snapshotDeadline`, defaulting to `kSnapshotPullDeadline` = 70 s.
    That is at least the old worst cumulative wait: connect was 10+20+40 = 70 s and refresh 5+10+20 = 35 s.
  - A newer pull supersedes an older one, and the superseded reply is discarded.
  - `countsTowardHealth` is deleted from the `AgentTransport` interface and every implementation, because
    nothing needs to opt out any more. A pull contributes at most one timeout per binding, so it cannot on
    its own reach the reset threshold of 3.
- **D-A8-6.** The netwatch drop reason `no-e2e-session` becomes **`no-established-session`**, on both sides.
  No netwatch joiner (`bridge/src/cli/netwatch.ts`) matches the string (READ, grep).
- **D-A8-7.** "Rekey" is removed wherever it means re-establishment, in `packages/antgrid_relay_client/**`
  and `app/lib/providers/**` and their tests. Leave project-row re-keying alone: `app/lib/providers/projects.dart`,
  `projects_reconcile_test.dart`, `open_folder_button.dart` and keyboard code use "key" in an unrelated
  sense. The stale mirror pointers at the deleted `bridge/src/relay-client.ts` in `machine_session.dart` and
  `relay_slot.dart` are fixed (§6.5).

## 2. Wire

No wire record is added, removed or reshaped.

| Record | After A8 |
|---|---|
| `{type:"ping"}` session frame (header `type` = `session`) | Sent by the **app only**. The bridge answers it with `pong` iff `sessions.has(peerId)`, unchanged. |
| `{type:"pong"}` session frame | Sent by the bridge in answer to a ping. The app zeroes `_missedPongs` on it. A pong reaching the bridge is ignored (no state, no reply). |
| Project stream | Unchanged framing. New app behaviour: a health reset (§6.3) is a Dart `reset()` of the send half, and the bridge sees it as a read rejection. The bridge already unbinds on that and FINs its own half (`project-streams.ts`). |

Stream kinds, admission order, caps and refusal codes are all unchanged. An expected race after a health
reset: the reopen can reach the bridge before the bridge has processed the reset. The bridge then refuses it
`INVALID` "project stream already open". That is an ordinary bind failure, which the app retries with
backoff (§6.3), and it needs no new code.

## 3. Bridge APIs (bridge-src implements; bridge-tests builds against these)

### 3.1 `bridge/src/peer-session-owner.ts`

Delete:
- the constants `PING_SILENCE_MS` and `MAX_MISSED_PONGS`;
- the `PeerSession` fields `lastRecvAt` and `missedPongs`, and their initialisers in `handleHello`;
- the two assignments in `receivePeerFrame` (`session.lastRecvAt = …`, `session.missedPongs = 0`);
- `protected livenessTimer`, `startLiveness()`, `stopLiveness()` and `checkLiveness()`;
- the `this.startLiveness()` call in `handleHello`, the `stopLiveness` calls in `dropSession` and
  `resetSessions`, and the comment above `this.sessions.set` in `handleHello` only if it names liveness.
  Keep the hello-timer race reasoning.

Keep and pin:
- `case "ping": if (this.sessions.has(peerId)) this.sendSessionFrame({ type: "pong" }, peerId);`, verbatim in
  behaviour;
- `case "pong":` returns with no effect, under a WHY comment: the bridge never pings, because QUIC keep-alive
  and idle timeout (`PEER_QUIC_MAX_IDLE_TIMEOUT_MS`) detect a dead app, so a pong carries nothing it needs;
- `resetSessions()` still drops every session;
- `dropSession(peerId)` keeps its peer-offline/`notifyPeerSessionOffline` semantics;
- the outbound no-recipient drop: `reason: "no-established-session"` (D-A8-6).

The class doc and `onSessionFrame`'s doc drop "liveness" as a bridge-owned concern. The session stream
carries the hello, `established`, and the app's ping and the bridge's pong.

### 3.2 `bridge/src/peer/native-host-connection.ts`

Comment-only change. `STREAM_PRIORITY_SESSION`'s comment becomes: above terminal (1), project (0) and tunnel
(-1), so the hello, `established` and the pong that answers the app's wedge probe never wait behind bulk. No
logic changes. The `closed()` handler and `retirePeer` stay as they are (D-A8-2).

### 3.3 Test seams on the bridge

| Seam | After A8 |
|---|---|
| `TestPeerSessionOwner` (`bridge/tests/test-peer-session-owner.ts`) | No liveness hooks to expose. Anything that reached `checkLiveness`/`startLiveness` goes. `dropSession(peerId)` is the way to simulate a session ending. |
| `bridge/tests/fake-session.ts` | Builds `PeerSession` without `lastRecvAt`/`missedPongs` (the type no longer has them). |
| Fake `connection()` in `native-host-connection.test.ts` | Gains a controllable `closed()`: a promise the test resolves with `{ reason: "timed out" }` to stand in for a QUIC idle close. The default stays a never-settling promise. |

## 4. Constants and where they live

| Constant | Value | TS home | Dart mirror |
|---|---|---|---|
| QUIC keep-alive (recorded, not set) | 5 000 ms | `PEER_QUIC_KEEP_ALIVE_INTERVAL_MS` in `packages/antgrid-wire/src/stream-open.ts`, exported from `index.ts` | `kPeerQuicKeepAliveInterval = Duration(seconds: 5)` in `packages/antgrid_relay_client/lib/src/models/stream_open.dart` |
| QUIC connection idle timeout (recorded, not set) | 30 000 ms | `PEER_QUIC_MAX_IDLE_TIMEOUT_MS`, same file | `kPeerQuicMaxIdleTimeout = Duration(seconds: 30)`, same file |
| App ping silence | 20 s | none (the bridge does not ping) | `kPingSilenceSeconds` (unchanged), `machine_session.dart` |
| App missed pongs before close | 2 | none | `kMaxMissedPongs` (unchanged), `machine_session.dart` |
| Consecutive timeouts before a project-stream reset | 3 | none | `kProjectStreamTimeoutsToReset = 3` (new, public), `machine_session.dart` |
| Snapshot pull deadline | 70 s | none | `kSnapshotPullDeadline = Duration(seconds: 70)` (new, public), `machine_session.dart` |

Both QUIC constants carry the same WHY comment on each side:
- they are iroh 1.0's defaults, which both bindings apply because neither exposes a transport config;
- the negotiated idle timeout is the minimum of both sides' values;
- mirror by hand, pinned by `peer-transport-vectors.json`.

Deleted: `PING_SILENCE_MS`, `MAX_MISSED_PONGS` (TS) and `_kConsecutiveTimeoutsToClose`, `_kSnapshotAttempts`
(Dart).

## 5. Wire package and vectors (bridge-src)

- `stream-open.ts` adds the two `PEER_QUIC_*` constants of §4, and `index.ts` exports them in its named
  `./stream-open` export list.
- `scripts/gen-peer-transport-vectors.ts` adds a **root-level** block to the fixture, emitted after
  `streamOpen`:
  ```json
  "quic": { "keepAliveIntervalMs": 5000, "maxIdleTimeoutMs": 30000 }
  ```
  Both values come from the constants, not literals.
- Regenerate `evals/fixtures/peer-transport-vectors.json` with `bun run --filter antgrid-wire gen:peer-vectors`.
  Nothing else in the fixture may change. Diff it and confirm the only change is the added block.
- bridge-tests asserts `fixture.quic` equals the two TS constants (`peer-transport-vectors.test.ts`).
  dart+app asserts `kPeerQuicKeepAliveInterval.inMilliseconds == quic['keepAliveIntervalMs']` and
  `kPeerQuicMaxIdleTimeout.inMilliseconds == quic['maxIdleTimeoutMs']`
  (`packages/antgrid_peer_transport/test/peer_transport_vectors_test.dart`).

## 6. Dart APIs (dart+app implements)

### 6.1 `AgentTransport` (`packages/antgrid_relay_client/lib/src/agent_transport.dart`)

```dart
Future<Map<String, dynamic>> request(
  String method, {
  Map<String, dynamic>? params,
  Duration timeout = const Duration(seconds: 10),
});

Future<RemoteRequestResult<Map<String, dynamic>>> requestWithOutcome(
  String method, {
  Map<String, dynamic>? params,
  Duration timeout = const Duration(seconds: 10),
});
```

- `countsTowardHealth` is gone from both, and its doc paragraph goes with it.
- The `request` doc says what a timeout means now: on a remote project transport it counts toward that
  stream's reset (§6.3). On the control transport and on loopback it is only a failed call.
- Every implementer drops the parameter:
  - `BufferedAgentTransport` (`buffered_agent_transport.dart`);
  - `StreamTransport` (`machine_session.dart`);
  - `FakeAgentTransport` (`app/lib/test_helpers/fake_agent_transport.dart`: `request`, `requestWithOutcome`
    and the recorded-call shape if it stores the flag).
- `LocalTransport`, `DemoTransport`, `_TestTransport` (`hydrate_action_contract_test.dart`) and
  `_OutcomeTransport` (`remote_request_outcome_test.dart`) inherit from `BufferedAgentTransport` and do not
  name the flag (READ, grep). They need no change beyond compiling.

### 6.2 `MachineSession` (`machine_session.dart`)

- **Constructor.** Adds `Duration snapshotDeadline = kSnapshotPullDeadline`, exposed as the field
  `final Duration snapshotDeadline`.
  - `snapshotTimeout` (default 5 s) stays, with a new meaning: how long a caller of `refreshSnapshot` or
    `refreshDurableState` waits before going on. `connect()` waits `snapshotTimeout * 2`.
  - The pull itself runs until `snapshotDeadline`.
  - `pingSilence` is unchanged.
- **Deleted:** `notifyRpcResult`, `_consecutiveTimeouts` and its reset in `_handshakeAttempt`, and
  `_kConsecutiveTimeoutsToClose`. Also delete the sentence in `_teardownSession`'s comment that names the
  RPC-timeout close trigger.
- **Liveness.** `_startLiveness`/`_stopLiveness`/`_checkLiveness`, `_missedPongs`, `_lastRecv` and
  `_livenessTimer` are unchanged in behaviour, and their doc follows D-A8-3. Line 16's
  "`/// Liveness constants; mirror \`bridge/src/relay-client.ts\`.`" is replaced. The new doc says these
  constants are the app's own wedge probe, that nothing on the bridge mirrors them, and that
  `kPeerQuicMaxIdleTimeout` covers a dead bridge.
- **Drop reason.** Every `'no-e2e-session'` becomes `'no-established-session'`: `sendOnSession`,
  `_doSendOnSession` and `_sendSessionFrame`.
- **Out of scope.** The unreachable `'session-takeover'` arm in `_handleSessionFrame` stays; nothing sends
  one (peer-session.md §3). Report it in `outOfScopeNeeds` if you want it gone.

### 6.3 Per-project-stream timeout accounting (`StreamTransport`)

New private state, meaningful only when `projectId != null`:
- `int _bindEpoch`: incremented in `_onOpen()` (every fresh bind);
- `int _timeoutStreak`: set to 0 in `_onOpen()`;
- `int _healthResets`: consecutive health resets with no answered RPC in between.

`request` becomes:

```dart
@override
Future<Map<String, dynamic>> request(String method,
    {Map<String, dynamic>? params, Duration timeout = const Duration(seconds: 10)}) async {
  final epoch = (projectId != null && _bound) ? _bindEpoch : null;
  try {
    final r = await super.request(method, params: params, timeout: timeout);
    _noteAnswered(epoch);
    return r;
  } on RpcException catch (e) {
    if (e.code == 'E_TIMEOUT') {
      _noteTimeout(epoch);
    } else if (!_kLocalRpcFailureCodes.contains(e.code)) {
      _noteAnswered(epoch);
    }
    rethrow;
  }
}
```

- `_kLocalRpcFailureCodes = {'E_TIMEOUT', 'E_SEND_FAILED', 'E_SESSION_DOWN', 'E_STREAM_RESET', 'E_DISPOSED'}`.
  Any other code is the bridge's own application error, which proves the stream carried a reply.
- `_noteAnswered(epoch)`: no-op if `epoch == null || epoch != _bindEpoch`; otherwise `_timeoutStreak = 0`
  and `_healthResets = 0`.
- `_noteTimeout(epoch)`:
  - no-op if `epoch == null || epoch != _bindEpoch || !_bound`, so an outcome from an earlier binding never
    counts against the current one;
  - otherwise `_timeoutStreak++`, and at `kProjectStreamTimeoutsToReset` it calls `_resetForHealth()`.
- A late reply is proof too. `StreamTransport.noteOrphanResponse` (the existing 'late-response' tap) also
  sets `_timeoutStreak = 0` when `projectId != null && _bound`. A project transport only dispatches records
  from its current `_peerStream` while bound (READ, the read loop's `!_bound || !identical(_peerStream, stream)`
  guard), so the orphan did cross this binding's stream. It does not zero `_healthResets`.
- `requestWithOutcome` keeps calling `_requestRaw` directly and stays uncounted, as it is today.
- The control transport (`projectId == null`) never counts. No path anywhere in the package calls
  `relay.close()` because of an RPC timeout.

`_resetForHealth()`, which runs synchronously and in this order:
1. `final stream = _peerStream;` then log `warn` `'project stream reset after consecutive RPC timeouts'`,
   fields `{streamId, projectId, timeouts: _timeoutStreak, healthResets: _healthResets + 1}`;
2. `_timeoutStreak = 0; _healthResets++;`
3. `if (stream != null) _quietly(stream.reset());` (the explicit Dart reset, §0);
4. `failAllPending(code: 'E_STREAM_RESET', message: 'project stream reset after repeated timeouts');`
5. the same unbind `_onStreamEnded` does for the current stream: `_bound = false; _peerStream = null;
   _emitClosed(); session._markNotReady(projectId!);`. The old stream's later end is then stale and ignored,
   and its buffered records are dropped by the existing identity guard;
6. `if (session.isEstablished && _bindInFlight == null) _scheduleReopen();`

Pinned consequences:
- The reopen binds through the ordinary path, and `_onOpen()` runs `refreshSnapshot()`: this is the A4/A5
  resync.
- Terminal attachments, tunnel exchanges, uploads and other projects' transports are untouched: they are
  other streams with their own lifetimes.
- `projectStreamEvents` emits `(projectId, open:false)` and then `(projectId, open:true)` on rebind.
- **Backoff across repeated resets.** `_onOpen()` sets `_reopenAttempt = 0` **only if** `_healthResets == 0`.
  A stream that keeps timing out therefore reopens at 1 s, 2 s, 4 s … up to `kProjectStreamReopenMaxBackoff`
  (30 s), instead of hammering at 1 s. The first answered RPC (`_noteAnswered`) clears `_healthResets`.
  `_reopenAtEstablish` still zeroes `_reopenAttempt` (a fresh session starts clean).
- `dispose()` is unchanged apart from what §6.4 says.

### 6.4 Snapshot pull (`StreamTransport`)

Deleted: `_retrySnapshot`, `_kSnapshotAttempts`, the `attempt` parameter, and the `super.request` bypass
in `_pullSnapshot`.

```dart
Future<void> refreshSnapshot() async {
  await _fetchSnapshot(wait: session.snapshotTimeout);
  redriveHydrators();
}
Future<void> refreshDurableState() => _fetchSnapshot(wait: session.snapshotTimeout);
// connect(): await _fetchSnapshot(wait: session.snapshotTimeout * 2);

Future<void> _fetchSnapshot({required Duration wait}) {
  final gen = ++_snapshotGen;
  final pull = _pullSnapshot(gen);   // one request, timeout: session.snapshotDeadline
  // Completes when `pull` settles or `wait` elapses, whichever is first. The
  // timer is cancelled when `pull` settles, so no timer outlives the call.
  return _firstOf(pull, wait);
}
```

`_pullSnapshot(int gen)`:
- sends exactly one `request('state.snapshot', params: {'types': ['*'], 'exclude': _kHeavyReplayTypes},
  timeout: session.snapshotDeadline)`. It goes through the counted `request`, so a project stream's pull
  counts once per binding like any RPC;
- on a reply: **if `gen != _snapshotGen` (superseded) or the transport is disposed, discard it.** Leave
  `snapshotCache`, `outbound` and `_snoopControl` untouched. Otherwise apply it exactly as today, including
  `_snoopControl` on the control transport;
- on `E_TIMEOUT`: log `info` `'state.snapshot timed out'` with `{streamId, deadlineMs}`, leave the cache as it
  is, and send nothing more. The next establishment, bind or `refreshDurableState` is the next pull;
- on any other error: leave the cache as it is and send nothing more;
- never throws out of `_fetchSnapshot`.

A reply that lands after `wait` has elapsed but before `snapshotDeadline` is **applied**, because its request
is still pending. That is the point of the long deadline. `dispose()` keeps `_snapshotGen++` and
`failAllPending()`, so a pull in flight ends `E_DISPOSED` and applies nothing.

### 6.5 Doc and naming fixes (dart+app)

- `relay_slot.dart`. Replace "see the presence guard in `bridge/src/relay-client.ts`" with a pointer to the
  hand mirror `packages/antgrid-wire/src/relay-slot.ts` (`relaySlotId`/`slotMachineDeviceId`), or drop the
  sentence if nothing is left to point at. Drop the "E2E transcript" sentences, including the one in
  `baseSlotDeviceId`'s doc: there is no transcript.
- `relay_service.dart:139` ("online-after-offline rekey trigger") and `:633` ("MachineSession rekey arming").
  Say what the signal feeds now: presence is discovery only, and native links never derive a close or a
  restart from it (package CLAUDE.md). The words "rekey" and "arming" go.
- `app/lib/providers/agent_transport.dart:166`. Replace "rather than rekeying in place" with "a session has
  no in-place repair; …".
- `machine_session_establish_test.dart:171`. Rename the test to
  `'tears the session down, reports on takeoverEvents, and never re-establishes in place'`.
- `test/machine_session_rekey_test.dart` becomes **`test/machine_session_lifecycle_test.dart`**: the old file
  is deleted and its surviving tests move to the new one (§9.2).
- `packages/antgrid_eval_client/lib/src/commands.dart:51`. "[MachineSession] owns the E2E session and
  liveness" becomes "[MachineSession] owns the session and the app's wedge-probe ping".

### 6.6 Dart test seams

| Seam | After A8 |
|---|---|
| `establishSession(relay, {…})` (`test/support/fake_live_relay.dart`) | Adds `Duration? snapshotDeadline`, passed through to the `MachineSession` constructor. `snapshotTimeout` and `pingSilence` stay. |
| `FakeLiveRelay` | Needs a way to inject records onto an **opened project stream** without touching the session stream (`FakePeerStream` already models a stream's records; expose `injectRecord` on it if it has none). It also needs a way to observe `reset()` per `FakePeerStream` (`resetCalled`). `closeCalled` stays the link-close observation. |
| `FakeAgentTransport` | `request`/`requestWithOutcome` without `countsTowardHealth`. |

## 7. Netwatch

| Label | Before | After | Where |
|---|---|---|---|
| drop `reason`, outbound with no established session | `no-e2e-session` | `no-established-session` | `peer-session-owner.ts` (tx drop), `machine_session.dart` (three sites) |
| `peer:native-retired` `detail.reason` on a QUIC idle close | `connection-lost` | unchanged | `native-host-connection.ts` |
| ping/pong recurring hash note | peer-session.md §6 | unchanged | — |

No joiner rule changes (READ: `bridge/src/cli/netwatch.ts` has no reason match).

## 8. Test seams after the wave (summary)

| Seam | Does after A8 |
|---|---|
| `TestPeerSessionOwner.forTest` | Establishes with no interval scheduled. Pongs pings. `dropSession` ends a session. |
| fake Iroh `connection()` (bridge tests) | `closed()` is controllable and resolves to simulate an idle close. |
| `establishSession` + `FakeLiveRelay` (Dart) | `snapshotDeadline`, per-stream `injectRecord`/`resetCalled`, and `closeCalled`. |
| `DartAppClient.hardKill()` (evals, §9.3) | Kills the whole `dart run` process tree without letting the VM send a CONNECTION_CLOSE. |
| `RelayClient.ping(timeoutMs)` (evals, §9.3) | Sends a `ping` session frame and resolves with the round-trip ms on the `pong`. |
| `RelayClient` session-frame log (evals) | Records every inbound session frame's `type` so a test can assert "no `ping` arrived". |

## 9. Tests to add, change or delete

### 9.1 bridge-tests

- `bridge/tests/handshake-pull.test.ts`
  - **Keep** "ping is answered with pong".
  - **Add** "a pong from the app changes nothing and is not answered" **[break-only]**. Break: answer a pong
    with a ping.
  - **Delete** "2 missed pongs declare the session dead".
  - **Rewrite** "a session declared dead by liveness fires the coarse peer-offline only when it was the
    last" as "a dropped session fires the coarse peer-offline only when it was the last". It drives
    `dropSession(peerId)` instead of `checkLiveness` **[break-only]**. Break: fire `notifyPeerOffline`
    unconditionally in `dropSession`.
  - **Add** "establishing a session schedules no interval and sends no ping" **[fails-on-old]**.
    - Spy on `globalThis.setInterval` across `establish()` and expect zero calls from the owner.
    - Also expect that no `{type:"ping"}` is among the session frames the owner sent.
    - Old code calls `setInterval` in `startLiveness`. The 45 s idle proof that no ping ever goes out lives
      in the eval (§9.3).
- `bridge/tests/fake-session.ts`: drop `lastRecvAt`/`missedPongs`.
- `bridge/tests/netwatch.test.ts`
  - "records a send dropped for want of an E2E session" becomes "… for want of an established session".
  - It expects `"no-established-session"` **[fails-on-old]**.
- `bridge/tests/native-host-connection.test.ts`: **add** "a QUIC idle close retires the peer"
  **[break-only]**. Break: delete the `closed().then(...)` handler in `acceptPeer`.
  - Accept and establish a peer.
  - Resolve its fake `closed()` with `{reason:"timed out"}`.
  - Expect:
    - the session is gone;
    - `dropPeer` has run on the terminal, tunnel, upload and project registries (observe through a bound
      project stream being ended, or through the registries' public state);
    - a `peer:native-retired` record with `detail.reason === "connection-lost"` was written;
    - no `ping` session frame was ever written to the peer.
- `packages/antgrid-wire/tests/peer-transport-vectors.test.ts`: **add** "fixture's quic block equals
  `PEER_QUIC_KEEP_ALIVE_INTERVAL_MS`/`PEER_QUIC_MAX_IDLE_TIMEOUT_MS`" **[fails-on-old]** (the block is new).
- `bridge/tests/test-peer-session-owner.ts` and `bridge/tests/peer-session-hello.test.ts` change only if they
  reference a deleted member.

### 9.2 dart+app

**`packages/antgrid_relay_client/test/machine_session_rpc_health_test.dart`** is rewritten in place. It is
the per-stream accounting suite. Delete both `countsTowardHealth` tests, then add:
1. **"three timeouts on project X reset only X"** **[fails-on-old]**.
   - Establish, then open project X, project Y, a terminal attachment on X and a tunnel exchange on X.
   - Time out three RPCs on X.
   - Expect:
     - X's `FakePeerStream.resetCalled`;
     - X's pending RPCs fail `E_STREAM_RESET`;
     - `projectStreamEvents` emits `(X, open:false)`;
     - Y's stream, the terminal stream and the tunnel stream are **not** reset;
     - `closeCalled` is false;
     - a new project stream for X is opened, and after the fake's `stream-ready` a `state.snapshot` request
       goes out on it (the A4 resync).
   - Old code closes the link.
2. **"an answered RPC clears the streak"** **[fails-on-old]**. Two timeouts, one success, two timeouts: no
   reset. Break: drop the `_noteAnswered` call.
3. **"an application error clears the streak"** **[break-only]**. Two timeouts, then a reply `ok:false`
   `E_NOT_FOUND`, then two timeouts: no reset. Break: treat every `RpcException` as local.
4. **"a late reply clears the streak"** **[break-only]**. Two timeouts, then the reply to the first one lands
   (orphan), then two timeouts: no reset. Break: remove the `noteOrphanResponse` reset.
5. **"a timeout from an earlier binding is not counted"** **[break-only]**. Issue one RPC, force a rebind (end
   the stream, rebind), let the old RPC's timeout land, then time out two more: no reset. Break: drop the
   epoch check.
6. **"repeated health resets back off"** **[break-only]**. Two consecutive health resets with no answer in
   between: the second reopen is scheduled after a longer delay than the first. Break: zero `_reopenAttempt`
   unconditionally in `_onOpen`.
7. **"timeouts on the control transport never close the link"** **[fails-on-old]**. Five control-transport
   RPC timeouts leave `closeCalled == false`.

**`packages/antgrid_relay_client/test/machine_session_lifecycle_test.dart`** (new; `machine_session_rekey_test.dart`
is deleted):
- Move over unchanged: the groups 'no app traffic before the first handshake establishes', 'non-disconnect
  state churn' and 'session teardown fails in-flight RPCs'.
- Group 'closing the link on failure':
  - **delete** "3 consecutive RPC timeouts close the link…", "a successful RPC resets the timeout streak…"
    and "a timeout streak before establishment…" (their subject is gone; test 7 above pins the replacement);
  - **keep** "2 missed liveness pongs close the link", renamed **"a stalled session stream closes the link"**
    **[break-only]**. Break: never increment `_missedPongs`;
  - **add** **"a wedged bridge is declared dead by the ping while project records keep flowing"**
    **[break-only]**:
    - use `pingSilence: 30ms`;
    - the fake never answers `ping` and sends no session frame, while `injectRecord` feeds an open project
      stream every 10 ms;
    - expect `closeCalled` within 10 × `pingSilence`;
    - the break is to refresh `_lastRecv` from project records.

**`packages/antgrid_relay_client/test/machine_session_snapshot_retry_test.dart`**:
- Delete "a timed-out pull is retried with a longer wait…", "retries stop at the attempt cap" and "disposing
  the transport ends its retries".
- Rewrite "an error the agent answers with is not retried" as "an answered error sends no second pull".
- Keep "a reply that lands in time…", the `refreshDurableState` tests and the tree-exclusion group.
- Add:
  1. **"a timed-out pull sends exactly one request"** **[fails-on-old]**. Use `snapshotTimeout: 40ms` and
     `snapshotDeadline: 120ms`, and wait 400 ms: exactly one `state.snapshot` request was sent.
  2. **"a reply after the caller's wait but before the deadline is applied"** **[fails-on-old]**.
     - Use `snapshotTimeout: 40ms` and `snapshotDeadline: 500ms`.
     - `refreshDurableState()` completes. Then reply at ~150 ms.
     - The frames reach `messages`/`snapshotCache`.
     - Old code discarded that reply as late.
  3. **"a superseded pull's reply is discarded"** **[fails-on-old]**.
     - Start pull A, then call `refreshDurableState()` (pull B).
     - Reply to A with frame `a`: it is not applied.
     - Reply to B with frame `b`: it is applied.
     - Old code applied A.
  4. **"disposing mid-pull applies nothing"** **[break-only]**. Break: drop the disposed check.

**Netwatch reason** **[fails-on-old]**:
- `packages/antgrid_relay_client/test/netwatch_tap_test.dart`: rename "…for want of an E2E session" to
  "…for want of an established session", expecting `'no-established-session'`;
- `app/test/util/netwatch_test.dart`: the round-trip fixture uses `'no-established-session'`.

**Vectors.** `packages/antgrid_peer_transport/test/peer_transport_vectors_test.dart` gets "Dart QUIC timing
constants match the shared transport vector" **[fails-on-old]**.

**Compile-only fallout.** Update any relay_client or app test that passes `countsTowardHealth` or calls
`notifyRpcResult` (grep at HEAD: only the files above).

### 9.3 evals

- **`evals/helpers/dart-app-client.ts`**
  - `DartAppClient` keeps the spawned process as `{ pid: number; kill(): void }`.
  - It adds `async hardKill(): Promise<void>`:
    - **win32.** `taskkill /PID <pid> /T /F`. EXECUTED: `dart.exe run` spawns a child `dartvm.exe`
      (`pidprobe.ts`: Bun pid 7764 → `dartvm.exe` pid 10772). Killing only the Bun-spawned pid leaves the VM
      to exit on stdin EOF, which may be graceful and send a CONNECTION_CLOSE. `/T /F` terminates the tree
      forcefully.
    - **POSIX.** SIGKILL every pid from `pgrep -P <pid>` (recursively), then the pid itself.
    - Afterwards the existing `close()`/teardown must stay safe to call on an already-dead client.
- **`evals/helpers/relay-client.ts`**
  - Keep answering `ping` with `pong`.
  - Add `ping(timeoutMs = 5_000): Promise<number>`, which sends a `{type:"ping"}` session frame and resolves
    on the next `pong`.
  - Add `sessionFrameTypes(): string[]`, the log of inbound session frame types.
  - The client must retain its napi endpoint and connection references for its whole life (D-A8-1 trap).
- **New `evals/tests/peer-liveness.test.ts`** (in the `test:evals` sweep):
  - **"the bridge never pings an idle app, and still pongs"** **[fails-on-old]**.
    - Establish a `RelayClient` on a `setupTestEnv()` bridge and send nothing for 45 s. That is more than
      the old 20 s interval plus a 20 s silence threshold.
    - Expect no `ping` in `sessionFrameTypes()`.
    - Then `await client.ping()` resolves.
    - Timeout 70 s.
- **New `evals/scenarios/dart-client-e2e/dart-peer-liveness.test.ts`**:
  - **"the bridge retires a hard-killed Dart app on QUIC idle"** **[break-only at the eval level]**.
    - Call `setupDartTestEnv`, then wait for `agent:status`.
    - Record `t0` and call `env.app.hardKill()`.
    - Poll `GET http://127.0.0.1:<controlPort>/netwatch?limit=500&follow=0`, with `authorization: Bearer
      <token>` from `waitForHostFile(env.abDir)`, every 500 ms. Stop at the first
      `msgType === "peer:native-retired"` with `detail.reason === "connection-lost"` whose `at` is after `t0`.
    - Expect `elapsed >= 20_000` (proves an idle close, not a graceful CONNECTION_CLOSE) and
      `elapsed <= PEER_QUIC_MAX_IDLE_TIMEOUT_MS + 15_000`.
    - Timeout 90 s.
    - **Report the measured `elapsed`.** The ≥ 20 s bound is EXECUTED only napi↔napi, so if Dart↔napi
      measures below it, report the number rather than loosening the bound.
- **`evals/package.json`**: add `"test:evals:dart-liveness": "bun test scenarios/dart-client-e2e/dart-peer-liveness.test.ts"`,
  matching the flags of the existing `test:evals:dart-terminal` script.
- **Keep green, unchanged:** `gate-iroh-host-authorization` (its `ping` is the central WS, unrelated), the
  gates adjacent to `soak/native-fault-soak.test.ts` (no ping dependency, READ), and `test:evals:dart-terminal`.

## 10. Docs

| Doc | Change | Part |
|---|---|---|
| `docs/protocol/peer-session.md` §3 | Rewrite the first two paragraphs (§10.1 has the content to carry). | bridge-src |
| `docs/architecture.md` (~l.25, ~l.53) | The session stream carries the hello and the app's wedge-probe ping. QUIC keep-alive/idle is the liveness layer. `PeerSessionOwner` owns establishment, not liveness. | bridge-src |
| `bridge/CLAUDE.md` (l.39, l.86) | "owns peer session establishment" (drop "and peer liveness"). The l.86 sentence "any liveness failure is a full re-dial" becomes: a dead peer surfaces as the Iroh connection's `closed()` (QUIC idle), which retires the peer, and the bridge never pings. | bridge-src |
| `docs/iroh-reduction/ledger.md` | Add the row `\| A \| A8 liveness: explicit QUIC defaults, one app ping, per-stream RPC timeout recovery \| done \| <hash> \|`, and record under Stage A open items that D-A8-1's QUIC values are recorded rather than set. Also fill A7's `<hash>` as `63b1dca3`. | bridge-src |
| `app/CLAUDE.md` (l.35) | Replace the liveness sentence: "Liveness: QUIC keep-alive/idle (`kPeerQuicMaxIdleTimeout`) detects a dead bridge; `MachineSession`'s ping (20 s session-stream silence, 2 missed pongs → `link.close()`) exists only for a bridge wedged while QUIC still acks. RPC timeouts never close the link: 3 consecutive on one project stream reset and reopen that stream (`kProjectStreamTimeoutsToReset`)." Keep "never an in-place …" without the word rekey. | dart+app |
| `packages/antgrid_relay_client/CLAUDE.md` (l.15) | "(hello driver, wedge-probe ping)". Add one sentence on the per-project-stream timeout reset and the single snapshot pull with its deadline (`kSnapshotPullDeadline`). | dart+app |

### 10.1 Content for peer-session.md §3 (bridge-src writes the prose)

- Liveness is QUIC's.
  - Both endpoints run iroh 1.0's keep-alive 5 s and idle timeout 30 s.
  - These are recorded as `PEER_QUIC_KEEP_ALIVE_INTERVAL_MS`/`PEER_QUIC_MAX_IDLE_TIMEOUT_MS` and
    `kPeerQuicKeepAliveInterval`/`kPeerQuicMaxIdleTimeout`, not set, because neither binding exposes a
    transport config.
  - A peer that stops acking closes the connection on idle. The bridge retires it from `connection.closed()`.
- The app sends `ping` after `kPingSilenceSeconds` of session-stream silence and closes the `PeerLink` after
  `kMaxMissedPongs` unanswered. The ping's only job is a bridge wedged while its QUIC stack still acks. The
  bridge answers `ping` with `pong` and never pings.
- RPC timeouts never close the link. Three consecutive on one project stream reset that stream and reopen
  it, which reruns the bind resync (§1d). The control plane's only connection-level escape is the ping.
- Closing the link is still the whole recovery for the session. The supervisor redials through admission
  (§1) and the hello (§2).
- The `_SessionGeneration` and takeover paragraphs stay as they are.
- `notifyRpcResult` is no longer named anywhere.

## 11. Gates per part

| Part | Must run |
|---|---|
| bridge-src | `bun run --filter antgrid-wire gen:peer-vectors` (then diff: only the `quic` block), `bun run --filter antgrid-wire typecheck`, `bun run --filter antgrid-bridge typecheck` (test files may lag until bridge-tests lands; report which), `bun run --filter antgrid-relay typecheck` |
| bridge-tests | `bun run --filter antgrid-wire test`; `bun run --filter antgrid-bridge test > file`, grep `(fail)`, where only the known red is allowed |
| dart+app | `dart test` in `packages/antgrid_relay_client` and `packages/antgrid_peer_transport`; `cd app && flutter test -j 2`; `npm run check:font-tokens`; `analyze_files` while iterating. The controller runs `flutter analyze` once, never concurrently. |
| evals | `bun run --filter antgrid-evals typecheck`; `evals/tests/peer-liveness.test.ts`; `test:evals:dart-liveness`; `test:evals:dart-terminal`; `evals/tests/gate-iroh-host-authorization.test.ts` |

## 12. File ownership (disjoint and complete)

| File | Part |
|---|---|
| `packages/antgrid-wire/src/stream-open.ts`, `packages/antgrid-wire/src/index.ts`, `packages/antgrid-wire/scripts/gen-peer-transport-vectors.ts` | bridge-src |
| `evals/fixtures/peer-transport-vectors.json` (regenerated only, never hand-edited) | bridge-src |
| `bridge/src/peer-session-owner.ts`, `bridge/src/peer/native-host-connection.ts` (comment only) | bridge-src |
| `docs/protocol/peer-session.md`, `docs/architecture.md`, `bridge/CLAUDE.md`, `docs/iroh-reduction/ledger.md` | bridge-src |
| `packages/antgrid-wire/tests/peer-transport-vectors.test.ts` | bridge-tests |
| `bridge/tests/handshake-pull.test.ts`, `bridge/tests/fake-session.ts`, `bridge/tests/netwatch.test.ts`, `bridge/tests/native-host-connection.test.ts`, `bridge/tests/test-peer-session-owner.ts`, `bridge/tests/peer-session-hello.test.ts` (only if it references a deleted member) | bridge-tests |
| any other file under `bridge/tests/` | bridge-tests |
| `packages/antgrid_relay_client/**`: `lib/src/machine_session.dart`, `lib/src/agent_transport.dart`, `lib/src/buffered_agent_transport.dart`, `lib/src/models/stream_open.dart`, `lib/src/relay_slot.dart`, `lib/src/relay_service.dart`, `lib/src/local_transport.dart` (compile only), `lib/antgrid_relay_client.dart` (exports, if needed), `CLAUDE.md`, `test/support/fake_live_relay.dart`, `test/machine_session_rekey_test.dart` (deleted), `test/machine_session_lifecycle_test.dart` (new), `test/machine_session_rpc_health_test.dart`, `test/machine_session_snapshot_retry_test.dart`, `test/machine_session_establish_test.dart`, `test/netwatch_tap_test.dart`, `test/hydrate_action_contract_test.dart` (compile only) | dart+app |
| `packages/antgrid_peer_transport/test/peer_transport_vectors_test.dart` | dart+app |
| `packages/antgrid_eval_client/lib/src/commands.dart` | dart+app |
| `app/**`: `app/CLAUDE.md`, `app/lib/providers/agent_transport.dart`, `app/lib/test_helpers/fake_agent_transport.dart`, `app/lib/demo/demo_transport.dart` (compile only), `app/test/util/netwatch_test.dart`, `app/test/services/remote_request_outcome_test.dart` (compile only) | dart+app |
| `evals/**` except `evals/fixtures/peer-transport-vectors.json`: `evals/helpers/dart-app-client.ts`, `evals/helpers/relay-client.ts`, `evals/tests/peer-liveness.test.ts` (new), `evals/scenarios/dart-client-e2e/dart-peer-liveness.test.ts` (new), `evals/package.json` | evals |

Nothing under `relay/`, `web/`, `site/` or `aspire/` changes.

Some stale `bridge/src/relay-client.ts` pointers are outside A8's two named files. Do not fix them in A8;
report them if touched:
- `bridge/src/cli/phones.ts`, `bridge/src/paired-phones.ts`, `bridge/src/protocol.ts`, `bridge/scripts/iroh-host-smoke.ts`;
- `bridge/tests/host-control-plane.test.ts`, `bridge/tests/relay-client-watchdog.test.ts`;
- `evals/helpers/two-bridge.ts`, `evals/support/reachable.ts`, `evals/tests/gate-token-expiry.test.ts`,
  `evals/tests/prompt-retry.test.ts`;
- `relay/src/push/fcm.ts`, `docs/iroh-transport-reduction-plan.md`.

Symbols deleted or renamed, and every file that must stop referencing them (`git grep` at `63b1dca3`,
excluding `docs/iroh-reduction/`):

| Symbol | Call sites |
|---|---|
| `PING_SILENCE_MS`, `MAX_MISSED_PONGS` | `bridge/src/peer-session-owner.ts`, `bridge/tests/handshake-pull.test.ts` |
| `lastRecvAt`, `missedPongs` (TS) | `bridge/src/peer-session-owner.ts`, `bridge/tests/fake-session.ts`, `bridge/tests/handshake-pull.test.ts` |
| `livenessTimer`, `startLiveness`, `stopLiveness`, `checkLiveness` (TS) | `bridge/src/peer-session-owner.ts`, `bridge/tests/handshake-pull.test.ts` (the same-named Dart privates in `machine_session.dart` **stay**) |
| `notifyRpcResult` | `packages/antgrid_relay_client/lib/src/{machine_session,agent_transport}.dart`, `packages/antgrid_relay_client/test/machine_session_rekey_test.dart`, `docs/protocol/peer-session.md` |
| `_kConsecutiveTimeoutsToClose`, `_consecutiveTimeouts`, `_retrySnapshot`, `_kSnapshotAttempts` | `packages/antgrid_relay_client/lib/src/machine_session.dart` |
| `_pullSnapshot` (reshaped: `(int gen)`) | `packages/antgrid_relay_client/lib/src/machine_session.dart` |
| `countsTowardHealth` | `packages/antgrid_relay_client/lib/src/{agent_transport,buffered_agent_transport,machine_session}.dart`, `packages/antgrid_relay_client/test/machine_session_rpc_health_test.dart`, `app/lib/test_helpers/fake_agent_transport.dart` |
| `no-e2e-session` → `no-established-session` | `bridge/src/peer-session-owner.ts`, `bridge/tests/netwatch.test.ts`, `packages/antgrid_relay_client/lib/src/machine_session.dart`, `packages/antgrid_relay_client/test/netwatch_tap_test.dart`, `app/test/util/netwatch_test.dart` |
| "rekey" (re-establishment sense) | `packages/antgrid_relay_client/lib/src/{agent_transport,relay_service}.dart`, `packages/antgrid_relay_client/test/machine_session_establish_test.dart`, `packages/antgrid_relay_client/test/machine_session_rekey_test.dart` (file name), `app/lib/providers/agent_transport.dart` |
| `bridge/src/relay-client.ts` (in-scope pointers) | `packages/antgrid_relay_client/lib/src/{machine_session,relay_slot}.dart` |

## 13. Integration corrections (after the four parts landed)

What the integrator changed where the parts or this contract disagreed with the code that runs. Code wins.

- **Backoff never took effect (code, §6.3).** `StreamTransport._ensureBound` zeroed `_reopenAttempt`
  after every successful bind, which runs after `_onOpen()` has already applied the
  `_healthResets == 0` guard, so a stream that kept timing out still reopened at 1 s every time. The
  integrator deleted that reset; `_onOpen()` is now the only place a bind clears the backoff
  (`_reopenAtEstablish` still zeroes it for a fresh session).
- **Test 6, "repeated health resets back off" (§9.2), was reshaped.** Measuring the time until the
  reopened stream appears while injecting session `stream-ready` notices cannot see the timer: a ready
  notice for an unbound project rebinds at once (`MachineSession._markReady`). The test measures from
  the reset to the reopen's `project:start` on the session instead, and only then injects the ready
  notice. It asserts the second wait exceeds the first by more than 500 ms. Proven by the §9.2 break
  (zero `_reopenAttempt` unconditionally in `_onOpen`).
- **Test 1, "three timeouts on project X reset only X".** `projectStreamEvents` is an asynchronous
  broadcast stream, so the `(X, open:false)` notice lands one event-loop turn after the reset. The test
  yields once before asserting it.
- **"a wedged bridge is declared dead by the ping while project records keep flowing" (§9.2).** As
  written it awaited `openProject` before injecting the stream's `stream-ready`, so the bind could
  only time out, and a 30 ms `pingSilence` could close the link during setup before any project
  record flowed. The test now injects session pongs every 5 ms until the project is bound, asserts
  the link is still open, stops the pongs, and then feeds project records. It polls for the close for
  up to 500 ms (about 16 × `pingSilence`) rather than 10 ×, for headroom under load. Proven by the
  §9.2 break (refresh `_lastRecv` from project records).
- **Stale "liveness" wording outside the named spots** was fixed: `sendSessionFrame`'s doc
  (`peer-session-owner.ts`), the per-session offline hook's doc (`project-streams.ts`), and the
  session stream's contents in `peer-session.md` §1d. Comments naming "A8", "no longer" or the retry
  chain in the new tests, the eval helpers and `packages/antgrid_relay_client/CLAUDE.md` were
  reworded per §0.
- **The dart+app implementer's report was invalid.** It reported editing a file named `a.dart`, which
  does not exist. Its slice was nonetheless on disk; the integrator reviewed it against §6 and §9.2
  and gated it.
- **Adversarial review.** Test 1 ("three timeouts on project X reset only X") gained the
  contract's missing `closeCalled == false` assertion and was proven against the pre-wave behaviour
  (a timeout streak closing the link fails it on `E_SESSION_DOWN`). The snapshot suite gained "a pull
  whose own deadline expires is not re-asked" (`snapshotDeadline` 3 x `snapshotTimeout`), since "a
  timed-out pull sends exactly one request" never lets the 70 s deadline expire; proven by re-issuing
  the pull on `E_TIMEOUT` (4 requests instead of 1). "A QUIC idle close retires the peer" also checks
  the project registry's open-stream count; proven by disabling the `closed()` handler. Comments
  naming the decision id or narrating the deleted retry chain were reworded.
