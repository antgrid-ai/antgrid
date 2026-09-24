# Stage A, wave A2: terminal attachment streams

This is the frozen contract for four parallel implementers: **bridge-src**, **bridge-tests**, **dart+app**
and **evals**. Each part builds against the names and shapes below. Nobody may rename or reshape anything
pinned here without the controller's say. If your half needs something this file does not provide, report it
as `outOfScopeNeeds`. Do not invent it.

Sources: `stage-A-waves.md` §3 "A2", the owner decisions in `ledger.md` (D1–D7, hazard J), and the A0/A1
review carry-overs (§3.7 below). HEAD at authoring time is `a4e7e3ac`: A0a–A0d and A1 are committed. Where
this file and the spec disagree, this file wins for A2. The deviations are listed in §9.

---

## 0. What A2 changes, in one screen

- **A terminal attachment gets its own QUIC stream** on the native path. The app opens it with the A0b open
  frame `{kind:"terminal", projectId, checkoutId, requestId}`. The bridge admits it with a new `terminal`
  handler plugged into A1's `PeerStreamAcceptor`.
- **What the stream carries.** After the open frame, each record body is the raw UTF-8 JSON of one
  `AbMessage`. It is not a peer frame, there is no `{s,m}` envelope and no channel label.
  - App to bridge: `terminal:subscribe` (exactly once, as the first record), `terminal:ack`,
    `terminal:unsubscribe` and `terminal:history:request`.
  - Bridge to app: `terminal:subscribed`, `terminal:frame`, `terminal:display:status` and
    `terminal:history:page`.
  - Nothing else rides it. `terminal:input`, `terminal:resize`, `terminal:start` and everything else stay on
    the project stream.
- **Routing.** It happens in the mux subscriber, **after** its existing per-send gates. `subscribed`, and a
  `display:status` that names no bound attachment (UPGRADE_REQUIRED, UNKNOWN_TERMINAL, DISPLAY_FAILED from a
  failed attach), are routed by `(peerId, requestId)`. Everything else is routed by `(peerId, attachmentId)`.
  A message with no bound stream falls back to today's session path, unchanged.
- **Admission.** Admission requires a catalogued, safe projectId whose project is currently attached to the
  mux (§3.3). An open never opens or promotes a core.
- **Priority.** A terminal stream's send half runs at `STREAM_PRIORITY_TERMINAL = 1`. That is above the
  session stream, which still carries every project stream until A4, at the binding default of 0.
- **Ends.**
  - When delivery retires the attachment, the bridge `finish()`es its half. The app treats that FIN as a
    retirement without an ENDED status.
  - When the app FINs or resets its send half, the bridge synthesizes `terminal:unsubscribe`.
  - An overflow or a lost stream resets only that stream (D3).
  - Only `unauthorized` closes the connection.
- **Loopback and the socket path are unchanged on the wire (D2).** `openTerminalAttachment` has a socket
  implementation that sends the same messages over the existing socket and demultiplexes replies by
  requestId/attachmentId.
- **delivery.ts carry-over.** A retirement no longer aborts frames already handed to the transport, and every
  attachment notice is handed to the transport before `retire()` (§3.6).
- **No new `AbMessage` type, and `protocol.ts` is untouched.** `FRAME_VERSION`, the ALPN (`antgrid/peer/2`) and
  every refusal code are unchanged.

---

## 1. Wire records

| Record | TS | Dart | Status |
|---|---|---|---|
| Open frame `{kind:"terminal", projectId, checkoutId?, requestId}` | `TerminalStreamOpen` (`packages/antgrid-wire/src/stream-open.ts`) | `TerminalStreamOpen({required projectId, required requestId, checkoutId})` (`models/stream_open.dart`) | unchanged (A0b) |
| `{type:"stream:refused", code, message}` | `StreamRefused`, `StreamRefusedCode` | `StreamRefused`, `StreamRefused.tryDecode` | unchanged (A1) |
| Terminal-stream record body | UTF-8 JSON of one `AbMessage` of the eight types in §0 | same, as `Map<String, dynamic>` | **NEW usage**, no new schema |

Rules the two sides share:
- **Open frame.** The app always sends `checkoutId`, including the literal `"main"`. The bridge normalizes an
  absent `checkoutId` to `"main"`. `requestId` must be the uuid the first record's `terminal:subscribe`
  carries, because the Zod schema of that message requires a uuid.
- **First app record.** It must be a `terminal:subscribe` with `requestId === open.requestId` and
  `(checkoutId ?? "main") === (open.checkoutId ?? "main")`.
- **Later app records.** Each must be `terminal:ack`, `terminal:unsubscribe` or `terminal:history:request`,
  with `terminalId` equal to the subscribe's, the same normalized `checkoutId`, and
  `attachmentId`/`runId` equal to the ones the bridge bound from its own `terminal:subscribed`. Such a record
  sent before `subscribed` was written is a breach.
- **First bridge record.**
  - After a refusal: exactly one `stream:refused` record, then FIN. This is A1's in-band refusal, and
    `StreamRefused.tryDecode` decodes it.
  - Otherwise: the bridge's first record is `terminal:subscribed`, or the requestId-addressed
    `terminal:display:status` that ends the attempt.
- **Order.** Records on one stream are delivered in the order the bridge enqueued them. That is the whole fix
  for hazards A and B on the native path (§9, D-1).

---

## 2. Caps and constants: where they live

| Constant | Value | Home | Mirror |
|---|---|---|---|
| `STREAM_TERMINAL_APP_RECORD_MAX_BYTES` (**NEW**) | `16_384` | `packages/antgrid-wire/src/stream-open.ts`, exported by name from `index.ts` | Dart `kStreamTerminalAppRecordMaxBytes` in `models/stream_open.dart`; fixture `streamOpen.terminalRecords.appMaxRecordBytes` |
| `STREAM_TERMINAL_BRIDGE_RECORD_MAX_BYTES` (**NEW**) | `2_097_152` | same | Dart `kStreamTerminalBridgeRecordMaxBytes`; fixture `streamOpen.terminalRecords.bridgeMaxRecordBytes` |
| `STREAM_MAX_TERMINAL_ATTACHMENTS_PER_PEER` | 64 (A0b) | `stream-open.ts` | `kStreamMaxTerminalAttachmentsPerPeer` (A0b) |
| `TERMINAL_STREAM_MAX_QUEUED_BYTES` (**NEW**) | `3 * 1024 * 1024` | `bridge/src/peer/terminal-streams.ts` | none (side-local) |
| `STREAM_PRIORITY_TERMINAL` (**NEW**) | `1` | `bridge/src/peer/terminal-streams.ts` | none; Dart has no priority |
| `STREAM_RESET_TERMINAL` (**NEW**) | `0x13n` | `bridge/src/peer/terminal-streams.ts` | none; Dart cannot read reset codes |
| `STREAM_STOP_TERMINAL` (**NEW**) | `0x14n` | `bridge/src/peer/terminal-streams.ts` | none |
| `kTerminalAttachmentMaxQueuedBytes` (**NEW**) | `65_536` | `packages/antgrid_relay_client/lib/src/terminal_attachment.dart` | none (side-local) |

- `STREAM_TERMINAL_BRIDGE_RECORD_MAX_BYTES` is the app reader's cap. It is set to twice the bridge's
  `TERMINAL_VIEWER_MAX_BYTES` (1 MiB), which is the largest frame delivery ever hands over. The wire package
  cannot import the bridge's constant, which sits across the licence boundary, so bridge-src states that
  derivation in a comment at the constant.
- `STREAM_TERMINAL_APP_RECORD_MAX_BYTES` is the bridge reader's cap for the four small app-to-bridge verbs.
- `TERMINAL_STREAM_MAX_QUEUED_BYTES` bounds one attachment's writer queue: one viewer window
  (`TERMINAL_VIEWER_MAX_BYTES`) plus four history pages plus notices. When it is exceeded, only that stream is
  reset (D3).
- The generator (`packages/antgrid-wire/scripts/gen-peer-transport-vectors.ts`) adds this under `streamOpen`:
  `"terminalRecords": { "appMaxRecordBytes": 16384, "bridgeMaxRecordBytes": 2097152 }`.
  Nothing else in the fixture changes.

---

## 3. Bridge API (bridge-src implements; bridge-tests tests against exactly this)

### 3.1 `bridge/src/peer/stream-records.ts` (extended)

```ts
send(frame: Uint8Array, signal?: AbortSignal): Promise<StreamSendOutcome>;
abort(): void;
```

**`send(frame, signal?)`**
- A record whose `signal` is already aborted is not queued, and resolves `"dropped"`.
- If the signal aborts while the record is still queued, before its first slice has been handed to
  `writeAll`, the record is removed from the queue, its bytes leave `queuedBytes`, and it resolves `"dropped"`.
- Once its first slice has been handed over, the record always completes, because a partial record would
  corrupt the framing.
- Without a signal, behaviour is unchanged.

**`abort()`**
- Sets the writer stopped, drops the queue so every waiter resolves `"dropped"`, and resolves the `finish()`
  waiters.
- Issues `void stream.send.reset(resetCode)`, never awaited. It does **not** call `onFailure`.
- It is idempotent, and a no-op after `finish()` has been issued or after the writer stopped.

Everything else in the file is unchanged, including the slicing, the one `setPriority` before the first write,
the per-record and per-slice `authorized()`, and `failConnection` only for `unauthorized`.

### 3.2 NEW `bridge/src/peer/terminal-streams.ts`

```ts
import type { TerminalStreamOpen } from "antgrid-wire";
import type { StreamHandler } from "./stream-dispatch";
import type { StreamSendOutcome } from "./stream-records";
import type { AbMessage } from "../protocol";
import type { PeerSessionView, TerminalProjectBinding } from "../stream-mux";

export const TERMINAL_STREAM_MAX_QUEUED_BYTES = 3 * 1024 * 1024;
export const STREAM_PRIORITY_TERMINAL = 1;
export const STREAM_RESET_TERMINAL = 0x13n;
export const STREAM_STOP_TERMINAL = 0x14n;
export const TERMINAL_STREAM_INBOUND_TYPES: ReadonlySet<string>;   // subscribe, ack, unsubscribe, history:request
export const TERMINAL_STREAM_OUTBOUND_TYPES: ReadonlySet<string>;  // subscribed, frame, display:status, history:page

export interface TerminalStreamRegistryOptions {
  /** host-server `seenProjects.has`. Absent => every open is refused NOT_ALLOWED (fail closed). */
  projectCataloged?: (projectId: string) => boolean;
  /** `StreamMux.projectBinding`. Lookup only: never opens or promotes a core. */
  projectBinding: (projectId: string) => TerminalProjectBinding | null;
  peerSession: (peerId: string) => PeerSessionView | null;
  /** Retires the whole connection. Only ever called with "unauthorized" (writer) or
   *  "protocol-violation" (a malformed length prefix from StreamRecordReader). */
  retirePeer: (peerId: string, reason: "unauthorized" | "protocol-violation") => void;
  diagnostic?: (type: string, detail: Record<string, unknown>) => void;
}

export class TerminalStreamRegistry {
  constructor(opts: TerminalStreamRegistryOptions);
  /** Plugged in as `handlers: { terminal: registry.handler }`. */
  readonly handler: StreamHandler<TerminalStreamOpen>;
  /** Called from the mux subscriber after its gates. Returns undefined when no stream is
   *  bound for this (peerId, message), and the caller then uses the session path. */
  route(peerId: string, msg: AbMessage, signal?: AbortSignal): Promise<StreamSendOutcome> | undefined;
  retired(peerId: string, attachmentId: string): void;
  subscribeSettled(peerId: string, requestId: string, attachmentId: string | undefined): void;
  projectDetached(projectId: string): void;
  /** Connection retired: unbind everything for the peer without dispatching anything. */
  dropPeer(peerId: string): void;
  /** Live bindings holding a cap slot for the peer (tests and diagnostics). */
  attachmentCount(peerId: string): number;
}
```

**Handler contract** (carry-over 2). Every refusal is decided **synchronously, before any read is issued on
`recv`**, and returned for the acceptor to write. Once the handler starts its read loop it never returns a
refusal. It returns `undefined` synchronously, having started the loop with `void`. The checks, in this order:

| # | Check | Refusal |
|---|---|---|
| 1 | `attachmentCount(peerId) >= STREAM_MAX_TERMINAL_ATTACHMENTS_PER_PEER` | `CAP_EXCEEDED` |
| 2 | `requestId` is not a uuid (`z.string().uuid()`) | `INVALID` |
| 3 | `!isSafeProjectId(projectId)` (`bridge/src/project-id.ts`) | `NOT_ALLOWED` |
| 4 | `projectCataloged` absent, or `!projectCataloged(projectId)` | `NOT_ALLOWED` |
| 5 | `projectBinding(projectId) === null` | `NOT_READY` |
| 6 | `binding.refusalFor(peerId)` is non-null | `UPDATE_REQUIRED` when its code is `"UPDATE_REQUIRED"`, else `NOT_ALLOWED` |
| 7 | the peer already has a live binding with this `requestId` | `INVALID` |

The acceptor has already covered authorization, the open-frame read, `NOT_READY` for an unestablished session
and the pending cap. Past step 7 the handler:
1. Binds `(peerId, requestId)`, taking a cap slot.
2. Builds `new StreamRecordWriter(stream, admission.authorized, onFailure, TERMINAL_STREAM_MAX_QUEUED_BYTES, STREAM_PRIORITY_TERMINAL, STREAM_RESET_TERMINAL)`.
3. Builds `new StreamRecordReader(stream, STREAM_TERMINAL_APP_RECORD_MAX_BYTES, () => retirePeer(peerId, "protocol-violation"))`.
4. Starts the read loop.

**Read loop.** For each record:
1. Parse it with `parseMessage` (full Zod, not `parseMessageFast`).
2. Check it against the §1 rules.
3. Hand it to `binding.dispatch(msg, peerId)`.

A record that fails parsing or the §1 rules is a **stream** breach, not a connection breach:
- `writer.abort()`, then unbind.
- Issue `void recv.stop(STREAM_STOP_TERMINAL)`, which is legal here because the loop's read has just completed.
- Exit the loop.

`dispatch` returning false (the project's entry has gone, or `refusalFor` now refuses) is handled the same
way.

A rejection from `reader.read()` is the app's FIN or reset:
- If the binding recorded `runId`/`attachmentId`/`terminalId`/`checkoutId` from its `subscribed` and is still
  bound, dispatch a synthesized `createMessage("terminal:unsubscribe", {...})` from `peerId`.
- Mark the binding `appEnded`.
- `writer.abort()`, because the app no longer reads.
- Unbind. The loop exits without calling `stop`.

A `StreamProtocolViolation` is left to the reader's `onFailure`, which closes the connection.

**Writer `onFailure`** (carry-over 3):
- `"unauthorized"`: `retirePeer(peerId, "unauthorized")`, the only connection-closing path.
- `"overflow"` or `"stream-lost"`: synthesize `terminal:unsubscribe` as above if an attachment is bound, then
  unbind and free the slot. The writer has already reset its half.

**`route(peerId, msg, signal)`**. `msg.type` must be in `TERMINAL_STREAM_OUTBOUND_TYPES`, otherwise the result
is `undefined`. Then:
- `terminal:subscribed`: look up by `requestId`.
  - On a hit, record `attachmentId`, `runId`, `terminalId` and normalized `checkoutId`, index the binding
    under `(peerId, attachmentId)`, then enqueue.
  - If the binding is `appEnded` or its writer is finishing, return `Promise.resolve("dropped")`. The mux then
    throws for the signal, and `subscribe()`'s own catch retires the attachment.
- `terminal:display:status`: look up by `attachmentId` if present, else by `requestId`.
- `terminal:frame` and `terminal:history:page`: look up by `attachmentId` only.
- **Enqueueing** is `writer.send(utf8(JSON.stringify(msg)), signal)`.
  - A body over `STREAM_TERMINAL_BRIDGE_RECORD_MAX_BYTES` is not enqueued: it resolves `"dropped"` and emits a
    diagnostic. This is unreachable while delivery caps frames at 1 MiB.
- No binding gives `undefined`, and the message takes the session path. This includes history for an attachment
  that has already been unbound.

**Retirement, settle and unbind**:
- `retired(peerId, attachmentId)`: if the binding is `appEnded`, it is already unbound. Otherwise
  `void writer.finish()` and unbind. Frames and the notice queued before this call drain first, then FIN.
- `subscribeSettled(peerId, requestId, attachmentId)`: when `attachmentId` is `undefined` and the requestId
  binding never recorded an attachment, `void writer.finish()` and unbind. This is how UPGRADE_REQUIRED,
  UNKNOWN_TERMINAL, a failed attach and every silent `break` in agent-core end the stream. Otherwise it is a
  no-op.
- **Unbind** removes both index entries and frees the cap slot exactly once. After an unbind the read loop
  keeps reading only to observe the app's end. Any further record gets a discard, `void recv.stop(STREAM_STOP_TERMINAL)`
  and loop exit.
- `projectDetached(projectId)`: every binding for that project gets `writer.abort()` and is unbound. No
  unsubscribe is synthesized, because the core is gone.
- `dropPeer(peerId)`: bumps the peer's generation, then aborts and unbinds everything for it without
  dispatching. Every binding captures its peer generation at admission. A callback such as `onFailure`, a
  reader failure or a loop step from a binding whose generation is stale does nothing, and in particular never
  calls `retirePeer` on a newer connection for the same peerId.

### 3.3 `bridge/src/stream-mux.ts`

```ts
export interface TerminalStreamHooks {
  retired(peerId: string, attachmentId: string): void;
  subscribeSettled(peerId: string, requestId: string, attachmentId: string | undefined): void;
}

export interface TerminalProjectBinding {
  readonly streamId: string;
  /** entry.opts.mayAcceptFrom(peerSession(peerId)), re-read on every call. */
  refusalFor(peerId: string): StreamRefusal | null;
  /** Re-resolves the entry by streamId and re-runs refusalFor. Then the same
   *  unbound retraction dispatchInbound does (markBound), then
   *  entry.bus.dispatchInbound(msg, "control", "relay", peerId). False when the entry has
   *  gone or refusalFor refuses. */
  dispatch(msg: AbMessage, peerId: string): boolean;
}

// StreamHandle gains ONE optional member:
terminalHooks?: TerminalStreamHooks;

// StreamMuxTransport gains three OPTIONAL members:
routeTerminal?(peerId: string, msg: AbMessage, signal?: AbortSignal): Promise<StreamSendOutcome> | undefined;
terminalHooks?: TerminalStreamHooks;
projectDetached?(projectId: string): void;

// StreamMux gains:
projectBinding(projectId: string): TerminalProjectBinding | null;
```

- **`projectBinding`** returns the most recently attached live entry whose `opts.projectId === projectId`, or
  `null`. It is a lookup only.
- **In `attach()`'s subscriber `deliver`**, after `canSend()` has passed, and only when `peerId` is set:
  - `const routed = this.transport.routeTerminal?.(peerId, msg, signal)`.
  - When `routed` is not `undefined`, it replaces `sendEnvelope`, with the same signal handling: if a signal
    was given, reject with `Terminal delivery ${outcome}` on anything other than `"sent"`.
  - `mayDeliver`, `mayDeliverTo`, `gated()` and `unboundAtPeer` are therefore still evaluated per send, at
    enqueue time.
  - Remote access is additionally rechecked per record by the writer's `authorized()`.
- **`attach()`** returns `terminalHooks: this.transport.terminalHooks` on the handle.
- **`detach(streamId)`** calls `this.transport.projectDetached?.(projectId)` when no other live entry has that
  projectId.
- **Naming.** `StreamRefusal` here and in `stream-dispatch.ts` stay as they are. `terminal-streams.ts` imports
  the dispatch one under an alias.

### 3.4 `bridge/src/peer-session-owner.ts` and `bridge/src/peer/native-host-connection.ts`

`PeerSessionOwner`'s constructor passes the three new transport members to `new StreamMux({...})`. The members
are late-bound lambdas over new protected methods, whose defaults do nothing:

```ts
protected routeTerminalMessage(peerId: string, msg: AbMessage, signal?: AbortSignal): Promise<StreamSendOutcome> | undefined; // undefined
protected terminalRetired(peerId: string, attachmentId: string): void;                                           // no-op
protected terminalSubscribeSettled(peerId: string, requestId: string, attachmentId: string | undefined): void;   // no-op
protected terminalProjectDetached(projectId: string): void;                                                      // no-op
```

`NativePeerOptions` gains `projectCataloged?: (projectId: string) => boolean`.

`NativePeerSessions`:
- Owns one `TerminalStreamRegistry`, built with `projectCataloged: this.nativeOpts.projectCataloged`,
  `projectBinding: (id) => this.mux.projectBinding(id)`, `peerSession` and `retirePeer`. The `retirePeer`
  passed in is guarded: it acts only while `nativePeers.get(peerId)` is still the admitting peer.
- Overrides the four protected methods to delegate to the registry.
- `acceptPeer` passes `handlers: { terminal: this.terminalStreams.handler }`.
- `retirePeer` calls `this.terminalStreams.dropPeer(peerId)` right after `peer.streams?.stop()`.

### 3.5 `bridge/src/agent-core.ts`, `bridge/src/project-core.ts`, `bridge/src/host-server.ts`

**agent-core.ts**
- The `AgentCore` interface gains `setTerminalStreamHooks(hooks: TerminalStreamHooks | null): void`, declared
  beside `setPeerSessionProvider`.
- `viewerTransportFor(source)` gains
  `retired(_address, attachmentId) { if (source !== "loopback") terminalStreamHooks?.retired(source, attachmentId); }`.
- **`terminal:subscribe` case.** For a non-loopback `client`, every exit calls
  `terminalStreamHooks?.subscribeSettled(client, msg.requestId, attachmentId)`. The exits are the three
  `break`s, the `.then` (with the attachmentId it resolved, or `undefined`) and the `.catch`. In the `.catch`
  the call comes **after** the DISPLAY_FAILED notice has been handed to `sendAbToItsChannel`.
- **Invariant stated at the code.** From `transport.send` down to the registry's `writer.send`, the chain is
  synchronous: agent-core `send` → `sendTerminalTo` → `bus.deliverTo`, which calls `deliver` in its loop →
  mux `deliver` → `routeTerminal` → `writer.send`. That is what lets a notice handed over before `retire()` be
  queued ahead of the `finish()` that `retired` triggers. Nothing may insert an `await` into it.
- **Replace the comment above `sendPreviewAbTo`**, which wrongly calls `TERMINAL_CONNECTION_MAX_BYTES` "half
  `CHANNEL_WINDOW_BYTES`" when the two are equal. The new comment must say two things:
  - on the session path, terminal bulk rides "preview" so that a full terminal budget cannot occupy the control
    channel's whole credit window;
  - on the native path, an attachment with its own stream bypasses both channels, and
    `TERMINAL_CONNECTION_MAX_BYTES` then bounds only unacknowledged frame bytes per client.

**project-core.ts**
- `attachRelayStream` calls `core.setTerminalStreamHooks(handle.terminalHooks ?? null)` beside
  `setPeerSessionProvider`.
- Every teardown that nulls `setPeerSessionProvider` also calls `core.setTerminalStreamHooks(null)`.

**host-server.ts**
- `remoteDepsFor`'s handle wrapper forwards `terminalHooks: handle.terminalHooks`.
- The `native:` options block passes `projectCataloged: (projectId) => this.seenProjects.has(projectId)`.
- No other change. `project:start` keeps its order, and a stream open never touches `cores`.

### 3.6 `bridge/src/terminal-frames/delivery.ts` (carry-over 1)

- `private retire(attachment, opts?: { abortQueued?: boolean })`. The default is `true`, which is today's
  behaviour.
  - With `abortQueued: false` the attachment's `controller` is **not** aborted, so frames already handed to
    `transport.send` keep their signals and are written.
  - The byte accounting, `hub.schedule()` and the `retired` notification are unchanged.
- The ENDED branch in `tick` and `retireRun`: hand ENDED to `safeSend`, then `retire(attachment, { abortQueued: false })`.
- `fail()`: hand the status to `safeSend` **first**, then `retire(attachment)`.
- The rule, stated at `retire`: every attachment-scoped notice is handed to the transport before the
  retirement that follows it.

### 3.7 Carry-overs from the A0/A1 reviews: where each lands

| # | Carry-over | Lands in |
|---|---|---|
| 1 | ENDED after its frames, and retirement does not abort queued frames | §3.6, plus the FIFO writer and `finish()` in §3.2 |
| 2 | No refusal returned with a read outstanding | §3.2 handler contract |
| 3 | `finish()` for an orderly end, close only on `unauthorized`, overflow unbinds one stream | §3.2 writer `onFailure`, `retired` |
| 4 | Dart stream-open failure is not a sticky peer rejection | §4.3 |

---

## 4. Dart API (dart+app)

### 4.1 NEW `packages/antgrid_relay_client/lib/src/terminal_attachment.dart`

This file is exported from `antgrid_relay_client.dart`. It is new Apache code: write it fresh, and do not move
or copy anything from `app/` into it.

```dart
const int kTerminalAttachmentMaxQueuedBytes = 65536;

sealed class TerminalAttachmentEnd { const TerminalAttachmentEnd(); }
/// Stream path only: the bridge's half ended (FIN or reset; Dart cannot tell them apart).
final class TerminalAttachmentPeerEnded extends TerminalAttachmentEnd { const TerminalAttachmentPeerEnded(); }
final class TerminalAttachmentRefused extends TerminalAttachmentEnd { const TerminalAttachmentRefused(this.refusal); final StreamRefused refusal; }
/// Local failure: 'CAP_EXCEEDED', 'NO_PROJECT', 'STREAM_OPEN_FAILED', 'SEND_FAILED', 'INVALID_RECORD'.
final class TerminalAttachmentFailed extends TerminalAttachmentEnd { const TerminalAttachmentFailed(this.code, [this.error]); final String code; final Object? error; }
final class TerminalAttachmentTransportClosed extends TerminalAttachmentEnd { const TerminalAttachmentTransportClosed(); }
final class TerminalAttachmentClosedLocally extends TerminalAttachmentEnd { const TerminalAttachmentClosedLocally(); }

abstract interface class TerminalAttachment {
  String get requestId;
  String get checkoutId;
  /// True when this attachment rides its own native stream.
  bool get isStream;
  /// Every message for this attachment, in arrival order, exactly once. Single-subscription,
  /// buffered until listened to, closed when [done] completes.
  Stream<Map<String, dynamic>> get messages;
  /// Never throws. After [done] it is a no-op.
  Future<void> send(Map<String, dynamic> message);
  /// Idempotent. Sends nothing by itself: a caller holding an attachment sends
  /// terminal:unsubscribe through [send] first, as today.
  Future<void> close();
  Future<TerminalAttachmentEnd> get done;
}

/// The socket-path implementation used by every BufferedAgentTransport and by FakeAgentTransport.
class SocketTerminalAttachments {
  SocketTerminalAttachments(Future<void> Function(Map<String, dynamic> message) send);
  TerminalAttachment open({required String requestId, required String checkoutId, required Map<String, dynamic> subscribe});
  /// True when [json] belonged to an open attachment and was delivered to it; the caller must then not publish it.
  bool divert(Map<String, dynamic> json);
  /// Ends every open attachment TerminalAttachmentTransportClosed.
  void closeAll();
  @visibleForTesting
  void endAttachment(String requestId, TerminalAttachmentEnd end);
}
```

**`divert` rules.** The lookup table is open attachments only.
- `terminal:subscribed` whose `requestId` matches an attachment with no attachmentId yet: deliver it and record
  its `attachmentId`.
- `terminal:display:status`: deliver it if its `attachmentId` matches a recorded one, otherwise if its
  `requestId` matches.
- `terminal:frame` and `terminal:history:page`: deliver when the `attachmentId` matches.
- Anything else returns false.

`open()` sends `subscribe` through the injected `send`. After `close()` the attachment is removed from the
table, so a late reply reaches `messages` and today's stale-reply handling.

### 4.2 `AgentTransport`, `BufferedAgentTransport`, `FakeAgentTransport`

**`agent_transport.dart`** gains an abstract method:

```dart
/// [subscribe] is the complete terminal:subscribe message, checkoutId already stamped,
/// with subscribe['requestId'] == requestId. Returns synchronously; never throws.
TerminalAttachment openTerminalAttachment({
  required String requestId,
  required String checkoutId,
  required Map<String, dynamic> subscribe,
});
```

**`buffered_agent_transport.dart`**:
- Adds `late final SocketTerminalAttachments terminalAttachments = SocketTerminalAttachments((m) => send(m));`.
- The default `openTerminalAttachment` returns `terminalAttachments.open(...)`.
- `dispatchDecoded` runs `if (terminalAttachments.divert(json)) return;` after its `response` branch.
- `dispose()` calls `terminalAttachments.closeAll()`.

`LocalTransport`, `DemoTransport`, `_TestTransport` and `_OutcomeTransport` inherit all of this and need no
edit. DemoTransport already routes its fabricated replies through `dispatchDecoded`; dart+app verifies that
this includes its `terminal:subscribed` reply.

**`FakeAgentTransport`** (`app/lib/test_helpers/fake_agent_transport.dart`):
- Holds a `SocketTerminalAttachments` over its own `send`, so the subscribe lands in `sent` exactly as today.
- `openTerminalAttachment` delegates to it.
- `emitJson` diverts first.
- Exposes `endTerminalAttachment(String requestId, TerminalAttachmentEnd end)` for tests.

### 4.3 `machine_session.dart`: `MachineSession` and `StreamTransport`

`MachineSession` gains:
- `String? projectIdForStream(String streamId)`: the reverse of `_projectStreamIds`.
- An internal fail-fast count of terminal attachments, capped at `kStreamMaxTerminalAttachmentsPerPeer`. The
  count is internal to the package, so the names are free.

`StreamTransport.openTerminalAttachment` works as follows.
- **When `session.relay is! MultiStreamPeerLink`,** it uses the inherited socket path.
  `fake_live_relay.dart` takes this branch.
- **Otherwise** it returns a stream-backed handle immediately and does the following asynchronously:
  1. Take a slot. If none is free, end `TerminalAttachmentFailed('CAP_EXCEEDED')`.
  2. Resolve `projectId = session.projectIdForStream(streamId)`. If it is `null`, end `Failed('NO_PROJECT')`.
  3. `await (session.relay as MultiStreamPeerLink).openStream(TerminalStreamOpen(projectId: .., requestId: .., checkoutId: checkoutId), maxRecordBytes: kStreamTerminalBridgeRecordMaxBytes, maxQueuedBytes: kTerminalAttachmentMaxQueuedBytes)`.
     - **Carry-over 4.** Every throw is caught (`catch (e)`, whatever its type, including
       `PeerConnectionFailure(terminal: true)` from a closed link) and ends `Failed('STREAM_OPEN_FAILED', e)`.
     - Such a failure is never rethrown, never added to any `failureStream`, and never reported to the
       connection supervisor.
  4. Send `utf8.encode(jsonEncode(subscribe))` as the first record. If the outcome is not `accepted`, call
     `await stream.reset()` and end `Failed('SEND_FAILED')`.
  5. **Records.** If the first record is a `StreamRefused.tryDecode` hit, end `Refused`. Every other record is
     `jsonDecode`d to a map and added to `messages`. A record that is not a JSON map gets `reset()` and ends
     `Failed('INVALID_RECORD')`.
  6. **When records complete (done or error)**, always call `await stream.finish()` on the send half (a no-op
     if it was already finished), end `PeerEnded` (unless the attachment already ended), and release the slot.
  7. **`close()`.**
     - Before the open resolves: mark it closed; when the open resolves, `reset()` it and release the slot.
     - After the open: `await stream.finish()`, end `ClosedLocally`, and keep draining `records` to completion
       without delivering them. The slot is released at that completion.
  8. **Every error path calls `reset()` explicitly.** A dropped noq SendStream FINs, and a FIN is an orderly
     unsubscribe.
- The session going down (records end) is `PeerEnded`. Socket-path attachments on a StreamTransport end
  `TransportClosed` when the session stops being established.

### 4.4 `app/lib/services/terminal_service.dart`

**Sending.**
- The subscribe path replaces `session.sendForCheckout(subscribe)` with
  `session.transport.openTerminalAttachment(requestId: .., checkoutId: .., subscribe: <the same message, checkoutId stamped exactly as sendForCheckout stamps it>)`.
- Keep one attachment handle per terminalId.
- `ack`, `unsubscribe` and `history:request` for the attachment go through `handle.send`, stamped the same way.
- A history request for an attachment with no live handle, such as `_endedHistoryAttachment`, still goes
  through `sendForCheckout`, and its page comes back on the project stream.

**Receiving.**
- `handle.messages` feeds the same frame, subscribed, status and history handlers the router feeds today, after
  the same checkout filter.
- The router subscriptions stay, for anything the handle did not claim.

**Closing.** Everything that unsubscribes today (`suspendDisplay`, supersede, deletion, dispose) sends
`terminal:unsubscribe` through the handle when an attachment is bound, then calls `close()`. The subscribe
deadline closes the handle.

**How each end is handled:**
- `PeerEnded` while `_drainingEnded` holds the terminal: finish the drain now. The bridge wrote ENDED after
  its final frames, so nothing more is coming.
- `PeerEnded` right after a terminal status (ENDED, UNKNOWN_TERMINAL, UPGRADE_REQUIRED, ACK_TIMEOUT, or a
  latching DISPLAY_FAILED): the status handling already ran, so the end is a no-op.
- A bare `PeerEnded` the service did not cause (a bridge overflow or lost-stream reset, D3):
  - clear the frame tracking for that terminal;
  - re-subscribe once with a fresh requestId, but only if the terminal is still displayed and
    `transport.isEstablished`;
  - allow at most one such re-subscribe per terminal until a frame is next accepted, so it cannot loop;
  - otherwise leave it to the existing re-establish path.
- `Refused`, `Failed`, `TransportClosed`: treat it as a subscribe that got no reply. Clear the pending subscribe
  and leave re-subscription to the existing triggers. Never re-subscribe from the end handler.
- `ClosedLocally`: nothing.

Every existing test in `app/test/services/terminal_*_test.dart` must pass **unedited**. They run on
FakeAgentTransport's socket path, which puts the same messages in `sent`. Needing to edit one is a regression
signal, to be reported rather than patched.

### 4.5 Eval client `packages/antgrid_eval_client/lib/src/commands.dart` (dart+app)

New actions:

| Action | Fields | Effect and events |
|---|---|---|
| `terminal-attach` | `streamId`, `terminalId`, `requestId`, `checkoutId?` (default `"main"`), `version` (required; the Bun wrapper passes `TERMINAL_PROTOCOL_VERSION` from `bridge/src/terminal-frames/protocol.ts` unless a test overrides it, because the eval client cannot import `app/`'s `kTerminalFrameProtocolVersion`) | `_session!.streamFor(streamId).openTerminalAttachment(...)` with a `terminal:subscribe` built by `_createAbMessage`. It emits `{'event':'terminal-attach-opened','requestId','isStream'}`, then one `{'event':'terminal-attach-message','requestId','data': <json>}` per message, then `{'event':'terminal-attach-end','requestId','end': 'peerEnded'|'refused'|'failed'|'transportClosed'|'closedLocally','code'?: <refusal wire code or failure code>}` |
| `terminal-attach-send` | `requestId`, `data` | `handle.send(data)` |
| `terminal-attach-close` | `requestId` | `handle.close()` |

`_disposeAll` closes every open handle.

---

## 5. Test seams after A2

| Seam | After A2 |
|---|---|
| `bridge/tests/test-peer-session-owner.ts` | **Unchanged.** It inherits `PeerSessionOwner`'s no-op terminal methods, so every terminal message it sees takes the session path exactly as today. Tests that need stream routing use `terminal-streams.test.ts`'s fakes. |
| `packages/antgrid_relay_client/test/support/fake_live_relay.dart` | **Unchanged.** It implements `PeerLink` only, so `StreamTransport` uses the socket path over it. |
| `evals/helpers/relay-client.ts` | **NEW** `openTerminalStream`, below. The existing A1 methods are unchanged. |
| `evals/support/` (`openProjectStream`/`sendOnStream`) | **Unchanged.** Input and resize, and the legacy project-stream subscribe that `gate-terminal-frames` uses, still ride it (§9, D-3). |
| `packages/antgrid_eval_client/lib/src/commands.dart` | Three new actions (§4.5), owned by dart+app. |
| `evals/helpers/dart-app-client.ts` | **NEW** wrappers over the §4.5 actions, owned by evals: `terminalAttach(streamId, opts: { terminalId; requestId; checkoutId?; version? })` (it always sends `version`, defaulting to `TERMINAL_PROTOCOL_VERSION`), `terminalAttachSend(requestId, data)`, `terminalAttachClose(requestId)`, and `waitForTerminalAttach(requestId, predicate, timeoutMs?)`, which matches `terminal-attach-*` events. |

The new method on the evals `RelayClient`:

```ts
export interface TerminalStreamClient {
  /** Every record received so far, JSON-parsed (AbMessage or stream:refused), in arrival order. */
  readonly records: Array<Record<string, any>>;
  /** First record, already received or arriving before timeoutMs (default 10_000), matching predicate. */
  next(predicate: (record: Record<string, any>) => boolean, timeoutMs?: number): Promise<Record<string, any>>;
  /** Writes one [u32 BE len][UTF-8 JSON] record. */
  send(msg: AbMessage | Record<string, unknown>): Promise<void>;
  /** Orderly end of the app's send half. */
  finish(): Promise<void>;
  /** send.reset(0n), not awaited. */
  reset(): void;
  /** Resolves (never rejects) when the bridge's half has ended, by FIN or reset. */
  readonly ended: Promise<void>;
}
/** openBi on the live native connection; writes the terminal open frame
 *  (encodeStreamOpen({kind:"terminal", ...})) as the first record; then reads records until the end
 *  with StreamRecordReader (bridge/src/peer/stream-records.ts), capped at
 *  STREAM_TERMINAL_BRIDGE_RECORD_MAX_BYTES. It does NOT send the subscribe: the test sends it. */
openTerminalStream(open: { projectId: string; requestId: string; checkoutId?: string }): Promise<TerminalStreamClient>;
```

---

## 6. Tests: added, changed, deleted

The spec's named cases map as follows:
- **A7 hazards A and B on the native path**: `gate-terminal-streams` rows 1–2, `terminal-streams.test.ts`,
  and app `terminal_stream_attachment_test.dart`.
- **Refused without a project binding**: `gate-terminal-streams` row 7 and `terminal-streams.test.ts`.
- **Loopback terminal unchanged**: `local-terminal.test.ts`, `gate-terminal-frames.test.ts` and every existing
  app terminal test stay green unedited. The LocalTransport test is new.
- **`TERMINAL_VIEWER_MAX_FRAMES` backpressure over a stream**: `gate-terminal-streams` row 4.
- **Carry-over 1 (ENDED after frames)**: `terminal-frame-delivery.test.ts` and `terminal-streams.test.ts`.
- **Carry-over 4 (open failure not sticky)**: `terminal_attachment_test.dart`.

### bridge-tests

**NEW `bridge/tests/terminal-streams.test.ts`.** It drives `TerminalStreamRegistry` with fakes.
- The fake send half **models the binding mutex**: `reset`, `finish` and `setPriority` await any pending
  `writeAll`.
- The fake recv models the same for `stop` against a pending `readExact`.
- Neither fake defines `stopped` or `receivedReset`.
- A fake `TerminalProjectBinding` records dispatches.

The cases:
- `each refusal is decided before any read: CAP_EXCEEDED, INVALID requestId, NOT_ALLOWED unsafe id, NOT_ALLOWED uncatalogued, NOT_READY unbound, UPDATE_REQUIRED, INVALID duplicate requestId`. Asserts that `readExact` was never called for any of them.
- `an absent projectCataloged fails closed with NOT_ALLOWED`
- `an admitted stream sets STREAM_PRIORITY_TERMINAL once, before its first write`
- `the first record must be the matching terminal:subscribe; anything else aborts only that stream and stops its receive half after the read completed`
- `ack, unsubscribe and history:request naming another attachment, terminal or checkout abort only that stream`
- `a record over STREAM_TERMINAL_APP_RECORD_MAX_BYTES retires the connection as a protocol violation`
- `subscribed routes by requestId and binds the attachment; frames, history pages and attachment statuses then route by attachmentId`
- `a requestId-addressed display:status routes to the stream and subscribeSettled(undefined) then finishes it`
- `an unbound message returns undefined for the session path, including history for an unbound attachment`
- `retired() writes every frame and the ENDED queued before it, then FINs (carry-over 1)`
- `the app's FIN synthesizes terminal:unsubscribe with the bound runId and attachmentId, aborts the writer and frees the slot`
- `the app's FIN before subscribed makes subscribed resolve dropped`
- `writer overflow resets only that stream, synthesizes unsubscribe and frees the slot; the connection lives`
- `writer unauthorized retires the connection`
- `projectDetached aborts every binding for the project`
- `dropPeer unbinds without dispatching, and a stale binding's failure never retires a newer connection`
- `an aborted signal removes a queued frame before its first slice`

**`bridge/tests/stream-records.test.ts`**
- NEW `send() with an already-aborted signal is dropped without queueing`
- NEW `a signal aborted while queued removes the record and frees its queued bytes`
- NEW `a signal aborted after the first slice lets the record complete`
- NEW `abort() drops the queue, resets without awaiting, and never calls onFailure`
- NEW `abort() after finish() is a no-op`

**`bridge/tests/stream-mux.test.ts`**
- NEW `projectBinding returns the latest live entry for a projectId and null after detach`
- NEW `binding.dispatch re-runs mayAcceptFrom and reaches the bus as relay with the peerId`
- NEW `routeTerminal runs only after mayDeliver, mayDeliverTo and unboundAtPeer allow the send`
- NEW `a routed send replaces sendEnvelope, and an undefined route falls back to it`
- NEW `a routed non-sent outcome rejects a signalled delivery`
- NEW `detach calls projectDetached only when no other entry holds the project`
- NEW `attach returns the transport's terminalHooks on the handle`

**`bridge/tests/terminal-frame-delivery.test.ts`** (hub section)
- NEW `retireRun hands ENDED to the transport after every queued frame and aborts none of them`
- NEW `the ENDED tick path retires without aborting frames already handed over`
- NEW `fail() hands its status to the transport before retired() fires`
- The existing `every retirement the hub performs on its own clock is reported to the transport` must pass
  unchanged.

**`bridge/tests/terminal-frame-channel.test.ts`**
- Its existing channel expectations are **unchanged**, because routing moved below the core (§9, D-4).
- NEW `retired and subscribeSettled reach the terminal stream hooks with the relay peerId and never for loopback`
- NEW `every exit of a relay terminal:subscribe calls subscribeSettled once`. It covers the unknown terminal, a
  generation mismatch, the success path, and an attach failure after its DISPLAY_FAILED.

**`bridge/tests/project-core.test.ts`**
- NEW `attachRelayStream wires handle.terminalHooks into the core, and every teardown clears them`

**`bridge/tests/native-host-connection.test.ts`**
- NEW `a terminal-kind stream reaches the terminal handler (no longer refused NOT_ALLOWED)`. It uses a fake mux
  entry via `attachStream` and `projectCataloged: () => true`.
- NEW `a terminal-kind stream is refused NOT_ALLOWED when projectCataloged is not supplied`
- NEW `retiring a peer drops its terminal bindings`

**`packages/antgrid-wire/tests/stream-open.test.ts`**
- NEW `terminal record caps are exported from the package root as 16384 and 2097152`.

### dart+app

**NEW `packages/antgrid_relay_client/test/terminal_attachment_test.dart`**
- `socket path sends subscribe through send and diverts subscribed, frames, statuses and pages for its attachment only`
- `a requestId-addressed status reaches the attachment before subscribed`
- `after close() a late reply is not diverted`
- `closeAll ends every open attachment TransportClosed`
- `StreamTransport over a PeerLink that is not multi-stream uses the socket path`
- Stream path, with a local fake `MultiStreamPeerLink` and `PeerStream`:
  - `opens TerminalStreamOpen with the session's projectId and sends subscribe as the first record`
  - `records arrive on messages in record order (hazards A and B)`
  - `a stream:refused first record ends Refused`
  - `bridge FIN ends PeerEnded, finishes the send half and releases the slot`
  - `close() finishes the send half and ends ClosedLocally`
  - `an openStream throw ends Failed(STREAM_OPEN_FAILED) and never reaches failureStream (carry-over 4)`
  - `the 65th concurrent attachment ends Failed(CAP_EXCEEDED) without opening`
  - `a send outcome other than accepted resets the stream`
  - `an unknown projectId for the stream ends Failed(NO_PROJECT)`

**NEW `packages/antgrid_relay_client/test/local_transport_terminal_attachment_test.dart`**. It uses the same
local server fixture as `local_transport_connect_test.dart`.
- `LocalTransport.openTerminalAttachment sends the subscribe over the socket unchanged and diverts that attachment's replies away from messages`
- `unmatched terminal messages still reach messages`

**NEW `app/test/services/terminal_stream_attachment_test.dart`**. It uses FakeAgentTransport's
`endTerminalAttachment`.
- `PeerEnded during an ENDED drain completes the run immediately`
- `a bare PeerEnded re-subscribes once with a fresh requestId, and not again until a frame is accepted`
- `a bare PeerEnded while the transport is not established does not re-subscribe`
- `Refused and Failed clear the pending subscribe without re-subscribing`
- `ack, unsubscribe and history requests go through the attachment, stamped like sendForCheckout`
- `history for an ended attachment goes through sendForCheckout`

**`packages/antgrid_peer_transport/test/peer_transport_vectors_test.dart`**
- The existing caps test also asserts `kStreamTerminalAppRecordMaxBytes` and `kStreamTerminalBridgeRecordMaxBytes`
  against `streamOpen.terminalRecords`.

### evals

**NEW `evals/tests/gate-terminal-streams.test.ts`.** It uses `setupTestEnv()` with the native app client.
Terminals are started and driven over the first project stream (`sendOnStream`), and every subscribe goes over
`openTerminalStream`. The cases, one row each:
1. `a terminal stream carries subscribed first, then frames in increasing sequence, and nothing for its attachment rides the project stream` (hazard A)
2. `ENDED arrives on the stream after the frame at finalSequence, then the bridge ends the stream` (hazard B, using a guest that exits)
3. `input and resize stay on the project stream and still reach the attached screen`
4. `a never-acked consumer is capped at TERMINAL_VIEWER_MAX_FRAMES in flight on its stream and resumes after an ack`
5. `finishing the app's half unsubscribes: frames stop, the bridge ends its half, and a fresh stream subscribes again`
6. `resetting the app's half unsubscribes the same way`
7. `a terminal stream for a catalogued project with no binding is refused NOT_READY in-band and the session stays up`. The project is catalogued with `loopbackControl` `project:open` then `project:stop`, as `multi-stream-coexistence.test.ts` does.
8. `a terminal stream naming an uncatalogued project is refused NOT_ALLOWED and the session stays up`
9. `a first record that is not the matching subscribe ends only that stream and the session stays up`
10. `an unknown terminal is answered UNKNOWN_TERMINAL by requestId on the stream, then the stream ends`
11. `an unsupported version is answered UPGRADE_REQUIRED by requestId on the stream, then the stream ends`
12. `history paging over a terminal stream returns its pages on the stream`

"The session stays up" has A1's meaning: `nativeConnectionId` is unchanged **and** a `state.snapshot` on the
session stream answers `ok`.

**`evals/scenarios/dart-client-e2e/dart-terminal.test.ts`**
- NEW `a frame subscription rides its own terminal stream: subscribed then frames, acked, and an unsubscribe ends it`.
  It asserts `isStream: true`, receives `subscribed` and at least one frame, sends an ack via
  `terminalAttachSend`, sends `terminal:unsubscribe` and then `terminalAttachClose`, and expects
  `terminal-attach-end` to be `closedLocally` or `peerEnded`.

**Fixture and helpers**
- `evals/fixtures/peer-transport-vectors.json`: add `streamOpen.terminalRecords` only (§2).
- `evals/helpers/relay-client.ts` and `evals/helpers/dart-app-client.ts`: see §5.

**Nothing is deleted.** `gate-terminal-frames.test.ts`, `local-terminal.test.ts` and `gate-stream-admission.test.ts` are unedited.

### Gate (controller, once, after integration)

- `ALL`, as defined in `stage-A-waves.md` §3.
- `bun run --filter antgrid-evals test:evals`.
- `qualify:iroh-interop` and `qualify:iroh-host`. They are unchanged: the interop probe still opens a
  project-kind stream, which is still `NOT_ALLOWED`.
- `bun run --filter antgrid-wire gen:peer-vectors`, then `git diff` on the fixture must show only the
  `terminalRecords` addition.
- One `flutter analyze` run, from the controller only.
- Known bridge red: 6 stale-runId failures (index-hook-subcommand ×1, plugin/antigravity-post-title ×3,
  plugin/opencode-notify ×2) plus the two git-test flakes.
- `gate-vectors.test.ts`'s git-clean guard is red on the uncommitted fixture until the wave commit.

---

## 7. Call sites found by grep (rename and change sweep)

| Symbol | Hits | Owner and action |
|---|---|---|
| `AgentTransport` implementers | `BufferedAgentTransport` (`buffered_agent_transport.dart`, via its subclasses `LocalTransport`, `StreamTransport`, `DemoTransport`, `_TestTransport` in `hydrate_action_contract_test.dart`, `_OutcomeTransport` in `remote_request_outcome_test.dart`); `FakeAgentTransport` (implements directly) | dart+app. Only `BufferedAgentTransport`, `StreamTransport` and `FakeAgentTransport` are edited; the rest inherit |
| `StreamHandle` wrapper that must forward the new member | `host-server.ts` `remoteDepsFor` | bridge-src |
| `StreamHandle` literals in tests (`sendTunnel: ...`) | `control-plane-start`, `host-promotion`, `host-server`, `pause-streams`, `project-core`, the push-targeting tests, `relay-promotion`, `remote-access-gate` | **no edit**: `terminalHooks` is optional |
| `StreamMuxTransport` implementers | `peer-session-owner.ts` constructor, and stubs in `stream-mux.test.ts` | bridge-src; bridge-tests (stubs need no edit because the new members are optional) |
| `handlers: {}` | `native-host-connection.ts` `acceptPeer` | bridge-src |
| `retire(` / `retireRun` / `fail(` | `delivery.ts` only | bridge-src |
| `setPeerSessionProvider(null)` teardown sites | `project-core.ts` (three sites) | bridge-src: add `setTerminalStreamHooks(null)` at each |
| `"half \`CHANNEL_WINDOW_BYTES\`"` comment | `agent-core.ts`, above `sendPreviewAbTo` | bridge-src |
| `terminal:subscribe` senders | `terminal_service.dart`, `demo_transport.dart` (receiver), `gate-terminal-frames.test.ts`, `local-terminal.test.ts`, `handler.test.ts`, `local-promotion.test.ts`, `machine-trust.test.ts`, `scenarios/terminal/frame-output.ts`, `dart-app-client.ts` | dart+app edits `terminal_service.dart`; the evals keep the project-stream path unedited (D-3) |
| Caps in the vector fixture | `gen-peer-transport-vectors.ts`, `peer-transport-vectors.json`, `peer_transport_vectors_test.dart` | bridge-src, evals, dart+app |

---

## 8. File ownership (disjoint and complete)

| File | Part | Change |
|---|---|---|
| `packages/antgrid-wire/src/stream-open.ts` | bridge-src | two record-cap constants (§2) |
| `packages/antgrid-wire/src/index.ts` | bridge-src | named exports of the two constants |
| `packages/antgrid-wire/scripts/gen-peer-transport-vectors.ts` | bridge-src | `streamOpen.terminalRecords` |
| `bridge/src/peer/stream-records.ts` | bridge-src | §3.1 |
| `bridge/src/peer/terminal-streams.ts` (NEW) | bridge-src | §3.2 |
| `bridge/src/stream-mux.ts` | bridge-src | §3.3 |
| `bridge/src/peer-session-owner.ts` | bridge-src | §3.4 |
| `bridge/src/peer/native-host-connection.ts` | bridge-src | §3.4 |
| `bridge/src/agent-core.ts` | bridge-src | §3.5 |
| `bridge/src/project-core.ts` | bridge-src | §3.5 |
| `bridge/src/host-server.ts` | bridge-src | §3.5 |
| `bridge/src/terminal-frames/delivery.ts` | bridge-src | §3.6 |
| `docs/protocol/peer-session.md` | bridge-src | new "Terminal attachment streams" subsection: record set, first-record rule, routing keys, ends, caps pointer |
| `bridge/tests/terminal-streams.test.ts` (NEW) | bridge-tests | §6 |
| `bridge/tests/stream-records.test.ts` | bridge-tests | §6 |
| `bridge/tests/stream-mux.test.ts` | bridge-tests | §6 |
| `bridge/tests/terminal-frame-delivery.test.ts` | bridge-tests | §6 |
| `bridge/tests/terminal-frame-channel.test.ts` | bridge-tests | §6 |
| `bridge/tests/project-core.test.ts` | bridge-tests | §6 |
| `bridge/tests/native-host-connection.test.ts` | bridge-tests | §6 |
| `packages/antgrid-wire/tests/stream-open.test.ts` | bridge-tests | §6 |
| `packages/antgrid_relay_client/lib/src/models/stream_open.dart` | dart+app | two Dart constants |
| `packages/antgrid_relay_client/lib/src/terminal_attachment.dart` (NEW) | dart+app | §4.1 |
| `packages/antgrid_relay_client/lib/antgrid_relay_client.dart` | dart+app | export `terminal_attachment.dart` |
| `packages/antgrid_relay_client/lib/src/agent_transport.dart` | dart+app | §4.2 |
| `packages/antgrid_relay_client/lib/src/buffered_agent_transport.dart` | dart+app | §4.2 |
| `packages/antgrid_relay_client/lib/src/machine_session.dart` | dart+app | §4.3 |
| `packages/antgrid_relay_client/test/terminal_attachment_test.dart` (NEW) | dart+app | §6 |
| `packages/antgrid_relay_client/test/local_transport_terminal_attachment_test.dart` (NEW) | dart+app | §6 |
| `packages/antgrid_peer_transport/test/peer_transport_vectors_test.dart` | dart+app | §6 |
| `packages/antgrid_eval_client/lib/src/commands.dart` | dart+app | §4.5 |
| `app/lib/services/terminal_service.dart` | dart+app | §4.4 |
| `app/lib/test_helpers/fake_agent_transport.dart` | dart+app | §4.2 |
| `app/lib/demo/demo_transport.dart` | dart+app | verify only; edit only if a terminal reply bypasses `dispatchDecoded` |
| `app/test/services/terminal_stream_attachment_test.dart` (NEW) | dart+app | §6 |
| `evals/helpers/relay-client.ts` | evals | §5 |
| `evals/helpers/dart-app-client.ts` | evals | §5 |
| `evals/tests/gate-terminal-streams.test.ts` (NEW) | evals | §6 |
| `evals/scenarios/dart-client-e2e/dart-terminal.test.ts` | evals | §6 |
| `evals/fixtures/peer-transport-vectors.json` | evals | `streamOpen.terminalRecords` only |

These files are explicitly **not touched** in A2:
- `bridge/src/protocol.ts` (no message type added or removed; `CHECKOUT_VARIABLE_MESSAGE_TYPES` and
  `kCheckoutVariableMessageTypes` are unchanged)
- `bridge/src/peer/stream-dispatch.ts`, `bridge/src/message-bus.ts`, `bridge/src/terminal-frames/protocol.ts`
- `bridge/src/local-listener.ts` and all loopback code (D2)
- `bridge/tests/test-peer-session-owner.ts`, `bridge/tests/stream-dispatch.test.ts`, and every `StreamHandle`
  literal in tests
- `packages/antgrid_relay_client/lib/src/local_transport.dart` (it inherits), `peer_link.dart`,
  `connection_handshake.dart`, `test/support/fake_live_relay.dart`
- `packages/antgrid_peer_transport/lib/**`, including `iroh_peer_link.dart`, `leased_peer_link.dart`,
  `native_smoke.dart` and `interop_app.dart`
- `evals/support/**`, `gate-terminal-frames.test.ts`, `local-terminal.test.ts`, `gate-stream-admission.test.ts`
- `bridge/scripts/**`

`docs/iroh-reduction/ledger.md` is updated by the controller at the wave commit and belongs to no part.

---

## 9. Deviations from the spec, and open items

- **D-1: reading of hazards A and B.**
  - **Hazard B** is ENDED overtaking its final frames, because the bridge prioritizes control over preview
    (`terminal_service.dart`'s drain).
  - **Hazard A** is read as its spec row describes it, "racy today (delivery.ts)" and app-side: a frame being
    processed before its `subscribed`, because the app dispatches the two channels independently.
  - On a terminal stream both collapse into one ordered record sequence, so the native-path tests assert order.
    The app-side drain and deadline logic stays, because the socket path still needs it.
- **D-2: "the peer's project binding".** Today the mux entry is host-owned per project, not per peer; per-peer
  project streams are A4. A2 therefore admits on four things, all checked per peer except the binding:
  - the project's live mux entry (`projectBinding`);
  - the per-peer `mayAcceptFrom` on that entry;
  - `isSafeProjectId`;
  - `seenProjects`, via `projectCataloged`.

  A4 must tighten the binding check to "this peer's own project stream is open".
- **D-3: the legacy project-stream subscribe stays accepted.**
  - Until A6, a `terminal:subscribe` arriving on the project stream still works. Its replies are unbound, so they
    fall back to the session path.
  - That keeps `gate-terminal-frames`, the Dart eval client's legacy terminal tests and older app builds green
    without edits. The app itself always uses `openTerminalAttachment`.
  - A6 decides whether to refuse the legacy path for native peers.
- **D-4: `terminal-frame-channel.test.ts`.** The spec says its expectations change for native only. Routing now
  happens in the mux subscriber, below the core, so the core-level channel expectations do not change. The
  native-only behaviour is pinned in `stream-mux.test.ts` and `terminal-streams.test.ts` instead.
- **D-5: `subscribeSettled` is not in the spec.** Without it, a subscribe that yields no attachment would leave
  its stream open until the app's 15s subscribe deadline. It is the only reason agent-core learns about
  requestIds.
- **D-6: no refusal fallback.** A `NOT_ALLOWED` from a skewed A1 bridge is not retried on the socket path. The
  ALPN is shared by A1 and A2, and this is a pre-release flag day.
- **D-7: the fixture grows.** The fixture gains `streamOpen.terminalRecords`, so the two new cross-language caps
  get the same drift check as A0b's caps.
- **D-8: where the terminal priority lives.** It is side-local and relative to the session stream's default 0.
  A4 must place project streams below it.
- **Open: slot accounting while the app lingers.** A binding frees its cap slot at unbind, which can come before
  the app FINs its half. A misbehaving app can therefore hold QUIC streams beyond the 64-attachment cap, but
  never beyond the 256 bidi limit.

---

## 10. Integration corrections (the code is right where this file disagreed)

- **§3.2 `dropPeer` generation.** The registry needs no peer generation counter. `unbind` marks the binding
  `unbound`, and every callback (writer `onFailure`, the reader's `onFailure`, the read loop) returns early on
  an unbound binding. `NativePeerSessions` additionally guards `retirePeer` on the peer still being registered.
- **§3.2 app FIN before `subscribed`.** The binding is marked `appEnded` but stays indexed by requestId, holding
  its slot, so the core's in-flight `subscribed` can be answered `"dropped"`. That `subscribed`, or
  `subscribeSettled`, then unbinds it. An app end that arrives before the first record was accepted
  unbinds at once: no subscribe was dispatched, so nothing would ever settle it, and the Dart
  close-during-open path would leak one bridge slot per occurrence.
- **§3.2 a record after unbind.** A record that arrives after the binding was retired or settled gets
  `recv.stop(STREAM_STOP_TERMINAL)` before the loop exits, as §3.2 says; abandoning the half instead kept
  the QUIC stream slot until garbage collection.
- **§4.1 `close()` on the socket path** does not await the message controller's close: that future waits for a
  listener to drain, and a caller that never listened to `messages` would hang.
- **§4.3 slot release.** Once a stream exists the slot is held until its `records` complete, including after
  `close()`, so the app never frees a slot the bridge is still counting. The paths that end without reading
  records (close during the open, `SEND_FAILED`) release it at once. A `records` error is treated as the
  bridge's end, and every fire-and-forget `reset()`/`finish()` swallows its own rejection.
- **§4.4 socket-path verbs.** `ack`, `unsubscribe` and `history:request` go through `handle.send` only when
  `handle.isStream`. On the socket path they go through `sendForCheckout`, which puts the same bytes in `sent`
  and keeps that path's throw-at-the-call for a transport that refuses a send (`TerminalAttachment.send` never
  throws). The existing `terminal_frame_mode_test.dart` row "a send that throws at the call still leaves the
  request bounded" depends on it.
- **§4.4 `Refused`/`Failed`/`TransportClosed`** republish hydration after clearing the pending subscribe, so
  the pane leaves `awaitingScreen`.
- **§5 `TerminalStreamClient.records`** holds the records no `next()` has consumed yet: `next()` removes the
  record it returns.
- **§6 gate row 12** runs the host with `ANTGRID_TERMINAL_HISTORY_TEST=1`, as `gate-terminal-frames` does,
  because history recording is off under `NODE_ENV=test`. The guest prints two pages of rows, because the
  archive commits in page-sized batches.
- **§6 the new `dart-terminal.test.ts` row** is outside `test:evals`, which ignores `scenarios/dart-client-e2e/`.
  Run it with `bun run --filter antgrid-evals test:evals:dart-terminal`.
- **§3.5 project-core.ts, promoted local cores.** `startLocal()`'s promotion wrapper dropped `peerId` on its
  way to the core, so on a promoted local core every phone collapsed onto the `"relay"` client key and the
  hooks never matched a binding. The wrapper now passes `peerId` through, and `project-core.test.ts` asserts
  the real peerId.
