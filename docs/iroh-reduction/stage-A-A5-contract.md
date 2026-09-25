# Stage A, wave A5: delete credits, schedulers, frag and the envelope

This is the frozen contract for four parallel implementers: **bridge-src**, **bridge-tests**, **dart+app**
and **evals**. Each part builds against the names and shapes below. Nobody may rename or reshape anything
pinned here without the controller's say. If your half needs something this file does not provide, report it
as `outOfScopeNeeds`. Do not invent it.

Sources:
- `stage-A-waves.md` §1.1 ("Binding constraints"), §2 rows 3, 9 and 18, §3 "A5" and §4 (D1-D7);
- the owner decisions in `ledger.md`;
- the A4 contract, whose registry, seams and ownership pattern A5 keeps;
- the two A4 carry-overs: the `TestPayloadLink` multi-stream forward and the `answerAsker` loopback broadcast.

HEAD at authoring time is `11d1e210`: A0-A4 are committed. Where this file and the spec disagree, this file
wins for A5. The deviations are listed in §9.

Hard rules for every part:
- Edit only files your part owns (§8). Report anything else in `outOfScopeNeeds`.
- Never `git stash`, `checkout`, `reset` or `restore`.
- Bun tests per workspace only (`bun run --filter <name> test`), never bare `bun test` at the root.
- CLAUDE.md applies:
  - comments say WHY and carry no change narration;
  - no comment may mention "A5", "was", "no longer" or "used to" about code that is gone.
  - A5 adds and removes **no `AbMessage` type**. The one wire frame removed, the `credit` session frame, was
    never a member of `AbMessageSchema` / `KNOWN_TYPES` (see the comment above `SessionHelloFrame` in
    `protocol.ts`), so the "Adding a message type" checklist has nothing to reverse. Its hand-validated case
    in `handleSessionFrame`, both Dart handlers, and the eval emulator's case are all deleted (§1.3).
- Binding constraints (spec §1.1), unchanged and now applying to the session stream too:
  - every write is at most 256 KiB (`STREAM_RECORD_SLICE_BYTES` / `kPeerStreamSliceBytes`);
  - the bridge calls `setPriority` once, before the first write;
  - never await `stopped()` or `receivedReset()`;
  - `authorized()` is checked per record, on both read and write;
  - a Dart open frame goes out in the same call as `openBi`;
  - every Dart error path calls `reset` explicitly.
- Security invariants, none weakened (bridge-tests pins each one that A5 touches; §3.9):
  - `remoteFrameAllowed` inbound;
  - `mayDeliver` outbound;
  - `seenProjects` + `isSafeProjectId`;
  - `mayDeliverTo` on every send;
  - `mayAcceptFrom` at open and on every record;
  - a stream open never opens or promotes a core.

---

## 0. What A5 changes, in one screen

- **Credits are gone.**
  - Deleted: `flow.ts`, `flow.dart`, the `credit` session frame, every `rxFlow`, `noteConsumed`,
    `sendCredit` and window stall, the per-tick credit resend in `checkLiveness`, and the Dart
    `_consumed` / `_creditSent` / `_noteConsumed` / `_sendCredit`.
  - QUIC flow control is the only backpressure.
- **Both schedulers are gone.**
  - Deleted: `bridge/src/send-scheduler.ts` and `send_scheduler.dart`.
  - The bridge's session stream writes through the same `StreamRecordWriter` (and reads through the same
    `StreamRecordReader`) as every other stream.
  - `bridge/src/peer/records.ts` (`PeerRecords`) is deleted. `SendOutcome` and `PeerRecordFailure` are
    **rehomed into `bridge/src/peer/stream-records.ts` before** the files that defined them are deleted
    (spec trap 3: the tunnel manager's branches, and `project-streams.ts`'s "gated" / "too-large" outcomes).
- **Fragmentation is gone.**
  - Deleted: `frag.ts`, `frag.dart`, `frag-reassembler.ts`, `fragmentForSend`, `fragmentForProjectSend`,
    every `FragReassembler`, `FragHint` / `FragSendError`, the app's `FragmentRecoveryCoordinator`, and
    `MachineSession.fragmentAborts` / `fragmentSendErrors`.
  - One `AbMessage` is always exactly one record.
  - Record caps are asymmetric: the bridge reads app records up to about 1.5 MB, and the app reads bridge
    records up to `MAX_TRANSFER_BYTES` (32 MiB) plus framing.
  - A send over the sender's cap is refused locally with `MESSAGE_TOO_LARGE`, which is kept.
- **The `{s, m}` envelope and the peer-frame `channel` are gone.**
  - The session stream's peer-frame header becomes `{type: "session" | "message"}` (§1.1):
    - `"session"` carries a bare session frame (`session:hello`, `established`, `ping`, `pong`);
    - `"message"` carries the bare JSON of one control-plane `AbMessage`.
  - Deleted: `StreamEnvelope`, `CONTROL_STREAM_ID` / `kControlStreamId`, `PeerChannel`,
    `stream_envelope.dart`.
  - `FRAME_VERSION` stays `0x04` and the ALPN stays `antgrid/peer/2` (D5). All of A lands as one release on
    this branch (spec §5), so no interim build is ever deployed with the old header.
- **The app re-issues outstanding reads when a project stream resets** (§4.5). This replaces the frag-abort
  recovery:
  - an in-flight `git:diff` / `git:commit-diff`, and the Git pane's "view file" `file:read`, are re-sent once
    the project stream is back;
  - the selected file and the preview overlay already re-fire through their tier-3 hydrators on every bind,
    so they are not re-sent twice.
- **Loopback is untouched (D2).** The loopback JSON keeps its `channel` label. `PREVIEW_CHANNEL_MESSAGE_TYPES`
  and `kPreviewChannelInboundTypes` stay, re-documented as loopback-only (§3.8, §4.6).
- **Housekeeping inside owned files:**
  - the dead X25519 plumbing in `agent-core.ts` goes (§3.7);
  - the false "app retransmits" comment in `handleHello` is corrected (§3.4).
- **Carry-overs from A4:**
  - `TestPayloadLink` forwards `MultiStreamPeerLink` and the local `_MultiStreamConnector` is deleted (§5.4);
  - `answerAsker` addresses a loopback asker instead of broadcasting (§3.7).
- **Unchanged:**
  - every stream kind and its open-frame fields;
  - admission order and refusal codes (A4 §3.3, §3.4);
  - D7 caps;
  - the A4 ready notice (`stream-ready {projectId}`, hazard J);
  - project, terminal and tunnel stream priorities and reset codes;
  - the loopback wire.
  - D1 is descoped: `file:read`, diff, search, tree and upload stay on the project stream.

---

## 1. Wire records

### 1.1 The session stream

The first bidi stream keeps its A1 open frame, `{kind: "session"}`, unchanged. After it, every record is one
peer frame:

```
[u32 BE length][version 0x04][kind 0x00][u16 BE header length][header JSON][payload]
```

Header, TS (`packages/antgrid-wire/src/peer-protocol.ts`):

```ts
export const PeerFrameHeader = z.strictObject({
  type: z.enum(["session", "message"]),
});
export type PeerFrameHeader = z.infer<typeof PeerFrameHeader>;
export type PeerFrameKind = PeerFrameHeader["type"];
```

- `PeerChannel`, `StreamEnvelope` and `CONTROL_STREAM_ID` are deleted from this file.
- `FrameKind` (`{ message: 0x00 }`), `FRAME_VERSION`, `FIXED_PREFIX` and `MAX_HEADER_LEN` in `peer-frame.ts`
  are unchanged.
- `encodePeerFrame` / `decodePeerFrame` reject a payload over `MAX_TRANSFER_BYTES` with `PAYLOAD_TOO_LARGE`.
  Before, the limit was `MAX_FRAME_PAYLOAD`.
- A header carrying `channel`, or any other key, fails the strict parse with `BAD_HEADER`.

Dart mirror (`packages/antgrid_relay_client/lib/src/frame.dart`):
- `const String kPeerFrameSession = 'session';`
- `const String kPeerFrameMessage = 'message';`
- `_validatePeerHeader` accepts exactly one key, `type`, whose value is one of those two, and rejects
  anything else.
- Encode and decode check the payload against `kMaxTransferBytes`.

Payload by kind:

| Header `type` | Payload | Who may send it |
|---|---|---|
| `"session"` | Bare session frame JSON: `session:hello {attemptId, capabilities?}`, `established {attemptId}`, `ping`, `pong`. `credit` is **deleted**. | both sides |
| `"message"` | Bare JSON of exactly one control-plane `AbMessage`, with no `{m}` wrapper and no `s`. | both sides, **only after establishment** |

Receive rules. These are the bridge's `receivePeerFrame(payload, from, kind)` and the Dart `IncomingPeerFrame`
dispatch.
1. No session for this peer yet:
   - only `kind === "session"` whose JSON `type` is `session:hello` goes to `SessionHelloFrame.safeParse`
     and then `handleHello`;
   - a parse failure calls `refusePeer(from, "protocol-violation")`;
   - everything else is dropped with the existing diagnostic reason `"pre-establishment"`, and nothing is
     counted.
2. An established session, with `kind === "session"`:
   - `session:hello` → `handleHello`, unchanged;
   - `ping` → reply `pong` on the session kind;
   - `pong` → no-op;
   - anything else is dropped with the diagnostic reason `"unknown-session-frame"`. That covers an old app's
     `credit`, and an `AbMessage`-typed body sent with the wrong kind.
3. An established session, with `kind === "message"`:
   - `JSON.parse` failure → drop with reason `"plaintext-not-json"`;
   - a value that is not an object with a string `type` → drop with reason `"unrecognized-plaintext"`. This
     is where a stale `{m}` / `{s, m}` body lands;
   - otherwise `dispatchControlPlane(json, "control", from)`, unchanged downstream, including
     `remoteFrameAllowed`.
   - `ping` / `pong` AbMessages of kind `"message"` are control-plane messages, **not** liveness frames. The
     header kind, not the JSON type, is the discriminator: `ping`, `pong` and a whole `session:*` family exist
     as `AbMessage` literals too.

Per-direction record caps on the session stream (the constants are in §2):
- **bridge reads** (app → bridge): `PEER_MAX_RECORD_BYTES` (unchanged value, 1_501_028). A longer length
  prefix is a protocol violation and retires the connection (close code 2).
- **app reads** (bridge → app): `PEER_MAX_BRIDGE_RECORD_BYTES` / `kPeerMaxBridgeRecordBytes`
  (`MAX_TRANSFER_BYTES + MAX_HEADER_LEN + FIXED_PREFIX` = 33_555_460).

### 1.2 The project stream

The open frame `{kind: "project", projectId}` is unchanged, as are the ready notice, `stream-ready
{projectId}` as the first record, and admission.

- Each record after the first is the bare UTF-8 JSON of exactly one `AbMessage`.
- **`{"__frag": …}` records no longer exist.** An inbound record that parses to a value with no string `type`
  (a stale fragment included) is dropped through the registry's existing unparseable-record path. It is never
  buffered.
- Record caps by direction (§2):
  - **bridge reads** `STREAM_PROJECT_APP_RECORD_MAX_BYTES` (1_500_000). Over it, `StreamRecordReader` raises
    its protocol violation, which retires the connection (A2 D3, unchanged);
  - **app reads** `STREAM_PROJECT_BRIDGE_RECORD_MAX_BYTES` (= `MAX_TRANSFER_BYTES`).

### 1.3 Frames removed

| Frame | Where it was | Action |
|---|---|---|
| `{type:"credit", channel, consumed}` (session frame) | bridge `handleSessionFrame` case; Dart `machine_session.dart` credit case (~`:1077-1093`) and `_sendCredit`; `evals/helpers/relay-client.ts` `sendCredit` and `case "credit"` | delete everywhere. Not an `AbMessage`, so no schema, union, `KNOWN_TYPES` or Dart parser row exists |
| `{s?, m}` envelope | bridge `routeAppEnvelope` / `routeReassembledEnvelope` / `sendAppEnvelope`; Dart `_dispatchDecoded` StreamEnvelope branch and `sendOnSession`; evals `routeAppEnvelope` / `sendControlEnvelope` | delete; payload is the bare message (§1.1) |
| `{"__frag": …}` records | session and project streams, both directions, all four parts | delete |
| peer-frame header `channel` | `PeerFrameHeader`, Dart `_validatePeerHeader`, `iroh_peer_link.dart`, evals, smoke scripts | replaced by `type` (§1.1) |

No record is **added**.

---

## 2. Caps and constants: where they live

TS in `packages/antgrid-wire/src/stream-open.ts` (the Dart mirror is in
`packages/antgrid_relay_client/lib/src/models/stream_open.dart`):

| TS name | Value | Dart name | Meaning |
|---|---|---|---|
| `MAX_TRANSFER_BYTES` | `33_554_432` | `kMaxTransferBytes = 33554432` | largest single `AbMessage` JSON the **bridge** writes on any stream. **Defined here now**, not re-exported from `frag.ts` |
| `STREAM_PROJECT_APP_RECORD_MAX_BYTES` | `1_500_000` | `kStreamProjectAppRecordMaxBytes = 1500000` | app → bridge: bridge's read cap on a project record, and the app's send refusal threshold on both the project and the session stream (payload bytes) |
| `STREAM_PROJECT_BRIDGE_RECORD_MAX_BYTES` | `= MAX_TRANSFER_BYTES` | `kStreamProjectBridgeRecordMaxBytes = 33554432` | bridge → app: the app's `maxRecordBytes` for `openStream(ProjectStreamOpen)` |
| `STREAM_TUNNEL_REQUEST_BODY_MAX_BYTES` | `= MAX_TRANSFER_BYTES` | unchanged | unchanged, now referencing the local constant |

- **Deleted:** `STREAM_PROJECT_RECORD_MAX_BYTES` / `kStreamProjectRecordMaxBytes`.
- **Deleted from `stream-open.ts`:** the `MAX_TRANSFER_BYTES, PEER_MAX_RECORD_BYTES` re-export and both
  imports (from `./frag` and `./peer-authorization`). `stream-open.ts` then imports nothing from the peer
  modules, and `peer-frame.ts` imports `MAX_TRANSFER_BYTES` from it, with no cycle.

TS in `packages/antgrid-wire/src/peer-authorization.ts` (the Dart mirror is in `frame.dart`):

| TS name | Value | Dart name |
|---|---|---|
| `PEER_MAX_RECORD_BYTES` | `STREAM_PROJECT_APP_RECORD_MAX_BYTES + MAX_HEADER_LEN + FIXED_PREFIX` (**same value** as today, 1_501_028): bridge's read cap on a session record | `kPeerMaxRecordBytes` |
| `PEER_MAX_BRIDGE_RECORD_BYTES` (**new**) | `MAX_TRANSFER_BYTES + MAX_HEADER_LEN + FIXED_PREFIX` (33_555_460): the app's read cap on a session record | `kPeerMaxBridgeRecordBytes` |

- `relay/src/server.ts` imports `PEER_MAX_RECORD_BYTES` for its WebSocket `maxPayloadLength`. The value is
  unchanged, so `relay/` is not touched.
- `packages/antgrid_peer_transport/lib/src/iroh_peer_link.dart`'s top-level `maxPeerRecordBytes` is
  deleted. Its session reader uses `kPeerMaxBridgeRecordBytes`.

Bridge-local (no wire mirror), in `bridge/src/peer/native-host-connection.ts`:

| Name | Value | Why |
|---|---|---|
| `SESSION_STREAM_MAX_QUEUED_BYTES` | `67_108_864` | fits two max-size control-plane records; the same per-stream bound as `PROJECT_STREAM_MAX_QUEUED_BYTES` |
| `STREAM_PRIORITY_SESSION` | `2` | above terminal (`1`), project (`0`) and tunnel (`-1`): liveness frames must not wait behind bulk |
| `STREAM_RESET_SESSION` | `0x19n` | the next free code after `STREAM_STOP_PROJECT = 0x18n` |

App-local, in `packages/antgrid_relay_client/lib/src/models/stream_open.dart`:
- `const int kSessionStreamMaxQueuedBytes = 4194304;`. The app's session-link write queue is bounded
  because the app only sends small control-plane records. Over it, `sendFrame` returns
  `PeerSendOutcome.backpressured`, as today with `kSocketInflightBytes`.

Deleted wholesale:
- `flow.ts` (`CHANNEL_WINDOW_BYTES`, `SOCKET_INFLIGHT_BYTES`, `CREDIT_BATCH_BYTES`, `WINDOW_RESYNC_AGE_MS`,
  `MAX_SEND_QUEUE_BYTES`, `WINDOW_STALL_WARN_MS`) and `flow.dart` (the `k…` mirrors);
- `frag.ts` (`MAX_FRAME_PAYLOAD`, `FRAG_THRESHOLD`, `FRAG_DATA_BUDGET`, `TRANSFER_TIMEOUT_MS`,
  `GLOBAL_REASSEMBLY_BUDGET`, `MAX_REREQUESTS`, `MAX_FRAGMENT_COUNT`, `FragHint`, `FragEnvelope`,
  `isFragEnvelope`, `splitForJsonData`, `buildFragments`) and `frag.dart` (the mirrors plus `FragSendError`,
  `FragReassembler`).
- `utf8ByteLength` **survives**: it moves from `frag.dart` to `frame.dart`, with the same signature and
  semantics, including U+FFFD for an unpaired surrogate. `preview_service.dart:657` and `machine_session.dart`
  keep calling it.
- `packages/antgrid-wire/src/index.ts`:
  - drops `export * from "./frag"` and `export * from "./flow"`;
  - in the named `stream-open` export list, replaces `STREAM_PROJECT_RECORD_MAX_BYTES` with
    `MAX_TRANSFER_BYTES`, `STREAM_PROJECT_APP_RECORD_MAX_BYTES` and `STREAM_PROJECT_BRIDGE_RECORD_MAX_BYTES`;
  - `peer-authorization` stays a star export, so `PEER_MAX_BRIDGE_RECORD_BYTES` rides it;
  - the comment about the ambiguous star exports is deleted, because the ambiguity is gone.
- Dart barrel `packages/antgrid_relay_client/lib/antgrid_relay_client.dart` drops the `flow.dart`,
  `frag.dart`, `send_scheduler.dart` and `models/stream_envelope.dart` exports.

---

## 3. Bridge API (bridge-src implements; bridge-tests tests against exactly this)

### 3.1 `bridge/src/peer/stream-records.ts` (rehome first)

Add, verbatim:

```ts
/** What a bus-facing send reports: `StreamSendOutcome` plus the two refusals
 *  decided before any writer is reached. `"too-large"` is a message over the
 *  sender's cap (MESSAGE_TOO_LARGE); `"gated"` is an outbound authorization
 *  hook (`mayDeliver`/`mayDeliverTo`) saying no. */
export type SendOutcome = StreamSendOutcome | "too-large" | "gated";

/** Why a peer's whole connection is retired. Mapped to a QUIC close code by
 *  `native-host-connection.ts`: unauthorized 3, protocol-violation 2, else 1. */
export type PeerRecordFailure = "connection-lost" | "protocol-violation" | "queue-full" | "unauthorized" | "superseded";
```

Retarget the importers **in the same edit**:
- `agent-core.ts:33` and `project-streams.ts:28` (`SendOutcome`);
- `peer-session-owner.ts:20` and `native-host-connection.ts:12` (`PeerRecordFailure`).

Then delete `send-scheduler.ts`, `records.ts` and `frag-reassembler.ts`. The writer and reader classes are
unchanged.

### 3.2 `packages/antgrid-wire` (bridge-src)

- `flow.ts`, `frag.ts`: delete.
- `peer-protocol.ts`, `peer-frame.ts`, `peer-authorization.ts`, `stream-open.ts`, `index.ts`: §1.1 and §2.
- `scripts/gen-peer-transport-vectors.ts`:
  - `framing.maxPayloadBytes` → `MAX_TRANSFER_BYTES`;
  - `framing.maxRecordBytes` stays `PEER_MAX_RECORD_BYTES`;
  - add `framing.maxBridgeRecordBytes: PEER_MAX_BRIDGE_RECORD_BYTES`;
  - `samples` become exactly two: `{name:"message", header:{type:"message"}, kind:FrameKind.message,
    payloadHex:"deadbeef"}` and `{name:"session", header:{type:"session"}, kind:FrameKind.message,
    payloadHex:"000102ff"}`;
  - delete the `fragmentation` and `flowControl` blocks;
  - `streamOpen.projectRecords` becomes `{ appMaxRecordBytes: STREAM_PROJECT_APP_RECORD_MAX_BYTES,
    bridgeMaxRecordBytes: STREAM_PROJECT_BRIDGE_RECORD_MAX_BYTES, maxTransferBytes: MAX_TRANSFER_BYTES }`;
  - nothing else changes.

### 3.3 `bridge/src/project-streams.ts`

- Delete:
  - `fragmentForProjectSend`, `ProjectFragmentResult` (or whatever the `:75` union is named),
    `messageFragKey`;
  - the per-binding reassembler, `sweepFragments()`, and the `newReassembler` field of
    `ProjectStreamRegistryOptions`;
  - every `FRAG_*` / `buildFragments` / `FragReassembler` import.
- `writeToRecipients`, or the equivalent send site at `:443`:
  1. `JSON.stringify(msg)` once;
  2. if `Buffer.byteLength(json) > MAX_TRANSFER_BYTES`: `diagnostics.warn`, then
     `opts.onError?.("MESSAGE_TOO_LARGE", "<type> exceeds MAX_TRANSFER_BYTES")` (the registry's existing
     error hook), then a drop diagnostic with reason `"MESSAGE_TOO_LARGE"` and `detail.bytes`, then return
     `"too-large"` and write nothing;
  3. otherwise, for each recipient that passes `mayDeliverTo`, write the one record through that binding's
     `StreamRecordWriter.send(bytes, signal)`;
  4. aggregate as today: any `"dropped"` → `"dropped"`; all `"sent"` → `"sent"`.
- The per-send `mayDeliverTo`, the per-record inbound `mayAcceptFrom`, and `mayDeliver` are untouched.
- Inbound reader cap: `new StreamRecordReader(stream, STREAM_PROJECT_APP_RECORD_MAX_BYTES, …)`.
- An inbound record is `JSON.parse`d directly (no `accept()` step). The existing malformed-record handling
  applies unchanged.
- `PROJECT_STREAM_MAX_QUEUED_BYTES`, `STREAM_PRIORITY_PROJECT`, `STREAM_RESET_PROJECT` and
  `STREAM_STOP_PROJECT`: unchanged.

### 3.4 `bridge/src/peer-session-owner.ts`

Delete:
- `FRAG_ID_SEED`, `fragIdCounter`, `FragmentForSendResult`, `fragmentForSend` (and its export);
- the `PeerSession` fields `frag`, `scheduler`, `rxFlow` and `stallWarned`;
- `newFragReassembler`, `newSendScheduler`, `drain`, `noteWindowStall`, `freshRxFlow`, `noteConsumed`,
  `sendCredit`, `recordQueueDrop` and `messageFragKey`;
- the frag sweep interval, and `stopFragSweep` with every caller of it. The registry's `sweepFragments`
  call goes with them;
- `onPeerPlaintext`'s frag branch, `routeReassembledEnvelope` and `routeAppEnvelope`;
- the `credit` case of `handleSessionFrame`, and the `channel` / `consumed` fields of its parameter type;
- the credit resend in `checkLiveness`, and scheduler clearing in `dropSession`;
- the `"project-on-session-stream"` drop and its `logUnknownStreamDrop` call. No `s` exists to test any
  more. **Keep** `logUnknownStreamDrop` only if another caller remains, else delete it with its throttle
  maps (`UNKNOWN_STREAM_LOG_INTERVAL_MS`, `MAX_TRACKED_UNKNOWN_STREAMS`);
- imports from `antgrid-wire` of `buildFragments`, `FRAG_THRESHOLD`, `MAX_TRANSFER_BYTES` (re-imported from
  the new home if used), `TRANSFER_TIMEOUT_MS`, `GLOBAL_REASSEMBLY_BUDGET`, `CONTROL_STREAM_ID`,
  `CREDIT_BATCH_BYTES` and `WINDOW_STALL_WARN_MS`.

Replace the two abstract send hooks (`sendNativePayload`, `sendNativeScheduled`) with exactly one:

```ts
/** Write one session-stream record to `peerId`. Returns null when that peer
 *  has no live session stream (nothing was queued); otherwise the writer's
 *  outcome. `signal` cancels only while the record is still queued. */
protected abstract writeSessionRecord(
  peerId: string,
  kind: PeerFrameKind,
  payload: Buffer,
  diagnosticType: string,
  signal?: AbortSignal,
): Promise<StreamSendOutcome> | null;
```

Receive:
- `protected receivePeerFrame(payload: Uint8Array, from: string, kind: PeerFrameKind): void` follows the §1.1
  receive rules.
- `lastRecvAt` / `missedPongs` are still reset on any record from an established peer.
- Diagnostics keep their current event shape until A6 retypes netwatch. Every session-stream event carries
  `channel: "control"` and no `streamId` (or `"0"` where the field is required).

Send:
- `send(msg, target?)` and `sendOnChannel(msg, channel, target?)` keep their **public signatures**. They are
  on `RemoteHostConnection` and called by `host-server.ts` and `agent-core.ts`. `channel` now labels only the
  diagnostic.
- Both call the renamed `sendAppEnvelope` → **`sendControlPlane(msg, channel, target = {kind:"broadcast"},
  signal?, authorized?): Promise<SendOutcome>`**:
  1. `signal?.aborted` or `authorized?.() === false` → `"dropped"`;
  2. `resolveRecipients(target)` is empty → the existing `"no-e2e-session"` drop → `"dropped"`;
  3. `JSON.stringify(msg)` once; over `MAX_TRANSFER_BYTES` → `opts.onError?.("MESSAGE_TOO_LARGE", …)`, a
     drop diagnostic with reason `"MESSAGE_TOO_LARGE"`, and `"too-large"`;
  4. for each recipient, `writeSessionRecord(peerId, "message", buf, type, signal)`; `null` counts as
     `"dropped"`;
  5. aggregate as §3.3 step 4.
- The per-message `authorized` predicate is checked **at send time only** (D-4).
- `sendSessionMessage` (`:286`) calls `sendControlPlane(msg, "control", {kind:"peer", peerId})`.
- `sendSessionFrame(obj, to)` becomes `void this.writeSessionRecord(to, "session", Buffer.from(JSON…),
  type)` and does no charging.

`handleHello` comment:
- Delete the parenthetical "(the app retransmits until it sees `established`)" at `:778-780`.
- If the sentence needs a replacement, state the true contract: the app sends one hello per connection and
  does not retransmit (`connection_handshake.dart`). A lost `established` surfaces as the app's handshake
  timeout and a fresh dial.

`PeerSessionOwnerOptions`: drop any `creditBatchBytes` / scheduler / frag option. Keep `onError`.

### 3.5 `bridge/src/peer/native-host-connection.ts`

Per-peer record:
- `records?: PeerRecords` becomes `sessionWriter?: StreamRecordWriter`.
- Built right after the session open frame is read and validated, where `new PeerRecords(…)` is today:
  ```ts
  const writer = new StreamRecordWriter(
    { send: stream.send },
    () => this.authorized(peerId, endpointId),
    (reason) => { if (this.nativePeers.get(peerId)?.sessionWriter === writer)
      this.retirePeer(peerId, reason === "unauthorized" ? "unauthorized"
        : reason === "overflow" ? "queue-full" : "connection-lost"); },
    SESSION_STREAM_MAX_QUEUED_BYTES, STREAM_PRIORITY_SESSION, STREAM_RESET_SESSION,
  );
  const reader = new StreamRecordReader({ recv: stream.recv }, PEER_MAX_RECORD_BYTES,
    () => { if (this.nativePeers.get(peerId) === peer) this.retirePeer(peerId, "protocol-violation"); });
  ```
- A session-stream overflow retires the **connection**. This is the one exception to D3: losing the session
  stream is losing the session. With no 5 s write timeout, no connection is killed for a slow write. Dead
  peers are detected by liveness (`checkLiveness` ping/pong) alone.
- Nothing in this file may await `stopped()` or `receivedReset()`.

Read loop:

```ts
for (;;) {
  if (!this.authorized(peerId, endpointId)) { this.retirePeer(peerId, "unauthorized"); return; }  // D-11
  const record = await reader.read();                 // rejects on FIN/reset → retire "connection-lost"
  if (!this.authorized(peerId, endpointId)) { this.retirePeer(peerId, "unauthorized"); return; }
  const frame = decodePeerFrame(record);              // FrameError → retire "protocol-violation"
  this.receivePeerFrame(frame.payload, peerId, frame.header.type);
}
```

- A `StreamProtocolViolation` from the reader has already retired the peer through `onFailure`, so the catch
  must not retire it a second time with a different reason.
- The pre-hello timer and the `acceptUni` guard call `retirePeer(peerId, "connection-lost")` and
  `retirePeer(peerId, "protocol-violation")` directly. They replaced `records.close(…)`.
- `retirePeer` calls `peer.sessionWriter?.abort()` in place of `records.close(reason)`, then closes the
  connection with the mapped code as today.

`writeSessionRecord`:
- `peer?.sessionWriter` is absent → `null`;
- otherwise `writer.send(encodePeerFrame({ type: kind }, payload), signal)`.
- Delete the `sendNativeScheduled` / `sendNativePayload` overrides and the imports of `MAX_FRAME_PAYLOAD`,
  `PendingSinkWrite`, `QueuedAppFrame` and `PeerRecords`.
- The `receivePeerFrame` override (`:520`) takes `kind: PeerFrameKind` in place of `channel`.

### 3.6 `bridge/src/protocol.ts`

- The `PREVIEW_CHANNEL_MESSAGE_TYPES` doc comment (`:3060-3084`) is rewritten. The set itself is unchanged.
  The rewrite says:
  - the channel label is a **loopback** concept (D2);
  - `LocalTransport` / `message_router.dart` gate on it;
  - on Iroh, terminal payloads ride their own terminal streams and the session stream has no channels.
- It keeps the hand-mirror sentence (`kPreviewChannelInboundTypes`, `checkout-mirror-contract.test.ts`) and
  the `sendAbToItsChannel` sentence.
- It drops every mention of `SendScheduler`, `SOCKET_INFLIGHT_BYTES`, credits and windows.
- No schema change.

### 3.7 `bridge/src/agent-core.ts`

- `SendOutcome` import from `./peer/stream-records`.
- The `sendPreviewAbTo` doc comment (`:2497-2517`) is rewritten to the loopback-only rationale, with no
  scheduler, `CHANNEL_WINDOW_BYTES` or `SOCKET_INFLIGHT_BYTES`. `sendAbToItsChannel` is kept unchanged: it
  still picks the loopback label, and on Iroh the terminal route intercepts first.
- **Dead X25519 plumbing**, deleted:
  - `generateEphemeralKeypair` and `EphemeralKeypair` from the `:36` import (keep the import line only if
    something else in it is still used);
  - `readonly nextKeypair: () => EphemeralKeypair;` in the `AgentCore` interface (`:237`);
  - `const initialKeypair = generateEphemeralKeypair();` (`:685`);
  - `function nextKeypair()` (`:963-965`);
  - `nextKeypair,` in the returned object (`:5038`).
  - `key-exchange.ts` is **kept**: `push/seal.ts` uses it.
  - `evals/tests/machine-trust.test.ts` imports `generateEphemeralKeypair` from `key-exchange.ts` for push
    keys only and never reads `AgentCore.nextKeypair`, so it is unaffected (verified by grep; §7).
- **Carry-over 2, `answerAsker`** (`attachTransport`, `:4845`) becomes:
  ```ts
  const answerAsker = (res: AbMessage): void => {
    if (source === "loopback") bus.publishOnly(res, channel, "loopback");
    else if (peerId !== undefined) bus.publishOnly(res, channel, "relay", peerId);
    else log.warn("Dropping %s: relay asker has no peerId", res.type);
  };
  ```
  - The WHY comment says an RPC response belongs to its asker, and a broadcast hands it to every relay peer
    bound to the project.
  - A relay-origin frame without a `peerId` cannot be addressed, so it fails closed.
  - `host-server.ts`'s own `answerAsker` (machine bus) is **not** changed.

### 3.8 Other bridge-src files

- `bridge/src/tunnel-manager.ts`: no change needed (it already imports `StreamSendOutcome`). Verify it still
  compiles after `send-scheduler.ts` is gone.
- `bridge/src/peer/stream-dispatch.ts`: reword the `:5` comment. It names `PeerRecords`; the session
  stream's I/O is now `StreamRecordWriter` / `StreamRecordReader`.
- `bridge/scripts/iroh-host-smoke.ts`:
  - `PeerRecords` → `StreamRecordWriter` / `StreamRecordReader`;
  - header `{type:"message"}` for control-plane sends and `{type:"session"}` for the hello;
  - bare messages, not `{m}`;
  - the project reader cap becomes `STREAM_PROJECT_BRIDGE_RECORD_MAX_BYTES`.
- `bridge/scripts/iroh-interop-smoke.ts`: verify only.
- `bridge/CLAUDE.md`:
  - line 39 ("owns peer session establishment, fragments, scheduling and peer liveness") → "establishment and
    peer liveness";
  - line 86: drop "fragmentation, scheduling and credits". Add one clause: the session stream's I/O is the
    same `StreamRecordWriter` / `StreamRecordReader` as every other stream, and its header `type` (`session`
    vs `message`) is the only discriminator between liveness and control-plane records.

### 3.9 Security invariants A5 touches (bridge-tests pins each)

| Invariant | Where after A5 | Pinned by |
|---|---|---|
| `authorized()` per inbound session record | §3.5 read loop | native-host-connection row N3 |
| `authorized()` per outbound slice | `StreamRecordWriter` (unchanged) | existing `stream-records.test.ts` rows |
| pre-establishment drop of everything but a `session`-kind hello | §1.1 rule 1 | peer-session-hello rows H1, H2 |
| `remoteFrameAllowed` on control-plane inbound | `dispatchControlPlane` (unchanged) | existing `remote-access-gate.test.ts` (verify) |
| `mayDeliverTo` per project send, `mayAcceptFrom` per project record | `project-streams.ts` (unchanged) | existing `project-streams.test.ts` rows (verify) |
| RPC reply addressed to the asker, loopback included | §3.7 | `agent-core-answer-asker.test.ts` |

---

## 4. Dart API (dart+app)

### 4.1 `packages/antgrid_relay_client/lib/src/peer_link.dart`

```dart
class IncomingPeerFrame {
  const IncomingPeerFrame({required this.kind, required this.payload});
  /// [kPeerFrameSession] or [kPeerFrameMessage].
  final String kind;
  final Uint8List payload;
}

abstract interface class PeerLink {
  // … unchanged members …
  Future<PeerSendOutcome> sendFrame(String kind, Uint8List payload);
}
```

- `channel` is renamed to `kind` on both. Every implementer and caller changes with it (§7).
- An implementer given a kind outside the two constants returns `PeerSendOutcome.failed` and fails the link
  as `INVALID_PEER_FRAME`, as it does for a bad channel today.
- `PeerSendOutcome`, `PeerStream` and `MultiStreamPeerLink` are unchanged.

### 4.2 `packages/antgrid_peer_transport/lib/src/iroh_peer_link.dart`

Session-stream reader (`_read`):
- The length check is against `kPeerMaxBridgeRecordBytes`.
- A body longer than `kPeerStreamSliceBytes` is read in `readExact` pieces of at most that size, mirroring
  `StreamRecordReader`.
- `decodePeerFrame` followed by the header-kind check.
- Emits `IncomingPeerFrame(kind: header['type'], payload: …)`.

Session-stream writer (`sendFrame(kind, payload)`):
- Kind check.
- `payload.length > kStreamProjectAppRecordMaxBytes` → `tooLarge`.
- Encode `{'type': kind}`.
- Queue bound `kSessionStreamMaxQueuedBytes` → `backpressured`.
- **Delete the 5 s `WRITE_TIMEOUT` timer** (spec §2 row 3). Liveness is the dead-peer detector.
- The record is written through a new top-level helper shared with `NativePeerStream._writeInSlices`:
  ```dart
  /// Writes [record] in `writeAll` calls of at most [kPeerStreamSliceBytes]:
  /// a cancel or reset then waits on one slice, never a whole record.
  /// Returns false if [stop] turned true between slices.
  Future<bool> writeRecordInSlices(PeerStreamSend send, Uint8List record, {bool Function()? stop});
  ```
- `IrohPeerLink._send` becomes a `PeerStreamSend` (`_IrohStreamSend(send)`) so the helper applies.
- Every error path of `sendFrame` still ends in `_fail(…)`, which closes the connection. Nothing here is a
  per-stream reset.
- Delete the `kMaxFramePayload` and `kSocketInflightBytes` references and `maxPeerRecordBytes`.
- The dial-time comment at `:102-105` is rewritten. It currently says the session stream keeps its own I/O
  "for the credit/frag path". The true reason: the session stream is the session, so its failures close the
  connection rather than reset one stream.

`leased_peer_link.dart`: `sendFrame(String kind, …)` forwards. `bin/native_smoke.dart`: header
`{'type': 'message'}` / `'session'`, `sendFrame('message', …)`, and the `channel` checks become kind checks.

### 4.3 `MachineSession` (`machine_session.dart`)

Delete:
- the constructor params `channelWindowBytes`, `socketInflightBytes` and `creditBatchBytes`, and the fields
  behind them;
- `_scheduler`, `debugScheduler`, `_consumed` / `_creditSent`, `_noteConsumed` / `_sendCredit`, and the tick
  credits;
- `_reassembler` (session and per-project), `_fragCounter`, `_fragAborts` / `_fragSendErrors`,
  `fragmentAborts` / `fragmentSendErrors`;
- the `StreamEnvelope` branch of `_dispatchDecoded` and the `credit` case.

Add:

```dart
/// One outbound message refused locally for exceeding the peer's read cap.
class MessageTooLarge {
  const MessageTooLarge(this.type, this.bytes);
  final String? type;
  final int bytes;
}
Stream<MessageTooLarge> get messageTooLarge;   // broadcast
```

`sendOnSession(Map<String, dynamic> message, String channel)` keeps its signature. It is serialized on one
`_sessionSendChain` future, and does, in order:
1. `_generation == null` → the existing `'no-e2e-session'` drop and info log;
2. `jsonEncode`, then `utf8ByteLength(json) > kStreamProjectAppRecordMaxBytes` → `_dropped('tx',
   'message-too-large', …, detail: {'bytes': n})`, add a `MessageTooLarge`, return;
3. **generation fence**: capture `gen = _generation` when the call is chained. Immediately before
   `relay.sendFrame(kPeerFrameMessage, bytes)`, if `!identical(gen, _generation)`, drop with
   `'no-e2e-session'` and the existing warn "queued frame dropped — session went down before it was sent".
   This preserves the `_SessionGeneration` dequeue fence that the deleted scheduler enforced (`app/CLAUDE.md`,
   "Session hello, no app-layer crypto");
4. after the send, the `outcome != accepted || !identical(gen, _generation)` check and `_annotate` are
   unchanged.

The future still means "handed to the link, or dropped". Other session sends:
- session frames (`ping`, `pong`) go via `relay.sendFrame(kPeerFrameSession, …)`, directly and unchained;
- the hello is `connection_handshake.dart`'s, with the kind `session`.

Inbound (`relay.messageStream`):
- `kind == kPeerFrameSession` → session frames: `established` stays with the handshake; `ping` → `pong`;
  `pong` → liveness; else drop `'unknown-session-frame'`;
- `kind == kPeerFrameMessage` → `jsonDecode`, then a map with a String `type` →
  `dispatchFromSession(json, 'control')`, else drop `'unrecognized-plaintext'`.

Project transport (`_ProjectStreamTransport` or equivalent):
- `openStream(ProjectStreamOpen(projectId), maxRecordBytes: kStreamProjectBridgeRecordMaxBytes,
  maxQueuedBytes: kProjectStreamMaxQueuedBytes)`.
- `_onProjectRecord` decodes one record as one message, with no reassembly.
- `_doSendProject`:
  - `utf8ByteLength > kStreamProjectAppRecordMaxBytes` → `session._dropped('tx', 'message-too-large', …)`
    plus a `MessageTooLarge` event, and return;
  - otherwise one `stream.send(bytes)`.
- The reopen, backoff, cap-slot and `projectStreamEvents` behavior from A4 are unchanged.

Diagnostics that named `kControlStreamId` use a private `const _kSessionStreamLabel = '0'`, so netwatch
captures keep their shape until A6.

`connection_handshake.dart`:
- `msg.channel != 'control'` → `msg.kind != kPeerFrameSession`;
- the hello is sent with `sendFrame(kPeerFrameSession, …)`.

`models/stream_open.dart`: §2 constants. `frame.dart`: §1.1, §2, plus `utf8ByteLength`. Delete
`flow.dart`, `frag.dart`, `send_scheduler.dart` and `models/stream_envelope.dart`.

`packages/antgrid_relay_client/CLAUDE.md`:
- the `machine_session.dart` bullet loses:
  - "control-plane frag reassembly";
  - the `StreamEnvelope`/`s` sentence;
  - `credit` from the session-frame list;
  - the whole `send_scheduler.dart` / credit-window passage;
- it gains the header-kind discriminator and the §4.3 generation fence;
- the `frag.dart` bullet is deleted. Its `utf8ByteLength` rationale moves to a doc comment on the function in
  `frame.dart`.

### 4.4 Carry-over 1 is a test helper: see §5.4.

### 4.5 App: re-issue on project-stream reset (spec "A5 Build")

`app/lib/services/file_service.dart`:
- Delete `onFragmentSuccess` and its three call sites (`:459`, `:506`, `:611`), `handleFragmentFailure`, and
  the frag-backstop wording in the `gitActionTimeout` doc (`:80-84`) and at `:1096`.
- **Keep** `_failFileContent` and `_failDiff`: the retry bound below uses them. The user-facing text becomes
  `'Transfer failed — the connection to the machine reset while loading.'`.
- Add:
  ```dart
  /// Consecutive stream resets one outstanding request survives before its
  /// pane is failed instead of re-requested. Bounds a transfer that resets its
  /// stream every time it is sent.
  static const int kMaxStreamResetReissues = 2;

  /// Re-sends the reads this service is still waiting on, after the project
  /// stream carrying them was reset and reopened (their replies died with it).
  void reissueAfterStreamReset();
  ```
- Tracked state:
  - `_inflightDiff`, a `({String path, String? sha})?`. It is set by `requestDiff` / `requestCommitDiff`.
    It is cleared when the matching `git:diff-content` / `git:commit-diff-content` lands, or when the diff is
    cleared or superseded. It is **not** cleared by the latch's timeout or `SessionDownException` catch.
  - `_inflightGitView`, a `String?`. It is set by `gitViewFile`, and cleared when the `file:content` for that
    path lands or the Git view is cleared.
  - A `Map<String, int> _resetReissues` keyed `'diff <sha?> <path>'` / `'view <path>'`, cleared on the
    matching reply.
- Behavior:
  - diff: if `_inflightDiff` is still what the pane targets (`git.diffPath == path` and `git.diffCommitSha ==
    sha`), bump its counter and call `requestDiff(path)` or `requestCommitDiff(sha, path)`. Once the counter
    exceeds `kMaxStreamResetReissues`, call `_failDiff(path)` instead and clear the tracking;
  - Git view: the same shape, with `requestFileContent(path)` and `viewingLoading: true`, else
    `_failFileContent(path)`;
  - **not** re-sent: `files.selectedFilePath` and `preview.path`. Their tier-3 hydrators
    (`_hydrateSelectedFile`, `_hydratePreview`) already re-fire on every project-stream (re)bind
    (`machine_session.dart`, the hydrator re-drive after bind), and re-sending here would double a
    multi-megabyte read.

`app/lib/project/project_session.dart`:
- Delete the `FragmentRecoveryCoordinator` wiring (`:158-170`), `_fragAbortSub`, `_fragSendErrSub`,
  `_onFragmentSendError` and the `fragment_recovery.dart` import.
- Add `_messageTooLargeSub = session.messageTooLarge.listen(_onMessageTooLarge)`. It logs as
  `_onFragmentSendError` did: `developer.log('send dropped: MESSAGE_TOO_LARGE <type> <bytes>', name:
  'antgrid.relay')`. It is cancelled in `dispose` where the old subs were.
- Add `bool _projectStreamLost = false;`. In the `projectStreamEvents` listener:
  - `open == false` sets it;
  - `open == true`, and it is set: clear it, run the existing `resyncFocusState`, `resyncFocus` and
    `_markUp`, **then** call `reissueAfterStreamReset()` on the `FileService` of every bundle in
    `checkoutServiceBundles` (main included).
  - The `sessionDownEvents` listener also sets it.
  - The first open of a session re-issues nothing.

`app/lib/project/fragment_recovery.dart`: delete.

`app/lib/services/preview_service.dart`: no change. `utf8ByteLength` now resolves from `frame.dart` through
the same barrel.

### 4.6 App: loopback labels stay

- `app/lib/project/project_message_classification.dart`: the `kPreviewChannelInboundTypes` doc comment says
  the set gates the **loopback** `channel` label only (D2). Keep the set and the mirror sentence.
- `app/lib/project/message_router.dart:95-110`: the gate is kept. Only its comment changes, to the same
  loopback-only wording.
- Spec trap 2: removing `channel` from the loopback JSON breaks desktop preview (`preview_service.dart:191`)
  with every Iroh test green. `local_transport.dart` and the loopback JSON are **not touched**.

### 4.7 Eval client (`packages/antgrid_eval_client/lib/src/commands.dart`)

- `kControlStreamId` → a private `const _kControlHandle = '0';`. The eval protocol's handle is unchanged
  (A4 D-8).
- The file-level doc (`:51`) drops "control-plane fragment reassembly".
- `generateX25519KeyPair` (`:161`) is **not** touched: it feeds `DeviceIdentity`'s X25519 fields, which are
  outside A5.

---

## 5. Test seams after A5

### 5.1 `bridge/tests/test-peer-session-owner.ts` (bridge-tests)

- The imports of `QueuedAppFrame`, `PendingSinkWrite` and `FragReassembler` are deleted.
- `setNativeWriter(writer: (payload: Buffer, to: string, kind: PeerFrameKind, diagnosticType: string) =>
  boolean)`.
- The single override `writeSessionRecord(peerId, kind, payload, type)` calls the writer. `false` →
  `null`; `true` → record the outbound, then `Promise.resolve("sent")`.
- Outbox entries become `{ kind: PeerFrameKind; payload: Buffer }`:
  - `readToPeer(peerId): unknown` pops one and returns the parsed payload: a bare `AbMessage` or session
    frame, never `{m}`;
  - **new** `readFrameToPeer(peerId): { kind: PeerFrameKind; body: unknown }` for rows that assert the kind;
  - `sentTo(peerId): ReadonlyArray<Buffer>` keeps returning payload bytes;
  - **new** `sentFramesTo(peerId): ReadonlyArray<{ kind: PeerFrameKind; payload: Buffer }>`.
- `sendFromPeer(peerId, obj, kind: PeerFrameKind = "message")`. The `Channel` parameter is gone.
- `injectPeerPayload(payload, from, kind: PeerFrameKind = "message")` → `receivePeerFrame(payload, from,
  kind)`.
- `injectPeerFrame(frame, peerId)` decodes and passes `decoded.header.type`.
- `establish(…)` injects its hello with kind `"session"`, and still deletes the `established` reply from the
  outbox.
- `openProjectStream(…).read()` parses each record directly. The reassembler and the `__frag` branch go, and
  so does the loop-scoping comment about them.
- `forTest` drops `creditBatchBytes`.
- The trailing export becomes `export { MAX_APP_SESSIONS } from "../src/peer-session-owner";`.

`bridge/tests/fake-session.ts`:
- `newSendScheduler` and the `scheduler` / `frag` / `rxFlow` / `stallWarned` fields are dropped from the
  installed `PeerSession`;
- the comment mentioning `sendAppEnvelope` becomes `sendControlPlane`.

### 5.2 `packages/antgrid_relay_client/test/support/fake_live_relay.dart` (dart+app)

- `FakeLiveRelay` implements `sendFrame(String kind, Uint8List payload)`.
- Its captured-frame list records `kind`.
- Its injector for agent → app frames takes `kind` (default `kPeerFrameMessage`) and emits
  `IncomingPeerFrame(kind:, payload:)`.
- Helpers that wrapped `{'m': …}` send the bare message.
- Helpers that built `credit` or `__frag` frames are deleted.
- The fake agent's `established` reply and `pong` go out with the kind `kPeerFrameSession`.

### 5.3 `evals/helpers/relay-client.ts` and `evals/support/` (evals)

`relay-client.ts`:
- Imports:
  - delete `PeerRecords`, `FragReassembler`, `CREDIT_BATCH_BYTES` and `CONTROL_STREAM_ID`;
  - import `StreamRecordWriter`, `StreamRecordReader` from `../../bridge/src/peer/stream-records`, and
    `PEER_MAX_BRIDGE_RECORD_BYTES` and `STREAM_PROJECT_BRIDGE_RECORD_MAX_BYTES` from `antgrid-wire`.
- `connectNative`: the session stream gets the following pair. Its open frame is written as the first record
  on the writer, and `writer.send` keeps order:
  ```ts
  new StreamRecordWriter(stream, () => generation === this.nativeGeneration, onFailure, 64 MiB)
  new StreamRecordReader(stream, PEER_MAX_BRIDGE_RECORD_BYTES, onFailure)
  ```
- Receive: `decodePeerFrame(record)`:
  - `header.type === "session"` → `handleSessionFrame`;
  - `"message"` → parse. Tag the message `_streamId = "0"`, as the envelope path did, and queue it.
- Send:
  - `sendPlaintextFrame(obj, kind: "session" | "message")`;
  - `sendControlEnvelope` → `sendControlMessage(msg)`, which writes the bare `msg` with kind `"message"`;
  - `performE2EHandshake` sends its hello with kind `"session"`.
- Delete `rxConsumed`, `rxCredited`, `creditsPaused`, `noteConsumed`, `sendCredit`, `setCreditsPaused`,
  `consumedBytes`, `fragReassembler`, the fragment counter, and `case "credit"`.
- `sendOnStream(handle, msg, channel = "control")` keeps its **signature** (A4 D-8). On `"0"`, `channel` is
  ignored and it calls `sendControlMessage`. On a project handle, it writes one record with no fragmenting.
- The project-stream reader cap becomes `STREAM_PROJECT_BRIDGE_RECORD_MAX_BYTES`. The `__frag` branch at
  `:1424` goes.
- Doc comments at `:284-297`, `:1351` and `:1443-1449` drop fragments, credits and envelopes.

`evals/support/stream.ts`:
- **add** `export const CONTROL_HANDLE = "0";`, the eval-side name for the machine control plane.
- `evals/helpers/dart-app-client.ts` imports it in place of `CONTROL_STREAM_ID`.

### 5.4 Carry-over 1: `app/test/helpers/fixed_peer_connector.dart` (dart+app)

`TestPayloadLink implements PeerLink, MultiStreamPeerLink`:
- `openStream(open, {required maxRecordBytes, required maxQueuedBytes})` forwards to `carrier` when `carrier
  is MultiStreamPeerLink`.
- Otherwise it throws the same `UnsupportedError` that `LeasedPeerLink.openStream` throws for a non-multi
  inner link. This mirrors the production wrapper, which also implements the interface unconditionally.
- `sendFrame(String kind, …)` forwards.
- `_NoopPayloadLink` takes the new `sendFrame` signature.
- `app/test/relay/relay_connection_open_test.dart` deletes `_MultiStreamConnector` and
  `_MultiStreamPayloadLink` (`:310-333`) and uses `FixedPeerConnector(relay)` directly.

---

## 6. Tests: added, changed, deleted

### bridge-tests

**Delete** (with spec §2 row 18):
- `bridge/tests/send-scheduler.test.ts`
- `bridge/tests/native-session-send-scheduler.test.ts`
- `bridge/tests/relay-client-credit-window.test.ts`
- `bridge/tests/relay-client-frag-send.test.ts`
- `bridge/tests/frag-reassembler.test.ts`
- `bridge/tests/peer-records.test.ts`
- `packages/antgrid-wire/tests/flow.test.ts`
- `packages/antgrid-wire/tests/frag.test.ts`

**Change:**
- `bridge/tests/terminal-frame-cancellation.test.ts`: delete every row that constructs `SendScheduler`
  (`:69-73`). If no row remains, delete the file and list it in the report.
- `bridge/tests/project-streams.test.ts`: row 15 is replaced by:
  - **P1** "a message over the app read cap is written as one record, never fragmented". A 5 MB
    `file:content` arrives as exactly one record after `stream-ready`, and no record has a `__frag` key.
  - **P2** "a message over `MAX_TRANSFER_BYTES` is too-large, writes nothing and reports MESSAGE_TOO_LARGE".
    The outcome is `"too-large"`, the `onError` code is `MESSAGE_TOO_LARGE`, and no write happened.
  - **P3** "A5: a 32 MiB record is written as slices, not as one array" (spec test 2). A `file:content`
    whose JSON is `MAX_TRANSFER_BYTES - 1024` bytes goes through `sendTo`. Assertions:
    - every `writeAll` call on the fake has length `<= STREAM_RECORD_SLICE_BYTES`;
    - there are at least 128 calls;
    - the reassembled record equals the JSON.
  - **P4** "an inbound `__frag` record is dropped, not buffered". It is followed by a normal verb, which
    dispatches.
  - **P5** "an app record over `STREAM_PROJECT_APP_RECORD_MAX_BYTES` is a protocol violation". The length
    prefix is `1_500_001`, and the connection-retire hook fires with `protocol-violation`.
  - Rows at `:335`, `:403-413` that reason about `FRAG_THRESHOLD` are rewritten against the §2 caps.
  - The imports of `buildFragments`, `FRAG_THRESHOLD` and `MAX_TRANSFER_BYTES` from the old names are fixed.
- `bridge/tests/native-host-connection.test.ts`:
  - **N1** "the session stream sets priority `STREAM_PRIORITY_SESSION` once, before its first write";
  - **N2** "a 32 MiB control-plane record on the session stream is written in ≤256 KiB slices", through
    `writeSessionRecord`;
  - **N3** "an inbound session record read after authorization is revoked retires the peer unauthorized
    (close code 3) and is not dispatched";
  - **N4** "a session header carrying `channel` retires the peer protocol-violation (close code 2)";
  - **N5** "an inbound session record longer than `PEER_MAX_RECORD_BYTES` retires the peer
    protocol-violation";
  - **N6** "a session-stream write that never completes does not retire the peer on a timer". Hold the fake
    write, advance past 5 s with the suite's clock control, and assert the peer is still in `nativePeers`.
    If the suite has no clock control, bridge-tests reports this row as `outOfScopeNeeds` instead of
    sleeping.
  - Also: update the `sendNativeScheduled` / `sendNativePayload` harness types at `:8`, `:352` and `:508` to
    `writeSessionRecord`.
- `bridge/tests/peer-session-hello.test.ts`:
  - **H1** "pre-establishment, a `message`-kind record is dropped with `pre-establishment` and establishes
    nothing";
  - **H2** "pre-establishment, a `session:hello` body sent with the `message` kind does not establish";
  - **H3** "an established `message`-kind `{m: …}` body is dropped `unrecognized-plaintext`";
  - **H4** "an established `message`-kind `ping` AbMessage reaches control-plane dispatch and is not answered
    with a liveness `pong`";
  - **H5** "a `credit` session frame is dropped `unknown-session-frame`";
  - rewrite `:57`, `:75` and `:345` (bare messages, not `{m}`), and the `PeerRecords` comments at
    `:208-224`.
- `bridge/tests/handshake-pull.test.ts`:
  - `:97` sends a bare message (kind `"message"`, no `"preview"`);
  - `:167-168` expect the bare message;
  - the three `creditBatchBytes` / `setNativeWriter` users take the new seam.
- `bridge/tests/terminal-frame-cancellation.test.ts`, `tunnel-manager-stream.test.ts`,
  `tunnel-manager-ws-order.test.ts`: import paths only, where they touched the deleted files.
- **New** `bridge/tests/agent-core-answer-asker.test.ts` (carry-over 2):
  - **Q1** "a loopback asker's RPC reply reaches the loopback subscriber only". A bus has one `"loopback"`
    subscriber and one `"relay"` subscriber for peer P. A loopback-origin `state.snapshot` request is
    answered to the loopback subscriber, and the relay subscriber receives nothing.
  - **Q2** "a relay asker's reply reaches that peer only", the D-10 regression, with two relay peers.
  - **Q3** "a relay-origin request with no peerId is answered to no one".
  - Build on whichever existing `attachTransport` harness is lightest. `agent-core-terminal-snapshot-rpc.test.ts`
    is the reference.
- `packages/antgrid-wire/tests/peer-frame.test.ts`:
  - both kinds round-trip;
  - `{type:"message", channel:"control"}` is rejected `BAD_HEADER`;
  - a `MAX_TRANSFER_BYTES + 1` payload is rejected `PAYLOAD_TOO_LARGE`, replacing the `MAX_FRAME_PAYLOAD + 1`
    row.
- `packages/antgrid-wire/tests/stream-open.test.ts`:
  - `:113-116` becomes "`MAX_TRANSFER_BYTES` is 33_554_432 and defined in stream-open.ts";
  - `:222-226` becomes "project caps are asymmetric": app 1_500_000, bridge `MAX_TRANSFER_BYTES`;
  - add "`PEER_MAX_RECORD_BYTES` is unchanged at 1_501_028 and `PEER_MAX_BRIDGE_RECORD_BYTES` is
    `MAX_TRANSFER_BYTES + MAX_HEADER_LEN + FIXED_PREFIX`".
- `packages/antgrid-wire/tests/peer-transport-vectors.test.ts`: follow §3.2. Delete the fragmentation and
  flow-control expectations (`:8-23`, `:130-134`), and update `projectRecords` (`:87-91`).
- Verify only (edit only if red): `stream-records.test.ts`, `remote-access-gate.test.ts`,
  `checkout-mirror-contract.test.ts`, `host-server.test.ts`, `host-control-plane.test.ts`,
  `control-plane-start.test.ts`, `account-trust-phone-registration.test.ts`, `relay-client-no-pairing.test.ts`,
  `session-bus-remote-directory.test.ts`, `netwatch.test.ts`, `netwatch-remote.test.ts`,
  `host-policy-fixture.ts`, and the push-targeting tests.

### dart+app

**Delete:**
- `packages/antgrid_relay_client/test/flow_test.dart`
- `packages/antgrid_relay_client/test/frag_test.dart`
- `packages/antgrid_relay_client/test/send_scheduler_test.dart`
- `packages/antgrid_relay_client/test/machine_session_flow_control_test.dart`
- `app/test/project/fragment_recovery_test.dart`

**Change:**
- `packages/antgrid_relay_client/test/machine_session_envelope_test.dart` is rewritten around the header
  kind (keep the filename):
  - **E1** "a `message`-kind bare AbMessage dispatches on the control plane";
  - **E2** "a `message`-kind `{m: …}` body is dropped `unrecognized-plaintext`";
  - **E3** "a `session`-kind `ping` is answered with a `session`-kind `pong`";
  - **E4** "a `message`-kind `ping` AbMessage is not answered as liveness";
  - **E5** "a `session`-kind `credit` is dropped";
  - **E6** "`sendOnSession` writes the bare message with the `message` kind".
- **New** rows in `machine_session_establish_test.dart` or `…_rekey_test.dart`, whichever already drives
  generations:
  - **G1** "a control-plane send chained behind a pending write is dropped, not written, when the session
    generation changes before its turn". This ports the scheduler's dequeue-fence row.
  - **G2** "`sendOnSession` over `kStreamProjectAppRecordMaxBytes` drops `message-too-large`, writes
    nothing, and emits one `MessageTooLarge`".
- `machine_session_project_stream_test.dart`:
  - **S1** "the project stream is opened with `maxRecordBytes: kStreamProjectBridgeRecordMaxBytes`";
  - **S2** "a 20 MB inbound project record dispatches as one message";
  - **S3** "a project send over `kStreamProjectAppRecordMaxBytes` drops `message-too-large` and emits
    `MessageTooLarge`";
  - replace any frag rows.
- `packages/antgrid_peer_transport/test/native_peer_stream_test.dart`:
  - **W1** "`writeRecordInSlices` writes a 32 MiB record in `writeAll` calls of at most
    `kPeerStreamSliceBytes`", over the existing fake `PeerStreamSend`;
  - **W2** "`writeRecordInSlices` stops between slices when `stop` turns true".
- `packages/antgrid_peer_transport/test/peer_transport_vectors_test.dart`:
  - follow the §3.2 fixture;
  - delete the frag and flow expectations (`:76-86`);
  - `kMaxFramePayload` (`:36`) → `kMaxTransferBytes`;
  - add `kPeerMaxBridgeRecordBytes` and both project caps.
- `app/test/services/file_service_test.dart`: the frag-failure rows at `:716` and `:733` are replaced by:
  - **F1** "reissueAfterStreamReset re-sends an in-flight `git:diff` for the pane's current path";
  - **F2** "…re-sends an in-flight `git:commit-diff` with its sha";
  - **F3** "…re-sends the Git view's `file:read` and sets viewingLoading";
  - **F4** "…does not re-send the selected file or the preview (hydrators own them)";
  - **F5** "…does nothing for a diff whose reply already landed";
  - **F6** "…fails the diff pane after `kMaxStreamResetReissues` consecutive resets without a reply";
  - **F7** "…does not re-send a diff the user navigated away from".
- `app/test/project/project_session_stream_events_test.dart`:
  - **R1** "a project-stream reopen after `open:false` calls reissueAfterStreamReset on every checkout's
    FileService once";
  - **R2** "the first open re-issues nothing";
  - **R3** "a reopen after `sessionDownEvents` re-issues";
  - its `_FakeLink` takes the new `sendFrame` signature.
- `app/test/relay/relay_connection_open_test.dart`: §5.4.
- Mechanical (new `sendFrame(kind, …)` / `IncomingPeerFrame(kind:)`, and no `{m}`, credit or frag):
  - `connection_handshake_test.dart`, `machine_session_establish_test.dart`, `machine_session_rekey_test.dart`,
    `machine_session_snapshot_retry_test.dart`, `machine_session_stream_binding_test.dart`,
    `netwatch_tap_test.dart`, `peer_link_test.dart`, `relay_message_test.dart`, `terminal_attachment_test.dart`,
    `tunnel_stream_test.dart`;
  - `connection_attempt_test.dart`, `leased_peer_link_lifecycle_test.dart`, `leased_peer_link_stream_test.dart`;
  - `app/test/connection/peer_connection_session_binding_test.dart`,
    `app/test/connection/peer_transport_integration_test.dart`, `app/test/helpers/test_peer_runtime.dart`,
    `app/test/providers/agent_transport_test.dart`, `agent_transport_coords_retry_test.dart`,
    `agent_transport_identity_test.dart`.

### evals

**Delete:** `evals/tests/fragmentation.test.ts` and `evals/tests/gate-flow-control.test.ts` (spec).

**New** `evals/tests/gate-terminal-latency-under-transfer.test.ts`: the A7 concurrency gate, over the real
`@number0/iroh` binding through `connectNative`.
- Setup:
  - `setupTestEnv()`;
  - `createTestProject()` plus one file `big.png`: a PNG signature followed by 10_000_000 random bytes, so
    `file-tree.ts` ships it as base64 (about 13.3 MB per `file:content`);
  - open the project stream;
  - start a terminal running a ticker that prints `T<Date.now()>` every 100 ms;
  - attach a terminal stream.
- Both ends drain: the client runs its project-stream reader and its terminal-stream reader as independent
  loops for the whole test, and never pauses either.
- Baseline: 3 s of stamps with no transfer. Record the p95 latency, where latency = receipt time − stamp,
  same host clock.
- Load:
  - send three `file:read` for `big.png` back to back on the project stream. That is about 40 MB of
    `file:content` queued behind one another, above `MAX_TRANSFER_BYTES` in aggregate, which is the
    spec's "32 MiB `file:read`";
  - measure stamps from the first send until the third reply lands.
- Assert:
  - all three `file:content` arrive, and each decodes to the file's SHA-256. This also covers the round trip
    that `fragmentation.test.ts` used to pin;
  - at least one stamp arrives inside the load window when that window is longer than 500 ms;
  - load-window max latency ≤ 2000 ms;
  - load-window p95 ≤ baseline p95 + 750 ms.
- The test is part of the default `test:evals` sweep, with no `package.json` change.

**Change:**
- `evals/helpers/relay-client.ts` and `evals/support/stream.ts`: §5.3.
- `evals/helpers/dart-app-client.ts`: `CONTROL_STREAM_ID` → `CONTROL_HANDLE` (§5.3).
- `evals/tests/gate-inventory-miss.test.ts` and `evals/tests/gate-iroh-host-authorization.test.ts`:
  - `PeerRecords` → `StreamRecordWriter` / `StreamRecordReader` (session reader cap
    `PEER_MAX_BRIDGE_RECORD_BYTES`, project reader cap `STREAM_PROJECT_BRIDGE_RECORD_MAX_BYTES`);
  - header `{type: "session" | "message"}`;
  - bare messages.
- `evals/fixtures/peer-transport-vectors.json`: regenerated by the controller (§Gate), owned by evals.
- Verify only (edit only if red):
  - `gate-vectors.test.ts`, `gate-project-streams.test.ts`, `gate-stream-admission.test.ts`,
    `gate-terminal-streams.test.ts`, `gate-tunnel-streaming.test.ts`, `multi-stream-coexistence.test.ts`,
    `drill-in.test.ts`, `machine-trust.test.ts`, `sealed-preview-http.test.ts`,
    `gate-two-devices-one-bridge.test.ts`, `gate-multi-machine-slots.test.ts`;
  - `soak/native-fault-soak.test.ts`, `scenarios/**`, `helpers/two-bridge.ts`, `helpers/chat.ts`,
    `support/session-bus.ts`.

### Gate (controller, once, after integration)

- `ALL`, `EVALS` and `INTEROP`, as `stage-A-waves.md` §3 defines them.
- The A7 eval passes inside `EVALS`. Also run it once on its own:
  `bun run --filter antgrid-evals test -- tests/gate-terminal-latency-under-transfer.test.ts`, or the
  workspace's equivalent single-file invocation.
- `bun run --filter antgrid-evals test:evals:native-soak`. **Report only**: its 128 MiB RSS bound was red on
  A3 and A4 (ledger). Record whether it still trips, at what time, and whether the functional assertions
  pass. Do not change the bound.
- One forced-relay run:
  `ANTGRID_IROH_RELAY_BIN=.tmp/iroh-relay-bin/bin/iroh-relay.exe bun run --filter antgrid-evals test:evals:iroh-relay-authorization`
  (relay-only dial). See §9 D-7.
- `bun run --filter antgrid-wire gen:peer-vectors`, then `git diff` on the fixture. It must show only the
  §3.2 changes.
- One `flutter analyze`, from the controller only. Then `cd packages/<each> && dart analyze`, sequentially,
  never concurrently.
- Known red:
  - bridge ×6: index-hook-subcommand ×1, plugin/antigravity-post-title ×3, plugin/opencode-notify ×2;
  - the git-branches stash-pop and git-sync timeouts under load;
  - `gate-vectors.test.ts`'s git-clean guard until the wave commit.

---

## 7. Call sites found by grep (rename and delete sweep)

TS pattern (`git grep`, excluding `docs/iroh-reduction/` and `docs/iroh-transport-reduction-plan.md`):

`SendScheduler|send-scheduler|PeerRecords|peer/records"|fragmentForSend|fragmentForProjectSend|FragReassembler|frag-reassembler|CREDIT_BATCH_BYTES|WINDOW_STALL_WARN_MS|SOCKET_INFLIGHT_BYTES|CHANNEL_WINDOW_BYTES|MAX_SEND_QUEUE_BYTES|WINDOW_RESYNC_AGE_MS|buildFragments|isFragEnvelope|FRAG_THRESHOLD|FRAG_DATA_BUDGET|MAX_FRAME_PAYLOAD|TRANSFER_TIMEOUT_MS|GLOBAL_REASSEMBLY_BUDGET|MAX_REREQUESTS|MAX_FRAGMENT_COUNT|CONTROL_STREAM_ID|StreamEnvelope|PeerChannel|QueuedAppFrame|PendingSinkWrite|__frag|sendAppEnvelope|noteConsumed|newReassembler|STREAM_PROJECT_RECORD_MAX_BYTES|sendNativePayload|sendNativeScheduled|nextKeypair|initialKeypair`

| Symbol | Hits at `11d1e210` | Owner and action |
|---|---|---|
| `send-scheduler` / `SendScheduler` / `QueuedAppFrame` / `PendingSinkWrite` | src: `peer-session-owner.ts`, `native-host-connection.ts`, `records.ts`, `send-scheduler.ts`; tests: `send-scheduler`, `native-session-send-scheduler`, `terminal-frame-cancellation`, `native-host-connection`, `test-peer-session-owner`, `fake-session` | deleted (§3.4, §3.5, §6) |
| `SendOutcome` | `agent-core.ts:33`, `project-streams.ts:28`, `peer-session-owner.ts`, `records.ts` | → `peer/stream-records.ts` (§3.1) |
| `PeerRecordFailure` | `peer-session-owner.ts:20`, `native-host-connection.ts:12` | → `peer/stream-records.ts` (§3.1) |
| `PeerRecords` | `native-host-connection.ts`, `bridge/scripts/iroh-host-smoke.ts`, `peer-records.test.ts`, `peer-session-hello.test.ts` (comments), `stream-dispatch.ts:5` (comment); evals `relay-client.ts`, `gate-inventory-miss`, `gate-iroh-host-authorization` | → `StreamRecordWriter`/`Reader`; bridge-src, bridge-tests, evals respectively |
| frag symbols (`buildFragments`, `FRAG_*`, `FragReassembler`, `__frag`, `fragmentFor*`, `newReassembler`, `TRANSFER_TIMEOUT_MS`, …) | wire `frag.ts`, `index.ts`, `peer-frame.ts`, `peer-authorization.ts`, `stream-open.ts`, vectors script and tests; bridge `peer-session-owner.ts`, `project-streams.ts`, `frag-reassembler.ts`; tests `frag-reassembler`, `relay-client-frag-send`, `project-streams`, `test-peer-session-owner`; evals `relay-client.ts`, `fragmentation.test.ts` | deleted. `bridge/src/git-sync.ts`'s local `TRANSFER_TIMEOUT_MS` is an **unrelated** name: leave it |
| flow symbols | wire `flow.ts`, vectors script and tests; bridge `peer-session-owner.ts`, `records.ts`, `send-scheduler.ts`, `agent-core.ts` and `protocol.ts` comments; tests `relay-client-credit-window`, `send-scheduler`; evals `relay-client.ts`, `gate-flow-control` | deleted |
| `MAX_FRAME_PAYLOAD` | wire `frag.ts`, `peer-frame.ts`, `peer-authorization.ts`, `stream-open.ts`; `native-host-connection.ts`; `peer-frame.test.ts`, `stream-open.test.ts`, vectors | → `MAX_TRANSFER_BYTES` / `STREAM_PROJECT_APP_RECORD_MAX_BYTES` per §2 |
| `STREAM_PROJECT_RECORD_MAX_BYTES` | wire `stream-open.ts`, `index.ts`, vectors script and test, `stream-open.test.ts`; `project-streams.ts`; `iroh-host-smoke.ts`; evals `relay-client.ts` | → the §2 pair by direction |
| `PEER_MAX_RECORD_BYTES` | `peer-authorization.ts`, `stream-open.ts` (re-export, deleted), `records.ts`, `relay/src/server.ts`, vectors | **kept**; value unchanged, `relay/` untouched |
| `CONTROL_STREAM_ID` / `StreamEnvelope` / `PeerChannel` | wire `peer-protocol.ts`; `peer-session-owner.ts`; `send-scheduler.ts`; evals `relay-client.ts`, `dart-app-client.ts` | deleted; evals use `CONTROL_HANDLE` (§5.3) |
| `sendAppEnvelope` | `peer-session-owner.ts`, `fake-session.ts` (comment) | → `sendControlPlane` |
| `sendNativePayload` / `sendNativeScheduled` | `peer-session-owner.ts`, `native-host-connection.ts`, `test-peer-session-owner.ts`, `native-host-connection.test.ts` | → `writeSessionRecord` |
| `nextKeypair` / `initialKeypair` / `generateEphemeralKeypair` | `agent-core.ts` only. `generateEphemeralKeypair` also in `key-exchange.ts`, `push/*`, `evals/tests/machine-trust.test.ts` (push keys) | delete the agent-core uses only |
| `answerAsker` | `agent-core.ts:4845` (changed), `host-server.ts:1100` (unchanged), `control-plane-capability-card.test.ts:381` (comment, unchanged) | §3.7 |
| Prose | `bridge/CLAUDE.md:39, :86`; `packages/antgrid_relay_client/CLAUDE.md:15, :17` | bridge-src and dart+app. `docs/protocol/peer-session.md`, `docs/architecture.md`, root and `app/` CLAUDE.md are **A6** |

Dart pattern:

`kChannelWindowBytes|kSocketInflightBytes|kCreditBatchBytes|kWindowResyncAgeMs|kMaxSendQueueBytes|kWindowStallWarnMs|kMaxFramePayload|kFragThreshold|kFragDataBudget|kTransferTimeoutMs|kGlobalReassemblyBudget|kMaxRerequests|kMaxFragmentCount|FragHint|FragEnvelope|FragSendError|isFragEnvelope|splitForJsonData|buildFragments|FragReassembler|SendScheduler|send_scheduler|kControlStreamId|StreamEnvelope|stream_envelope|IncomingPeerFrame|sendFrame\(|fragmentAborts|fragmentSendErrors|FragmentRecoveryCoordinator|fragment_recovery|onFragmentSuccess|handleFragmentFailure|kStreamProjectRecordMaxBytes|maxPeerRecordBytes|creditBatchBytes|channelWindowBytes|socketInflightBytes|debugScheduler|'credit'|_MultiStreamConnector|TestPayloadLink|utf8ByteLength`

| Symbol | Hits at `11d1e210` | Action |
|---|---|---|
| flow / frag / scheduler constants and classes | relay_client `flow.dart`, `frag.dart`, `send_scheduler.dart`, `frame.dart`, `machine_session.dart`, barrel; peer_transport `iroh_peer_link.dart`; tests `flow_test`, `frag_test`, `send_scheduler_test`, `machine_session_flow_control_test`, `peer_transport_vectors_test`; `machine_session.dart:33` comment | deleted or retargeted (§2, §4.3) |
| `utf8ByteLength` | `frag.dart` (def), `machine_session.dart`, `app/lib/services/preview_service.dart:657` | **kept**, moves to `frame.dart` |
| `kControlStreamId` / `StreamEnvelope` | `machine_session.dart` (15), `commands.dart` (9), `stream_envelope.dart`; tests `netwatch_tap_test` (3), `relay_message_test` (9) | `_kSessionStreamLabel` / `_kControlHandle` / tests updated |
| `IncomingPeerFrame` / `sendFrame(` | `peer_link.dart`, `connection_handshake.dart`, `machine_session.dart`, `iroh_peer_link.dart`, `leased_peer_link.dart`, `bin/native_smoke.dart`; every fake in §6 dart+app "mechanical" plus `fake_live_relay.dart`, `fixed_peer_connector.dart` | `channel` → `kind` (§4.1) |
| fragment recovery | `app/lib/project/fragment_recovery.dart`, `project_session.dart:22, :80-81, :158-170, :276, :518-519`, `file_service.dart:78-84, :459, :506, :611, :632-690, :1096`; `fragment_recovery_test.dart`, `file_service_test.dart:716, :733` | §4.5 |
| `_MultiStreamConnector` | `relay_connection_open_test.dart:310-333` | deleted (§5.4) |
| `maxPeerRecordBytes` | `iroh_peer_link.dart:13, :191` | deleted (§4.2) |
| `channel: 'control'` on `AgentTransport.send` | `bin/interop_app.dart:73, :119`, app services | **loopback label, kept** (D2); not a `PeerLink` call |

---

## 8. File ownership (disjoint and complete)

| File | Part | Change |
|---|---|---|
| `packages/antgrid-wire/src/flow.ts` | bridge-src | DELETE |
| `packages/antgrid-wire/src/frag.ts` | bridge-src | DELETE |
| `packages/antgrid-wire/src/peer-protocol.ts` | bridge-src | §1.1 |
| `packages/antgrid-wire/src/peer-frame.ts` | bridge-src | §1.1 |
| `packages/antgrid-wire/src/peer-authorization.ts` | bridge-src | §2 |
| `packages/antgrid-wire/src/stream-open.ts` | bridge-src | §2 |
| `packages/antgrid-wire/src/index.ts` | bridge-src | §2 |
| `packages/antgrid-wire/scripts/gen-peer-transport-vectors.ts` | bridge-src | §3.2 |
| `bridge/src/send-scheduler.ts` | bridge-src | DELETE (after §3.1) |
| `bridge/src/frag-reassembler.ts` | bridge-src | DELETE |
| `bridge/src/peer/records.ts` | bridge-src | DELETE (after §3.1) |
| `bridge/src/peer/stream-records.ts` | bridge-src | §3.1 (two types added) |
| `bridge/src/peer/stream-dispatch.ts` | bridge-src | comment at `:5` |
| `bridge/src/peer/native-host-connection.ts` | bridge-src | §3.5 |
| `bridge/src/peer-session-owner.ts` | bridge-src | §3.4 |
| `bridge/src/project-streams.ts` | bridge-src | §3.3 |
| `bridge/src/agent-core.ts` | bridge-src | §3.7 |
| `bridge/src/protocol.ts` | bridge-src | §3.6 (comment only) |
| `bridge/src/tunnel-manager.ts`, `bridge/src/peer/terminal-streams.ts`, `bridge/src/peer/tunnel-streams.ts`, `bridge/src/remote-host-connection.ts`, `bridge/src/relay-promotion.ts`, `bridge/src/host-server.ts` | bridge-src | verify only |
| `bridge/scripts/iroh-host-smoke.ts` | bridge-src | §3.8 |
| `bridge/scripts/iroh-interop-smoke.ts` | bridge-src | verify only |
| `bridge/CLAUDE.md` | bridge-src | §3.8 |
| `bridge/tests/test-peer-session-owner.ts` | bridge-tests | §5.1 |
| `bridge/tests/fake-session.ts` | bridge-tests | §5.1 |
| `bridge/tests/send-scheduler.test.ts` | bridge-tests | DELETE |
| `bridge/tests/native-session-send-scheduler.test.ts` | bridge-tests | DELETE |
| `bridge/tests/relay-client-credit-window.test.ts` | bridge-tests | DELETE |
| `bridge/tests/relay-client-frag-send.test.ts` | bridge-tests | DELETE |
| `bridge/tests/frag-reassembler.test.ts` | bridge-tests | DELETE |
| `bridge/tests/peer-records.test.ts` | bridge-tests | DELETE |
| `bridge/tests/terminal-frame-cancellation.test.ts` | bridge-tests | §6 (rows or DELETE) |
| `bridge/tests/project-streams.test.ts` | bridge-tests | §6 P1-P5 |
| `bridge/tests/native-host-connection.test.ts` | bridge-tests | §6 N1-N6 |
| `bridge/tests/peer-session-hello.test.ts` | bridge-tests | §6 H1-H5 |
| `bridge/tests/handshake-pull.test.ts` | bridge-tests | §6 |
| `bridge/tests/agent-core-answer-asker.test.ts` (NEW) | bridge-tests | §6 Q1-Q3 |
| `bridge/tests/tunnel-manager-stream.test.ts`, `tunnel-manager-ws-order.test.ts`, `stream-records.test.ts`, `remote-access-gate.test.ts`, `checkout-mirror-contract.test.ts`, `host-server.test.ts`, `host-control-plane.test.ts`, `control-plane-start.test.ts`, `account-trust-phone-registration.test.ts`, `relay-client-no-pairing.test.ts`, `session-bus-remote-directory.test.ts`, `netwatch.test.ts`, `netwatch-remote.test.ts`, `host-policy-fixture.ts`, `control-plane-capability-card.test.ts`, `push/*` | bridge-tests | verify only (mechanical seam updates if red) |
| `packages/antgrid-wire/tests/flow.test.ts` | bridge-tests | DELETE |
| `packages/antgrid-wire/tests/frag.test.ts` | bridge-tests | DELETE |
| `packages/antgrid-wire/tests/peer-frame.test.ts` | bridge-tests | §6 |
| `packages/antgrid-wire/tests/stream-open.test.ts` | bridge-tests | §6 |
| `packages/antgrid-wire/tests/peer-transport-vectors.test.ts` | bridge-tests | §6 |
| `packages/antgrid_relay_client/lib/src/flow.dart` | dart+app | DELETE |
| `packages/antgrid_relay_client/lib/src/frag.dart` | dart+app | DELETE (`utf8ByteLength` moves first) |
| `packages/antgrid_relay_client/lib/src/send_scheduler.dart` | dart+app | DELETE |
| `packages/antgrid_relay_client/lib/src/models/stream_envelope.dart` | dart+app | DELETE |
| `packages/antgrid_relay_client/lib/src/frame.dart` | dart+app | §1.1, §2, `utf8ByteLength` |
| `packages/antgrid_relay_client/lib/src/models/stream_open.dart` | dart+app | §2 |
| `packages/antgrid_relay_client/lib/src/peer_link.dart` | dart+app | §4.1 |
| `packages/antgrid_relay_client/lib/src/connection_handshake.dart` | dart+app | §4.3 |
| `packages/antgrid_relay_client/lib/src/machine_session.dart` | dart+app | §4.3 |
| `packages/antgrid_relay_client/lib/antgrid_relay_client.dart` | dart+app | barrel (§2) |
| `packages/antgrid_relay_client/CLAUDE.md` | dart+app | §4.3 |
| `packages/antgrid_relay_client/test/support/fake_live_relay.dart` | dart+app | §5.2 |
| `packages/antgrid_relay_client/test/flow_test.dart`, `frag_test.dart`, `send_scheduler_test.dart`, `machine_session_flow_control_test.dart` | dart+app | DELETE |
| `packages/antgrid_relay_client/test/machine_session_envelope_test.dart` | dart+app | §6 E1-E6 |
| `packages/antgrid_relay_client/test/machine_session_project_stream_test.dart` | dart+app | §6 S1-S3 |
| `packages/antgrid_relay_client/test/machine_session_establish_test.dart`, `machine_session_rekey_test.dart` | dart+app | §6 G1-G2 (in whichever fits) + mechanical |
| `packages/antgrid_relay_client/test/connection_handshake_test.dart`, `machine_session_snapshot_retry_test.dart`, `machine_session_stream_binding_test.dart`, `netwatch_tap_test.dart`, `peer_link_test.dart`, `relay_message_test.dart`, `terminal_attachment_test.dart`, `tunnel_stream_test.dart` | dart+app | mechanical |
| `packages/antgrid_peer_transport/lib/src/iroh_peer_link.dart` | dart+app | §4.2 |
| `packages/antgrid_peer_transport/lib/src/leased_peer_link.dart` | dart+app | §4.2 |
| `packages/antgrid_peer_transport/bin/native_smoke.dart` | dart+app | §4.2 |
| `packages/antgrid_peer_transport/bin/interop_app.dart` | dart+app | verify only |
| `packages/antgrid_peer_transport/test/native_peer_stream_test.dart` | dart+app | §6 W1-W2 |
| `packages/antgrid_peer_transport/test/peer_transport_vectors_test.dart` | dart+app | §6 |
| `packages/antgrid_peer_transport/test/connection_attempt_test.dart`, `leased_peer_link_lifecycle_test.dart`, `leased_peer_link_stream_test.dart` | dart+app | mechanical |
| `packages/antgrid_eval_client/lib/src/commands.dart` | dart+app | §4.7 |
| `app/lib/project/fragment_recovery.dart` | dart+app | DELETE |
| `app/lib/project/project_session.dart` | dart+app | §4.5 |
| `app/lib/services/file_service.dart` | dart+app | §4.5 |
| `app/lib/project/project_message_classification.dart` | dart+app | §4.6 (comment) |
| `app/lib/project/message_router.dart` | dart+app | §4.6 (comment) |
| `app/lib/services/preview_service.dart` | dart+app | verify only |
| `app/test/project/fragment_recovery_test.dart` | dart+app | DELETE |
| `app/test/services/file_service_test.dart` | dart+app | §6 F1-F7 |
| `app/test/project/project_session_stream_events_test.dart` | dart+app | §6 R1-R3 |
| `app/test/helpers/fixed_peer_connector.dart` | dart+app | §5.4 |
| `app/test/relay/relay_connection_open_test.dart` | dart+app | §5.4 |
| `app/test/helpers/test_peer_runtime.dart`, `app/test/connection/peer_connection_session_binding_test.dart`, `app/test/connection/peer_transport_integration_test.dart`, `app/test/providers/agent_transport_test.dart`, `agent_transport_coords_retry_test.dart`, `agent_transport_identity_test.dart` | dart+app | mechanical |
| `evals/helpers/relay-client.ts` | evals | §5.3 |
| `evals/helpers/dart-app-client.ts` | evals | §5.3 |
| `evals/support/stream.ts` | evals | §5.3 (`CONTROL_HANDLE`) |
| `evals/tests/fragmentation.test.ts` | evals | DELETE |
| `evals/tests/gate-flow-control.test.ts` | evals | DELETE |
| `evals/tests/gate-terminal-latency-under-transfer.test.ts` (NEW) | evals | §6 A7 |
| `evals/tests/gate-inventory-miss.test.ts` | evals | §6 |
| `evals/tests/gate-iroh-host-authorization.test.ts` | evals | §6 |
| `evals/fixtures/peer-transport-vectors.json` | evals | regenerated at the gate (§3.2 shape) |
| the evals listed "verify only" in §6 | evals | verify only |

These files are explicitly **not touched** in A5:
- `relay/**`: the `PEER_MAX_RECORD_BYTES` value is unchanged;
- `bridge/src/peer/key-exchange.ts` and `bridge/src/push/**`;
- `bridge/src/message-bus.ts`, `bridge/src/local-listener.ts` and all loopback code (D2);
- `bridge/src/netwatch*.ts`, `bridge/src/cli/netwatch.ts` (A6);
- `packages/antgrid_relay_client/lib/src/local_transport.dart`, `agent_transport.dart`,
  `buffered_agent_transport.dart`, `terminal_attachment.dart`, `tunnel_stream.dart`,
  `crypto_service.dart`;
- `app/lib/test_helpers/**`, `app/lib/demo/**`;
- `docs/protocol/peer-session.md`, `docs/architecture.md`, root `CLAUDE.md`, `app/CLAUDE.md` (all A6), and
  `docs/iroh-transport-reduction-plan.md`.

`docs/iroh-reduction/ledger.md` is updated by the controller at the wave commit and belongs to no part.

---

## 9. Deviations from the spec, and open items

- **D-1: the session stream keeps the peer frame, and its header `type` becomes the discriminator.** The
  spec deletes `PeerFrameHeader.channel` and the `{s, m}` envelope, but does not say what tells a liveness
  frame from a control-plane message afterwards.
  - The JSON `type` cannot do it: `ping`, `pong` and `session:*` are also `AbMessage` literals.
  - Keeping the frame, with `type: "session" | "message"`, needs no new framing and keeps `FRAME_VERSION`
    and the ALPN (D5).
  - It keeps `relay/`'s `PEER_MAX_RECORD_BYTES` import meaningful.
- **D-2: the asymmetric caps are named per direction, not per stream.** On the project stream they are
  `STREAM_PROJECT_APP_*` / `STREAM_PROJECT_BRIDGE_*`, the terminal naming. On the session stream they are
  `PEER_MAX_RECORD_BYTES` (unchanged) and the new `PEER_MAX_BRIDGE_RECORD_BYTES`.
  - The app's outbound refusal uses the 1.5 MB app cap on both streams.
  - No app-originated message comes near it. Uploads are chunked at 512 KiB (`UploadService.kChunkBytes`),
    and the app sends no file writes.
- **D-3: session-stream overflow retires the connection.** D3 ("reset only that stream") does not apply to
  the one stream that is the session. The 5 s write timeout goes for the bridge and the app alike (spec
  row 3), so a slow-draining peer is never killed by a timer; liveness decides.
- **D-4: the per-message `authorized` predicate on control-plane sends is checked at send time only.**
  - `PeerRecords` rechecked a per-record `permitted` at drain, and `StreamRecordWriter` has no such hook.
  - Connection-level `authorized()` is still checked per slice.
  - With no credit window, the session queue holds milliseconds of traffic, not seconds.
  - Adding a per-record predicate to the shared writer would change three A2-A4 stream kinds for one caller.
- **D-5: re-issue is scoped to what nothing else re-fires.** The selected file and the preview are already
  re-read by their tier-3 hydrators on every project-stream bind. Re-sending them from
  `reissueAfterStreamReset` would double a 13 MB read on every reset. The re-issue bound
  (`kMaxStreamResetReissues = 2`) replaces the old `kMaxRerequests`.
- **D-6: the A7 load is three 10 MB-binary `file:read`s, not one 32 MiB record.** `file-tree.ts` caps a read
  at 10 MB binary (about 13.3 MB base64) and 1 MB text. So a single 32 MiB `file:read` does not exist on the
  real path. Three back-to-back reads put more than `MAX_TRANSFER_BYTES` on the project stream at once. The
  32 MiB single-record property is pinned by bridge rows P3 / N2 and Dart row W1.
- **D-7: "one forced-relay run" is the existing relay gate** (`test:evals:iroh-relay-authorization`, a
  relay-only dial through the stock relay binary). A full app ↔ bridge session forced through the relay is
  still not exercised (ledger, "Stage C open items"). The eval harness has no knob that withholds direct
  addresses from `connectNative`, and adding one is outside A5.
- **D-8: `TestPayloadLink` implements `MultiStreamPeerLink` unconditionally and throws for a plain carrier.**
  This mirrors `LeasedPeerLink`, the production wrapper. A test whose carrier cannot open streams then fails
  loudly at `openStream`, rather than silently taking a single-stream path.
- **D-9: diagnostics keep `channel: "control"` / stream id `"0"` for session-stream events** until A6
  retypes netwatch. Changing the event shape here would touch netwatch files A6 owns.
- **D-10: `answerAsker` fails closed for a relay-origin frame with no `peerId`.** Before, such a frame fell
  through to `bus.publish` and broadcast. No production path produces one: every native inbound carries its
  peer.
- **D-11 (integration): the session read loop checks `authorized()` before each read, not only after.**
  `PeerRecords.read()` checked admission before awaiting the length prefix, and the first pass of the loop
  runs synchronously inside admission. Checking only after the read let a peer admitted under a snapshot
  whose own `endpoint` no longer names this bridge (`AuthorizationLease.allows` checks only `peers`) idle
  in `nativePeers` until it sent something. The existing row "a revoked local endpoint cannot admit a peer
  using an otherwise allowed device lease" pins it. The pre-hello timer calls `retirePeer(peerId,
  "connection-lost")` as §3.5 says: `StreamRecordWriter.abort()` resets only the send half and never
  closes the connection, so a silent peer outlived the timer.
- **D-12 (integration): call sites the §7 sweep missed.**
  - D-10 made two existing rows' positive controls silent, because they dispatched a relay-origin RPC
    with no `peerId`: `agent-core-terminal-snapshot-rpc.test.ts` and `agent-core-transcript-snapshot.test.ts`
    now pass the peer they installed.
  - `agent-core-answer-asker.test.ts`'s fake relay wire records untargeted publishes too, as the
    production project-stream subscriber delivers them to every peer. Without that, Q1 and Q3 pass against
    the broadcasting `answerAsker` as well.
  - Dart files the §7 pattern did not reach: `test/frame_test.dart` (the `channel` header rows; it gains
    a `channel`-rejected and a bad-`type` row), `app/test/providers/agent_transport_identity_test.dart`
    (hello filter by kind), `terminal_attachment_test.dart`'s socket-path row (bare message, no `{m}`),
    and the `sendFrame(String channel, …)` overrides in eight fakes, renamed to `kind` so
    `avoid_renaming_method_parameters` stays quiet.
  - S3 filters the bind's hydration `request` out of the project stream's sent records.
  - The A7 gate subscribed with a hard-coded `version: 1`, so it was refused and never saw a frame. It now
    sends `TERMINAL_PROTOCOL_VERSION`. A measured run: a 1.5 s load window carried 14 stamps, with a max
    latency of 91 ms against a 76 ms baseline p95.
  - `project_session_stream_events_test.dart`'s `_FakeLink.close()` counts closes rather than closing
    its controllers: R3 re-handshakes over the same link after the failed attempt closes it, the way
    `LeasedPeerLink` redials beneath a session.
- **Open: the native soak's RSS bound.** It was red on A3 and A4 (ledger). A5 deletes the scheduler queues,
  reassembly buffers and per-fragment strings, so the controller should record whether the trip time moves.
  Do not tune the bound.
- **Open: head-of-line within a project** (A4 open item). It is unchanged: one project stream is one FIFO,
  so a 13 MB `file:content` still delays that project's `tree:update`. Terminal frames are unaffected, which
  the A7 gate now pins with a number.
- **Open: stale docs until A6.** `docs/protocol/peer-session.md` §5 (credit windows) and §8.8 (fragments), and
  `docs/architecture.md`, still describe the deleted machinery.
