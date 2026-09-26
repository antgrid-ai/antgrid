# Stage A, wave A9: the session stream drops the binary peer-frame envelope

This is the frozen contract for four parallel implementers: **bridge-src**, **bridge-tests**, **dart+app**
and **evals**. Each part builds against the names and shapes below. Nobody may rename or reshape anything
pinned here without the controller's say. If your part needs something this file does not provide, report it
as `outOfScopeNeeds`. Do not invent it.

A9 removes the last application-layer framing on the native path. Today every record on the session stream
is `[u32 BE len][version u8][kind u8][header length u16][header JSON {type:"session"|"message"}][payload]`,
and the header's `type` is the only thing that tells a liveness `ping` from the control-plane `AbMessage`
literal `ping`. After A9:
- a session-stream record is `[u32 BE len][UTF-8 JSON]`, byte for byte the shape of a project-stream record,
  read and written by the same record reader and writer the project stream uses;
- the session-level frames get their own type names, which no `AbMessage` uses. Dispatch is on the JSON
  `type` alone;
- the envelope codec and every constant that exists only for it are deleted on both sides;
- the two session record caps lose their header allowance, so each equals its payload cap exactly;
- the loopback wire is untouched (D2): it never carried the envelope.

Sources:
- `stage-A-waves.md` §1.1 ("Binding constraints") and §4 (owner decisions D1–D7);
- the owner decisions in `ledger.md`, including Hazard J (A4 contract);
- the A5 contract (session reader caps, `PEER_MAX_BRIDGE_RECORD_BYTES`), the A7 and A8 contracts (format,
  ownership pattern, netwatch tagging).

HEAD at authoring time is `8397c8a3`. ALPN stays `antgrid/peer/2` and there is **no ALPN bump**: Stages B and
A ship as one release that was never published, so no deployed peer speaks the envelope. `FRAME_VERSION` is
deleted, not bumped: nothing remains on the wire for it to version.

Evidence labels: **EXECUTED** means I ran it in this session. **READ** means I read the source and did not
run it.

## 0. Rules for every part

- Edit only the files your part owns (§12). Report anything else in `outOfScopeNeeds`.
- Never `git stash`, `checkout`, `reset` or `restore`.
- Bun tests per workspace only (`bun run --filter <name> test`), never bare `bun test` at the root. Send
  full-suite runs to a file and grep it for `(fail)`.
- CLAUDE.md comment rules apply: comments explain WHY, never narrate the change ("was the envelope", "A9
  removed …" are forbidden in code comments). Docs and the ledger may name the wave.
- Security invariants you must not weaken. None of them is touched by a correct A9, and a diff that moves any
  of them is wrong:
  - the remote-access switch: `remoteFrameAllowed` inbound, `mayDeliver` outbound;
  - `seenProjects` + `isSafeProjectId` bounding every `projectId`;
  - `mayDeliverTo` on every send and `mayAcceptFrom` at open (checkoutRouting);
  - a stream open never opens or promotes a core;
  - the pre-establishment gate: before a peer has a session, the only record that does anything is a
    `session:hello`; everything else is a `pre-establishment` drop (§3.2);
  - `authorized()` before and after every session-record read (`native-host-connection.ts` read loop).
- Binding constraints (`stage-A-waves.md` §1.1), unchanged:
  - no single write larger than 256 KiB (`writeRecordInSlices`/`kPeerStreamSliceBytes`, the TS writer's
    slicing);
  - `setPriority` at most once, before the first write;
  - never `await` `stopped()` or `receivedReset()`;
  - a Dart stream is invisible to the peer until its first write;
  - every Dart error path on a stream calls reset.
- Known red, which is not yours to fix:
  - bridge: 6 stale-runId failures (`index-hook-subcommand` ×1, `plugin/antigravity-post-title` ×3,
    `plugin/opencode-notify` ×2);
  - under load, the `git-branches` stash-pop test and the `git-sync` already-up-to-date test can time out.

## 1. Decisions

- **D-A9-1. Names.** The session frames are exactly these five, one scheme (`session:` + verb), all new except
  `session:hello`:

  | Type | Direction | Body | Old name |
  |---|---|---|---|
  | `session:hello` | app → bridge | `{type, attemptId, capabilities?}` (`SessionHelloFrame`, unchanged) | same |
  | `session:established` | bridge → app | `{type, attemptId}` (`SessionEstablishedFrame`) | `established` |
  | `session:ping` | app → bridge (either direction is legal to receive) | `{type}` | `ping` under header `session` |
  | `session:pong` | reply to a ping | `{type}` | `pong` under header `session` |
  | `session:takeover` | bridge → app, **reserved**: nothing sends it | `{type}` | `session-takeover` |

  `session:takeover` stays because Stage B D5 kept the app's receive arm; it is renamed so the scheme has no
  exception.
- **D-A9-2. No AbMessage changes.** `PingMessage`/`PongMessage` (`ping`/`pong`) stay in `AbMessageSchema` and
  `KNOWN_TYPES`: many bridge tests use them as dummy control messages. None of the five session types is added
  to `AbMessageSchema`, `KNOWN_TYPES` or the Dart `parseAbMessage` switch. The message-type checklist
  (root CLAUDE.md "Adding a message type") therefore has nothing to add or remove, and
  `CHECKOUT_VARIABLE_MESSAGE_TYPES` / `kCheckoutVariableMessageTypes` do not change (session frames never
  touch the working tree). The disjointness is proved by tests (§9), not by review.
- **D-A9-3. Dispatch.** On both sides, after establishment: parse the record as JSON; if its `type` is in the
  session set, it is a session frame; otherwise it is the control plane. A record whose `type` is an old name
  (`ping`, `pong`, `established`, `session-takeover`) is therefore a control-plane message: the bridge hands
  `ping`/`pong` to the bus (which has no handler for them) and never answers with a pong.
- **D-A9-4. Non-JSON is a drop, not a violation.** The envelope decode failure (a protocol violation that
  retired the peer) goes away with the envelope. A record that is not JSON, or has no string `type`, is
  dropped with the existing reasons (`plaintext-not-json`, `unrecognized-plaintext`), exactly as a malformed
  payload inside a valid envelope was dropped before. A zero-length or over-cap length prefix is still a
  protocol violation (the record reader enforces it).
- **D-A9-5. Caps.** The session record caps equal the payload caps (§4). A record is its payload now, so the
  old `+ MAX_HEADER_LEN + FIXED_PREFIX` allowance is dead weight that let a record 1028 bytes past the payload
  cap through the reader.
- **D-A9-6. The app keeps its own session reader/writer.** `IrohPeerLink` does not reuse `NativePeerStream`
  for the session stream: session overflow must answer `PeerSendOutcome.backpressured` without resetting the
  stream (resetting the session stream would end the connection). Same wire as a project stream, not the same
  class.
- **D-A9-7. Netwatch.** `frameId` already hashes the JSON payload, not the envelope
  (`frameIdFor`/`frameIdOf`), so the derivation does not change. The app gains transport-edge rows for session
  records, and the joiner stops excluding native rows by default (§7).
- **D-A9-8. Loopback (D2).** Unchanged. **EXECUTED** `git grep` for every deleted symbol (§12 table):
  neither `bridge/src/local-listener.ts` nor `packages/antgrid_relay_client/lib/src/local_transport.dart`
  references any of them. The loopback wire is JSON WebSocket text with a `channel` field, a
  `{type:"hello", token}` → `{type:"ready"}` handshake and no ping/pong (**READ**).

Owner decisions carried unchanged (`stage-A-waves.md` §4): D1 (request-stream scope), D2 (no loopback wire
change), D3 (overflow resets that stream; never retire the connection for a slow stream), D4 (cancel by reset,
in-band `stream:refused`), D5 (ALPN; see the header: no bump for A9), D6 (synchronous in-order dispatch, one
session per connection), D7 (stream caps). Hazard J (a project stream opens only after that project's ready
notice) is untouched.

## 2. Wire

### 2.1 Session stream

```
stream 0 (first bidi stream of the connection, app-opened):
  record 1  [u32 BE len][UTF-8 JSON {"kind":"session"}]          StreamOpen, unchanged
  record n  [u32 BE len][UTF-8 JSON {"type": <string>, ...}]     one session frame or one AbMessage
```

- `len` is the byte length of the JSON body; `0 < len <= cap(direction)` (§4). The reader rejects `0` and
  anything over the cap as a protocol violation.
- A body is exactly one JSON object. There is no header, no version byte and no kind byte.
- A session-frame body is one of the five types in D-A9-1. Any other `type` is one `AbMessage` of the control
  plane, exactly the JSON that used to ride the `message` header.

### 2.2 Wire package: names (`packages/antgrid-wire/src/peer-protocol.ts`)

`PeerFrameHeader` and `PeerFrameKind` are deleted. In their place, newly authored (no bridge code moves into
the Apache package):

```ts
export const SESSION_FRAME_TYPES = [
  "session:hello",
  "session:established",
  "session:ping",
  "session:pong",
  "session:takeover",
] as const;
export type SessionFrameType = (typeof SESSION_FRAME_TYPES)[number];
export const SessionFrameTypeSchema = z.enum(SESSION_FRAME_TYPES);
export function isSessionFrameType(type: unknown): type is SessionFrameType;
export const SessionPingFrame = z.object({ type: z.literal("session:ping") });
export const SessionPongFrame = z.object({ type: z.literal("session:pong") });
export const SessionTakeoverFrame = z.object({ type: z.literal("session:takeover") });
```

- `isSessionFrameType` is `typeof type === "string" && (SESSION_FRAME_TYPES as readonly string[]).includes(type)`.
- Ping/pong/takeover bodies are dispatched on `type` alone and never validated at runtime. The three schemas
  exist so the vectors generator can validate its samples. They are non-strict on purpose: an extra key on a
  ping must never cost a pong.
- `SessionHelloFrame` and `SessionEstablishedFrame` stay in `bridge/src/protocol.ts` (their `capabilities`
  shape is `SessionHelloCapabilities`, which is ELv2 and must not move). `SessionEstablishedFrame`'s literal
  becomes `"session:established"`. Both stay out of `AbMessageSchema` and `KNOWN_TYPES`.

### 2.3 Dart mirror (`packages/antgrid_relay_client/lib/src/frame.dart`)

```dart
const String kSessionHello = 'session:hello';
const String kSessionEstablished = 'session:established';
const String kSessionPing = 'session:ping';
const String kSessionPong = 'session:pong';
const String kSessionTakeover = 'session:takeover';
const Set<String> kSessionFrameTypes = {
  kSessionHello, kSessionEstablished, kSessionPing, kSessionPong, kSessionTakeover,
};
bool isSessionFrameType(Object? type) => type is String && kSessionFrameTypes.contains(type);
```

`frame.dart` is already exported by `lib/antgrid_relay_client.dart`; keep it exported. The mirror is by hand.
The vectors fixture (§5) is what catches drift.

## 3. Bridge APIs and seams (bridge-src)

### 3.1 `bridge/src/peer-session-owner.ts`

- The import of `PeerFrameKind` goes; import `isSessionFrameType` from `antgrid-wire`.
- ```ts
  protected abstract writeSessionRecord(
    peerId: string,
    payload: Buffer,
    diagnosticType: string,
    signal?: AbortSignal,
  ): Promise<StreamSendOutcome> | null;
  ```
  The `kind` parameter is removed. `sendControlPlane` and `sendSessionFrame` both call it with the JSON bytes.
- `receivePeerFrame(payload, from, kind)` is **renamed** `receiveSessionRecord(payload: Uint8Array, from: string): void`.
- `sendSessionFrame(obj, to)` is unchanged in signature; its callers send `{type:"session:established",
  attemptId}` (both sites in `handleHello`) and `{type:"session:pong"}`.
- `onSessionFrame(plaintext, peerId, frameId?, bytes?)` and `onControlMessage(plaintext, peerId, frameId?,
  bytes?)` keep their signatures and their drop reasons. `onSessionFrame`'s doc loses the "header `type`"
  wording.

### 3.2 Admission and dispatch order (`receiveSessionRecord`)

This order is pinned. Steps 1–2 are today's gate without the kind check.

1. `frameId = frameIdFor(payload)`, `bytes = payload.length`, `session = sessions.get(from)`.
2. **No session:** parse the body as JSON (failure → `null`). If it is an object whose `type === "session:hello"`:
   record `rx frame` (`msgType: "session:hello"`), `SessionHelloFrame.safeParse` it, a failure →
   `refusePeer(from, "protocol-violation")`, else `handleHello(parsed, from, frameId, bytes)`; return.
   Anything else → record `rx drop` reason `pre-establishment`; return. Nothing reaches
   `handleSessionFrame`, `dispatchControlPlane`, the bus or a stream.
3. **Session exists:** `plaintext = utf8(payload)`. Peek the type: `JSON.parse` in a try; `type` is the
   object's `type` if it is a string, else `undefined`.
4. `isSessionFrameType(type)` → `onSessionFrame(plaintext, from, frameId, bytes)`. Otherwise →
   `onControlMessage(plaintext, from, frameId, bytes)`, which keeps producing `plaintext-not-json` and
   `unrecognized-plaintext` for bodies that step 3 could not type. (Parsing twice is accepted: project
   traffic no longer rides this stream.)

`handleSessionFrame(obj, peerId)` cases:

| `type` | Action |
|---|---|
| `session:hello` | as today (re-ack, or protocol violation on a different attemptId) |
| `session:ping` | if `sessions.has(peerId)`: `sendSessionFrame({type:"session:pong"}, peerId)` |
| `session:pong` | no-op (the bridge never pings; QUIC idle detects a dead app) |
| anything else in the set (`session:established`, `session:takeover`) | drop, reason `unknown-session-frame` (warn as today) |

There is no `case "ping"`, `"pong"` or `"credit"` any more. An old-name `ping` reaches `dispatchControlPlane`
→ `parseMessageFast` → the bus, where nothing answers it.

### 3.3 `bridge/src/peer/native-host-connection.ts`

- Imports: `decodePeerFrame`, `encodePeerFrame`, `PeerFrameKind` go.
- The session read loop keeps `new StreamRecordReader({recv}, PEER_MAX_RECORD_BYTES, …)` (the cap's value
  changes through the import) and both `authorized()` checks. It calls
  `this.receiveSessionRecord(record, peerId)` directly. The `try { decodePeerFrame } catch → retire
  protocol-violation` block is deleted (D-A9-4).
- `protected override receiveSessionRecord(payload, from)`: the lease check that `receivePeerFrame`'s override
  does today, unchanged, then `super.receiveSessionRecord(payload, from)`.
- `protected override writeSessionRecord(peerId, payload, diagnosticType, signal?)`: sends `payload` itself
  through `peer.sessionWriter.send(payload, signal)`.
- `recordNativeWrite(payload, msgType)` loses `peerFrameBytes`; its `detail` becomes
  `{ recordBytes: payload.length + 4, lengthPrefixBytes: 4 }`. Every other field is unchanged
  (`dir:"tx", kind:"frame", transport:"iroh", channel:"control", streamKind:"session",
  streamId: NETWATCH_SESSION_STREAM_LABEL, msgType, bytes: payload.length, frameId: frameIdFor(payload)`).

### 3.4 `bridge/src/protocol.ts`

Only `SessionEstablishedFrame`'s literal (`"established"` → `"session:established"`) and the two frames' doc
comments. `PingMessage`/`PongMessage`, `AbMessageSchema`, `KNOWN_TYPES`, `parseMessageFast` and `agent-core.ts`
do not change.

### 3.5 `bridge/src/cli/netwatch.ts` (§7)

### 3.6 Smoke scripts (`bridge/scripts/`)

- `iroh-host-smoke.ts` (`qualify:iroh-host`): `send`/`sendHello` write the JSON bytes as one record
  (`sessionWriter.send(Buffer.from(JSON.stringify(value), "utf8"))`); `read` parses each record as JSON. It
  awaits `type === "session:established" && attemptId === attemptId`, **then** sends `{type:"session:ping"}` and
  awaits `{type:"session:pong"}` before the project loop.
- `iroh-interop-smoke.ts` (`qualify:iroh-interop`): after `await next("established")`, add
  `await next("session-ping-pong")`. The check names emitted by `interop_app.dart` are unchanged otherwise.

## 4. Constants

| Constant | Home | Value after A9 | Before |
|---|---|---|---|
| `PEER_MAX_RECORD_BYTES` (app → bridge session record, bridge's reader cap) | `packages/antgrid-wire/src/peer-authorization.ts` | `= STREAM_PROJECT_APP_RECORD_MAX_BYTES` (1_500_000) | 1_501_028 |
| `PEER_MAX_BRIDGE_RECORD_BYTES` (bridge → app, app's reader cap) | same | `= MAX_TRANSFER_BYTES` (33_554_432) | 33_555_460 |
| `kPeerMaxRecordBytes` | `packages/antgrid_relay_client/lib/src/frame.dart` | `= kStreamProjectAppRecordMaxBytes` | with header allowance |
| `kPeerMaxBridgeRecordBytes` | same | `= kMaxTransferBytes` | with header allowance |
| `kSessionStreamMaxQueuedBytes` | `models/stream_open.dart` | 4_194_304, unchanged | |
| `STREAM_PROJECT_APP_RECORD_MAX_BYTES`, `MAX_TRANSFER_BYTES`, every `STREAM_*` cap, `StreamRefusedCode` | `stream-open.ts` / `models/stream_open.dart` | unchanged | |

- `peer-authorization.ts` stops importing from `peer-frame`. Its doc comments say each cap equals its payload
  cap because a session record carries only its payload.
- The send-side refusals are unchanged: the app answers `PeerSendOutcome.tooLarge` above
  `kStreamProjectAppRecordMaxBytes`; the bridge drops `MESSAGE_TOO_LARGE` above `MAX_TRANSFER_BYTES`. Each
  now equals the far side's reader cap exactly.
- `relay/src/server.ts` uses `PEER_MAX_RECORD_BYTES` as the central WebSocket's `maxPayloadLength`; it moves
  to 1_500_000 through the import with **no edit to `relay/`**. Central control envelopes are far below it
  (**READ**). bridge-tests runs the relay suite to confirm (§11).
- Refusal codes and stream kinds are unchanged: open kinds `session`/`project`/`terminal`/`tunnel-http`/
  `tunnel-ws`/`upload`; `stream:refused` codes `NOT_READY`/`UPDATE_REQUIRED`/`NOT_ALLOWED`/`CAP_EXCEEDED`/
  `INVALID`. A9 adds no stream kind and no open-frame field.

## 5. Wire package and vectors (bridge-src)

- **Delete** `packages/antgrid-wire/src/peer-frame.ts` (`FRAME_VERSION`, `FIXED_PREFIX`, `MAX_HEADER_LEN`,
  `FrameKind`, `FrameError`, `FrameErrorReason`, `encodePeerFrame`, `decodePeerFrame`).
- `packages/antgrid-wire/src/index.ts`: remove every `./peer-frame` export; `export * from "./peer-protocol"`
  stays and now carries §2.2's names.
- `packages/antgrid-wire/scripts/gen-peer-transport-vectors.ts`: the `framing` block is **replaced** by:

  ```jsonc
  "sessionRecords": {
    "maxAppRecordBytes": 1500000,        // PEER_MAX_RECORD_BYTES
    "maxBridgeRecordBytes": 33554432,    // PEER_MAX_BRIDGE_RECORD_BYTES
    "types": ["session:hello", "session:established", "session:ping", "session:pong", "session:takeover"],
    "samples": [
      { "name": "hello",       "json": "{\"type\":\"session:hello\",\"attemptId\":\"a1\"}",       "session": true,  "recordHex": "…", "frameId": "1e65322bad672889949c1355" },
      { "name": "established", "json": "{\"type\":\"session:established\",\"attemptId\":\"a1\"}", "session": true,  "recordHex": "…", "frameId": "…" },
      { "name": "ping",        "json": "{\"type\":\"session:ping\"}",                              "session": true,  "recordHex": "…", "frameId": "87de6691fb39ea6cf0dfe208" },
      { "name": "pong",        "json": "{\"type\":\"session:pong\"}",                              "session": true,  "recordHex": "…", "frameId": "5bd8f18eec9a79ae8a044822" },
      { "name": "control-ping","json": "{\"type\":\"ping\",\"id\":\"m1\",\"timestamp\":0}",        "session": false, "recordHex": "…", "frameId": "…" }
    ]
  }
  ```

  - `json` is the exact body string; `recordHex` is `u32 BE len(json)` followed by the UTF-8 bytes;
    `frameId` is `sha256(json utf8).hex.slice(0, 24)`; `session` is `isSessionFrameType(JSON.parse(json).type)`.
  - The generator validates each session sample against `SessionFrameTypeSchema` plus the matching body
    schema (`SessionPingFrame`/`SessionPongFrame`, or a local check for hello/established).
  - **EXECUTED:** the three frameIds shown were computed with `sha256sum` in this session; the hello one equals
    the pin already asserted by `bridge/tests/netwatch.test.ts` and `netwatch_tap_test.dart`.
  - The `native`, `authorization`, `streamOpen` and `quic` blocks are unchanged. The header comment stops
    saying "Peer transport v4" and describes the session-record pin.
- `evals/fixtures/peer-transport-vectors.json` is **regenerated** with `bun run --filter antgrid-wire
  gen:peer-vectors`, never hand-edited. The diff must be exactly: `framing` gone, `sessionRecords` added.

## 6. Dart APIs and seams (dart+app)

### 6.1 `packages/antgrid_relay_client/lib/src/frame.dart`

Keep `frameIdOf`, `utf8ByteLength`, `kPeerMaxRecordBytes`, `kPeerMaxBridgeRecordBytes` (re-derived, §4) and add
§2.3. Delete `peerFrameVersion`, `peerFrameFixedPrefix`, `maxPeerFrameHeaderBytes`, `kPeerFrameSession`,
`kPeerFrameMessage`, `FrameKind`, `FrameErrorReason`, `FrameException`, `encodePeerFrame`, `decodePeerFrame`,
`_validatePeerHeader`.

### 6.2 `peer_link.dart`

```dart
class IncomingSessionRecord {
  const IncomingSessionRecord({required this.payload});
  final Uint8List payload;
}

abstract class PeerLink {
  Stream<IncomingSessionRecord> get messageStream;
  Future<PeerSendOutcome> sendRecord(Uint8List payload);
  // everything else unchanged
}
```

`IncomingPeerFrame` and `sendFrame(String kind, Uint8List payload)` are gone. `PeerStream`,
`MultiStreamPeerLink`, `PeerSendOutcome` are unchanged. `LeasedPeerLink.sendRecord` delegates as `sendFrame`
does today; its `messageStream` fence is unchanged.

### 6.3 `packages/antgrid_peer_transport/lib/src/iroh_peer_link.dart`

- New public pure helper, used by the session `_read` **and** `NativePeerStream`'s framed read:
  `bool peerRecordLengthOk(int length, int maxRecordBytes) => length > 0 && length <= maxRecordBytes;`
- `_read`: a length failing `peerRecordLengthOk(length, kPeerMaxBridgeRecordBytes)` → `_fail('INVALID_RECORD_LENGTH', false)`.
  The body is read in slices as today and emitted as `IncomingSessionRecord(payload: bytes)`. The
  `on FrameException → INVALID_RECORD` arm is deleted.
- `sendRecord(payload)`: `closed` if not dispatch-allowed; `tooLarge` if `payload.length >
  kStreamProjectAppRecordMaxBytes`; `size = payload.length + 4`; `backpressured` if `_queued + size >
  kSessionStreamMaxQueuedBytes` (no reset); otherwise the same queued, sliced write as today with `record =
  [u32 BE payload.length][payload]`. The `INVALID_PEER_FRAME` failure is deleted (there is no kind to validate).
- `dial`'s open-frame write, `encodeStreamOpenFrame`, `PeerStreamOpener` and the error codes of
  `NativePeerStream` are unchanged.

### 6.4 `connection_handshake.dart`

- Sends the hello as `_relay.sendRecord(utf8.encode(jsonEncode({'type': kSessionHello, 'attemptId': …,
  'capabilities': …})))`. The capabilities literal is unchanged (it must still name every
  `SessionHelloCapabilities` key).
- The listener decodes each record's JSON (skipping undecodable ones) and completes on
  `json['type'] == kSessionEstablished && json['attemptId'] == attemptId`. No kind filter.

### 6.5 `machine_session.dart`

- `_onPeerFrame(IncomingPeerFrame)` → `_onSessionRecord(IncomingSessionRecord)`; `bad-utf8` drop keeps its
  reason with `channel: 'control'`. `_lastRecv`/`_missedPongs = 0` on every inbound record, unchanged.
- `_dispatchDecoded(String plaintext, String frameId)` (the `kind` parameter goes):
  1. JSON decode; failure → `_dropped('rx', 'plaintext-not-json', channel: 'control', streamId:
     kSessionStreamLabel, streamKind: 'session', frameId: frameId)`.
  2. `type` not a `String` → `_dropped('rx', 'unrecognized-plaintext', …same tags…)`.
  3. Emit the rx transport row (§7.1).
  4. `isSessionFrameType(type)` → `_handleSessionFrame(json, frameId)`; else `_snoopControl(json)` and
     `_streams[kSessionStreamLabel]?.dispatchFromSession(json, 'control')` as today.
- `_handleSessionFrame`: `kSessionPing` → send `{'type': kSessionPong}`; `kSessionPong` → `_missedPongs = 0`;
  `kSessionTakeover` → the current takeover body (teardown, report); default → `unknown-session-frame` drop.
  No `'ping'`, `'pong'` or `'session-takeover'` arm remains.
- `_checkLiveness` sends `{'type': kSessionPing}`. `kPingSilenceSeconds`, `kMaxMissedPongs` and the
  `pingSilence` ctor parameter are unchanged.
- The control send (today `relay.sendFrame(kPeerFrameMessage, bytes)`) and `_sendSessionFrame` both call
  `relay.sendRecord(bytes)`. On `accepted` with an unchanged generation, each emits the tx transport row
  (§7.1) instead of `_annotate`.
- The class doc stops describing the envelope. `_annotate` is deleted if nothing else calls it.

### 6.6 Other Dart

- `packages/antgrid_peer_transport/bin/native_smoke.dart`: scenarios `echo`, `oversize`, `refused-stream`,
  `extra-uni-stream`, `revoked` write/read plain records. `oversize` writes the length prefix
  `kMaxTransferBytes + 1` (not `0xffffffff`) and expects `INVALID_RECORD_LENGTH`.
- `packages/antgrid_peer_transport/bin/interop_app.dart`: immediately after `_emit({'check': 'established'})`,
  subscribe to `link.messageStream` (it is broadcast), `link.sendRecord(utf8.encode('{"type":"session:ping"}'))`,
  await a record whose JSON `type == 'session:pong'` (10 s timeout → fail the run), then
  `_emit({'check': 'session-ping-pong'})`. The subsequent checks keep their order.
- `packages/antgrid_eval_client/**`: **READ** no envelope use; its `commands.dart` mentions the ping only in
  prose. No change unless the compile says otherwise.
- `app/lib/connection/peer_connection.dart`, `app/lib/widgets/agent_transcript_view.dart`: comment text
  `session-takeover` → `session:takeover`.
- `app/lib/util/netwatch.dart`: the comments at the `FRAME_VERSION` mirror note and the "transport edge"
  paragraph stop naming `FRAME_VERSION`/the envelope. `NetwatchEvent`, `record`, `annotate` and the `tap`
  adapter are unchanged.

## 7. Netwatch

### 7.1 App transport rows for session records (dart+app)

**READ:** the app's native capture has no `op:'frame'` row for a session record today, only `op:'annotate'`
naming an event nothing recorded, so a session record's app half never reaches the capture file and cannot
join. After A9, `MachineSession` emits exactly one row per session record in each direction, through
`relay.netTap`, only when the tap is non-null (the id computation stays behind the null check):

```dart
{
  'op': 'frame', 'dir': 'rx' | 'tx', 'kind': 'frame', 'transport': 'iroh',
  'channel': 'control', 'streamKind': 'session', 'streamId': kSessionStreamLabel,   // '0'
  'msgType': type, 'bytes': payload.length, 'frameId': frameIdOf(payload),
}
```

This applies to session frames and control-plane AbMessages alike: both ride the session stream. The
resulting app JSONL line is `NetwatchEvent.toJson` of that row (`origin: 'app'`).

### 7.2 Bridge rows (bridge-src)

Unchanged: rx rows from `receiveSessionRecord`/`onSessionFrame`/`onControlMessage`, tx rows from
`recordNativeWrite`, all `transport:"iroh", channel:"control", streamKind:"session", streamId: "0"`.
`frameIdFor` is unchanged. The join key (`frameId\0channel\0sender`) therefore pairs app `tx` with bridge `rx`
and the reverse.

### 7.3 Joiner (`bridge/src/cli/netwatch.ts`, bridge-src)

**READ:** `runNetwatchJoin` narrows a join with no transport flag to `relay: true`, so every `iroh` row is
filtered out of both halves before `joinCaptures` runs. That makes a native join empty. Pinned fix:

```ts
/** The transport narrowing a join applies. Neither flag = everything but loopback. */
export function joinSelected(event: NetwatchEvent, opts: NetwatchCliOptions): boolean;
```

- `opts.local` → `transportOf(event) === "local"`; `opts.relay` → `=== "relay"`; neither → `!== "local"`.
- `runNetwatchJoin` filters both halves with `joinSelected(e, opts)` and no longer builds `scoped`. The live
  (non-join) filter `selected` is unchanged. The comment above it states the loopback reason.
- `joinCaptures` and `readAppCapture` keep their behaviour; `readAppCapture` gains `export`, because the
  §9 pairing test in `bridge/tests/netwatch-join.test.ts` imports it directly.

## 8. Seams after the wave

| Seam | Owner | After A9 |
|---|---|---|
| `bridge/tests/test-peer-session-owner.ts` | bridge-tests | Writer/outbox entries lose `kind`. `sendFromPeer(peerId, obj)`; `injectPeerPayload(payload, from)` → `receiveSessionRecord`; `injectPeerFrame` is **deleted** (callers use `injectPeerPayload`); `readFrameToPeer(peerId) → { body }` (no `kind`); `sentFramesTo(peerId)` returns parsed bodies; `setNativeWriter((payload, to, diagnosticType) => boolean)`; `establish()` sends the hello through `sendFromPeer` and awaits `session:established`. |
| `packages/antgrid_relay_client/test/support/fake_live_relay.dart` | dart+app | `class SentRecord { final Uint8List payload; Map<String, dynamic> get json; }` replaces `SentFrame`; `sendRecord(payload)` records one; `inject(IncomingSessionRecord)`; `injectFrame(payload, {kind})` → `injectRecord(Uint8List payload)`; `encodeFromAgent(String)` stays; `openedStreams`/`FakePeerStream` unchanged. |
| `evals/helpers/relay-client.ts` | evals | `handleBinaryFrame` → `handleSessionRecord(data)`: parse JSON, drop what does not parse or has no string `type`, then `isSessionFrameType(obj.type)` → `handleSessionFrame(obj)` else `dispatchAbMessage`. Cases: `session:established` → deliver; `session:ping` → reply `session:pong` if established; `session:pong` → resolve the oldest waiter; `session:takeover` → deliver (queued under that name). The hello wait matches `type === "session:established"`. `ping()` sends `session:ping`. `sendControlMessage`/`sendSessionFrame` write the JSON bytes as one record. Imports lose `encodePeerFrame`/`decodePeerFrame`/`PeerFrameKind`; `PEER_MAX_BRIDGE_RECORD_BYTES` stays. `sessionFrameTypes()` keeps its semantics (types seen via `handleSessionFrame`). |
| `evals/support/**` | evals | **EXECUTED** grep: no envelope symbol and no session-frame name. Unchanged. |
| `packages/antgrid_eval_client/lib/src/commands.dart` | dart+app | Unchanged (prose only). |
| `evals/helpers/dart-app-client.ts` | evals | Comments naming `established` → `session:established`. |

## 9. Tests per part

Markers: **[fails-on-old]** means the test fails against HEAD `8397c8a3` as written. **[break-only]** means it
cannot be run on old code (it uses a new name), so the implementer proves it by applying the named break,
watching the test go red, and restoring. Record each break in the report as EXECUTED.

### bridge-tests

- `bridge/tests/peer-session-hello.test.ts`
  - **Change H1** (pre-establishment drop): a `{type:"session:ping"}` and a `{type:"ping"}` before the hello
    are both `pre-establishment` drops.
  - **Delete H2** (hello under the `message` header): there is no header.
  - **Replace H4** with **"an old-name ping is control plane, not a session frame"**: after establishment,
    inject `{type:"ping", id, timestamp}`; assert it reaches the bus (`dispatchInbound` sees type `ping`) and
    no record goes back to the peer; then inject `{type:"session:ping"}` and assert exactly one
    `{type:"session:pong"}` to the peer and nothing on the bus. **[break-only]**: add `"ping"` to
    `SESSION_FRAME_TYPES` and a `case "ping"` pong arm → red; restore.
  - **Change H5** (stale `credit`): it now reaches `onControlMessage`, is not a known type, reaches no bus
    handler and draws no reply; no `unknown-session-frame` drop.
  - **New:** a `session:takeover` or `session:established` from the app is dropped `unknown-session-frame`
    and reaches no bus.
  - The re-ack test expects `{type:"session:established", attemptId}`. Native tests build the hello and the
    paused ping as plain JSON records (`helloFrame()` returns `Buffer.from(JSON.stringify(…))`).
  - Delete the pre-hello envelope test if it only exercised envelope decoding; keep its admission half if it
    has one.
- `bridge/tests/native-host-connection.test.ts`
  - **Change N5:** push `lengthPrefix(STREAM_PROJECT_APP_RECORD_MAX_BYTES + 1)` (the literal payload cap plus
    one, not `PEER_MAX_RECORD_BYTES + 1`) and assert the peer retires `protocol-violation`.
    **[fails-on-old]**: the old reader cap was 1_501_028, so a 1_500_001 prefix was accepted.
  - Remove `FRAME_VERSION`, `FrameKind`, `encodePeerFrame`, `PeerFrameKind`, `rawPeerFrame`; `pushRecord`
    sites push plain JSON; `writeSessionRecord(slot, payload, …)` calls drop the kind; assert
    `recordNativeWrite`'s detail is `{recordBytes, lengthPrefixBytes}` if a test reads it.
  - **New:** a non-JSON session record after establishment is a `plaintext-not-json` drop and the peer stays
    connected (D-A9-4).
- `bridge/tests/protocol.test.ts`: `SessionEstablishedFrame` parses `session:established` and rejects
  `established`. **New disjointness test:** for every `t` in `SESSION_FRAME_TYPES`, no
  `AbMessageSchema.options[i].shape.type.value` equals `t`, and `parseMessageFast(JSON.stringify({type: t}))`
  is `null` (which is the `KNOWN_TYPES` check). Also assert the options list is non-empty and contains
  `"ping"`, so the loop cannot pass vacuously. **[break-only]**: add `"session:ping"` to `KNOWN_TYPES` → red;
  restore. **EXECUTED** at HEAD with a throwaway Bun probe: `AbMessageSchema.options` has 168 literal types,
  none of the five session types among them, and `ping` present; the `KNOWN_TYPES` block's `session:*`
  entries are list/list:result/create/fork/start/stop/rename/archive/unarchive/delete/set-mode/setup/focus/
  result/updated.
- `bridge/tests/handshake-pull.test.ts`, `netwatch-remote.test.ts`, `netwatch.test.ts`: drop kinds, use
  `session:established`, `session:ping`/`session:pong`; `netwatch.test.ts` l.126's `injectPeerFrame` becomes
  `injectPeerPayload`. The `frameIdFor` pin (`1e65322bad672889949c1355`) stays.
- `bridge/tests/netwatch-join.test.ts`
  - **New `joinSelected` table test:** no flags keeps `iroh` and `relay`, drops `local`; `--local` keeps only
    `local`; `--relay` keeps only `relay`. **[break-only]**: make the no-flag branch `=== "relay"` → red.
  - **New pairing test:** read the `ping` sample from `evals/fixtures/peer-transport-vectors.json`. Write one
    literal app capture line to a temp file,
    `{"seq":1,"at":<t>,"dir":"tx","kind":"frame","transport":"iroh","origin":"app","channel":"control","streamId":"0","streamKind":"session","msgType":"session:ping","bytes":23,"frameId":"<sample.frameId>"}`,
    and read it back with `readAppCapture`. Produce the bridge half from the real receive path: a
    `TestPeerSessionOwner`, established, `injectPeerPayload(Buffer.from(sample.json))`, then take the netwatch
    ring's `rx frame` row. Filter both halves with `joinSelected(e, {})` and run `joinCaptures(app, bridge, now)`.
    Assert the app row and the bridge row are both verdict `matched`. **[fails-on-old]** in substance, since
    the old default narrowing dropped both `iroh` rows. **[break-only]** as written: (a) narrow `joinSelected`'s
    default to relay → red; (b) make `frameIdFor` hash `[len][body]` → red. Restore both.
- `bridge/tests/project-streams.test.ts`, `terminal-frame-cancellation.test.ts` and every other
  `setNativeWriter`/`createMessage("pong")` user: compile only.
- `packages/antgrid-wire/tests/peer-frame.test.ts`: **delete**.
- `packages/antgrid-wire/tests/peer-transport-vectors.test.ts`: replace the `framing` assertions with
  `sessionRecords`. The caps equal the constants; `types` deep-equals `SESSION_FRAME_TYPES`; for each sample,
  `recordHex` is the length prefix plus UTF-8 `json`, `frameId` equals the sha256/24 of `json`, and `session`
  equals `isSessionFrameType(JSON.parse(json).type)`.
- `packages/antgrid-wire/tests/stream-open.test.ts` l.162: `PEER_MAX_RECORD_BYTES === 1_500_000 ===
  STREAM_PROJECT_APP_RECORD_MAX_BYTES` and `PEER_MAX_BRIDGE_RECORD_BYTES === MAX_TRANSFER_BYTES`.
  **[fails-on-old]**.
- **New** `packages/antgrid-wire/tests/peer-protocol.test.ts` (or a block in an existing wire test):
  `isSessionFrameType` accepts the five and rejects `ping`, `pong`, `established`, `session-takeover`,
  `session:list`, `undefined`, `42`.

### dart+app

- `packages/antgrid_relay_client/test/frame_test.dart`: delete the envelope groups; keep `frameIdOf`/
  `utf8ByteLength`; add `isSessionFrameType` (same accept/reject table as the wire test).
- `packages/antgrid_peer_transport/test/peer_transport_vectors_test.dart`: `sessionRecords` block. The caps
  equal `kPeerMaxRecordBytes`/`kPeerMaxBridgeRecordBytes`, and `kPeerMaxBridgeRecordBytes == kMaxTransferBytes`
  **[fails-on-old]**. `kSessionFrameTypes` set-equals `types`. For each sample, `frameIdOf(utf8(json)) ==
  frameId`, the length-prefixed bytes equal `recordHex`, and `isSessionFrameType(type) == session`.
- **New** `packages/antgrid_peer_transport/test/peer_record_length_test.dart`: `peerRecordLengthOk(0, m)`
  false; `(m, m)` true; `(kMaxTransferBytes + 1, kPeerMaxBridgeRecordBytes)` false **[break-only]** (restore
  the old `+ maxPeerFrameHeaderBytes + peerFrameFixedPrefix` derivation → red).
- `machine_session_envelope_test.dart`: keep the file name. Its cases become **"an old-name ping from the
  bridge is control plane"**: inject `{type:'ping'}`, assert no `session:pong` among `sentRecords` and that it
  was dispatched to the control transport; inject `{type:'session:ping'}`, assert exactly one `session:pong`.
  **[break-only]**: re-add a `case 'ping'` arm that pongs → red.
- `machine_session_establish_test.dart` / `machine_session_lifecycle_test.dart`: the takeover group injects
  `{type:'session:takeover'}`. **New:** `{type:'session-takeover'}` does **not** tear down (it is control
  plane). **[break-only]**: add `'session-takeover'` back as an arm → red.
- `connection_handshake_test.dart`: the hello is a plain record with `type == 'session:hello'`; an
  `{type:'established'}` reply does **not** complete the handshake, and `{type:'session:established',
  attemptId}` does. **[break-only]**: match `'established'` → red.
- `netwatch_tap_test.dart`: **new** — with a tap armed, one session-stream tx (`session:ping` via the liveness
  path or `_sendSessionFrame`) and one rx each produce exactly one `op:'frame'` row with the §7.1 fields, and
  the ping row's `frameId` equals the fixture's `ping` sample. **[fails-on-old]** (no such rows today).
  Drop-reason assertions use `channel: 'control'`.
- `app/test/util/netwatch_test.dart`: **new** — feeding the §7.1 row through `Netwatch.tap` writes a JSONL line
  whose keys and values match bridge-tests' literal line (dir, kind, transport `iroh`, origin `app`, channel,
  streamId, streamKind, msgType, bytes, frameId). **[fails-on-old]** only if the adapter needs a change;
  otherwise it is a lockstep pin and says so in its name.
- **New** `app/test/models/session_frame_types_disjoint_test.dart`: read `lib/models/ab_message.dart` as text,
  collect every `case '<literal>':`, assert the set is non-empty and contains `agent:hello`, and assert it is
  disjoint from `kSessionFrameTypes`. Also assert `parseAbMessage({'type': t, 'id': 'x', 'timestamp': 0})` is
  `null` for each session type. **[break-only]**: add `case 'session:ping':` to the parser → red.
  **EXECUTED** at HEAD: no `case` literal in `ab_message.dart` is a session type, `ping` or `pong`.
- Every other `PeerLink` fake and `FakeLiveRelay` user (§12) is a compile fix: `sendFrame(kind, p)` →
  `sendRecord(p)`, `IncomingPeerFrame(kind:…, payload:…)` → `IncomingSessionRecord(payload:…)`,
  `injectFrame` → `injectRecord`, `'established'` → `'session:established'`.

### evals

- `evals/tests/peer-liveness.test.ts`: `sessionFrameTypes()` does not contain `session:ping` (the bridge never
  pings), and `env.app.ping()` resolves. **[break-only]**: delete the bridge's `session:ping` arm → the ping
  times out.
- `evals/tests/gate-two-devices-one-bridge.test.ts`: `drainQueued("session:takeover")`, still zero.
- `evals/tests/gate-inventory-miss.test.ts`, `evals/tests/gate-iroh-host-authorization.test.ts`: raw session
  streams write the hello as a plain JSON record and wait for `session:established`; the
  `PEER_MAX_BRIDGE_RECORD_BYTES` reader stays.
- `evals/tests/gate-vectors.test.ts`: the comment says "session-record bytes", not "peer-frame bytes". The
  git-clean guard fails until the fixture is committed; that is expected.
- The real-binding round trip is `qualify:iroh-host` (Bun app ↔ real bridge: hello → `session:established` →
  `session:ping` → `session:pong`) and `qualify:iroh-interop` (Dart `IrohPeerLink` ↔ Bun bridge, the new
  `session-ping-pong` check). **[fails-on-old]**: the old bridge answers an envelope-less record with a
  protocol-violation retire.

## 10. Docs (bridge-src unless marked)

| File | Change |
|---|---|
| `CLAUDE.md` (root) | The `antgrid-wire` parenthetical: drop "peer-frame codec" and "source of truth for `FRAME_VERSION`". Say it holds the session-frame type names, the stream-open records and the relay control-envelope Zod schemas, and keep "the Dart client mirrors it **by hand**". No counts. |
| `bridge/CLAUDE.md` | Where it describes session-stream records or `receivePeerFrame`, name `receiveSessionRecord` and "one JSON record, dispatched on `type`". |
| `DEVELOPMENT.md` | The three `antgrid-wire` descriptions lose "frame codec" and `FRAME_VERSION`. |
| `docs/protocol/peer-session.md` | Drop the `FRAME_VERSION` line at the top. Rewrite the envelope section as the session-record layout (§2.1), the session-frame table (D-A9-1) and dispatch-on-`type` (§3.2). Rename `receivePeerFrame` and `established`, and point caps at §4's constants. |
| `docs/architecture.md` | The session stream carries "one length-prefixed JSON record per session frame or control message"; the `antgrid-wire` paragraph drops the codec and `FRAME_VERSION` and names `SESSION_FRAME_TYPES`. |
| `SECURITY.md` | "vectors for the frame format" → "for the session-record and stream-open formats". |
| `docs/iroh-reduction/ledger.md` | Add the A9 row after A8: `\| A \| A9 session stream drops the peer-frame envelope \| done \| <hash> \|`, and an A9 gate-evidence bullet filled in by the commit agent. |
| `packages/antgrid_relay_client/CLAUDE.md` (dart+app) | Where it names `kPeerFrameSession`/`kPeerFrameMessage`, say session frames are typed by `kSessionFrameTypes`. |
| Historical plans and earlier contracts (`docs/iroh-transport-reduction-plan.md`, `docs/native-transport-followup-plan.md`, `stage-*-contract.md`, `stage-*-waves.md`) | Unchanged. They are records. |

## 11. Gates per part

| Part | Gate |
|---|---|
| bridge-src | `bun run --filter antgrid-wire gen:peer-vectors` (diff: `framing` → `sessionRecords` only); `bun run --filter antgrid-wire typecheck`; `bun run --filter antgrid-bridge typecheck` (test files may lag until bridge-tests lands; report which); `bun run --filter antgrid-relay typecheck`; `bun run --filter antgrid-bridge qualify:iroh-host`; `qualify:iroh-interop` once dart+app has landed |
| bridge-tests | `bun run --filter antgrid-wire test`; `bun run --filter antgrid-bridge test > file`, grep `(fail)`: only the known red is allowed; `bun run --filter antgrid-relay test` (the cap moved through the import) |
| dart+app | `dart test` in `packages/antgrid_relay_client` and `packages/antgrid_peer_transport`; `cd app && flutter test -j 2`; `npm run check:font-tokens`; `analyze_files` while iterating. The controller runs `flutter analyze` once, never concurrently. |
| evals | `bun run --filter antgrid-evals typecheck`; `evals/tests/peer-liveness.test.ts`; `evals/tests/gate-two-devices-one-bridge.test.ts`; `evals/tests/gate-inventory-miss.test.ts`; `evals/tests/gate-iroh-host-authorization.test.ts`; `test:evals:dart-liveness`; `test:evals:dart-terminal` |

## 12. File ownership (disjoint and complete)

| File | Part |
|---|---|
| `packages/antgrid-wire/src/peer-frame.ts` (deleted), `src/peer-protocol.ts`, `src/peer-authorization.ts`, `src/index.ts`, `scripts/gen-peer-transport-vectors.ts` | bridge-src |
| `evals/fixtures/peer-transport-vectors.json` (regenerated only) | bridge-src |
| `bridge/src/peer-session-owner.ts`, `bridge/src/peer/native-host-connection.ts`, `bridge/src/protocol.ts` (§3.4 only), `bridge/src/cli/netwatch.ts`, `bridge/src/host-server.ts` (comment naming `receivePeerFrame` only) | bridge-src |
| `bridge/scripts/iroh-host-smoke.ts`, `bridge/scripts/iroh-interop-smoke.ts` | bridge-src |
| `CLAUDE.md`, `bridge/CLAUDE.md`, `DEVELOPMENT.md`, `SECURITY.md`, `docs/protocol/peer-session.md`, `docs/architecture.md`, `docs/iroh-reduction/ledger.md` | bridge-src |
| `packages/antgrid-wire/tests/peer-frame.test.ts` (deleted), `tests/peer-transport-vectors.test.ts`, `tests/stream-open.test.ts`, `tests/peer-protocol.test.ts` (new) | bridge-tests |
| `bridge/tests/test-peer-session-owner.ts`, `peer-session-hello.test.ts`, `native-host-connection.test.ts`, `protocol.test.ts`, `handshake-pull.test.ts`, `netwatch.test.ts`, `netwatch-remote.test.ts`, `netwatch-join.test.ts`, and any other file under `bridge/tests/` | bridge-tests |
| `packages/antgrid_relay_client/**`: `lib/src/frame.dart`, `lib/src/peer_link.dart`, `lib/src/connection_handshake.dart`, `lib/src/machine_session.dart`, `lib/antgrid_relay_client.dart` (exports, if needed), `CLAUDE.md`, `test/support/fake_live_relay.dart`, `test/frame_test.dart`, `test/connection_handshake_test.dart`, `test/machine_session_envelope_test.dart`, `test/machine_session_establish_test.dart`, `test/machine_session_lifecycle_test.dart`, `test/machine_session_project_stream_test.dart`, `test/machine_session_snapshot_retry_test.dart`, `test/machine_session_stream_binding_test.dart`, `test/machine_session_rpc_health_test.dart`, `test/peer_link_test.dart`, `test/terminal_attachment_test.dart`, `test/tunnel_stream_test.dart`, `test/upload_stream_test.dart`, `test/netwatch_tap_test.dart` | dart+app |
| `packages/antgrid_peer_transport/**`: `lib/src/iroh_peer_link.dart`, `lib/src/leased_peer_link.dart`, `bin/native_smoke.dart`, `bin/interop_app.dart`, `test/peer_transport_vectors_test.dart`, `test/peer_record_length_test.dart` (new), `test/connection_attempt_test.dart`, `test/leased_peer_link_lifecycle_test.dart`, `test/leased_peer_link_stream_test.dart` | dart+app |
| `packages/antgrid_eval_client/**` (only if the compile demands it) | dart+app |
| `app/**`: `lib/connection/peer_connection.dart` (comment), `lib/widgets/agent_transcript_view.dart` (comment), `lib/util/netwatch.dart` (comments), `test/connection/peer_connection_session_binding_test.dart`, `test/connection/peer_transport_integration_test.dart`, `test/helpers/fixed_peer_connector.dart`, `test/helpers/test_peer_runtime.dart`, `test/project/project_session_stream_events_test.dart`, `test/providers/agent_transport_coords_retry_test.dart`, `test/providers/agent_transport_identity_test.dart`, `test/providers/agent_transport_test.dart`, `test/relay/relay_connection_open_test.dart`, `test/util/netwatch_test.dart`, `test/models/session_frame_types_disjoint_test.dart` (new) | dart+app |
| `evals/**` except the fixture: `helpers/relay-client.ts`, `helpers/dart-app-client.ts` (comments), `tests/peer-liveness.test.ts`, `tests/gate-two-devices-one-bridge.test.ts`, `tests/gate-inventory-miss.test.ts`, `tests/gate-iroh-host-authorization.test.ts`, `tests/gate-vectors.test.ts` (comment) | evals |
| `relay/**` | nobody (the value moves through the import) |

### Deleted or renamed symbol → call sites

The call sites come from an **EXECUTED** `git grep -lF` at HEAD, excluding historical contracts.

| Symbol | Call sites |
|---|---|
| `encodePeerFrame`, `decodePeerFrame` (TS) | `bridge/scripts/iroh-host-smoke.ts`, `bridge/src/peer/native-host-connection.ts`, `bridge/tests/{native-host-connection,netwatch,peer-session-hello}.test.ts`, `bridge/tests/test-peer-session-owner.ts`, `evals/helpers/relay-client.ts`, `evals/tests/gate-inventory-miss.test.ts`, `evals/tests/gate-iroh-host-authorization.test.ts`, `packages/antgrid-wire/{scripts/gen-peer-transport-vectors.ts,src/index.ts,src/peer-frame.ts,tests/peer-frame.test.ts,tests/peer-transport-vectors.test.ts}` |
| `encodePeerFrame`, `decodePeerFrame`, `FrameException`, `FrameKind`, `FrameErrorReason` (Dart) | `packages/antgrid_relay_client/lib/src/frame.dart`, `test/frame_test.dart`, `packages/antgrid_peer_transport/{lib/src/iroh_peer_link.dart,bin/native_smoke.dart,test/peer_transport_vectors_test.dart}` |
| `FRAME_VERSION` | `packages/antgrid-wire/{src/peer-frame.ts,src/index.ts,scripts/gen-peer-transport-vectors.ts,tests/peer-frame.test.ts}`, `bridge/tests/native-host-connection.test.ts`, `app/lib/util/netwatch.dart` (comment), `CLAUDE.md`, `DEVELOPMENT.md`, `docs/architecture.md`, `docs/protocol/peer-session.md`, `docs/iroh-reduction/ledger.md` (history; leave) |
| `FIXED_PREFIX`, `MAX_HEADER_LEN` | `packages/antgrid-wire/{src/peer-frame.ts,src/index.ts,src/peer-authorization.ts,scripts/gen-peer-transport-vectors.ts,tests/stream-open.test.ts}` |
| `peerFrameVersion`, `peerFrameFixedPrefix`, `maxPeerFrameHeaderBytes` | `packages/antgrid_relay_client/lib/src/frame.dart`, `packages/antgrid_peer_transport/test/peer_transport_vectors_test.dart` |
| `PeerFrameHeader`, `PeerFrameKind` | `packages/antgrid-wire/src/peer-protocol.ts`, `bridge/src/peer-session-owner.ts`, `bridge/src/peer/native-host-connection.ts`, `bridge/tests/native-host-connection.test.ts`, `bridge/tests/test-peer-session-owner.ts`, `evals/helpers/relay-client.ts`, `docs/protocol/peer-session.md` |
| `FrameError` (TS) | `packages/antgrid-wire/{src/peer-frame.ts,src/index.ts,tests/peer-frame.test.ts}` |
| `kPeerFrameSession`, `kPeerFrameMessage` | `packages/antgrid_relay_client/{lib/src/frame.dart,lib/src/peer_link.dart,lib/src/connection_handshake.dart,lib/src/machine_session.dart,CLAUDE.md}`, `packages/antgrid_peer_transport/{lib/src/iroh_peer_link.dart,bin/native_smoke.dart,test/leased_peer_link_lifecycle_test.dart}`, relay_client tests (§12 row), `app/test/{project/project_session_stream_events_test,providers/agent_transport_identity_test,relay/relay_connection_open_test}.dart` |
| `IncomingPeerFrame` → `IncomingSessionRecord`, `sendFrame` → `sendRecord` | every Dart file in the dart+app rows of §12 that declares a `PeerLink` or `FakeLiveRelay` |
| `SentFrame` → `SentRecord`, `injectFrame` → `injectRecord` | `fake_live_relay.dart` and its users under `packages/antgrid_relay_client/test/` |
| `receivePeerFrame` → `receiveSessionRecord` | `bridge/src/peer-session-owner.ts`, `bridge/src/peer/native-host-connection.ts`, `bridge/src/host-server.ts` (comment), `bridge/tests/test-peer-session-owner.ts`, `bridge/tests/peer-session-hello.test.ts` (comments), `docs/protocol/peer-session.md` |
| `injectPeerFrame` (deleted) | `bridge/tests/test-peer-session-owner.ts`, `bridge/tests/netwatch.test.ts` |
| `"established"` → `"session:established"` | `bridge/src/{peer-session-owner,protocol}.ts`, `bridge/scripts/iroh-host-smoke.ts`, `bridge/tests/{handshake-pull,peer-session-hello,protocol}.test.ts`, `evals/helpers/relay-client.ts`, `evals/tests/{gate-inventory-miss,gate-iroh-host-authorization}.test.ts`, `packages/antgrid_relay_client/lib/src/connection_handshake.dart`, `test/connection_handshake_test.dart`, `app/test/relay/relay_connection_open_test.dart`. `bridge/scripts/iroh-interop-smoke.ts` and `interop_app.dart` use `established` as a **check name**; it stays. `app/test/control_plane_client_test.dart` uses it as a test title; it stays. |
| `ping`/`pong` as session frames → `session:ping`/`session:pong` | `bridge/src/peer-session-owner.ts`, `packages/antgrid_relay_client/lib/src/machine_session.dart`, `evals/helpers/relay-client.ts`, `bridge/tests/{handshake-pull,peer-session-hello}.test.ts`, `evals/tests/peer-liveness.test.ts`. `PingMessage`/`PongMessage` and `createMessage("pong")` in tests are control-plane and **stay**. |
| `session-takeover` → `session:takeover` | `packages/antgrid_relay_client/lib/src/machine_session.dart`, `test/machine_session_{establish,lifecycle}_test.dart`, `app/lib/connection/peer_connection.dart`, `app/lib/widgets/agent_transcript_view.dart`, `app/test/project/project_session_stream_events_test.dart`, `evals/helpers/relay-client.ts`, `evals/tests/gate-two-devices-one-bridge.test.ts`, `docs/protocol/peer-session.md` |
| `INVALID_RECORD` / `INVALID_PEER_FRAME` on the session link | `packages/antgrid_peer_transport/lib/src/iroh_peer_link.dart` only. `INVALID_RECORD` on project/terminal streams (`machine_session.dart`, `terminal_attachment.dart`, their tests, `relay-client.ts`) **stays**. |
| `recordNativeWrite`'s `peerFrameBytes` | `bridge/src/peer/native-host-connection.ts`, any bridge test that reads the detail |
