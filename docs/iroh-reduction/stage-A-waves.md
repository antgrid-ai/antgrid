# Stage A (purpose-specific QUIC streams): adversarial wave plan

Every claim below carries a label:
- **READ**: I read the code at the cited file:line in this session.
- **EXECUTED**: I ran a command (grep, ls, sed).
- **INFERRED**: my reasoning, not checked against code.
- **Reader-confirmed**: a reader's READ claim that I agree with but did not re-open myself.

I ran no test suites and no analyzer.

**Starting state.** HEAD is `d241d934`. Stages C and B have not started: `bridge/src/e2e/` still exists and `peer-session-owner.ts:9` still imports the credit and frag constants (EXECUTED). Everything below assumes B has landed, as the plan orders. The one exception is Wave A0, which can land before B.

---

## 1. Adjudication: attempts to refute the stage's premise

### 1.1 Feasibility of the bridge binding: holds, with a hard constraint the plan ignores

- **READ** `bridge/node_modules/@number0/iroh/src/endpoint.rs:845-909`. `SendStream` is `Arc<tokio::Mutex<…>>`.
  - `write` and `write_all` hold the lock across the await (`:856-864`).
  - `reset` (`:879-882`), `set_priority` (`:888-889`) and `stopped` (`:901-902`) take the same lock.
  - `RecvStream` has the same shape: `read` holds the lock (`:927-929`) and `stop` takes it (`:971-974`).
- **READ** `bridge/src/peer/records.ts:73-76`. Today's 5s write timeout only rejects the JS promise. The pending `writeAll` keeps the lock, which is why `close()` retires the entire connection (`:127` comment: "The owner must also close the native connection").
- **Consequence (INFERRED):**
  - A `reset()` issued while a `writeAll` is flow-blocked waits until the peer drains.
  - Awaiting `stopped()` or `receivedReset()` on a live stream wedges every later write or read on it.
  - The only thing that preempts a stuck write is closing the connection (`Connection.close` is synchronous: READ `index.d.ts:35`).
- **The design survives if** the bridge:
  - writes each record in bounded slices (≤256 KiB `writeAll` calls), so a cancel waits at most one slice;
  - calls `setPriority` once, before the first write;
  - never awaits `stopped()` or `receivedReset()`;
  - learns about a peer reset only through its own pending `read()` rejecting.

### 1.2 Feasibility of the Dart binding: holds for open/accept/FIN, not for signalling

- **READ** `iroh_quic-1.0.3/lib/src/stream.dart`. The whole API is `writeAll`, `finish`, `reset(code)`, `read`, `readExact`, `readToEnd` and `stop(code)`. It has no priority, no `stopped` and no `receivedReset`.
- **READ** `errors.dart:73-77`. Errors arrive as `IrohStreamException(message)` with **no reset code**.
- **New finding, not in the plan or either reader:** the bridge cannot use QUIC reset codes to tell the app *why* it refused a stream (NOT_READY, UPDATE_REQUIRED, cap exceeded, NOT_ALLOWED), because Dart cannot read them. Every refusal has to be an in-band record (`{"type":"stream:refused", code, message}`) followed by FIN. The reset code exists only for the bridge's diagnostics.
- **Reader-confirmed:**
  - A Dart stream is invisible to the peer until its first write (`connection.dart:19-21`). The open frame must go out in the same step as `openBi`.
  - Dropping a noq `SendStream` FINs it rather than resetting it. Every error path in the app must call `reset` explicitly.

### 1.3 Stream-limit claim: wrong as written

- **READ** `index.d.ts:45-47`. The bridge can call `setMaxConcurrentBiStreams` only per `Connection`, after accept.
- **Reader-confirmed:** Dart has no transport-config setter.
- Correct plan text: the app opens every stream, so only the bridge's limit applies.
- **INFERRED:** exceeding the QUIC MAX_STREAMS limit makes the opener's `openBi` *wait*; nothing is reset. A7's "extra stream is reset" therefore holds only for an application-level cap set below the QUIC limit. The app also needs its own open semaphore, or a preview page firing many tunnel requests stalls with no error.

### 1.4 Security premise: holds, with three points to adjudicate

- **Reader risk: "deleting stream-mux removes `mayDeliver`, so the phone keeps receiving with the switch off."** Partly refuted.
  - **READ** `native-host-connection.ts:266`: `authorized()` returns false when `!remoteAccessEnabled()`.
  - **READ** `records.ts:35-38, :62`: every record send checks `authorized()` and closes the connection with `unauthorized`.
  - So switching remote access off kills the native connection on its next record. The protection holds **only if** every new per-stream writer calls `authorized()` on every write, as `PeerRecords` does.
  - Keep `mayDeliver` anyway: it is cheap, and it is the documented outbound half of the gate (READ `project-core.ts:560-566`).
- **`mayDeliverTo` / `mayAcceptFrom` must be ported, not deleted.**
  - **READ** `project-core.ts:567-580`. `mayDeliverTo` is evaluated **per send**, because `hasIsolatedSessions()` can become true after a stream is bound.
  - Checking it only at open time lets a stale app keep receiving isolated-session output as main. Nothing fails at compile time or in tests.
- **The open frame must never open or promote a core.**
  - **READ** `host-server.ts:1727-1745`. `project:start` runs remote-access, then `seenProjects`, then the checkout-routing check, and only then `open()`, which spawns the `terminals:` startup commands.
  - The project open frame may bind only to a core where `isRelayRegistered()` is true (READ `:1795`), and it re-checks remote access, `isSafeProjectId`, `seenProjects` and `mayAcceptFrom`.
  - Terminal and tunnel open frames should be admitted **only if the same peer currently holds an open project stream for that projectId (INFERRED recommendation)**. The project stream then stays the single admission point, and the "only bound on projectId" rule in root CLAUDE.md stays true.

### 1.5 A new cross-stream ordering hazard the plan misses (hazard J, INFERRED from READ)

- **The race:** `project:start` travels on the session stream and the project open frame on a new stream. QUIC does not order across streams, so the open can arrive before `project:start` has opened the core.
  - Today this is sequenced: `project:start`, then `firstRegister`, then `stream-ready`, then bind (READ `host-server.ts:1813-1826`).
- **Resolution:**
  - Keep a ready notice on the session stream: `stream-ready` without `streamId`, or a renamed `project:ready {projectId}`.
  - The app opens a project stream only after that notice, or after an advert with `running:true`.
  - An early open is refused in-band with `NOT_READY` and FIN, never parked.

### 1.6 Request streams are the weakest part of the plan: recommend descoping them from Stage A

**What request streams need:**
- **READ** `protocol.ts:848-865`: `file:read` and `file:content` carry no `requestId`.
- **Reader-confirmed:** `git:diff` / `git:diff-content` have none either, and replies are broadcast through the bus with no reply handle (`message-bus.ts:255`).
- Moving them to request streams therefore needs:
  - a `requestId` retrofit on both halves;
  - per-requester reply binding in agent-core;
  - an app switch from fire-and-forget to RPC, while keeping one `file:content` fanning out to several panes (reader: `file_service.dart:448`);
  - a new hazard-D guard.
- None of that is needed on loopback, which shares every producer.

**Why keeping them on the project stream costs nothing:**
- **READ** `protocol.ts:3129-3132`: `file:content` rides **control** today, not preview.
- **READ** `peer-session-owner.ts:125-135`: its fragments are FIFO on that channel.
- So a 32 MiB `file:content` already head-of-line blocks project control traffic today. Leaving it on the project stream is no regression.
- A7's concurrency test (terminal latency during a 32 MiB `file:read`) still means something, because terminal frames get their own stream at higher bridge priority.

**Uploads stay chunked:**
- Reader-confirmed: `upload_service.dart:93-99` and `local-listener.ts:135` (READ: `maxPayloadLength: 1048576`).
- The chunk-and-ack protocol serves loopback. Keep it unchanged on the project stream in Stage A.

**Tunnel is the one purely remote producer.**
- Reader-confirmed: `preview_service.dart:723` branches on `isLocal`.
- Tunnel HTTP and WebSocket streams are therefore a clean move and carry most of the deletion.

### 1.7 Deleting frag moves the problem to large records

- **READ** `frag.ts:1,4`: `MAX_FRAME_PAYLOAD=1_500_000`, `MAX_TRANSFER_BYTES=33_554_432`.
- **READ** `peer-authorization.ts:3,6-7`: `PEER_MAX_RECORD_BYTES` derives from `frag.ts`.
- With frag deleted, the bridge-to-app project stream must accept records up to `MAX_TRANSFER_BYTES + header`. The limit is still enforced on serialized utf8 bytes, as today at `peer-session-owner.ts:125-127`, and the `MESSAGE_TOO_LARGE` path stays.
- **Two traps that compile clean:**
  - **Write side:** `writeAll(Array.from(buf))` on a 32 MiB record builds a JS array with 32M elements. `records.ts:73` does exactly this, harmlessly today at ≤1.5 MB per fragment. Write in slices.
  - **Inbound caps:** make them asymmetric. The bridge still accepts only about 1.5 MB inbound (the app sends small messages plus ≤1 MiB upload chunks). The app accepts the full transfer cap.
- `MAX_TRANSFER_BYTES` and `PEER_MAX_RECORD_BYTES` need a new home before `frag.ts` goes.

### 1.8 Ordering hazards A–D: which are live today, and where they are fixed

| Hazard | Adjudicated state | Where it gets fixed |
|---|---|---|
| **A** | Bridge-side order is sound: `subscribed` is awaited before `ready` (reader-confirmed). The race is on the app: per-channel async decrypt tails (READ `machine_session.dart:975-995`). | **Stage B**, provided B replaces `_inboundTails` with synchronous in-order dispatch. Add that as a B requirement. A's terminal stream makes it structural. |
| **B** | Live. Control-over-preview priority on the bridge lets ENDED overtake queued frames. | **A0 app fix now:** keep accepting frames up to ENDED's `finalSequence` (READ `protocol.ts:2226`, `finalSequence` on display:status). This is independent of transport, and the terminal stream later makes it structural. |
| **C** | Live, app-only (reader-confirmed `terminal_history_model.dart:233-234`). | A0: a monotonic boundary guard. |
| **D** | Not live today; request streams would create it. | Descoping 1.6 removes it. The existing `file:tree:unchanged` guard (reader: `file_service.dart:229-236`) remains the pattern to follow if request streams return later. |

### 1.9 Terminal stream binding: the plan names no key

- **READ** `protocol.ts:2150-2160`. The app mints `requestId` on `terminal:subscribe`. The bridge mints `attachmentId` in `subscribed`.
- **READ** `agent-core.ts:755-783`. Viewer connections are per `ClientKey` (per peer), and multiple attachments share one connection and one budget.
- **Binding scheme:**
  - The terminal stream's first record is `terminal:subscribe`.
  - The bridge binds `(peerId, requestId)` to the stream, then `(peerId, attachmentId)` once `subscribed` is emitted.
  - `UPGRADE_REQUIRED` carries only `requestId` (READ `:2219-2224`), which is why the requestId key is needed.
- **Seam:** the relay branch of `sendTerminalTo` in agent-core routes by `attachmentId`/`requestId` into a stream registry. The loopback branch is unchanged.
- **Input and resize stay on the project stream.** The plan's table moves them, but they are terminal-level verbs rather than attachment-level, and they go through `remoteFrameAllowed` (INFERRED).
- **`TERMINAL_CONNECTION_MAX_BYTES` needs no re-derivation.** It equals `CHANNEL_WINDOW_BYTES`, not half of it (READ `terminal-frames/protocol.ts:27`, `flow.ts:9`); the comment at `agent-core.ts:2542-2551` is wrong. It is a per-peer memory bound, so keep it and fix the comment.

---

## 2. Plan corrections

| # | Plan text | Correction | Method |
|---|---|---|---|
| 1 | "Set `max_concurrent_bidi_streams` explicitly on both endpoints" | Set it on the bridge only, per accepted `Connection` (`index.d.ts:47`). Dart cannot set it and does not need to. Add an app-side open semaphore. An app cap below the QUIC limit is what produces resets. | READ |
| 2 | A2 "Extend PeerLink with … priority" | Dart has no priority and no reset codes (`stream.dart`, `errors.dart:73`). Refusals must be in-band records. | READ |
| 3 | A2 "per-stream writers" | Must drop both connection-kill rules (`records.ts:41-44` queue-full, `:73-76` 5s timeout; app `iroh_peer_link.dart:241-244`, reader-confirmed). Must write in bounded slices, call `setPriority` before the first write, never await `stopped`/`receivedReset`, and keep `authorized()` per write. On per-stream overflow, reset **that stream** and the app reopens and resyncs. | READ |
| 4 | Session row "session-bus frames" | Wrong. They ride the **project** stream, peer-addressed (READ `project-core.ts:141-148`). Keep them there; `sendToAppSession` must also require that peer's project stream to be open. | READ |
| 5 | Project `{projectId, checkoutId?}` | Drop `checkoutId`. Project streams are per project, and checkout routing stays per message (reader-confirmed `protocol.ts:3144-3146`). | Reader-confirmed |
| 6 | A3 gates "on the open frame" | Also port `mayDeliverTo` as a per-send filter and `mayAcceptFrom` as the open-time refusal (READ `project-core.ts:567-580`). The open binds only to a relay-registered core and never opens one (READ `host-server.ts:1727-1745`). Add the hazard J ready notice. | READ |
| 7 | A4 `TERMINAL_CONNECTION_MAX_BYTES` "half of window" | False; the values are equal. Keep the constant and fix the comment at `agent-core.ts:2542-2551`. | READ |
| 8 | A4 terminal stream carries "input, resize" | Keep them on the project stream. The stream binds by subscribe `requestId`, then `attachmentId`. | READ / INFERRED |
| 9 | A5 request streams and upload deletion | Descope (1.6). Upload chunking serves loopback. | READ |
| 10 | A5 tunnel "delete pre-open buffer" | Delete the **pre-open** buffer (reader: `tunnel-manager.ts:847-882`). Keep the connecting-state `pending` buffer, because upstream connect is async. Keep awaiting the write (natural backpressure). | Reader-confirmed |
| 11 | A7 "cancel resets only its stream" | Cancel travels in-band (§4 D4). A test against a stalled upstream must use the real binding (interop or eval), because fakes lack the mutex. | READ / INFERRED |
| 12 | A6 delete `frag.ts`/`flow.ts` | First rehome `MAX_TRANSFER_BYTES`, `PEER_MAX_RECORD_BYTES` (`peer-authorization.ts:3-7`) and `SendOutcome` (tunnel-manager branches on it). On the Dart side, `kMaxFramePayload` / `kSocketInflightBytes` are used by `frame.dart` and `iroh_peer_link.dart`, and `FragHint`/`kMaxRerequests` by `fragment_recovery.dart`, `file_service.dart` and `preview_service.dart` (reader-confirmed). | READ / reader-confirmed |
| 13 | A6 "delete control/preview split and mirrors" | Only on the native path. Loopback JSON carries `channel` (reader-confirmed `local-listener.ts:195,247,348`; `message_router.dart:103-106`; `preview_service.dart:191`). Keep the loopback label and `PREVIEW_CHANNEL_MESSAGE_TYPES` in Stage A (§4 D2). | Reader-confirmed |
| 14 | A1 `{s,m}` removal names only TS | Also the Dart mirror `models/stream_envelope.dart`, the `PeerFrameHeader.channel` record header (`peer-protocol.ts:4-10`), the eval client and `interop_app.dart`. | Reader-confirmed |
| 15 | A1 FRAME_VERSION bump only | Also bump the ALPN `antgrid/peer/1` → `/2` (READ `peer-authorization.ts:5`). An old app is then refused at the ALPN check (READ `native-host-connection.ts:203`) instead of failing opaquely on a malformed open frame. | READ |
| 16 | Hazard A "racy today (delivery.ts)" | The race is app-side and closes in Stage B if dispatch becomes synchronous. | READ |
| 17 | "Generation fencing on each stream" | Streams die with their connection, and a concurrent connection for the same peer is refused (READ `native-host-connection.ts:210-212`). If B keeps one session per connection (re-hello means close), per-stream fencing reduces to connection identity. State that instead of building a fence. | READ / INFERRED |
| 18 | A6 test list | Missing (reader-confirmed): bridge `native-host-connection`, `project-core`, `host-server`, `host-promotion`, `relay-promotion`, `remote-access-gate`, `agent-reach-gate`, `handshake-pull`, `netwatch`, `terminal-frame-channel`, `checkout-mirror-contract`, the push-targeting tests, `test-peer-session-owner.ts`; Dart `machine_session_stream_binding_test`, `…_unknown_stream_log_test`, `…_snapshot_retry_test`, `relay_message_test`, `peer_transport_vectors_test`, `fragment_recovery_test`; evals `fragmentation`, `gate-flow-control`, `gate-tunnel-streaming`, `multi-stream-coexistence`, `gate-iroh-host-authorization`, `drill-in`. `native_smoke.dart:111-118` asserts EXTRA_STREAM. | Reader-confirmed |
| 19 | Expected reduction −4.8K to −5.4K | With the recommended descope, INFERRED closer to −3K to −4K. Unmeasured. | INFERRED |

---

## 3. Wave breakdown

**Preconditions:**
- Stage B has landed, with plaintext hello, synchronous in-order app dispatch and one session per connection.
- Worktree setup: `bun install`, `flutter pub get` in `app/`, and `dart pub get` in each of `packages/antgrid_relay_client`, `antgrid_peer_transport` and `antgrid_eval_client`. Reader EXECUTED: only `app/` has `package_config`.
- `flutter analyze` runs once, from the controller, at the end of each wave. Never concurrently.

**Sequencing:**
- A0a–A0d are parallel with each other; A0d may also land before B.
- A1 through A6 are serialized. Each one changes the native wire and the TS and Dart phone emulators, which are shared files.
- Inside a wave, implementers are split by the file ownership listed.

**Gate shorthand used below:**
- `ALL`:
  - `bun run --filter antgrid-wire test`
  - `bun run --filter antgrid-bridge test`
  - `cd packages/antgrid_relay_client && dart test`
  - `cd packages/antgrid_peer_transport && dart test`
  - `cd app && flutter test -j 2`
  - `npm run check:font-tokens`
- `EVALS`: `bun run --filter antgrid-evals test:evals`
- `INTEROP`: `bun run --filter antgrid-bridge qualify:iroh-interop`

### A0: additive groundwork, no wire change (4 parallel commits)

**A0a. Bridge per-stream record I/O**
- **Owns:** new `bridge/src/peer/stream-records.ts` and new `bridge/tests/stream-records.test.ts`.
- **Build:** `StreamRecordWriter` and `StreamRecordReader` over `{send, recv}`.
  - Writes `[u32 len][frame]` in ≤256 KiB `writeAll` slices.
  - `setPriority(p)` must be called before the first write.
  - `authorized()` is checked per record, and failure closes the **connection**.
  - A bounded per-stream queue; overflow resets **the stream** with a code and never touches the connection.
  - No write timeout.
  - The reader takes a per-stream-kind max length, reads the header with `readExact(4)`, then reads the body in ≤256 KiB pieces into one `Buffer`.
  - Never calls `stopped` or `receivedReset`.
- **Tests:** a fake stream that **models the binding mutex**, where `reset` awaits any pending `writeAll`. Assert the writer never issues a reset while it has a slice outstanding beyond one slice. Also test: overflow resets the stream only; unauthorized closes the connection; a 32 MiB record is written as more than one slice.
- **Gate:** `bun run --filter antgrid-bridge test`.
- **Trap:** a fake without the mutex passes every test and hides the deadlock.

**A0b. Wire: open-frame schema**
- **Owns:**
  - new `packages/antgrid-wire/src/stream-open.ts` and its export in `index.ts`;
  - new `packages/antgrid_relay_client/lib/src/models/stream_open.dart` and its export;
  - vectors in `scripts/gen-peer-transport-vectors.ts` and `evals/fixtures/peer-transport-vectors.json`;
  - `packages/antgrid_peer_transport/test/peer_transport_vectors_test.dart` (open-frame cases only).
- **Schema:** Zod, a discriminated union on `kind`:
  - `session`;
  - `project {projectId}`, no checkoutId;
  - `terminal {projectId, checkoutId?, requestId}`;
  - `tunnel-http {projectId, requestId}`;
  - `tunnel-ws {projectId, wsId}`.
  - Plus a `STREAM_OPEN_MAX_BYTES` cap (for example 4 KiB), `stream:refused {code, message}`, and the new home for `MAX_TRANSFER_BYTES`/`PEER_MAX_RECORD_BYTES` (re-exported from `frag.ts` for now).
- **Gate:** `bun run --filter antgrid-wire test`, `dart test` in relay_client and peer_transport.
- **Trap:** the Dart mirror is by hand. A vector test is the only cross-check, so every kind needs a vector.

**A0c. Dart multi-stream link (additive)**
- **Owns:**
  - new abstract `MultiStreamPeerLink` in `packages/antgrid_relay_client/lib/src/peer_link.dart`, a separate interface so the 15 `PeerLink` implementers are untouched;
  - `packages/antgrid_peer_transport/lib/src/iroh_peer_link.dart` and `leased_peer_link.dart`;
  - new tests in `peer_transport/test`.
- **Build:**
  - `openStream(StreamOpen)` writes the open frame in the same call as `openBi`, goes through a per-link open semaphore, and returns a per-stream reader and writer with the same slicing and no connection-fatal timeout.
  - The lease fence covers `openStream` and every per-stream read and write (reader-confirmed: the fence today covers only `messageStream`/`sendFrame`, `leased_peer_link.dart:59-98`).
  - Explicit `reset` on every error path.
  - Keep the single-stream guard for now.
- **Gate:** `dart test` in peer_transport and relay_client.
- **Traps:**
  - a noq drop FINs, so a missing reset reads as a clean end;
  - an unfenced stream API keeps flowing after revocation.

**A0d. App hazards B and C (transport-independent)**
- **Owns:** `app/lib/services/terminal_service.dart` (ENDED handling around `:1212-1219`, reader-confirmed), `app/lib/models/terminal_history_model.dart:233-234`, and their tests.
- **Build:**
  - After ENDED, keep the attachment in a draining state and accept frames up to `finalSequence`, then retire it.
  - Make the history boundary monotonic.
- **Tests:** interleavings with ENDED delivered before the last frames, and an older page arriving after a newer boundary. Both must fail on HEAD (verify against the true original; do not partially revert).
- **Gate:** `cd app && flutter test -j 2`.

### A1: multi-stream admission, flag day (serialized; bridge, Dart, evals together)

- **Owns:**
  - `bridge/src/peer/native-host-connection.ts` (`acceptPeer`, `:197-264`);
  - `packages/antgrid-wire/src/peer-frame.ts` (FRAME_VERSION) and `peer-authorization.ts` (ALPN `/2`);
  - Dart `frame.dart` and `peerAlpn`;
  - `iroh_peer_link.dart` (remove the EXTRA_STREAM guard `:156-176`; dial writes `{kind:"session"}`);
  - `evals/helpers/relay-client.ts` (phone emulator open frame);
  - `packages/antgrid_eval_client/lib/src/commands.dart`;
  - `packages/antgrid_peer_transport/bin/native_smoke.dart` (replace the EXTRA_STREAM assertion with "an invalid open frame is refused and the connection lives") and `bin/interop_app.dart`.
- **Build:**
  - The first accepted stream must declare `session`, and it keeps carrying today's full protocol, `{s,m}` mux included.
  - Each later accepted stream goes to **its own task**: open frame read under a 5s deadline, a per-peer pending-open cap, Zod parse under the size cap.
  - Add a dispatch table `Map<kind, handler>` in a new file `bridge/src/peer/stream-dispatch.ts`. For now every non-session kind is refused in-band.
  - Call `connection.setMaxConcurrentBiStreams(N)` right after accept.
  - Delete the second-`acceptBi` guard (`:248`). Keep the `acceptUni` guard (`:249`).
- **Tests:**
  - an invalid or oversized open frame is refused and the connection survives;
  - a peer over the pending cap is reset;
  - a stale ALPN is refused;
  - accepting stream N+1 is not blocked by stream N with no open frame (per-stream task).
- **Gate:** `ALL` + `EVALS` + `INTEROP`.
- **Traps:**
  - an inline `await readOpenFrame()` inside the accept loop means one silent stream stalls every later stream (INFERRED from QUIC accept order);
  - the eval emulator forgets the open frame, and every eval fails at setup, which is at least loud.

### A2: terminal attachment streams (serialized)

- **Owns:**
  - Bridge: new `bridge/src/peer/terminal-streams.ts` (registry `(peerId, requestId|attachmentId) → writer`, registered into `stream-dispatch.ts`); `agent-core.ts` (relay branch of `sendTerminalTo`, `:2537`, and the `viewerTransportFor` send; comment fix `:2542-2551`); a slim `project-core.ts` hook to expose "peer has project X bound".
  - Dart: `machine_session.dart` or a new `terminal_stream.dart` in relay_client; `agent_transport.dart` gains `openTerminalAttachment()`; `local_transport.dart` implements it by filtering the single socket by `requestId`/`attachmentId`, with no wire change.
  - App: `terminal_service.dart` (subscribe path `:392` `_heavySub`, sends `:801/:890/:923/:970`), `test_helpers/fake_agent_transport.dart`, `demo/demo_transport.dart`.
  - Evals: `relay-client.ts` terminal helpers and `dart-client-e2e/dart-terminal.test.ts`.
- **Build:**
  - The terminal stream carries only the frame protocol types: subscribe, subscribed, frame, ack, unsubscribe, history request/page, display:status.
  - Bridge priority: terminal above project.
  - Admission requires the peer's project binding for that projectId.
  - Inbound verbs are dispatched with the same `peerId` ClientKey as today, so `remoteFrameAllowed` and `focusPausedByClient` still apply.
  - FIN or reset of the stream means unsubscribe. The bridge calls `retired()`, and the app treats FIN as ENDED-less retirement.
- **Tests:**
  - A7 hazards A and B on the native path;
  - terminal stream refused without a project binding;
  - loopback terminal unchanged (existing app tests stay green);
  - `TERMINAL_VIEWER_MAX_FRAMES` backpressure over a stream.
- **Gate:** `ALL` + `EVALS` + `INTEROP`.
- **Traps:**
  - **Loopback breaks silently** if the app service calls the stream API without a LocalTransport implementation. Iroh evals stay green. Add a LocalTransport terminal test.
  - Routing `subscribed` by `attachmentId` before the registry knows it. Route `subscribed` and `UPGRADE_REQUIRED` by `requestId`.
  - `terminal-frame-channel.test.ts` expectations change for native only.

### A3: tunnel HTTP and WebSocket streams (serialized; remote-only)

- **Owns:**
  - Bridge: `bridge/src/tunnel-manager.ts`, `tunnel-protocol.ts`, the tunnel-stream handlers in a new `bridge/src/peer/tunnel-streams.ts`, `project-core.ts:611` (`setPlainHook`).
  - Dart and app: `app/lib/services/preview_service.dart` and a relay_client tunnel stream helper.
  - Evals: `gate-tunnel-streaming`, `relay-client.ts` tunnel helpers.
- **Build:**
  - HTTP flow:
    - The app writes one head record and then the request body as raw bytes, and keeps its send half open until the response completes.
    - The bridge replies with one head record and then raw body bytes; FIN means end.
    - The bridge resets its send half on upstream error.
  - Cancel (§4 D4):
    - The app resets its **send half** (idle, so the lock is free) and keeps draining its receive half until the bridge's reset arrives.
    - The bridge sees the reset through its pending `read()`, aborts the upstream, and resets its send half between slices.
  - WebSocket: one stream per socket, data both ways, close = FIN.
  - **Delete:** outbox (`tunnel-manager.ts:183-193, 520-561`), pre-open buffer (`:847-882`), `http-chunk.seq`, `http-end.chunks`, and lost-head retry (`preview_service.dart:411-439`).
  - **Keep:** the connecting-state `pending` buffer, and awaiting each write.
  - `SendOutcome` moves to `stream-records.ts`.
- **Tests:**
  - A7 cancel against a **stalled upstream through the real binding** (eval, not a fake);
  - stream cap: the app semaphore holds, and an over-cap open gets an in-band refusal while the connection lives;
  - a WebSocket close after data arrives after the data.
- **Gate:** `ALL` + `EVALS` + `INTEROP`.
- **Traps:**
  - awaiting `stopped()` or `receivedReset()` on the bridge wedges the stream (the mutex again);
  - an app error path without an explicit `reset` delivers a truncated body as a clean FIN. The bridge must check Content-Length where one exists, and the app must check its own sent length;
  - `abortTunnelStreams` on peer offline stays driven by **session** lifecycle.

### A4: project streams replace the mux (serialized; the largest wave)

- **Owns:**
  - Bridge:
    - `bridge/src/stream-mux.ts`, slimmed into a new `project-streams.ts` registry that keeps attach/detach and ports `mayDeliver`, `mayDeliverTo` (per send), `mayAcceptFrom` (open-time refusal) and the online/offline/session-gone hooks (READ `project-core.ts:559-612`);
    - `project-core.ts`, including `sendToAppSession` `:141-148`, which returns true only if that peer's project stream is open;
    - `host-server.ts` (remove `streamIds` from the advert; `stream-ready` becomes `{projectId}` only; `:1792-1826`, `:2711-2730`);
    - `relay-promotion.ts`, `remote-host-connection.ts`;
    - `peer-session-owner.ts` routing (the `mux.dispatchInbound` split);
    - `protocol.ts` (remove `stream-unbound`/`stream-invalid` from the schema, the union, `KNOWN_TYPES` and the `handleAbMessage` switch, per the CLAUDE.md add/remove rule).
  - Dart: `machine_session.dart` (`streamFor`, `bindProject`, `sendOnStream`, `streamReadyEvents`), `models/stream_envelope.dart` (keep only while frag lives), `app/lib/providers/agent_transport.dart:369-381`, `app/lib/project/project_session.dart:157-213` (re-hook focus re-declaration and `_markUp`/`_markDown` to project-stream open/FIN).
  - Evals: `relay-client.ts` (streamId learning `:707-708`, `:1028-1036`), `evals/support/` `openProjectStream`/`sendOnStream`, the eval client `commands.dart`, `gate-iroh-host-authorization`, `multi-stream-coexistence`, `machine-trust`, `drill-in`.
- **Build:**
  - Open `{kind:"project", projectId}`, then `isSafeProjectId`, remote access, `seenProjects`, relay-registered core (else `NOT_READY`, hazard J), `mayAcceptFrom`, then bind.
  - A broadcast becomes "write to every peer with an open project stream for X".
  - `state.snapshot` and `agent:status` stay on the project stream (hazard E). Machine-level `agent:projects`/`agent:tools` stay on the session stream.
  - Frag framing still runs over project-stream records in this wave.
  - `peerConnected` and push suppression stay driven by session establishment.
- **Tests:**
  - an open refused for an unknown, unsafe or not-ready project and for a stale app on an isolated project;
  - switch off: no delivery, and the connection retires;
  - a peer that becomes stale mid-stream when a core gains isolated sessions is muted per send;
  - session-bus delivery false without an open project stream;
  - two devices, one project, independent streams.
- **Gate:** `ALL` + `EVALS` + `INTEROP` + `evals/soak/native-fault-soak.test.ts`.
- **Traps:**
  - open-on-bind "for convenience" bypasses the three gates before `open()` and spawns startup terminals;
  - dropping the per-send `mayDeliverTo`;
  - re-deriving `peerConnected` from stream open, which makes push fallback fire for an established phone that has not opened X;
  - deleting the focus re-declaration hook paints a wrong unread dot, and no transport test catches it.

### A5: delete credits, schedulers, frag and envelope (serialized)

- **Owns:**
  - Bridge: `send-scheduler.ts` (delete), `peer-session-owner.ts` (credits `:412-430`, `:812-831`, `:1426-1434`; `rxFlow`/scheduler fields; `fragmentForSend`; reassembler), `frag-reassembler.ts` (delete), `records.ts` (delete; the session stream uses `stream-records`), `agent-core.ts` (`sendAbToItsChannel` native half).
  - Wire: `flow.ts`, `frag.ts`, the `{s,m}` part of `peer-protocol.ts` and `PeerFrameHeader.channel`.
  - Dart: `flow.dart`, `frag.dart`, `send_scheduler.dart`, `stream_envelope.dart`, and the fragment consumers `app/lib/project/fragment_recovery.dart`, `project_session.dart:163-170, 270`, `file_service.dart:78, 459, 506, 611, 632`, `preview_service.dart:946, 1073, 1094`.
  - Evals: remove frag and credits from `relay-client.ts`; delete `fragmentation` and `gate-flow-control`.
  - Tests: every deletion in the plan's list plus row 18 of §2.
- **Build:**
  - Asymmetric record caps: bridge inbound about 1.5 MB, app inbound `MAX_TRANSFER_BYTES + header`.
  - Keep `MESSAGE_TOO_LARGE`.
  - Replace the app's fragment-failure path: when a project stream resets, re-issue outstanding `file:read`/`git:diff` on reopen.
  - `PREVIEW_CHANNEL_MESSAGE_TYPES` and the loopback `channel` label stay (§4 D2).
- **Tests:**
  - A7 concurrency: terminal frame latency bounded while a 32 MiB `file:read` streams, with **both ends draining**. Run it with an eval against the real binding.
  - A 32 MiB record written as slices, not as one array.
- **Gate:** `ALL` + `EVALS` + `INTEROP` + soak + one forced-relay run.
- **Traps:**
  - `Array.from(32 MiB)` compiles and passes on small fixtures;
  - removing `channel` from the loopback JSON breaks desktop preview through `preview_service.dart:191` with every Iroh test green;
  - deleting `SendOutcome` with the scheduler breaks the tunnel manager's branches.

### A6: docs, diagnostics and ledger (parallel with nothing; last)

- **Owns:** `bridge/src/netwatch.ts`, `cli/netwatch.ts`, `netwatch-ui-page.ts` (the `channel`/`streamId` fields become stream kind plus QUIC stream id); `docs/architecture.md`; `docs/protocol/peer-session.md` (delete §8.8; add the stream catalogue); `docs/session-messaging.md` if wording changes; root and scoped `CLAUDE.md` (eval-harness text: `openProjectStream` and snapshot; the checkout-routing rule; remove `stream-ready` streamId mentions); a new Stage A ledger next to the plan.
- **Gate:** `bun run --filter antgrid-bridge test`.

---

## 4. Decisions the owner must make before Stage A starts

1. **D1. Scope of request streams.**
   - **Recommendation:** descope `file:read`, git diff, search, tree snapshot and upload from Stage A. They stay on the project stream.
   - **Why:**
     - Their replies have no `requestId` or reply handle, and loopback shares every producer.
     - Moving them creates hazard D and forks upload for loopback.
     - Keeping them costs no performance against today, because `file:content` already rides control FIFO.
   - Revisit as a Stage A′ if profiling shows project-stream head-of-line blocking matters.
2. **D2. Loopback wire.**
   - **Recommendation:** no loopback wire change in Stage A.
   - Keep `{channel, …}` on the loopback JSON and keep `PREVIEW_CHANNEL_MESSAGE_TYPES`/`kPreviewChannelInboundTypes`, now documented as loopback-only.
   - The app's new stream APIs (`openTerminalAttachment`) get LocalTransport implementations over the existing socket.
3. **D3. Per-stream overflow policy.**
   - **Recommendation:** overflow on a stream resets **that stream**. The app reopens it and resyncs, for a project stream through `state.snapshot`.
   - Never retire the connection for a slow stream. Retire it only for `unauthorized` or a protocol violation.
4. **D4. Cancel mechanism**, given the binding mutexes and that Dart cannot read reset codes.
   - **Recommendation:**
     - The app keeps its send half open for the stream's life and cancels by resetting it.
     - The bridge learns of the cancel through its pending read.
     - All refusals are in-band `stream:refused` records.
   - Forking `iroh_quic` for reset codes or priority means self-signed prebuilts (reader: `prebuilt.dart:13-27`); do not.
5. **D5. ALPN bump.**
   - **Recommendation:** bump to `antgrid/peer/2` with the FRAME_VERSION bump in A1, and again for B if B ships separately. A stale app then gets a clean ALPN refusal.
6. **D6. B prerequisite.**
   - Require Stage B to replace `_inboundTails` (READ `machine_session.dart:989-995`) with synchronous in-order dispatch, and to make a re-hello close the connection (one session per connection).
   - A's per-stream fencing and hazard A both rely on this. Add both to B's step B3.
7. **D7. Stream caps.**
   - **Recommendation:** QUIC bidi limit on the bridge of 256 per connection.
   - Application caps per peer, below that limit: projects ≤ 32, terminal attachments ≤ 64, tunnel streams ≤ 128, pending opens ≤ 16.
   - App-side semaphores mirror the application caps.
   - The numbers need a decision. The layering does not.
8. **Plan open question 3 (B and A packaging).**
   - **Recommendation:** ship them separately, B first, each with its own FRAME_VERSION and ALPN.
   - Waves A1–A5 are individually wire-breaking but live on one branch, so only the final A version is released. A single B+A flag day would put the E2E removal and the transport rewrite into one untestable diff.