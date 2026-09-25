# Stage A, wave A4: project streams replace the mux

This is the frozen contract for four parallel implementers: **bridge-src**, **bridge-tests**, **dart+app**
and **evals**. Each part builds against the names and shapes below. Nobody may rename or reshape anything
pinned here without the controller's say. If your half needs something this file does not provide, report it
as `outOfScopeNeeds`. Do not invent it.

Sources: `stage-A-waves.md` §1.4, §1.5 (hazard J), §2 rows 4-6 and §3 "A4"; the owner decisions in
`ledger.md` (D1-D7); the A2 and A3 contracts, whose registry pattern A4 mirrors; and the four A3
carry-overs in `ledger.md` "Stage A open items". HEAD at authoring time is `05a879a4`: A0a-A0d and A1-A3 are
committed. Where this file and the spec disagree, this file wins for A4. The deviations are listed in §9.

Hard rules for every part:
- Edit only files your part owns (§8). Report anything else in `outOfScopeNeeds`.
- Never `git stash`, `checkout`, `reset` or `restore`.
- Bun tests per workspace only (`bun run --filter <name> test`), never bare `bun test` at the root.
- CLAUDE.md applies: comments say WHY and carry no change narration. The "Adding a message type" checklist
  applies in reverse when removing one (schema, `AbMessageSchema` union, `KNOWN_TYPES`, exported type, any
  `handleAbMessage` case, and every Dart mirror).

---

## 0. What A4 changes, in one screen

- **Every project gets one QUIC stream per app peer.** The app opens it with the A0b open frame
  `{kind:"project", projectId}` (schema unchanged). A new bridge handler, `"project"`, is plugged into A1's
  `PeerStreamAcceptor`. Records are the bare UTF-8 JSON of one `AbMessage`, or one `{"__frag":…}` fragment of
  one. There is no `{s, m}` envelope on a project stream.
- **`bridge/src/stream-mux.ts` is deleted.** A new `bridge/src/project-streams.ts` holds
  `ProjectStreamRegistry`. It keeps `attach`/`detach` and ports `mayDeliver`, `mayDeliverTo` (checked per send),
  `mayAcceptFrom` (checked at open, and still per inbound record) and the online/offline/session-gone hooks.
- **A broadcast means "write to every peer with an open project stream for X".** A peer-addressed send needs
  that peer's open stream. `sendToAppSession` returns true only when that peer's stream is open and deliverable.
- **Hazard J: the app opens a project stream only after a ready notice for that project.** The notice arrives
  on the session stream. It is `stream-ready {projectId}` (the `streamId` field is removed), or an
  `agent:projects` entry with `running:true`. An open that arrives early is refused in-band with `NOT_READY`
  and a FIN. It is never parked.
- **The bridge's first record on an admitted project stream is `stream-ready {projectId}`.** A refused open's
  first record is `stream:refused`. The app treats its project stream as bound only once that first
  `stream-ready` arrives. This is also what makes the new terminal and tunnel rule race-free.
- **Terminal and tunnel opens now need the same peer's open project stream for that projectId**, else they are
  refused `NOT_ALLOWED`. This is the wire comment's existing wording in `stream-open.ts`. Closing the project
  stream does not tear down that peer's terminal or tunnel streams.
- **Removed from the wire:** `stream-unbound` and `stream-invalid` (both sides, full checklist), the
  `streamId` field of `stream-ready` and of the `agent:projects` entries, and every `{s: <id>}` project
  envelope. A session-stream `{s, m}` whose `s` is present and not `"0"` is dropped with a diagnostic.
- **Unchanged:**
  - `peerConnected`, `connState.peerOnline` and push suppression stay driven by session establishment;
  - machine-level `agent:projects`, `agent:tools`, `stream-ready`, `control:result`, host verbs and the
    control-plane `state.snapshot` stay on the session stream;
  - `state.snapshot` and `agent:status` for a project ride that project's stream (hazard E);
  - frag, credits and the session scheduler stay until A5;
  - `FRAME_VERSION`, the ALPN `antgrid/peer/2`, the refusal code set, and the loopback wire (D2, D5).
- **Carry-overs from A3, all four closed here:** §4.4 (Dart terminal slot), §3.9 (promoted core `peerId`,
  already satisfied at HEAD), §3.8 (`abortTunnelStreams` per peer), §6 (`authorized()` tests).

---

## 1. Wire records

### 1.1 A project stream

| Direction | Record | Notes |
|---|---|---|
| app → bridge | the A0b open frame `{kind:"project", projectId}` | written by `openBi` in the same step (Dart: `MultiStreamPeerLink.openStream`) |
| bridge → app, first | `stream:refused {code, message}` then FIN | the A0b record; codes in §3.3 |
| bridge → app, first | `stream-ready {id, timestamp, type:"stream-ready", projectId}` | `createMessage("stream-ready", {projectId})`; the bind is complete when this is written |
| both, after | UTF-8 JSON of one `AbMessage`, no envelope | the same JSON the session path carried inside `m` |
| both, after | UTF-8 JSON `{"__frag":{id,i,n,hint?},"data":…}` | built by the existing `buildFragments`/Dart `buildFragments` over the BARE message JSON; reassembled per stream |
| either | FIN | clean close of that half |
| either | reset | error on that half; the other side unbinds |

Rules:
- A record never exceeds `STREAM_PROJECT_RECORD_MAX_BYTES` (§2). A message whose UTF-8 JSON exceeds
  `FRAG_THRESHOLD` is sent as fragments. One larger than `MAX_TRANSFER_BYTES` is refused at the sender with
  `MESSAGE_TOO_LARGE` (bridge `SendOutcome "too-large"`, Dart `FragSendError`), as today.
- All fragment records of one message are handed to the writer in one synchronous loop, so no other record can
  interleave inside a fragment set.
- Fragment ids stay unique per sender: the bridge's process-global counter; Dart
  `'$machineDeviceId-$projectId-${counter}'`.
- Each project-stream binding owns its own reassembler on each side. On the bridge it draws from the owner's
  shared `reassemblyBudget`. The owner's frag sweep also sweeps the registry's reassemblers.
- The inbound `channel` for a project-stream message is always `"control"`, on both sides. Channel labels
  survive only on the session stream and on loopback (D2).
- A first bridge record that is neither `stream:refused` nor a `stream-ready` naming this projectId is a
  protocol error. The app resets its send half and fails the bind with `INVALID_RECORD`.

### 1.2 Session-stream records that change

| Record | Before | After (TS `bridge/src/protocol.ts`; Dart mirror) |
|---|---|---|
| `stream-ready` | `StreamReadyMessage {type, projectId, streamId}` | `StreamReadyMessage {type:"stream-ready", projectId: z.string()}`. Stays in `KNOWN_TYPES`. Dart reads `projectId` only, in `machine_session.dart` `_snoopControl`. |
| `agent:projects` entry | `streamId: z.string().optional()` (`protocol.ts:704`) | field deleted; `running` is the dialable signal. Dart stops reading `streamId`. |
| `stream-invalid` | `StreamInvalidMessage {streamId}` | **deleted**: schema, union entry, `KNOWN_TYPES`, exported type `StreamInvalid`. Dart: the `'stream-invalid'` branch and `_onStreamInvalid`. |
| `stream-unbound` | `StreamUnboundMessage {streamId}` | **deleted**: same list, `StreamUnbound`. Bridge: the `dispatchControlPlane` consume. Dart: `_notifyStreamUnbound` and its constants. |
| `{s, m}` with `s` ≠ `"0"` | routed to the mux | dropped. Bridge: netwatch drop `reason:"project-on-session-stream"` plus the existing throttled `logUnknownStreamDrop` warn. Dart: `_dropped('rx','project-on-session-stream')`, no log line. |

Neither removed type has a `handleAbMessage` case (verified: `agent-core.ts` has none) or a case in
`app/lib/models/ab_message.dart` (verified: no hit). `StreamEnvelope` (TS `peer-protocol.ts`, Dart
`models/stream_envelope.dart`) and `CONTROL_STREAM_ID`/`kControlStreamId` stay until A5. Their doc comments
say "control plane only".

---

## 2. Caps and constants: where they live

| Constant | Value | Home | Mirror |
|---|---|---|---|
| `STREAM_MAX_PROJECTS_PER_PEER` | 32 (A0b) | `packages/antgrid-wire/src/stream-open.ts` | `kStreamMaxProjectsPerPeer` (A0b) |
| `STREAM_PROJECT_RECORD_MAX_BYTES` (**NEW**) | `MAX_FRAME_PAYLOAD` = `1_500_000`, both directions | `stream-open.ts`, exported by name from `index.ts` | Dart `kStreamProjectRecordMaxBytes = 1500000` in `models/stream_open.dart`; fixture `streamOpen.projectRecords.maxRecordBytes` |
| `PROJECT_STREAM_MAX_QUEUED_BYTES` (**NEW**) | `67_108_864` (= `MAX_SEND_QUEUE_BYTES`) | `bridge/src/project-streams.ts` | none (side-local) |
| `STREAM_PRIORITY_PROJECT` (**NEW**) | `0`, set explicitly | `bridge/src/project-streams.ts` | none; Dart has no priority |
| `STREAM_RESET_PROJECT` (**NEW**) | `0x17n` | `bridge/src/project-streams.ts` | none; Dart cannot read reset codes |
| `STREAM_STOP_PROJECT` (**NEW**) | `0x18n` | `bridge/src/project-streams.ts` | none |
| `kProjectStreamMaxQueuedBytes` (**NEW**) | `67108864` | `packages/antgrid_relay_client/lib/src/machine_session.dart` | none (side-local) |
| `kProjectStreamReopenInitialBackoff` / `kProjectStreamReopenMaxBackoff` (**NEW**) | 1 s / 30 s | `machine_session.dart` | none |
| `INVALID_NOTICE_COOLDOWN_MS` / `INVALID_NOTICE_TTL_MS` | unchanged values | move from `stream-mux.ts` to `project-streams.ts` | none; they now pace only the refused-sender `control:result` notice |

- The fixture generator (`packages/antgrid-wire/scripts/gen-peer-transport-vectors.ts`) adds
  `"projectRecords": { "maxRecordBytes": 1500000 }` under `streamOpen`. Nothing else in the fixture changes.
- The `NOT_READY`/`NOT_ALLOWED` comment in `stream-open.ts` (lines 88-98) gains the project case: `NOT_READY`
  also covers "the project has no relay-registered core yet (hazard J)".
- Queue sizing: a project stream carries what the per-session scheduler carried for that project, so it
  gets that scheduler's cap. Anything the session path accepted cannot overflow one project stream. The
  per-peer worst case is now 32 × 64 MiB instead of 64 MiB. That is an open item (§9), not a blocker.
- Priority: 0 is the same as the session stream. It is below terminal streams (1) and above tunnel streams
  (-1), as the A2 file comment in `terminal-streams.ts` requires ("A4 must place project streams below it").

---

## 3. Bridge API (bridge-src implements; bridge-tests tests against exactly this)

### 3.1 NEW `bridge/src/project-streams.ts` (replaces `stream-mux.ts`)

These types move here from `stream-mux.ts` with their names and doc comments kept: `StreamHandle`,
`TerminalStreamHooks`, `TerminalProjectBinding`, `TunnelProjectBinding`, `PeerSessionView`, `SendTarget`,
`StreamRefusal`, `AttachStreamOpts`. Every importer switches its path (§7). Changed shapes:

```ts
export interface StreamHandle {
  detach(): void;
  /** Unchanged semantics: "gated" when the switch or the receiver mute says no; "dropped" when the target
   *  peer holds no open project stream for this project; "too-large" past MAX_TRANSFER_BYTES; else the
   *  writer's outcome ("sent" only once every fragment was written). `channel` is ignored natively (§1.1). */
  sendTo(msg: unknown, channel: Channel, target: SendTarget): Promise<SendOutcome>;
  /** True iff `peerId` holds an open project stream for this project AND mayDeliver() AND
   *  mayDeliverTo(peerSession(peerId)). Synchronous; what ProjectCore.sendToAppSession returns. */
  deliverableTo(peerId: string): boolean;
  readonly terminalHooks?: TerminalStreamHooks;
}                                   // `streamId` is removed

export interface AttachStreamOpts {
  projectId?: string;
  onAdmitted?: () => void;          // was (streamId) => void; still fired synchronously inside attach()
  onPeerOnline?: () => void;
  onPeerOffline?: () => void;
  onPeerSessionGone?: (peerId: string) => void;
  /** NEW. This peer's project stream for THIS project ended while its session lives on: the app closed it
   *  (FIN or reset), or it overflowed or was lost (D3). Not fired by detach() or dropPeer(). */
  onPeerStreamClosed?: (peerId: string) => void;
  tunnels?: TunnelStreamServer;
  mayDeliver?: () => boolean;
  mayDeliverTo?: (peer: PeerSessionView) => boolean;
  mayAcceptFrom?: (peer: PeerSessionView | null) => StreamRefusal | null;
}                                   // `streamId` and `onLocalReady` are removed

export interface TerminalProjectBinding {
  /** NEW: the peer holds an open project stream for this project. */
  hasOpenStream(peerId: string): boolean;
  refusalFor(peerId: string): StreamRefusal | null;
  /** entry.bus.dispatchInbound(msg, "control", "relay", peerId) after re-running refusalFor.
   *  No mute bookkeeping any more. Does NOT require an open project stream (no cascade, §0). */
  dispatch(msg: AbMessage, peerId: string): boolean;
}                                   // `streamId` is removed

export interface TunnelProjectBinding {
  hasOpenStream(peerId: string): boolean;   // NEW
  refusalFor(peerId: string): StreamRefusal | null;
  mayDeliverTo(peerId: string): boolean;
  tunnels(): TunnelStreamServer | null;
}                                   // `streamId` is removed

export interface ProjectStreamRegistryOptions {
  /** Fail closed: absent => every open is refused NOT_ALLOWED. */
  remoteAccessEnabled?: () => boolean;
  /** host-server `seenProjects.has`. Absent => NOT_ALLOWED (fail closed). */
  projectCataloged?: (projectId: string) => boolean;
  peerSession(peerId: string): PeerSessionView | null;
  /** Peer-addressed control-plane send on the SESSION stream (the refused-sender control:result notice). */
  sendSessionMessage(peerId: string, msg: AbMessage): void;
  /** One reassembler per binding; the owner supplies it over its shared reassemblyBudget. */
  newReassembler(peerId: string, onComplete: (json: string) => void): FragReassembler;
  /** Retires the whole connection. Only "unauthorized" (writer) or "protocol-violation" (reader prefix). */
  retirePeer(peerId: string, reason: "unauthorized" | "protocol-violation"): void;
  /** A2 routing, unchanged: a terminal-bound message for `peerId` goes to its terminal stream. `undefined`
   *  falls back to that peer's PROJECT stream (was: the session stream). */
  routeTerminal?(peerId: string, msg: AbMessage, signal?: AbortSignal): Promise<StreamSendOutcome> | undefined;
  terminalHooks?: TerminalStreamHooks;
  /** The project's last live entry detached (unchanged meaning). */
  projectDetached?(projectId: string): void;
  diagnostic?(event: Parameters<typeof netwatch.record>[0]): void;
  now?: () => number;
}

export class ProjectStreamRegistry {
  constructor(opts: ProjectStreamRegistryOptions);
  /** Registered into PeerStreamAcceptor as `{ project: registry.handler }`. */
  readonly handler: StreamHandler<ProjectStreamOpen>;
  attach(bus: MessageBus, opts: AttachStreamOpts): StreamHandle;
  projectBinding(projectId: string): TerminalProjectBinding | null;
  tunnelBinding(projectId: string): TunnelProjectBinding | null;
  hasOpenStream(peerId: string, projectId: string): boolean;
  openStreamCount(peerId: string): number;
  notifyPeerOnline(): void;                     // same semantics as StreamMux's, minus the mute reset
  notifyPeerOffline(): void;
  notifyPeerSessionOffline(peerId: string): void;
  /** The peer's session or connection is gone: writer.abort() + recv.stop(STREAM_STOP_PROJECT) on every
   *  binding it holds, unbind, no hooks (onPeerSessionGone is the owner's). Never awaits. */
  dropPeer(peerId: string): void;
  sweepFragments(): void;
  detachAll(): void;
}
```

Deleted with `stream-mux.ts`, with no replacement: `StreamMux`, `StreamMuxTransport`, `StreamEntry`,
`unboundAtPeer`, `markBound`, `markUnbound`, `notifyStreamInvalid`, `dispatchInbound(streamId, …)`, the
16-hex id allocation, and the `CONTROL_STREAM_ID` re-export. Importers take `CONTROL_STREAM_ID` from
`antgrid-wire`.

**Attach.** At most one live entry per `projectId`. A second `attach` for a projectId that already has a live
entry replaces it as the admission target (the newest wins, as `projectBinding` did). Existing bindings stay
on the entry they bound to until it detaches. The bus subscription keeps `audience: "relay"`. `onAdmitted`
fires synchronously, then `onPeerOnline` fires if a session already exists, as today.

**Outbound (bus `deliver(msg, channel, signal, peerId)`).**
1. `mayDeliver()` false → gated. This is checked per send, never cached.
2. Recipients: `peerId` given → that peer only, else every peer with an open binding for this project.
3. Per recipient: `mayDeliverTo(peerSession(peer))` is re-read on every send. A peer it rejects is skipped
   (broadcast) or the send is gated (addressed).
4. Addressed: `routeTerminal(peerId, msg, signal)` first. `undefined` → that peer's project stream. No open
   stream → "dropped".
5. Encode once, fragment once, then `writer.send(record, signal)` per recipient.
6. The signal and outcome contract of today's `deliver` is kept: when a signal is present, a non-"sent"
   outcome rejects.

**Detach.** The entry leaves the index and the bus unsubscribes. Every binding on that entry gets
`writer.finish()` (FIN after the queued records) and `recv.stop(STREAM_STOP_PROJECT)`, neither awaited. The
bindings are unbound, and `projectDetached(projectId)` runs as before when it was the last entry. No
`onPeerStreamClosed`.

### 3.2 Binding lifecycle

- **Writer:** `new StreamRecordWriter(stream.send, authorized, onFailure, PROJECT_STREAM_MAX_QUEUED_BYTES,
  STREAM_PRIORITY_PROJECT, STREAM_RESET_PROJECT)`. `authorized` is the admission's `authorized()`, which
  includes the remote-access switch.
- **Reader:** `new StreamRecordReader(stream.recv, STREAM_PROJECT_RECORD_MAX_BYTES, …)`.
- **Writer failures:**
  - `"unauthorized"` → `retirePeer(peerId, "unauthorized")`;
  - `"overflow"` or `"stream-lost"` → unbind, `recv.stop(STREAM_STOP_PROJECT)`, fire
    `onPeerStreamClosed(peerId)`. Only this stream resets (D3). The app reopens and resyncs through
    `state.snapshot`.
- **Reader failures:** a `StreamProtocolViolation` → `retirePeer(peerId, "protocol-violation")`.
- **App ends its half** (FIN or a read rejection): unbind, `writer.finish()`, fire `onPeerStreamClosed`.
- **Inbound record:** in order,
  1. drop it if the binding is unbound;
  2. offer it to the binding's reassembler (a `__frag` record is consumed there);
  3. `parseMessageFast`, and drop non-`AbMessage` JSON with a diagnostic;
  4. re-run `mayAcceptFrom(peerSession(peerId))`. On refusal, drop the record and send one addressed
     `control:result {ok:false, projectId, error:{code,message}}` on the session stream, rate-limited per
     `(peerId, projectId)` by `INVALID_NOTICE_COOLDOWN_MS` (today's `notifyRefused`, moved). The stream stays
     open;
  5. `entry.bus.dispatchInbound(msg, "control", "relay", peerId)`.

  agent-core's `remoteFrameAllowed` gate still runs inside the bus handler.
- **Never** await `stopped()` or `receivedReset()`. `StreamRecordWriter`'s ≤256 KiB `writeAll` slices,
  once-only `setPriority` and per-record `authorized()` are reused, not re-implemented.

### 3.3 Project-stream admission (inside `handler`, all synchronous, before any read is issued)

`PeerStreamAcceptor` runs first, unchanged: the pending cap (16), the 5 s open deadline, `authorized()`
(false retires the connection as unauthorized), `INVALID` for a bad open frame, and `NOT_READY` when the peer
has no established session. Then:

| # | Check | Refusal |
|---|---|---|
| 1 | `openStreamCount(peerId) >= STREAM_MAX_PROJECTS_PER_PEER` | `CAP_EXCEEDED` "too many project streams" |
| 2 | `!isSafeProjectId(projectId)` | `NOT_ALLOWED` "unsafe project id" |
| 3 | `!(opts.remoteAccessEnabled?.() ?? false)` | `NOT_ALLOWED` "mobile access is disabled on this machine" |
| 4 | `!(opts.projectCataloged?.(projectId) ?? false)` | `NOT_ALLOWED` "project not recognized" |
| 5 | no live entry for `projectId` (the core is not relay-registered) | `NOT_READY` "project is not ready; wait for stream-ready" (hazard J) |
| 6 | `!(entry.opts.mayDeliver?.() ?? true)` | `NOT_ALLOWED` "mobile access is disabled on this machine" |
| 7 | `entry.opts.mayAcceptFrom?.(peerSession(peerId))` non-null | that refusal (`UPDATE_REQUIRED` for a stale app on an isolated project) |
| 8 | this peer already holds a binding for `projectId` | `INVALID` "project stream already open" |
| 9 | bind: index it, write `stream-ready {projectId}` as the first record, then start the read loop | — |

- The open **never opens or promotes a core**. It only looks up an entry that `project:start` (or a desktop
  promotion) already attached. `remoteAccessEnabled` (3) and `seenProjects` (4) are checked in addition to
  the acceptor's `authorized()`, not instead of it.
- A refusal is written in-band by the acceptor (`stream:refused`, then FIN, D4), exactly as for terminals and
  tunnels.
- Cap slots count bound streams only. A binding's slot is freed when it is unbound, as for A2 and A3.

### 3.4 Terminal and tunnel admission (`peer/terminal-streams.ts`, `peer/tunnel-streams.ts`)

- New step directly after the existing `binding === null → NOT_READY` step, in both registries:
  `!binding.hasOpenStream(peerId)` → `NOT_ALLOWED` "open the project stream first". Every other step and its
  order is unchanged.
- The project stream becomes the single per-peer admission point for a projectId, which is what keeps root
  CLAUDE.md's "`seenProjects` + `isSafeProjectId` are the only bound" true. The existing catalog and
  `isSafeProjectId` checks in both registries stay (defence in depth).
- A project stream closing does not unbind the peer's terminal or tunnel streams.
- Import paths move to `../project-streams`. The `binding.streamId` reads go away (they were diagnostic only).
- `TerminalStreamRegistry.route()` is unchanged. Its `undefined` now falls back to the project stream (§3.1
  step 4).

### 3.5 `bridge/src/peer-session-owner.ts`

- `protected readonly mux: StreamMux` becomes `protected readonly projectStreams: ProjectStreamRegistry`, built
  in the constructor with:
  - `remoteAccessEnabled: this.opts.remoteAccessEnabled`;
  - `projectCataloged: this.opts.projectCataloged`;
  - `peerSession`;
  - `sendSessionMessage: (peerId, msg) => void this.sendAppEnvelope(CONTROL_STREAM_ID, msg, "control",
    {kind:"peer", peerId})`;
  - `newReassembler` over `this.reassemblyBudget`, with the `TRANSFER_INTERRUPTED` `onAbort` of
    `newFragReassembler`;
  - `retirePeer: (p, r) => this.retirePeerConnection(p, r)`;
  - `routeTerminal`, `terminalHooks` and `projectDetached`, wired to the existing protected hooks.
- `PeerSessionOwnerOptions` gains `remoteAccessEnabled?: () => boolean` and
  `projectCataloged?: (projectId: string) => boolean`.
- NEW `protected retirePeerConnection(peerId, reason): void`. The base class calls `this.dropSession(peerId)`.
  `NativePeerSessions` overrides it with its `retirePeer`, guarded on `nativePeers.has(peerId)`, as the A2/A3
  registries are.
- `attachStream(bus, opts)` → `this.projectStreams.attach(bus, opts)`.
- `routeAppEnvelope`: `s` absent or `"0"` → `dispatchControlPlane`, unchanged. Otherwise drop it (§1.2). No
  `stream-invalid` is sent.
- `dispatchControlPlane`: delete the `stream-unbound` consume. The `netwatch:events` consume stays.
- `handleHello` → `projectStreams.notifyPeerOnline()`.
- `dropSession(peerId)` → `projectStreams.dropPeer(peerId)`, then `notifyPeerSessionOffline(peerId)`, then
  `notifyPeerOffline()` when it was the last session. The order of the last two is unchanged.
- The frag sweep also calls `projectStreams.sweepFragments()`.
- **Deleted:**
  - `noteStreamBound`;
  - `isForeignSlot`, with the `slotMachineDeviceId` import. Production has no caller: its only caller is the
    test seam's `markPeerOffline`. `slotMachineDeviceId` itself stays exported from `antgrid-wire` and
    `relay-slot.ts`;
  - the `closeStream` wiring.
- `sendAppEnvelope` keeps its signature. Only control-plane callers remain, and they pass `CONTROL_STREAM_ID`.
  `fragmentForSend`, `MAX_APP_SESSIONS` and the scheduler are untouched (A5).
  `logUnknownStreamDrop`/`UNKNOWN_STREAM_LOG_INTERVAL_MS` stay for the §1.2 drop.

### 3.6 `bridge/src/peer/native-host-connection.ts`, `remote-host-connection.ts`, `relay-promotion.ts`

- `NativePeerSessions`:
  - passes `remoteAccessEnabled` and `projectCataloged` through to `super(opts)`;
  - adds `project: this.projectStreams.handler` to the `PeerStreamAcceptor` handlers;
  - `TerminalStreamRegistry`'s `projectBinding` and `TunnelStreamRegistry`'s `tunnelBinding` point at
    `this.projectStreams`;
  - `retirePeer` also calls `this.projectStreams.dropPeer(peerId)`;
  - overrides `retirePeerConnection`.
- `NativeHostConnection` deletes its `noteStreamBound` proxy. `RemoteHostConnection`'s `Pick` drops
  `"noteStreamBound"`.
- `relay-promotion.ts`: import path only.

### 3.7 `bridge/src/host-server.ts`, `bridge/src/protocol.ts`

- Delete the `streamIds` map (`:645-648`) and every read and write of it (`:1019`, `:1023`, `:1781`, `:1805`,
  `:2700`, `:2706`).
- `remoteDepsFor(projectId).attachStream` and the `ensureRemoteRuntime` `attachStream` (`:969`) pass `opts`
  straight to `client.attachStream(bus, opts)`, with no id allocation. The wrapper returns
  `{detach, sendTo, deliverableTo, terminalHooks}`.
- `buildProjectsAdvertisement` entries lose `streamId`. `running` keeps its exact gate:
  `isRelayRegistered() && (!needsCheckoutRouting || peerCanRoute)`.
- The idempotent `project:start` path (`:1780-1786`) and `reportFirstRegister` (`:1803-1810`) publish
  `createMessage("stream-ready", {projectId})` on `"control"` whenever the core is relay-registered. No
  `noteStreamBound` call.
- The `project:start` order (`:1727-1745`) is unchanged: remote access, `seenProjects`, checkout routing, then
  `open()`/`promote()`. The native options add nothing new: `projectCataloged` and `remoteAccessEnabled` are
  already passed (`:830-837`).
- `protocol.ts`: the §1.2 edits, and the `StreamReadyMessage` comment rewritten for the new meaning. It is
  the hazard J ready notice, and also the bridge's first record on an admitted project stream.
- The `control:result` comment at `:1202` that mentions stream-ready waiters now says "pending project open".
- **RPC replies are addressed to the asking peer** (found at integration). Before A4 a `response` published on
  the bus reached only the asker's slot by way of its stream id. With one stream per project per peer, a
  broadcast reply lands on every peer that has the project open. So:
  - `host-server.ts` `answerAsker(res, channel, bus, peerId)` answers the control-plane `state.snapshot` and
    the generic `dispatchRpc` reply;
  - `agent-core.ts`'s project inbound handler answers `transcriptSnapshot`, `terminal.snapshot` and
    `dispatchRpc` through `bus.publishOnly(res, channel, "relay", peerId)` for a relay peer, and through
    `bus.publish` for loopback.
  - `evals/tests/gate-project-streams.test.ts` row 4 pins it.

### 3.8 Carry-over 3: `abortTunnelStreams` scoped to the peer (`tunnel-manager.ts`, `agent-core.ts`, `peer/tunnel-streams.ts`, `project-core.ts`)

```ts
// tunnel-manager.ts
export interface TunnelHttpExchange { readonly peerId: string; /* rest unchanged */ }
private readonly inflight = new Map<AbortController, string>();   // controller -> peerId
/** Aborts every in-flight HTTP run for `peerId`. WS runs are left alone, as today. */
abortHttpStreams(peerId: string): void;
stop(): void;                                                      // still aborts every run
// agent-core.ts (interface at :281 and the implementation at :4969)
abortTunnelStreams(peerId: string): void;
```

- `TunnelStreamRegistry` sets `peerId` on the exchange it builds (`tunnel-streams.ts:486`).
- `project-core.ts` calls `core.abortTunnelStreams(peerId)` from `onPeerSessionGone`, and **no longer** from
  `onPeerOnline` or `onPeerOffline`. So a second phone establishing no longer aborts the first phone's preview
  loads. Session lifecycle still drives the abort, per the A3 trap.

### 3.9 `bridge/src/project-core.ts`

- `sendToAppSession(peerId, msg)`: when `this.streamHandle?.deliverableTo(peerId)` is not true, return false
  and send nothing. Otherwise `void this.streamHandle.sendTo(msg, "control", {kind:"peer", peerId})` and
  return true.
- `attachRelayStream` opts:
  - `onAdmitted: () => {…}` takes no argument;
  - NEW `onPeerStreamClosed: (peerId) => this.noteClientGone(peerId)`. A device that closed the project stops
    vouching for its focus there, and it re-declares focus on reopen (§4.3);
  - `onPeerOnline` and `onPeerOffline` keep `peerConnected`, `connState.peerOnline` and `noteClientGone("relay")`
    exactly as they are, minus the `abortTunnelStreams` calls (§3.8).
- The push dispatcher's `shouldFallback` and `resolveTargets` are unchanged. Deriving `peerConnected` from
  stream open would fire push fallback at an established phone that has not opened X (spec trap).
- **Carry-over 2 is already satisfied at HEAD.** `8a13d83b` threads `peerId` through `startLocal`'s promotion
  wrapper (`project-core.ts:502-509`). `project-core.test.ts` ("attachRelayStream wires handle.terminalHooks
  into the core…", peers `phone-1`/`phone-2`) pins it. A4 adds only the registry half (§6,
  `project-streams.test.ts` row 12): the registry dispatches with `(msg, "control", "relay", peerId)`.
  Together with the existing wrapper row, that pins attribution end to end.

### 3.10 Security invariants (none weakened; bridge-tests pins each)

| Invariant | Where it lives after A4 | Pinned by |
|---|---|---|
| Inbound switch: `remoteFrameAllowed` | agent-core bus handler, unchanged; project records reach it through `bus.dispatchInbound` | existing `remote-access-gate.test.ts` |
| Outbound switch: `mayDeliver` | registry, per send; also admission step 6 | `project-streams.test.ts` rows 5, 6 |
| Connection-level switch | the acceptor's `authorized()`, and the writer's per-record `authorized()` | `native-host-connection.test.ts` (existing), `stream-records.test.ts` new rows |
| `seenProjects` + `isSafeProjectId` bound the projectId | admission steps 2 and 4; terminal and tunnel registries keep theirs | rows 2, 3 |
| `mayDeliverTo` per send | registry step 3, re-read every send | row 7 |
| `mayAcceptFrom` at open (and per inbound record) | admission step 7; §3.2 inbound step 4 | rows 8, 9 |
| A stream open never opens or promotes a core | admission step 5 is a lookup only | row 4, and `control-plane-start.test.ts` new row |
| Terminal and tunnel need the peer's project stream | §3.4 | `terminal-streams.test.ts`, `tunnel-streams.test.ts` new rows |

---

## 4. Dart API (dart+app)

### 4.1 `packages/antgrid_relay_client/lib/src/models/stream_open.dart`

- Add `const int kStreamProjectRecordMaxBytes = 1500000;`.
- Update the `NOT_READY` doc comment as §2 does.

### 4.2 `MachineSession` (`machine_session.dart`)

```dart
typedef ProjectStreamEvent = ({String projectId, bool open});

/// The session-stream transport (machine control plane). Replaces streamFor(kControlStreamId).
StreamTransport get control;

/// Returns the project's transport once its project stream is bound (the bridge's first record was
/// stream-ready). Creates the transport on first use; concurrent calls share one attempt. Sequence, under
/// ONE deadline:
///  1. wait for establishment (as bindProject did);
///  2. unless a ready notice for projectId has been seen since establishment or since this project's last
///     stream end, send [startMessage] on the session stream and await `stream-ready {projectId}`
///     (or an agent:projects entry running:true). A `control:result {ok:false, verb:"project:start",
///     projectId}` fails with ProjectBindException(code, message);
///  3. take a project slot. Over kStreamMaxProjectsPerPeer it fails at once with
///     ProjectBindException('CAP_EXCEEDED', …) and never waits;
///  4. MultiStreamPeerLink.openStream(ProjectStreamOpen(projectId),
///     maxRecordBytes: kStreamProjectRecordMaxBytes, maxQueuedBytes: kProjectStreamMaxQueuedBytes);
///  5. first record: stream-ready → bound; stream:refused → ProjectBindException(refusal.code.wireValue,
///     refusal.message). A NOT_READY refusal clears the ready mark and repeats from 2 once, then fails.
/// A link that is not a MultiStreamPeerLink fails with ProjectBindException('STREAM_UNSUPPORTED', …).
/// A failed call disposes a transport it created — unless another openProject caller is still waiting on
/// the same transport, or an earlier call already handed it out. Each caller keeps its own deadline: a
/// caller that inherits a shared attempt which timed out on the other caller's shorter deadline runs its
/// own attempt with the time it has left.
Future<StreamTransport> openProject(
  String projectId,
  Map<String, dynamic> startMessage, {
  Duration timeout = const Duration(seconds: 20),
});

/// The live transport for projectId, bound or not; null if none.
StreamTransport? projectTransport(String projectId);

/// open:true once per bind (after the first stream-ready record); open:false once per bound stream's end,
/// or at session loss, whichever comes first.
Stream<ProjectStreamEvent> get projectStreamEvents;

/// Session-stream send; exactly the old sendOnStream(kControlStreamId, …) path.
Future<void> sendOnSession(Map<String, dynamic> message, String channel);
```

- **Ready tracking (`_readyProjects`).**
  - A project is added on a live or replayed `stream-ready {projectId}`, or on an `agent:projects` entry with
    `running == true`.
  - It is removed when an advert lists it as not running or omits it, and when its project stream ends.
  - The whole set is cleared on session loss and at each establishment.
  - A project that becomes ready while a live transport for it is unbound and not opening starts that
    transport's open.
- **Reopen.**
  - When a bound project stream ends while its transport is not disposed, the transport schedules a reopen.
  - The reopen waits for establishment, backs off from `kProjectStreamReopenInitialBackoff` doubling to
    `kProjectStreamReopenMaxBackoff`, then runs steps 2-5 with `projectStartMessageBuilder(projectId)` as
    the start message. If there is no builder, it reopens only on a ready notice.
  - A successful bind resets the backoff.
  - At each (re)establishment every live project transport reopens at once, with no backoff. The control
    transport still runs `refreshSnapshot()`.
- **Deleted:**
  - `streamFor`, `bindProject`, `sendOnStream`, `streamReadyEvents`, `streamIdForProject`,
    `projectIdForStream`;
  - `_projectStreamIds`, `_streamReadyWaiters` (becomes a per-project ready waiter), `_invalidStreamIds`,
    `_rebindInFlight`, `_recordProjectStream`, `_onStreamInvalid`;
  - `_notifyStreamUnbound`, `_unboundNotifiedAt`, `_unboundNoticeInterval`, `_kMaxTrackedUnboundStreams`;
  - `_logUnknownStreamDrop`, `_unknownStreamLoggedAt`, `_unknownStreamSuppressed`, and the
    `unknownStreamLogInterval` constructor parameter.
- **Kept:** `ProjectBindException`, `projectStartMessageBuilder` (now the reopen's start message),
  `fragmentAborts`/`fragmentSendErrors` (the project-stream reassemblers and senders feed the same
  controllers), `sessionDownEvents`, `established`, `takeoverEvents`, and the terminal and tunnel slot
  semaphores.
- **Inbound control-plane frames do not create the control transport.** They dispatch to it only when it
  already exists. Creating it on inbound would fire a `state.snapshot` pull nobody asked for.
- **Inbound session-stream envelopes** whose `s` is present and not `"0"` are dropped (§1.2).
  `StreamEnvelope` is used for the control plane only.

### 4.3 `StreamTransport`

- It is either the control transport or one project's transport. Fields:
  - `final String? projectId`, null for control;
  - `String get streamId => projectId ?? kControlStreamId;`, a diagnostic and eval handle only;
  - `bool get isProjectBound`;
  - `isEstablished`: `session.isEstablished` for control, `session.isEstablished && isProjectBound` for a
    project.
- `_retarget` and the mutable `streamId` field are deleted.
- **`send(message, channel)`, project transport.**
  - Not bound: drop with `_dropped('tx','no-project-stream')` and return. The snapshot pull at the next bind
    is the reconnect contract, as it was pre-establishment.
  - Bound: encode the bare JSON, then apply the `MESSAGE_TOO_LARGE` check, then fragment past
    `kFragThreshold`.
  - `await stream.send(record)` runs for each record, serialized through one per-transport chain.
  - A non-`accepted` outcome resets the stream explicitly (a dropped noq `SendStream` FINs), unbinds, and
    takes the reopen path.
- **`send`, control transport:** `session.sendOnSession`.
- **Inbound records:**
  - fragments go through a per-transport `FragReassembler` whose `onAbort` feeds `session._fragAborts`;
  - JSON objects go to `dispatchFromSession(json, 'control')`;
  - undecodable records are dropped with `_dropped('rx','bad-record')`, and the stream stays up.
- **`connect()`:** unchanged for control. A project transport only sets `TransportState.connected`, because
  its bind already ran `refreshSnapshot()`.
- **Bind:** on every bind, emit `open:true`, then `refreshSnapshot()`. The snapshot and the tier-3 hydrators
  ride the project stream.
- **`dispose()`:** `finish()` the project stream (clean close), keep draining, free the slot when its records
  end, and remove the transport from the session.
  - **Session dispose does not await the drain.** `MachineSession.dispose` first fails every pending ready
    waiter, then disposes each transport. A project transport disposed under a disposed session finishes
    (or resets, mid-bind) its stream and returns at once, so one unresponsive stream cannot hang teardown.
    A per-project dispose on a live session still awaits the bridge's FIN.
- **Slot release:** a project slot is released only once the stream's records have ended. This is the same
  rule as §4.4, for the same reason: the bridge counts the stream until it sees the end.
- **Terminal and tunnel opens** take `projectId` from the transport, not from `projectIdForStream`.
  - Opening one on the control transport ends it `NO_PROJECT` (terminal) or
    `TunnelExchangeFailure('STREAM_UNBOUND')` (tunnel), as today.
  - Opening one on an unbound project transport fails at once: terminal `TerminalAttachmentFailed('NO_PROJECT_STREAM')`,
    tunnel `TunnelExchangeFailure('STREAM_UNBOUND')`.
- The native terminal and tunnel paths, and the `MultiStreamPeerLink` fallback for terminal attachments,
  are otherwise unchanged.

### 4.4 Carry-over 1: `_StreamTerminalAttachment` holds its slot until the records drain

In `_start()`, two branches currently call `_releaseSlot()` right after `stream.reset()`: close-while-opening
(`machine_session.dart` ~`:1913`) and `SEND_FAILED` (~`:1928`). Both become the A3 tunnel pattern:

```dart
_quietly(stream.reset());
_end(const TerminalAttachmentClosedLocally());       // or TerminalAttachmentFailed('SEND_FAILED', sendError)
// The bridge counts this stream against its cap until it sees the reset and ends its own half; freeing
// the slot first lets the next open race that and draw a spurious CAP_EXCEEDED.
await _readRecords(stream);
return;
```

`_end` already skips the release while `_stream != null && !_recordsDone`. `_readRecords` releases after
`_recordsDone = true`.

### 4.5 App (`app/lib/providers/agent_transport.dart`, `app/lib/project/project_session.dart`)

- **`_buildRelayTransportFor`:** a bare machine id → `session.control`. A compound id →
  `await session.openProject(projId, createAbMessage('project:start', {'projectId': projId}))`. The rest is
  unchanged (`transport.connect()`, dispose on teardown). The doc comment at `:155-170` drops "streamId" and
  "stream-ready" wording in favour of "ready notice, then project stream".
- **`ProjectSession`, focus re-declaration hook (keep it).**
  - `_streamReadySub` becomes a subscription to `session.projectStreamEvents` filtered on
    `e.projectId == wireProjectId`.
  - On `open:true`: `_router.resyncFocusState()`, `sessionsService.resyncFocus()`, `_markUp()`, in that order.
  - On `open:false`: `_markDown()`.
  - `_sessionDownSub` stays.
  - The big comment explaining why both halves of the focus declaration are restated stays, reworded from
    "stream-ready" to "project stream (re)bind". Deleting the hook paints a wrong unread dot, and no transport
    test catches it, so §6 adds an app test for it.
- `ProjectSession._down` is initialised from `transport.isEstablished`, unchanged.
- `app/lib/services/control_plane_client.dart:667`: the comment's `sendOnStream` becomes `sendOnSession`.
- `LocalTransport`, `FakeAgentTransport`, `DemoTransport` and the `AgentTransport` interface are unchanged
  (§9 D-2).

### 4.6 Eval client (`packages/antgrid_eval_client/lib/src/commands.dart`)

- The handle is `projectId` for project traffic and `kControlStreamId` for the session stream.
- `handshake`: attach `session.control`, and emit `{'event':'stream-ready','projectId':p,'streamId':p}` for
  each `projectStreamEvents` event with `open:true`.
- `project-start`: `await session.openProject(projectId, …)`, then emit
  `{'event':'project-started','projectId':p,'streamId':p}`.
- `send-encrypted`, `snapshot` and `terminal-attach` resolve `streamId` as `kControlStreamId` →
  `session.control`, else `session.projectTransport(streamId)`. A missing project transport emits
  `{'event':'error', …}`.
- `_streamReadySub`'s type changes to `StreamSubscription<ProjectStreamEvent>?`.

### 4.7 Interop probe (`packages/antgrid_peer_transport/bin/interop_app.dart`)

- The pre-bind probe opens `ProjectStreamOpen(firstProjectId)` before any `project:start`. It now expects
  `NOT_READY` (hazard J) and emits `{'check':'stream-refused','code':'NOT_READY'}`.
- `bindProject` + `_Inbox(live, streamId)` becomes `openProject` + an inbox over the returned transport.
- The resume check "Resume changed host-owned project binding" is deleted: there is no id left to compare.
  Resume is still proven by the fresh `file:read`.

---

## 5. Test seams after A4

| Seam | After A4 |
|---|---|
| `bridge/tests/test-peer-session-owner.ts` | `markPeerOffline` loses its `isForeignSlot` guard and just calls `dropSession`. `forTest` defaults `options.remoteAccessEnabled` to `() => true` and `options.projectCataloged` to `() => true`, and a caller may override both. **NEW** `openProjectStream` (below). The session helpers (`establish`, `sendFromPeer`, `readToPeer`, `sentTo`, `injectPeer*`) are unchanged and carry session-stream traffic only. |
| `packages/antgrid_relay_client/test/support/fake_live_relay.dart` | `FakeLiveRelay implements PeerLink, MultiStreamPeerLink` (below). `establishSession(...)` loses `unknownStreamLogInterval`. `FakeHandshaker` is unchanged. |
| `evals/helpers/relay-client.ts` | `streamByProject` becomes a per-project stream table. `openProjectStream`/`sendOnStream`/`waitForStreamAbType` keep their names, with the handle being `projectId` (below). |
| `evals/support/` | `stream.ts`: `firstProjectStream(app, projectId)` waits for an advert entry with `running:true`, then returns `await app.openProjectStream(projectId)`, which is `projectId`. `streamSnapshot`, `resolveOnFreshAdvert` and `bindFirstProject` are unchanged in signature. `session-bus.ts` is unchanged. The file header comment is reworded ("stream handle" rather than "streamId"). |
| eval client `commands.dart` | §4.6. Event shapes are unchanged; the `streamId` values are now the handle. |

```ts
// bridge/tests/test-peer-session-owner.ts
export interface TestProjectStream {
  /** The first record, if it was stream:refused. */
  refusal(): { code: string; message: string } | undefined;
  /** Parsed AbMessages the bridge wrote after its first record (fragments reassembled), consuming. Throws when empty. */
  read(): any;
  /** Everything written so far (parsed, first record included), without consuming. */
  written(): ReadonlyArray<any>;
  /** One app → bridge record. A string is sent raw (a malformed body or a hand-built __frag record). */
  send(obj: unknown): Promise<void>;          // resolves after the registry processed it
  finish(): Promise<void>;                     // app FIN; resolves after the unbind ran
  reset(): Promise<void>;                      // app reset
  readonly resets: bigint[];                   // bridge send.reset codes
  readonly stops: bigint[];                    // bridge recv.stop codes
  readonly finished: boolean;                  // bridge send.finish called
  readonly priorities: number[];               // bridge setPriority calls
}
/** Drives the real registry handler with a fake AcceptedBiStream. `authorized` defaults to () => true.
 *  Refusals from PeerStreamAcceptor's own steps (session established, open-frame parse) are NOT modelled;
 *  native-host-connection.test.ts covers those. */
openProjectStream(peerId: string, projectId: string, opts?: { authorized?: () => boolean;
  maxQueuedBytes?: never }): Promise<TestProjectStream>;
```

```dart
// fake_live_relay.dart
class FakePeerStream implements PeerStream {
  final StreamOpen open;
  final List<Uint8List> sent;                  // records the app wrote
  int resetCalls; int finishCalls;
  PeerSendOutcome nextOutcome;                 // default accepted
  void injectRecord(Uint8List record);
  void injectJson(Map<String, dynamic> json);
  void injectStreamReady(String projectId);    // the bridge's first record
  void injectRefusal(String code, String message);
  void end();                                  // bridge FIN: closes `records`
}
// FakeLiveRelay additions
final List<FakePeerStream> openedStreams;
Future<PeerStream> openStream(StreamOpen open, {required int maxRecordBytes, required int maxQueuedBytes});
Object? openStreamError;                       // when set, openStream throws it
```

```ts
// evals/helpers/relay-client.ts
/** Waits for (or drives with project:start) the ready notice, openBi's {kind:"project",projectId}, and
 *  awaits the first record. Resolves to the handle (= projectId). Rejects with Error & {refusal} on
 *  stream:refused, or Error & {code} on control:result ok:false. Idempotent while the stream is open. */
openProjectStream(projectId: string, timeoutMs?: number): Promise<string>;
/** Admission probe: no ready wait, no project:start. */
openProjectStreamRaw(projectId: string, timeoutMs?: number): Promise<{
  refusal?: { code: string; message: string }; first?: Record<string, any>; ended: Promise<"fin" | "error">;
}>;
/** handle "0"/CONTROL_STREAM_ID → the session stream (unchanged); else that project's stream, fragmenting
 *  past FRAG_THRESHOLD. Synchronous signature; writes are chained per stream so call order is wire order.
 *  Throws if the project stream is not open. */
sendOnStream(handle: string, msg: object, channel?: "control" | "preview"): void;
closeProjectStream(handle: string): Promise<void>;            // finish our half, await the bridge's end
projectStreamEnded(handle: string): Promise<"fin" | "error">;
isProjectStreamOpen(handle: string): boolean;
// performE2EHandshake opts gain: omitCheckoutRouting?: boolean
```

- Project-stream messages are delivered with `_streamId = projectId`.
- `stream-ready` and `agent:projects` (`running:true`) populate the client's ready set. Neither carries a
  `streamId` any more.
- `openTerminalStream`/`openTunnelHttpStream`/`openTunnelWsStream` do not auto-open the project stream. Callers
  open it first, which every existing caller does through `firstProjectStream`/`bindFirstProject`.

---

## 6. Tests: added, changed, deleted

The spec's named cases map as follows:
- **Open refused for an unknown, unsafe or not-ready project, and for a stale app on an isolated project:**
  - `project-streams.test.ts` rows 2-4 and 8;
  - `gate-project-streams` rows 1-3.
- **Switch off: no delivery, and the connection retires:** `project-streams.test.ts` rows 5-6;
  `gate-project-streams` row 5.
- **A peer that goes stale mid-stream (the core gains isolated sessions) is muted per send:**
  `project-streams.test.ts` row 7.
- **Session-bus delivery is false without an open project stream:** `project-core.test.ts` new row;
  `project-streams.test.ts` row 10.
- **Two devices, one project, independent streams:** `project-streams.test.ts` row 11;
  `gate-project-streams` row 4.
- **Hazard J:** `gate-project-streams` row 1; `control-plane-start.test.ts` new row; Dart
  `machine_session_project_stream_test.dart`.
- **Focus re-declaration hook:** NEW app test (below).

### bridge-tests

**NEW `bridge/tests/project-streams.test.ts`.** It drives `ProjectStreamRegistry` through
`TestPeerSessionOwner.attachStream` + `openProjectStream`, or directly with fakes. Rows:
1. The admitted open's first record is `stream-ready {projectId}`. `setPriority(0)` runs once, before the
   first write. A broadcast after admission reaches the stream as a bare `AbMessage` (no `s`/`m` keys).
2. An unsafe id (`"../x"`) is refused `NOT_ALLOWED`. An uncatalogued id is refused `NOT_ALLOWED`.
3. `remoteAccessEnabled` false at open → `NOT_ALLOWED`.
4. Catalogued but no attached entry → `NOT_READY`, then FIN. No core is created: the attach spy is never
   called. The same open after `attach` → admitted.
5. `mayDeliver` false at open → `NOT_ALLOWED`. A switch flipped off after open: the next broadcast and the
   next addressed send return `"gated"`, and nothing is written.
6. An open stream whose `authorized()` flips false: the next write retires the peer as `"unauthorized"`
   through `retirePeerConnection`.
7. Mid-stream staleness: peers A (`checkoutRouting`) and B (not) both open. Broadcast reaches both. Flip the
   entry's `hasIsolatedSessions`: the next broadcast reaches A only, and B's addressed send returns
   `"gated"`.
8. A stale app (no `checkoutRouting`) on an isolated project → `UPDATE_REQUIRED` at open.
9. An inbound record from a peer that went stale after open is dropped and not dispatched. One
   `control:result {ok:false, projectId, error.code:"UPDATE_REQUIRED"}` goes out on the session stream. A
   second record within the cooldown sends no second notice.
10. `deliverableTo` is false before open, true after, false after the app FINs, and false while
    `mayDeliverTo` mutes the peer.
11. Two peers, one project: A's addressed reply is written only to A. A broadcast reaches both. A's FIN
    unbinds only A (B still receives). `onPeerStreamClosed("A")` fires once.
12. An inbound record is dispatched as `bus.dispatchInbound(msg, "control", "relay", peerId)` (carry-over 2,
    registry half).
13. The duplicate open for the same `(peer, project)` → `INVALID`. The 33rd concurrent project stream for one
    peer → `CAP_EXCEEDED`.
14. Overflow (a tiny `PROJECT_STREAM_MAX_QUEUED_BYTES` via a test-only constructor seam, or enough queued
    bytes against a gated write) resets that stream with `0x17n` and stops it with `0x18n`. The peer's other
    project stream and the connection are untouched, and `onPeerStreamClosed` fires.
15. A message over `FRAG_THRESHOLD` goes out as `__frag` records in order and reassembles to the original.
    One over `MAX_TRANSFER_BYTES` → `"too-large"`, and nothing is written. An inbound fragment set reassembles
    and dispatches once.
16. A terminal-bound message for a peer with no terminal stream falls back to that peer's project stream.
    With a bound terminal stream it goes there, not onto the project stream.
17. `detach()` finishes every binding on the entry, fires `projectDetached` when it was the last entry, and
    does not fire `onPeerStreamClosed`. `dropPeer` aborts without awaiting.
18. `onPeerOnline` fires at attach while a session exists. `onPeerSessionGone`/`onPeerOffline` fire from
    `dropSession` in the existing order. Opening or closing a project stream fires neither (session-driven).

**DELETE `bridge/tests/stream-mux.test.ts`.** Every row either maps to a row above or tests a deleted
mechanism (ids, `stream-invalid`, `stream-unbound`, the mute).

**`bridge/tests/stream-records.test.ts`: two new rows (carry-over 4).**
- "send-time authorized() refuses before the overflow check": `authorized` always false, and a frame larger
  than `maxQueuedBytes`. Expect `"dropped"`, `failures` exactly `["unauthorized"]`, no `reset`, no
  `writeAll`. Without the send-time check the overflow path would reset and report `"overflow"`.
- "drain-time authorized() refuses before priority or any write": `authorized` returns true on its first call
  only. Expect `"dropped"`, `failures` exactly `["unauthorized"]`, no `setPriority` call, no `writeAll`.
  Without the drain-time check, `setPriority` runs before the per-slice check catches it.

**Changed:**
- `terminal-streams.test.ts` and `tunnel-streams.test.ts`:
  - binding fakes drop `streamId` and add `hasOpenStream`;
  - new row "open with no open project stream for the peer → `NOT_ALLOWED`" (also: another peer's open stream
    does not count);
  - new row "closing the project stream does not unbind an open terminal/tunnel stream";
  - import paths change.
- `tunnel-manager-stream.test.ts`: `abortHttpStreams("A")` aborts A's run and leaves B's running. `stop()`
  still aborts both. Exchange fakes gain `peerId`.
- `remote-access-gate.test.ts`: the `abortTunnelStreams` rows become `abortTunnelStreams(peerId)`. The new
  row (a second phone's `onPeerOnline` aborts nothing; `onPeerSessionGone(A)` aborts only A's) landed in
  `project-core.test.ts`, which is where the native options that carry those hooks are built.
- `terminal-frame-cancellation.test.ts`: rewritten from `StreamMux`/`sendEnvelope` onto
  `ProjectStreamRegistry` plus a fake project-stream writer. Same assertions about cancellation.
- `handshake-pull.test.ts`: delete the two foreign-slot rows ("loss for a slot scoped at another machine never
  retires our session", "peer-offline for a slot scoped at another machine does not suppress our stream") and
  the `PHONE_SLOT` fixture if nothing else uses it. Keep "loss for an unscoped peer id retires its native
  session".
- `peer-session-hello.test.ts`: the `{s: handle.streamId, m}` send moves to `openProjectStream` + `send`.
- `native-host-connection.test.ts`:
  - `noteStreamBound` references go;
  - new row: an established peer with a catalogued, attached project gets a project open admitted, and the
    first record is `stream-ready`;
  - existing project-kind rows keep their expectations (pre-hello `NOT_READY`, switch off → close code 3,
    first-stream non-session kind → code 2).
- `control-plane-start.test.ts`:
  - `stream-ready` asserts `{projectId}` and no `streamId`;
  - `onAdmitted()` takes no argument;
  - new row "a project open before `project:start` is `NOT_READY` and creates no core; after `project:start`
    the bridge publishes `stream-ready {projectId}`".
- `host-promotion.test.ts`, `host-server.test.ts`: no `noteStreamBound`, no advert `streamId`,
  `onAdmitted()` with no argument.
- `project-core.test.ts`:
  - `onAdmitted()` takes no argument; the fake handle gains `deliverableTo`;
  - new row "`sendToAppSession` returns false and sends nothing when `deliverableTo(peer)` is false";
  - new row "`onPeerStreamClosed(peer)` clears that peer's focus claim".
- Import-path only (`../src/stream-mux` → `../src/project-streams`): `agent-reach-gate.test.ts`,
  `relay-promotion.test.ts`, `terminal-frame-channel.test.ts`, `push/push-multi-device-targeting.test.ts`,
  `push/push-restart-targeting.test.ts`.
- `relay-slot.test.ts`: the comment naming `isForeignSlot` (`:14`) is reworded.
- `test-peer-session-owner.ts`: §5.
- `packages/antgrid-wire/tests/stream-open.test.ts`: `STREAM_PROJECT_RECORD_MAX_BYTES === MAX_FRAME_PAYLOAD`.
- `packages/antgrid-wire/tests/peer-transport-vectors.test.ts`: the fixture's `projectRecords` equals the
  constant.
- Verify only, edit only if red: `terminal-frame-protocol.test.ts`, `worktree-remote-security.test.ts`,
  `send-scheduler.test.ts`, `native-session-send-scheduler.test.ts`, `relay-client-credit-window.test.ts`,
  `relay-client-frag-send.test.ts`, `host-control-plane.test.ts`, `fake-session.ts`,
  `stream-dispatch.test.ts`.

### dart+app

**NEW `packages/antgrid_relay_client/test/machine_session_project_stream_test.dart`.** Rows:
1. `openProject` with no ready notice sends `project:start` on the session stream and opens nothing until
   `stream-ready {projectId}` arrives. Then it opens `ProjectStreamOpen(projectId)` with
   `kStreamProjectRecordMaxBytes`, and resolves only after the first record `stream-ready`.
2. An advert `running:true` counts as the ready notice: no `project:start` is sent.
3. `stream:refused UPDATE_REQUIRED` → `ProjectBindException('UPDATE_REQUIRED', …)`. The send half is
   finished, the slot is freed only after `records` ends, and the transport is disposed.
4. A `NOT_READY` refusal re-drives `project:start` once, then fails with `NOT_READY` on a second refusal.
5. `control:result {ok:false, verb:"project:start"}` fails the open with its code.
6. The 33rd concurrent `openProject` fails `CAP_EXCEEDED` at once, and `openStream` is never called.
7. `send` on a bound transport writes one bare-JSON record. A message over `kFragThreshold` writes `__frag`
   records in order. Over `kMaxTransferBytes` emits a `FragSendError`, and nothing is written. An unbound
   transport writes nothing.
8. An inbound fragment set reassembles and dispatches once, on channel `'control'`.
9. A bound stream's end emits `open:false`, then a reopen after backoff through `projectStartMessageBuilder`.
   On re-bind it emits `open:true` and re-pulls `state.snapshot` over the project stream.
10. Re-establishment reopens every live project transport with no backoff.
11. `dispose()` finishes the stream, and nothing reopens.
12. A session-stream `{s:"x", m:…}` is dropped, and no `stream-unbound` is sent.
13. A non-`MultiStreamPeerLink` link fails with `STREAM_UNSUPPORTED`.

**`terminal_attachment_test.dart`, two new rows (carry-over 1).**
- "close() while the open is in flight resets, ends ClosedLocally, and holds the slot until the bridge's
  records end": with 64 attachments open, the 65th fails `CAP_EXCEEDED` until `end()` is called on the reset
  stream.
- "SEND_FAILED holds the slot until the records end": the same shape, with `nextOutcome` not accepted.
- The existing rows move from `streamFor('s…')` + injected `stream-ready {streamId}` to `openProject` + a
  bound fake project stream.

**Changed:**
- `tunnel_stream_test.dart`: rebinds through `openProject`. The `STREAM_UNBOUND` row uses an unbound project
  transport.
- `machine_session_stream_binding_test.dart`: **rewritten** as the ready-notice and advert rows not covered
  above (the snapshot-replayed advert, a shared waiter across callers, one deadline). The whole
  `stream-invalid` group is deleted.
- `machine_session_unknown_stream_log_test.dart`: **DELETE** (the mechanism is gone).
- `machine_session_envelope_test.dart`, `machine_session_rekey_test.dart`, `machine_session_rpc_health_test.dart`,
  `machine_session_snapshot_retry_test.dart`, `machine_session_flow_control_test.dart`:
  - `streamFor(kControlStreamId)` → `control`;
  - `streamFor('s1')` → a project bound through the fake;
  - `sendOnStream('0', …)` → `sendOnSession(…)`;
  - `bindProject` → `openProject`;
  - flow-control rows stay on the session stream.
- `support/fake_live_relay.dart`: §5.
- `packages/antgrid_peer_transport/test/peer_transport_vectors_test.dart`: `kStreamProjectRecordMaxBytes`
  equals the fixture's `projectRecords.maxRecordBytes`.
- `app/test/relay/relay_connection_open_test.dart`:
  - the "drill-in binds via stream-ready at 0 RTT" row becomes "an advert `running:true` makes `openProject`
    open the project stream with no `project:start`";
  - the "two projects share one session" row uses `openProject`;
  - `_RecordingRelay` gains `MultiStreamPeerLink`.
- **NEW `app/test/project/project_session_stream_events_test.dart`** (the spec trap: no transport test catches
  it). It builds a `ProjectSession` over a `StreamTransport` bound through an in-file fake link.
  - A second `open:true` (a reopen) writes the focus re-declaration frames that `resyncFocusState` and
    `sessionsService.resyncFocus` produce, onto the project stream, and marks the session up.
  - `open:false` fails a pending reply with `SessionDownException` at once.
- Verify only, edit only if red: `machine_session_establish_test.dart`, `netwatch_tap_test.dart`,
  `peer_link_test.dart`, `hydrate_action_contract_test.dart`, `relay_message_test.dart`,
  `app/test/connection/peer_connection_session_binding_test.dart`, `app/test/control_plane_client_test.dart`,
  `app/test/project/focus_resume_test.dart`, `app/test/project/message_router_test.dart`,
  `app/test/project_work_status_test.dart`, `app/test/providers/relay_connection_manager_test.dart`,
  `app/test/services/reconciliation_hydrate_test.dart`, `app/test/services/sessions_service_test.dart`,
  `app/test/session_bus/remote_directory_source_test.dart`, `app/test/widgets/recent_sessions_tab_test.dart`.

### evals

**NEW `evals/tests/gate-project-streams.test.ts`** (in the default `test:evals` sweep). Rows:
1. Hazard J:
   - a catalogued, cold project opened raw before `project:start` → `NOT_READY` then FIN, and the session stays
     up (a control-plane ping still answers);
   - after `project:start`, the session stream carries `stream-ready {projectId}` with no `streamId`;
   - `openProjectStream` then succeeds, and `streamSnapshot` returns `agent:status`.
2. `openProjectStreamRaw` for an uncatalogued id and for `"../x"` → `NOT_ALLOWED`, and the session stays up.
3. A second app that omits `checkoutRouting`, on a project that holds a managed worktree session (created by
   the first app with `session:create {isolation:"worktree"}`) → `UPDATE_REQUIRED`.
4. Two devices, one project:
   - both open;
   - `terminal:start` from A: A and B both see `terminal:started`;
   - A's `state.snapshot` response reaches A only;
   - A `closeProjectStream`: B still receives the next broadcast.
5. Switch off with a project stream open: the connection closes (native close observed), and no further
   project record arrives.
6. A terminal stream opened with no project stream for that project → `NOT_ALLOWED`. After
   `openProjectStream` it is admitted.

**Changed:**
- `gate-stream-admission.test.ts`: the project-kind row ("refused NOT_ALLOWED … A4 wires the project")
  becomes "a project-kind open for a catalogued project with no `project:start` is refused `NOT_READY` and the
  session stays up". The header comment is updated.
- `gate-iroh-host-authorization.test.ts`: `stream-ready` → open the project stream over its raw
  `PeerRecords`-style helpers, or switch to `RelayClient.openProjectStream`. `file:read` is sent as a
  project-stream record, not `{s, m}`.
- `drill-in.test.ts`, `machine-trust.test.ts`, `multi-stream-coexistence.test.ts`: `stream-ready` no longer
  carries `streamId`. The "fresh stream-ready" and "re-publishes it" comments and assertions move to the ready
  notice plus a successful open. `streamFor(` in `machine-trust.test.ts` follows the eval-client change.
- `fragmentation.test.ts`: the `{s, m}` comment (`:62-66`) now says fragments are project-stream records. The
  `_streamId` assertion stays (it equals the handle).
- `gate-terminal-streams.test.ts`, `gate-tunnel-streaming.test.ts`, `sealed-preview-http.test.ts`,
  `gate-two-devices-one-bridge.test.ts`: they must open the project stream before any terminal or tunnel
  stream. Most already do through `firstProjectStream`.
- `gate-multi-machine-slots.test.ts`: the comment naming `isForeignSlot` (`:92`) is reworded.
- `evals/helpers/harness.ts`:
  - `setupTestEnv` polls the advert for `running === true` (was `p.streamId`), then opens the project stream;
  - `TestEnv.streamId` stays and equals `projectId`;
  - the Dart `bindProject` path (`:970-1004`) uses the returned handle.
- `evals/helpers/dart-app-client.ts`: comments and the `openProjectStream` return value (the handle). The
  command shapes are unchanged.
- `evals/support/stream.ts`: §5.
- `evals/fixtures/peer-transport-vectors.json`: add `streamOpen.projectRecords` only.
- Verify only, edit only if red: `helpers/two-bridge.ts`, `helpers/chat.ts`, `support/session-bus.ts`,
  `soak/native-fault-soak.test.ts`, every scenario under `scenarios/`, and the other `tests/*` files that use
  `firstProjectStream`/`sendOnStream`.

### Gate (controller, once, after integration)

- `ALL`, `EVALS` and `INTEROP`, as `stage-A-waves.md` §3 defines them. `qualify:iroh-interop` expects the
  probe's refusal to be `NOT_READY` (bridge-src edits `bridge/scripts/iroh-interop-smoke.ts:102`).
- `bun run --filter antgrid-evals test:evals:native-soak`.
- `bun run --filter antgrid-wire gen:peer-vectors`, then `git diff` on the fixture must show only the
  `projectRecords` addition.
- One `flutter analyze` run, from the controller only.
- Known bridge red:
  - 6 stale-runId failures: index-hook-subcommand ×1, plugin/antigravity-post-title ×3,
    plugin/opencode-notify ×2;
  - the git-branches stash-pop and git-sync already-up-to-date timeouts under load.
- `gate-vectors.test.ts`'s git-clean guard is red on the uncommitted fixture until the wave commit.

---

## 7. Call sites found by grep (rename and delete sweep)

The pattern (`git grep`, excluding `docs/iroh-reduction/` and `docs/iroh-transport-reduction-plan.md`) is:

`stream-ready|stream-unbound|stream-invalid|StreamReady|StreamUnbound|StreamInvalid|streamIds|stream-mux|StreamMux|noteStreamBound|markBound|markUnbound|unboundAtPeer|notifyStreamInvalid|projectBinding|tunnelBinding|sendEnvelope|isForeignSlot|abortTunnelStreams|abortHttpStreams|notifyPeerOnline|notifyPeerSessionOffline|logUnknownStreamDrop|streamIdForProject|projectIdForStream|streamReadyEvents|bindProject|streamFor\(|kControlStreamId|StreamEnvelope|_retarget|ProjectBindException|projectStartMessageBuilder|onLocalReady|onAdmitted|sendToAppSession`

| Symbol | Hits | Owner and action |
|---|---|---|
| `stream-mux` imports | src: `agent-core.ts`, `peer-session-owner.ts`, `project-core.ts`, `relay-promotion.ts`, `peer/native-host-connection.ts`, `peer/terminal-streams.ts`, `peer/tunnel-streams.ts`; 12 test files (§6) | bridge-src (src), bridge-tests (tests): path → `project-streams` |
| `StreamMux` | the above plus `host-promotion.test.ts`, `docs/protocol/peer-session.md` | deleted; the docs mention is A6 |
| `noteStreamBound` | `host-server.ts`, `peer-session-owner.ts`, `peer/native-host-connection.ts`, `remote-host-connection.ts`; `control-plane-start`, `host-promotion`, `host-server` tests | delete |
| `markBound` / `markUnbound` / `unboundAtPeer` / `notifyStreamInvalid` | `stream-mux.ts`, `peer-session-owner.ts`, `bridge/CLAUDE.md`; `stream-mux.test.ts`, `terminal-frame-cancellation.test.ts` | delete |
| `projectBinding` / `tunnelBinding` | `native-host-connection.ts`, `terminal-streams.ts`, `tunnel-streams.ts`; their tests; `bridge/CLAUDE.md`; `docs/protocol/peer-session.md`; `evals/tests/gate-terminal-streams.test.ts` (comment) | kept as registry methods, reshaped (§3.1) |
| `sendEnvelope` | `stream-mux.ts`, `peer-session-owner.ts`; `stream-mux.test.ts`, `terminal-frame-cancellation.test.ts` | delete |
| `isForeignSlot` | `peer-session-owner.ts`, `bridge/CLAUDE.md:87`; `test-peer-session-owner.ts:143`, `relay-slot.test.ts:14` (comment); `evals/tests/gate-multi-machine-slots.test.ts:92` (comment) | delete the method and the seam guard; reword the comments |
| `abortTunnelStreams` / `abortHttpStreams` | `agent-core.ts`, `project-core.ts`, `tunnel-manager.ts`, `bridge/CLAUDE.md`; `remote-access-gate.test.ts`, `tunnel-manager-stream.test.ts` | take `peerId` (§3.8) |
| `stream-ready` | `host-server.ts`, `protocol.ts`, `peer-session-owner.ts` (comment), `bridge/scripts/iroh-host-smoke.ts:60`; `control-plane-start.test.ts`; evals `relay-client.ts`, `dart-app-client.ts`, `harness.ts`, `drill-in`, `gate-iroh-host-authorization`, `machine-trust`, `multi-stream-coexistence`; Dart `machine_session.dart`, `commands.dart`, and 5 relay-client tests; `app/lib/providers/agent_transport.dart` (comment), `app/test/relay/relay_connection_open_test.dart`; both CLAUDE.md files | reshaped to `{projectId}` (§1.2) |
| `stream-unbound` / `stream-invalid` | `protocol.ts`, `stream-mux.ts`, `peer-session-owner.ts`; `stream-mux.test.ts`; `machine_session.dart`; 3 relay-client tests | delete (§1.2) |
| `streamIds` (host-server map) | `host-server.ts` | delete |
| `streamReadyEvents` | `machine_session.dart`, `project_session.dart`, `commands.dart`, `machine_session_stream_binding_test.dart`, `agent-core.ts:2179` (comment) | → `projectStreamEvents`; the bridge comment is reworded by bridge-src |
| `bindProject` / `streamFor(` / `streamIdForProject` | `machine_session.dart`, `agent_transport.dart`, `commands.dart`, `interop_app.dart`, relay-client tests, `relay_connection_open_test.dart`, `evals/helpers/harness.ts` (comment), `evals/tests/machine-trust.test.ts` | → `openProject` / `control` / `projectTransport` |
| `projectIdForStream`, `_retarget` | `machine_session.dart` | delete |
| `kControlStreamId`, `StreamEnvelope`, `CONTROL_STREAM_ID` | Dart relay client, eval client, `agent_transport.dart`; TS wire, `send-scheduler.ts`, scheduler tests, evals helpers | **kept** (A5), control plane only |
| `ProjectBindException`, `projectStartMessageBuilder` | `machine_session.dart`, `peer_connection.dart`, `commands.dart`, `interop_app.dart`, `fake_live_relay.dart`, relay-client `CLAUDE.md` | **kept** (§4.2) |
| `onAdmitted` / `onLocalReady` | `project-core.ts`, `stream-mux.ts`; `control-plane-start`, `host-promotion`, `native-host-connection`, `project-core` tests | `onAdmitted()` with no argument; `onLocalReady` deleted |
| `sendToAppSession` | `project-core.ts`, `agent-core.ts`, `host-server.ts`, `session-bus/coordinator.ts` (comment), `bridge/CLAUDE.md:211`, `docs/architecture.md:96` | only `project-core.ts`'s body changes |
| `logUnknownStreamDrop` | `peer-session-owner.ts` (kept), `machine_session.dart` (deleted) | §1.2 |
| `notifyPeerOnline` / `notifyPeerSessionOffline` | `peer-session-owner.ts`, `stream-mux.ts`; `stream-mux.test.ts`, `handshake-pull.test.ts`; Dart hits are unrelated names | move to the registry, same names |
| `{ s: …, m }` project envelopes in tests | `peer-session-hello.test.ts`, `stream-mux.test.ts`; `evals/tests/gate-iroh-host-authorization.test.ts`, `fragmentation.test.ts` (comment); `evals/helpers/relay-client.ts`, `dart-app-client.ts` | move onto project streams |
| Prose | `bridge/CLAUDE.md` (the `stream-mux.ts`, `host-server.ts`, `peer-session-owner.ts` and `tunnel-manager.ts` bullets, and the `isForeignSlot` sentence), `packages/antgrid_relay_client/CLAUDE.md:15` | bridge-src and dart+app respectively. `docs/protocol/peer-session.md`, `docs/architecture.md`, root and `app/` CLAUDE.md are **A6** |

---

## 8. File ownership (disjoint and complete)

| File | Part | Change |
|---|---|---|
| `packages/antgrid-wire/src/stream-open.ts` | bridge-src | §2 constant and comment |
| `packages/antgrid-wire/src/index.ts` | bridge-src | named export |
| `packages/antgrid-wire/scripts/gen-peer-transport-vectors.ts` | bridge-src | `streamOpen.projectRecords` |
| `bridge/src/project-streams.ts` (NEW) | bridge-src | §3.1-§3.3 |
| `bridge/src/stream-mux.ts` | bridge-src | DELETE |
| `bridge/src/peer-session-owner.ts` | bridge-src | §3.5 |
| `bridge/src/peer/native-host-connection.ts` | bridge-src | §3.6 |
| `bridge/src/peer/terminal-streams.ts` | bridge-src | §3.4 |
| `bridge/src/peer/tunnel-streams.ts` | bridge-src | §3.4, §3.8 (`peerId` on the exchange) |
| `bridge/src/remote-host-connection.ts` | bridge-src | §3.6 |
| `bridge/src/relay-promotion.ts` | bridge-src | import path |
| `bridge/src/host-server.ts` | bridge-src | §3.7 |
| `bridge/src/protocol.ts` | bridge-src | §1.2 |
| `bridge/src/project-core.ts` | bridge-src | §3.8, §3.9 |
| `bridge/src/agent-core.ts` | bridge-src | §3.8; import path; the comment at `:2179` |
| `bridge/src/tunnel-manager.ts` | bridge-src | §3.8 |
| `bridge/scripts/iroh-host-smoke.ts` | bridge-src | ready notice + project stream instead of `stream-ready.streamId` + `{s,m}` |
| `bridge/scripts/iroh-interop-smoke.ts` | bridge-src | expect `NOT_READY` (`:100-102`) |
| `bridge/CLAUDE.md` | bridge-src | the bullets in §7 |
| `bridge/tests/project-streams.test.ts` (NEW) | bridge-tests | §6 |
| `bridge/tests/stream-mux.test.ts` | bridge-tests | DELETE |
| `bridge/tests/stream-records.test.ts` | bridge-tests | two rows |
| `bridge/tests/test-peer-session-owner.ts` | bridge-tests | §5 |
| `bridge/tests/terminal-streams.test.ts` | bridge-tests | §6 |
| `bridge/tests/tunnel-streams.test.ts` | bridge-tests | §6 |
| `bridge/tests/tunnel-manager-stream.test.ts` | bridge-tests | §6 |
| `bridge/tests/remote-access-gate.test.ts` | bridge-tests | §6 |
| `bridge/tests/terminal-frame-cancellation.test.ts` | bridge-tests | rewrite |
| `bridge/tests/handshake-pull.test.ts` | bridge-tests | delete the foreign-slot rows |
| `bridge/tests/peer-session-hello.test.ts` | bridge-tests | §6 |
| `bridge/tests/native-host-connection.test.ts` | bridge-tests | §6 |
| `bridge/tests/control-plane-start.test.ts` | bridge-tests | §6 |
| `bridge/tests/host-promotion.test.ts` | bridge-tests | §6 |
| `bridge/tests/host-server.test.ts` | bridge-tests | §6 |
| `bridge/tests/project-core.test.ts` | bridge-tests | §6 |
| `bridge/tests/relay-slot.test.ts` | bridge-tests | comment |
| `bridge/tests/agent-reach-gate.test.ts` | bridge-tests | import path |
| `bridge/tests/relay-promotion.test.ts` | bridge-tests | import path |
| `bridge/tests/terminal-frame-channel.test.ts` | bridge-tests | import path |
| `bridge/tests/push/push-multi-device-targeting.test.ts` | bridge-tests | import path |
| `bridge/tests/push/push-restart-targeting.test.ts` | bridge-tests | import path |
| `bridge/tests/terminal-frame-protocol.test.ts`, `worktree-remote-security.test.ts`, `send-scheduler.test.ts`, `native-session-send-scheduler.test.ts`, `relay-client-credit-window.test.ts`, `relay-client-frag-send.test.ts`, `host-control-plane.test.ts`, `fake-session.ts`, `stream-dispatch.test.ts` | bridge-tests | verify only |
| `packages/antgrid-wire/tests/stream-open.test.ts` | bridge-tests | §6 |
| `packages/antgrid-wire/tests/peer-transport-vectors.test.ts` | bridge-tests | §6 |
| `packages/antgrid_relay_client/lib/src/models/stream_open.dart` | dart+app | §4.1 |
| `packages/antgrid_relay_client/lib/src/machine_session.dart` | dart+app | §4.2-§4.4 |
| `packages/antgrid_relay_client/lib/src/models/stream_envelope.dart` | dart+app | doc comment: control plane only |
| `packages/antgrid_relay_client/CLAUDE.md` | dart+app | the `machine_session.dart` bullet |
| `packages/antgrid_relay_client/test/support/fake_live_relay.dart` | dart+app | §5 |
| `packages/antgrid_relay_client/test/machine_session_project_stream_test.dart` (NEW) | dart+app | §6 |
| `packages/antgrid_relay_client/test/machine_session_stream_binding_test.dart` | dart+app | rewrite |
| `packages/antgrid_relay_client/test/machine_session_unknown_stream_log_test.dart` | dart+app | DELETE |
| `packages/antgrid_relay_client/test/machine_session_envelope_test.dart`, `machine_session_rekey_test.dart`, `machine_session_rpc_health_test.dart`, `machine_session_snapshot_retry_test.dart`, `machine_session_flow_control_test.dart` | dart+app | §6 |
| `packages/antgrid_relay_client/test/terminal_attachment_test.dart` | dart+app | §6 (carry-over 1) |
| `packages/antgrid_relay_client/test/tunnel_stream_test.dart` | dart+app | §6 |
| `packages/antgrid_relay_client/test/machine_session_establish_test.dart`, `netwatch_tap_test.dart`, `peer_link_test.dart`, `hydrate_action_contract_test.dart`, `relay_message_test.dart` | dart+app | verify only |
| `packages/antgrid_peer_transport/bin/interop_app.dart` | dart+app | §4.7 |
| `packages/antgrid_peer_transport/test/peer_transport_vectors_test.dart` | dart+app | §6 |
| `packages/antgrid_eval_client/lib/src/commands.dart` | dart+app | §4.6 |
| `app/lib/providers/agent_transport.dart` | dart+app | §4.5 |
| `app/lib/project/project_session.dart` | dart+app | §4.5 |
| `app/lib/services/control_plane_client.dart` | dart+app | comment |
| `app/test/relay/relay_connection_open_test.dart` | dart+app | §6 |
| `app/test/project/project_session_stream_events_test.dart` (NEW) | dart+app | §6 |
| The app tests listed as verify-only in §6 | dart+app | verify only |
| `evals/helpers/relay-client.ts` | evals | §5 |
| `evals/helpers/dart-app-client.ts` | evals | §6 |
| `evals/helpers/harness.ts` | evals | §6 |
| `evals/support/stream.ts` | evals | §5 |
| `evals/tests/gate-project-streams.test.ts` (NEW) | evals | §6 |
| `evals/tests/gate-stream-admission.test.ts` | evals | §6 |
| `evals/tests/gate-iroh-host-authorization.test.ts` | evals | §6 |
| `evals/tests/drill-in.test.ts`, `machine-trust.test.ts`, `multi-stream-coexistence.test.ts`, `fragmentation.test.ts`, `gate-multi-machine-slots.test.ts` | evals | §6 |
| `evals/tests/gate-terminal-streams.test.ts`, `gate-tunnel-streaming.test.ts`, `sealed-preview-http.test.ts`, `gate-two-devices-one-bridge.test.ts` | evals | open the project stream first where they do not |
| `evals/fixtures/peer-transport-vectors.json` | evals | `streamOpen.projectRecords` only |
| `evals/helpers/two-bridge.ts`, `helpers/chat.ts`, `support/session-bus.ts`, `soak/native-fault-soak.test.ts`, `scenarios/**`, the other `tests/*` users of the stream helpers | evals | verify only |

These files are explicitly **not touched** in A4:
- `bridge/src/send-scheduler.ts`, `bridge/src/frag-reassembler.ts`, `bridge/src/peer/records.ts`,
  `packages/antgrid-wire/src/frag.ts`, `flow.ts`, `peer-protocol.ts`, and Dart `flow.dart`, `frag.dart`,
  `send_scheduler.dart` (all A5).
- `bridge/src/peer/stream-records.ts`, `bridge/src/peer/stream-dispatch.ts`, `bridge/src/message-bus.ts`,
  `bridge/src/local-listener.ts`, and all loopback code (D2).
- `packages/antgrid_relay_client/lib/src/local_transport.dart`, `agent_transport.dart`,
  `buffered_agent_transport.dart`, `peer_link.dart`, `terminal_attachment.dart`, `tunnel_stream.dart`,
  `connection_handshake.dart`; `packages/antgrid_peer_transport/lib/**`; `app/lib/test_helpers/**`,
  `app/lib/demo/**`.
- `docs/protocol/peer-session.md`, `docs/architecture.md`, root `CLAUDE.md`, `app/CLAUDE.md`, the netwatch
  files (all A6), and `docs/iroh-transport-reduction-plan.md`.

`docs/iroh-reduction/ledger.md` is updated by the controller at the wave commit and belongs to no part.

---

## 9. Deviations from the spec, and open items

- **D-1: the bridge answers an admitted open with a `stream-ready` record.** The spec names only the refusal
  path. Without a positive first record, Dart cannot tell when the bridge has bound the stream (D4: there is
  no ack, and `openStream` returns once the open frame is written). The app would then race its first
  `state.snapshot` and any terminal or tunnel open against the bind. Reusing `stream-ready` adds no message
  type.
- **D-2: no `LocalTransport` implementation.** D2 asks every new app stream API to have one. A4 adds no
  `AgentTransport` API: `openProject`, `control`, `projectTransport` and `projectStreamEvents` live on
  `MachineSession`, which loopback never uses. `LocalTransport` keeps its socket and its labels unchanged.
- **D-3: `stream-ready` keeps its name.** The spec allows `project:ready`. Keeping the name spares a message
  type add/remove pair, and the replay-dedup exemption it already has (it is not in `REPLAY_TYPES`) is what
  the idempotent `project:start` path relies on.
- **D-4: `mayAcceptFrom` is also re-checked per inbound record**, not only at open. A peer can go stale after
  open (the core gains isolated sessions), and dropping its verbs with the existing addressed notice is the
  inbound mirror of the per-send `mayDeliverTo`. Checking at open only would let a stale app keep driving an
  isolated project as main.
- **D-5: `onPeerStreamClosed` → `noteClientGone(peerId)`.** A device that closed a project must stop vouching
  for focus there. Its reopen re-declares focus through the kept hook (§4.5), so a transient reset costs one
  re-declaration, not a wrong unread dot.
- **D-6: a duplicate open is refused `INVALID`, not replaced.** The app never opens a second project stream
  for a project until the first one's records have ended (§4.2 reopen rule). A duplicate is therefore a client
  bug, and replacing would let a late open from a dying stream steal a live binding.
- **D-7: the project cap fails fast on the app.** Tunnels queue at their cap (A3 D-5). An over-cap project
  open fails `CAP_EXCEEDED` at once, because a waiting project open holds a Riverpod provider build and a UI
  spinner open indefinitely. 32 warm projects on one machine is not a normal state.
- **D-8: the eval handle is `projectId`.** Every helper that took a `streamId` keeps its signature. This keeps
  the ~40 eval files that thread a stream handle source-compatible, and means the handle no longer leaks a
  bridge-internal id.
- **D-9: the fixture grows** by `streamOpen.projectRecords`.
- **Open: per-peer queue ceiling.** 32 project streams × 64 MiB is a larger theoretical per-peer bound than
  the old single 64 MiB scheduler. In practice a project stream queues only what its own core emits. A5's
  asymmetric record caps are the natural point to revisit this.
- **Open: head-of-line within a project.** One project stream is one FIFO, so a 32 MiB `file:content` still
  delays that project's `tree:update`, exactly as control FIFO did (D1 accepted this). Terminal frames are
  unaffected: they have their own streams at priority 1.
- **D-10: RPC replies are addressed** (§3.7). A broadcast reply leaked one peer's answer onto every peer's
  stream once each peer had its own project stream.
- **D-11: deleted bridge rows.** `stream-mux.test.ts` (35), the two `handshake-pull.test.ts` foreign-slot
  rows, and two `native-session-send-scheduler.test.ts` rows that tested project traffic through the
  session scheduler, which it no longer carries.
- **D-12: the app's `relay_connection_open_test.dart` uses a local multi-stream connector.** The shared
  `TestPayloadLink` (`app/test/helpers/fixed_peer_connector.dart`) does not implement `MultiStreamPeerLink`,
  so `openProject` over it fails `STREAM_UNSUPPORTED`. The helper itself is outside A4's ownership.
- **D-13: `gate-flow-control.test.ts` is rewritten for A4, not left for A5 to delete.** Both of its rows
  pushed a project `file:content` through the session `control` credit window, and project records no longer
  touch that window (the rows read 0 consumed bytes). The rows now pin the inverse: a project body several
  windows long crosses while charging the session window less than one frame, and withholding session
  credits does not stall a project stream. The window's own stop-and-resume stays pinned by
  `bridge/tests/relay-client-credit-window.test.ts`. A5 still deletes the file with the credits.
- **D-14: the interop probe opens the smoke's local-only project.** `iroh-smoke-fixture.ts` opens `alpha` as
  `"remote"`, so its core is relay-registered before any `project:start` and an open for it is admitted, not
  refused. The probe opens the last project (opened `"local"`), which is cataloged but not relay-registered:
  that is the NOT_READY case.
- **Open: the native fault soak's RSS bound is red before A4.** `test:evals:native-soak` trips its 128 MiB
  process-RSS bound about 500 s into its 30-minute default, by well under 1 MiB on A4. The A3 tree
  (`git archive HEAD`, installed separately) trips it identically at 525 s with a similar cycle count; its
  functional assertions (no duplicate mutation, no stale relay admission, ownership released) pass on both.
  It last passed whole before Stage B (docs/iroh-simplification-ledger.md).
- **Open: stale docs until A6.** `docs/protocol/peer-session.md` still names `StreamMux.projectBinding` and
  the `{s, m}` project envelope. A6 owns that file.
