# Peer session protocol (native Iroh payload path)

This supersedes the old `docs/protocol/e2e-handshake.md` (v2 handshake crypto, retired). There is no
app-layer handshake, transcript, key schedule or rekey to specify any more: **QUIC/TLS between two
Iroh endpoints the authorization snapshot names is the confidentiality layer**, and a native connection
carries exactly one plaintext session hello. What follows is the shape of that hello and the invariants
around it that no single test suite owns end to end.

---

## 1. Identity and admission

A native connection is accepted only from an endpoint ID present in the caller's authorization lease
(`acceptPeer`, `bridge/src/peer/native-host-connection.ts`); the peer's Ed25519 pubkey used for
identity/push targeting (`admitPeer`, `bridge/src/peer-session-owner.ts`) comes from that same lease
entry, never from anything the peer sends over the wire — there is no signature for the bridge to
verify because the QUIC handshake already proved which endpoint dialed in.

**Same-endpoint reconnect:** the newest authenticated connection from a given endpoint ID retires the
prior one in `acceptPeer` ("newest wins") rather than being refused. Sessions are keyed per device, so
a *different* endpoint for the same device cannot sit alongside it: while the lease still authorizes the
held endpoint, the newcomer is the one closed — a second endpoint never evicts a live, authorized one.
Only when the held endpoint has lost its authorization is it retired in the newcomer's favour.

## 1a. Streams

ALPN `antgrid/peer/2`. Every native bidirectional stream — the session stream included — opens with one
open-frame record, `[u32 BE len][UTF-8 JSON StreamOpen]`; the body is raw JSON, not a peer frame. Schema
and codecs: `StreamOpen`/`StreamRefused`, `encodeStreamOpen`/`decodeStreamOpen`,
`encodeStreamRefused`/`decodeStreamRefused` (`packages/antgrid-wire/src/stream-open.ts`).

**The first stream** the bridge accepts must declare `{kind:"session"}`. A missing, unparseable or
non-session first open closes the connection (code `2n`, protocol violation) rather than being refused
in-band — there is no session yet worth keeping alive. Once validated, the session stream carries the
rest of this document unchanged: session-stream records (§4) and the hello (§2), all on the same stream,
with no open acknowledgement. There is no fragmentation and no credit-flow window left to carry (A5
deleted both — see §5): one `AbMessage` (or one session frame) is one record, sliced only at the
transport layer (`StreamRecordWriter`, `bridge/src/peer/stream-records.ts`), and
`MAX_TRANSFER_BYTES`/`PEER_MAX_RECORD_BYTES` bound a record's size instead of a window's.

**Every later stream** is admitted in its own task by `PeerStreamAcceptor`
(`bridge/src/peer/stream-dispatch.ts`), so stream *N+1* is never blocked behind stream *N*'s open-frame
read. Admission order per stream:

1. A pending-open cap per peer (`STREAM_MAX_PENDING_OPENS_PER_PEER`) — over cap is refused
   `CAP_EXCEEDED` without being read.
2. The open frame is read under a 5s deadline; a missed deadline resets the stream's send half (the read
   still holds the recv mutex, so `recv.stop` waits until that read settles, and a late frame is never
   admitted) and a native read failure (peer FIN/reset) drops the stream silently. Neither costs the
   connection.
3. A peer no longer authorized gets nothing written; the connection is retired as unauthorized instead.
4. An unparseable, zero-length or oversized open frame, or `{kind:"session"}` on a later stream (the
   session stream is already open), is refused `INVALID`.
5. A non-session open before the session is established is refused `NOT_READY`.
6. A well-formed kind with no registered handler is refused `NOT_ALLOWED`.

Refusals are in-band `{type:"stream:refused", code, message}` followed by FIN — the Dart binding cannot
read a QUIC reset code, so every refusal the app must act on has to be a record it can decode. Reset and
stop codes (`STREAM_STOP_REFUSED`, `STREAM_RESET_OPEN_TIMEOUT`, `STREAM_RESET_REFUSED`,
`bridge/src/peer/stream-dispatch.ts`) are bridge-side diagnostics only. A refused or timed-out later
stream never costs the connection; only an unauthorized peer or a first-stream protocol violation does.

As of Stage A wave A1 the handler table held nothing, so every well-formed later stream was refused
`NOT_ALLOWED`. Wave A2 registers `{kind:"terminal"}` (§1b); wave A3 adds `{kind:"tunnel-http"}` and
`{kind:"tunnel-ws"}` (§1c); wave A4 adds `{kind:"project"}` (§1d), which replaces the session stream's old
`{s,m}` mux entirely; wave A7 adds `{kind:"upload"}` (§1e). The QUIC-level cap
(`STREAM_MAX_BIDI_STREAMS_PER_CONNECTION`) is set
once per connection via `setMaxConcurrentBiStreams`, synchronously after the ALPN check. All caps are
defined once in `packages/antgrid-wire/src/stream-open.ts` and hand-mirrored in
`packages/antgrid_relay_client/lib/src/models/stream_open.dart`.

## 1b. Terminal attachment streams

A terminal attachment (§1a's `{kind:"terminal", projectId, checkoutId?, requestId}`) gets its own stream
once admitted by `TerminalStreamRegistry` (`bridge/src/peer/terminal-streams.ts`), plugged into
`PeerStreamAcceptor` as `handlers.terminal`. Admission additionally requires a catalogued, safe
`projectId` whose project currently has a live entry on the mux (`StreamMux.projectBinding`) — a lookup
only; a stream open never opens or promotes a core. Past admission, refusal reuses §1a's in-band
`stream:refused` codes; a `NOT_READY` here means the project has no live mux entry yet, not that the open
frame was malformed.

**Record set.** After the open frame, every record body is the raw UTF-8 JSON of one `AbMessage` — no
`{s,m}` peer-frame envelope and no channel label. Exactly eight message types ride this stream:
app→bridge `terminal:subscribe`, `terminal:ack`, `terminal:unsubscribe`, `terminal:history:request`;
bridge→app `terminal:subscribed`, `terminal:frame`, `terminal:display:status`, `terminal:history:page`.
Everything else — `terminal:input`, `terminal:resize`, `terminal:start` and the rest — stays on the
project/session stream, unchanged by this section.

**First-record rule.** The app's first record must be a `terminal:subscribe` naming the open frame's own
`requestId` and normalized `checkoutId` (an absent `checkoutId` on either the open frame or the message
normalizes to `"main"`). Every later app record must carry the same `terminalId`, `checkoutId`, and the
`attachmentId`/`runId` the bridge bound from its own `terminal:subscribed` — one arriving before
`subscribed` is a breach. The bridge's first record is either a refusal (§1a) or `terminal:subscribed`
itself, or the requestId-addressed `terminal:display:status` that ends a failed attempt. A record that
breaks either rule aborts only that stream, never the connection.

**Routing keys.** `subscribed`, and a `display:status` naming no bound attachment yet (UPGRADE_REQUIRED,
UNKNOWN_TERMINAL, a failed attach), route by `(peerId, requestId)`; every other outbound message routes by
`(peerId, attachmentId)`. A message with no bound stream falls back to that peer's project stream (§1d) —
this is how the app's own `terminal:subscribe` on the project stream (still accepted; the app itself never
sends one there) and older builds keep working.

**Ends.** When delivery retires the attachment, the bridge `finish()`es its send half; the app reads that
FIN as a plain retirement, not an ENDED status. When the app FINs or resets its send half, the bridge
synthesizes `terminal:unsubscribe` for whatever attachment was bound. An overflow or a lost stream resets
only that one stream (every other attachment and the connection are untouched); only `unauthorized`, or an
app record whose length prefix exceeds the stream's cap (a protocol violation), closes the connection.

**Caps.** `STREAM_TERMINAL_APP_RECORD_MAX_BYTES`, `STREAM_TERMINAL_BRIDGE_RECORD_MAX_BYTES` and
`STREAM_MAX_TERMINAL_ATTACHMENTS_PER_PEER` are defined once in `packages/antgrid-wire/src/stream-open.ts`
beside every other stream cap (§1a); the writer's queue ceiling
(`TERMINAL_STREAM_MAX_QUEUED_BYTES`) and stream priority (`STREAM_PRIORITY_TERMINAL`) are side-local to
`bridge/src/peer/terminal-streams.ts`, since Dart has no priority concept and nothing on the app side reads
them.

## 1c. Tunnel streams

Stage A wave A3 moves HTTP-proxy and browser-side-WebSocket preview traffic off the bus entirely and
onto its own QUIC streams, one per exchange: `{kind:"tunnel-http", projectId, requestId}` opens one
stream for exactly one HTTP request/response pair, `{kind:"tunnel-ws", projectId, wsId}` one stream for
one browser-side WebSocket's whole lifetime. Both are admitted by `TunnelStreamRegistry`
(`bridge/src/peer/tunnel-streams.ts`), plugged into `PeerStreamAcceptor` as `handlers["tunnel-http"]` /
`handlers["tunnel-ws"]`, and pass through §1a's cap/pending-open/timeout admission exactly as a terminal
stream does — including the catalogued-and-safe `projectId` / live mux binding check
(`StreamMux.tunnelBinding`, the tunnel counterpart of `projectBinding`), a lookup only, never an open or a
promotion.

**Record framing.** A tunnel stream carries two shapes of record. The head/close control records are
length-prefixed, `[u32 BE len][body]`, discriminated by the body's first byte:

| First byte | Meaning |
|---|---|
| `0x7B` (`{`) | UTF-8 JSON control record — the whole body is one JSON object |
| `0x02` | WebSocket frame, text |
| `0x03` | WebSocket frame, binary |

A WS frame still carries a tag because one stream multiplexes many discrete frames of either kind;
codecs and constants: `encodeTunnelDataRecord`/`decodeTunnelRecord`, `TUNNEL_RECORD_TAG_WS_TEXT`/
`_WS_BINARY` (`packages/antgrid-wire/src/stream-open.ts`). An HTTP request or response body, by
contrast, is the ONLY thing that stream carries in that direction once the head has gone by, so it
needs neither a length prefix nor a tag: it is raw bytes, read with `StreamRawReader` and written with
`StreamRecordWriter.sendRaw()` (`bridge/src/peer/stream-records.ts`), exactly like an upload's file
bytes (§1e).

**First-record rule.** The checkout a tunnel targets rides this record, not the open frame (D-7 — the
open-frame schemas above are frozen as of A0b). An HTTP stream's first record must be a JSON
`tunnel:http-request`, naming the same `requestId` as the open frame plus `checkoutId`, `headers` and
`bodyLength`; a WS stream's first record must be `tunnel:ws-open`, naming the same `wsId` as the open
frame's under the field `tunnelId`, plus `checkoutId`. Either is read under the same 5s deadline as §1a's
open frame. Once the head record parses, `AgentCore.tunnelStreams.admit(peerId, checkoutId)` runs, in
order: the remote-access switch (`NOT_ALLOWED` if off), checkout-routing capability if the peer's project
holds any isolated session (`UPDATE_REQUIRED`), the named checkout must be a currently running runtime
(`NOT_ALLOWED` — "unknown checkout"), and that runtime must have a `TunnelManager` (`NOT_ALLOWED`). Any
failure refuses in-band exactly as §1a describes, on the tunnel stream itself; a malformed head record, or
one naming an id other than the open frame's, is refused `INVALID`.

**The end of a body.** An HTTP stream's response ends when the bridge `finish()`es its send half — a
plain FIN, exactly like a terminal stream (§1b). Native FIN and reset are distinguishable on the wire,
so unlike the old length-prefixed framing this needs no JSON verb to tell the app which one happened.
A WS stream still ends with a JSON `tunnel:ws-close` (optional `code`/`reason`) then FIN, because a
close carries a code/reason a bare FIN cannot.

**Cancel.** The app cancels by resetting (or FIN-ing) its own send half; the bridge's pending read on that
half fails, which it treats as the app's cancel — aborting the upstream fetch or WS and then closing its
own send half in turn, exactly as if it had reached the end on its own. A raw read that would push the
request body past its declared `bodyLength`, or a record arriving after the app's own end, is a stream
breach. Failure isolation matches §1b: an overflow or a lost stream resets only that one stream — every
other tunnel, attachment and the connection are untouched — and only `unauthorized`, or a protocol
violation (a bad first stream, §1a, or an app record over the stream's cap), closes the connection.

**Caps.** `STREAM_MAX_TUNNEL_STREAMS_PER_PEER`; `STREAM_TUNNEL_DATA_MAX_BYTES` and
`STREAM_TUNNEL_RECORD_MAX_BYTES` (a WS data record's tagged payload, and payload + tag); and
`STREAM_TUNNEL_REQUEST_BODY_MAX_BYTES` (an HTTP request body, bounded the same as a session-path
transfer) are defined once in `packages/antgrid-wire/src/stream-open.ts` beside every other stream cap
(§1a). An HTTP body's raw reads and writes carry no record cap of their own — they use the same
`STREAM_RAW_READ_BYTES`/`STREAM_RECORD_SLICE_BYTES` as any other raw stream (§5).

## 1d. Project streams

Stage A wave A4 gives every project its own stream — `{kind:"project", projectId}`, no `checkoutId`: a
project stream is per PROJECT, and checkout routing stays per message on it, unchanged. It replaces the
`{s,m}` mux entirely: a bound stream carries no `s`/`m` envelope, one `AbMessage` is one record, and the
session stream (§1a) is left carrying only the machine control plane: the hello, the app's wedge-probe
`session:ping` and its `session:pong`, and machine-scoped verbs such as `agent:projects`, `stream-ready`
and `control:result`. Admitted
and routed by `ProjectStreamRegistry` (`bridge/src/project-streams.ts`), plugged into `PeerStreamAcceptor`
as `handlers.project`, and exposed to `TerminalStreamRegistry`/`TunnelStreamRegistry` as
`projectBinding`/`tunnelBinding` — both lookups only; neither a terminal nor a tunnel open ever opens or
promotes a core.

**Admission order**, synchronous and before any read: a per-peer cap (`STREAM_MAX_PROJECTS_PER_PEER`,
`CAP_EXCEEDED`); `isSafeProjectId` (`NOT_ALLOWED`); the remote-access switch (`NOT_ALLOWED`); the project
catalogued (`seenProjects`, `NOT_ALLOWED`); a relay-registered core for this project — else `NOT_READY`
(hazard J, `docs/iroh-reduction/stage-A-waves.md`: the app waits for `stream-ready {projectId}` on the
session stream and opens again, never parked); that core's outbound `mayDeliver` (`NOT_ALLOWED`); its
`mayAcceptFrom` (`UPDATE_REQUIRED` or `NOT_ALLOWED`); and finally a duplicate open for the same (peer,
project) pair (`INVALID`).

**The bind is the bridge's own first record.** `stream-ready {projectId}` is both the hazard-J ready notice
on the session stream AND the bridge's first write on a newly admitted project stream — the app treats its
project stream as bound only once this record arrives; there is no separate open acknowledgement.

**Outbound authorization runs on every send, not just at open.** `mayDeliver` (the remote-access switch,
outbound half) and `mayDeliverTo` (per-receiver: a peer that becomes stale mid-session because its project
gained an isolated session) are both re-read on every bus frame a project stream would carry, broadcast or
peer-addressed — the switch can flip and a core's isolated-session state can change after the stream is
already bound. `mayAcceptFrom` is the sender-side mirror, re-checked on every inbound record: a refused
record is dropped and the peer is told why by a `control:result {ok:false}` on the session stream,
rate-limited per (peer, project) pair (`INVALID_NOTICE_COOLDOWN_MS`).

**Session-bus frames** (`docs/session-messaging.md`) ride this stream, peer-addressed, exactly like any
other project-scoped bus frame — there is no separate stream for them.

**Failure isolation** matches §1b/§1c: an overflow or a lost stream resets only that one project stream
(the app reopens and resyncs through `state.snapshot`); only `unauthorized`, or a protocol violation (a bad
first stream, §1a, or an app record over `STREAM_PROJECT_APP_RECORD_MAX_BYTES`), closes the connection.

**Caps.** `STREAM_MAX_PROJECTS_PER_PEER`, `STREAM_PROJECT_APP_RECORD_MAX_BYTES` (app→bridge; the app only
ever writes small control-plane records) and `STREAM_PROJECT_BRIDGE_RECORD_MAX_BYTES` (bridge→app, equal to
`MAX_TRANSFER_BYTES` — a large reply such as `file:content` is still one record) are defined once in
`packages/antgrid-wire/src/stream-open.ts` beside every other stream cap (§1a); the writer's queue ceiling
(`PROJECT_STREAM_MAX_QUEUED_BYTES`) and stream priority (`STREAM_PRIORITY_PROJECT`, between terminal and
tunnel priority) are side-local to `bridge/src/project-streams.ts`.

## 1e. Upload streams

A remote file upload gets its own stream, `{kind:"upload", projectId, checkoutId?, requestId, fileName,
size, mimeType?}`, admitted by `UploadStreamRegistry` (`bridge/src/peer/upload-streams.ts`), plugged into
`PeerStreamAcceptor` as `handlers.upload`, and exposed to it via `ProjectStreamRegistry.uploadBinding`
(`UploadProjectBinding`, the upload counterpart of `tunnelBinding`/`projectBinding`) — a lookup only; an
upload stream never opens or promotes a core.

**Admission order.** Steps 1-8 run synchronously, before any read, and bind the stream on success so a
cap or duplicate check across concurrent opens is race-free: a per-peer cap
(`STREAM_MAX_UPLOAD_STREAMS_PER_PEER`, `CAP_EXCEEDED`); `isSafeProjectId` (`NOT_ALLOWED`); the project
catalogued (`NOT_ALLOWED`); a live project-stream entry for the project (`NOT_READY`); that peer already
holding the project's stream open (`NOT_ALLOWED`); the project's own `refusalFor`
(`UPDATE_REQUIRED`/`NOT_ALLOWED`); a duplicate open for the same (peer, requestId) pair (`INVALID`); and
the project declaring an upload server at all (`NOT_ALLOWED`). Steps 9-12 continue asynchronously once
bound: `UploadStreamServer.admit(peerId, checkoutId)` — unlike `tunnelStreams.admit` (§1c), this may
PREPARE a checkout runtime that is not yet running, replicating the lazy prepare an app's socket-path
upload verbs relied on before a stream open bypassed that bus-level dispatch — then
`FileUploadManager.begin()`, which admits the declared `fileName`/`size` and opens the file.

**Record framing.** The file's bytes need no record framing of their own: once admitted, the app writes
exactly `size` raw bytes (read with `StreamRawReader`, at most `STREAM_RAW_READ_BYTES` per native read)
and FINs its send half. The bridge answers with exactly one length-prefixed JSON record —
`stream:refused` (an early refusal) or `file:upload-result` (`ok`, or an error code including
`INCOMPLETE` for a FIN short of `size`) — then FINs in turn. There is no ack and no second record: the
exchange is exactly one file in, one result out.

**Overrun detection.** Each read requests `min(STREAM_RAW_READ_BYTES, remaining + 1)`: a well-behaved
peer's read never returns more than `remaining` bytes, so a chunk that does is the overrun signal on the
SAME read — there is no separate probe once the declared size is reached. An overrun resets the stream
(`STREAM_RESET_UPLOAD`) with no result reported, since the app has already broken the declared contract.

**Cancel.** The app cancels by resetting (or FIN-ing) its own send half; the bridge's pending read
observes it the same way a tunnel request body's cancel does (§1c), and the in-progress
`FileUploadManager` upload is cancelled with no result to report.

**Caps.** `STREAM_MAX_UPLOAD_STREAMS_PER_PEER`, `STREAM_UPLOAD_BRIDGE_RECORD_MAX_BYTES` (the one result
record), `STREAM_UPLOAD_MAX_FILE_NAME_LENGTH` and `STREAM_UPLOAD_MAX_MIME_TYPE_LENGTH` (open-frame
fields) are defined once in `packages/antgrid-wire/src/stream-open.ts` beside every other stream cap
(§1a); the writer's queue ceiling (`UPLOAD_STREAM_MAX_QUEUED_BYTES`) and stream priority
(`STREAM_PRIORITY_UPLOAD`, the same as tunnel priority — a background transfer never needs to preempt a
live terminal or project viewer) are side-local to `bridge/src/peer/upload-streams.ts`.

**Loopback unchanged.** The desktop app's own local upload still crosses the loopback socket as
`file:upload-start/ready/chunk/ack/done/result` (`LOOPBACK_UPLOAD_MESSAGE_TYPES`, `bridge/src/protocol.ts`)
— a same-machine caller has no QUIC stream to open one over, and a relay-origin frame naming one of these
six types is dropped rather than dispatched.

## 2. The hello

One plaintext hello establishes a session per connection:

```
peer → host : session:hello        { attemptId, capabilities? }
host → peer : session:established  { attemptId }
```

Schema: `SessionHelloFrame` / `SessionHelloCapabilities` in `bridge/src/protocol.ts`. These are bare
`{ type, ... }` objects with no `id`/`timestamp` envelope — deliberately outside `AbMessageSchema` /
`KNOWN_TYPES` (see the comment above `PeerSessionOwner.handleHello`), because a hello precedes the
session that envelope is scoped to.

- A hello naming an `attemptId` that already matches the peer's established session is re-acked
  idempotently (the driver has no retransmit loop of its own, but a duplicate must not be treated as a
  protocol violation). A *different* `attemptId` while already established closes the connection.
- A peer with no session must already be admitted (`peerPubkeyFor`), or the hello is dropped as
  `not-admitted`.
- **Pre-establishment frames are dropped per peer, fail closed** — `receiveSessionRecord`'s only way in
  for a session-less peer is a `session:hello`; everything else is dropped before it can reach dispatch,
  the session bus or a stream. This is enforced independently of the transport, because nothing above the
  QUIC layer proves a connected peer has said hello.
- `capabilities` is byte-identical in shape to the old `AppReadyMessage.capabilities` (the app's hello
  literals in `connection_handshake.dart` and `local_transport.dart` must keep naming every key
  `SessionHelloCapabilities` declares, and vice versa — Zod strips an undeclared key, and no suite spans
  both sides). `sessionBusCarrier` is a loopback-only key (`local-listener.ts`) and must never be copied
  into this native hello.

The Dart driver (`ConnectionHandshake` / `AppSessionHandshaker`, `packages/antgrid_relay_client`) is
still called "handshake" in code — that name predates this doc and was kept rather than churned twice —
but it drives no cryptographic exchange: it sends one hello and waits for `established`, with the whole
attempt bounded by one timeout. A connection that never establishes is closed by the caller, not retried
on the same link.

## 3. Session lifetime — no in-place rekey

There is no live-session key material to rotate, so what used to be "rekey" is now "close the link".
Liveness is QUIC's: both endpoints run iroh 1.0's keep-alive (5s) and connection idle timeout (30s),
recorded as `PEER_QUIC_KEEP_ALIVE_INTERVAL_MS`/`PEER_QUIC_MAX_IDLE_TIMEOUT_MS` and
`kPeerQuicKeepAliveInterval`/`kPeerQuicMaxIdleTimeout` rather than set, because neither binding exposes a
transport config. A peer that stops acking closes the connection on idle; the bridge retires it from
`connection.closed()` (`peer/native-host-connection.ts`).

The app additionally sends `session:ping` after `kPingSilenceSeconds` of session-stream silence and
closes the `PeerLink` after `kMaxMissedPongs` unanswered (`machine_session.dart`). Its only job is a
bridge whose event loop is wedged while its QUIC stack still acks — QUIC idle already covers a dead one.
The bridge answers `session:ping` with `session:pong` and never pings.

RPC timeouts never close the link. Three consecutive timeouts on one project stream reset and reopen
that stream alone, rerunning the bind resync (§1d); every other project, terminal, tunnel and upload
stream is untouched. The control plane's only connection-level escape is the app's ping.

Closing the link is still the whole recovery for the session, and the connection supervisor redials,
going through admission (§1) and the hello (§2) again. `MachineSession` fences sends/receives across a
reconnect with a per-connection generation token (`_SessionGeneration`/`_generation`,
`machine_session.dart`), not a key identity check, since there are no keys to compare.

`session:takeover` and the base class's capacity eviction are gone from the native path: `acceptPeer`'s
own capacity cap (§1) is the only admission-time bound, and nothing sends a takeover notice any more
(the type stays reserved in `SESSION_FRAME_TYPES` — §4 — because the app's receive arm still exists).

## 4. Session-record layout

A session-stream record is `[u32 BE len][UTF-8 JSON]` — byte for byte the same shape as a project-stream
record (§1d), read and written by the same record reader/writer both use. There is no header, no version
byte and no kind byte: the old two-value envelope (`PeerFrameHeader.type`, `session`/`message`) that once
told a liveness/session frame from a control-plane `AbMessage` is gone, because the JSON body's own `type`
is now sufficient — no `AbMessage` uses a `session:`-prefixed type, and nothing else on this stream uses
one either.

The five session frames, one scheme (`session:` + verb), are the whole set
`SESSION_FRAME_TYPES` (`packages/antgrid-wire/src/peer-protocol.ts`, hand-mirrored as
`kSessionFrameTypes` in `packages/antgrid_relay_client/lib/src/frame.dart`):

| Type | Direction | Body |
|---|---|---|
| `session:hello` | app → bridge | `{type, attemptId, capabilities?}` |
| `session:established` | bridge → app | `{type, attemptId}` |
| `session:ping` | either direction may receive it | `{type}` |
| `session:pong` | reply to a ping | `{type}` |
| `session:takeover` | bridge → app, reserved — nothing sends it (§3) | `{type}` |

`isSessionFrameType(type)` is the dispatch: a record whose `type` is one of these five is a session frame
(`PeerSessionOwner.onSessionFrame`/`handleSessionFrame`); everything else is the bare JSON of exactly one
`AbMessage` of the control plane (`onControlMessage`/`dispatchControlPlane`). An old envelope-era name
(`ping`, `pong`, `established`) is therefore control-plane traffic, not a session frame: `PingMessage`/
`PongMessage` stay in `AbMessageSchema`/`KNOWN_TYPES` for exactly this reason (see
`PeerSessionOwner.receiveSessionRecord`). A body that is not JSON, or whose `type` is not a string, is
dropped (`plaintext-not-json`/`unrecognized-plaintext`) rather than treated as a protocol violation — only
a zero-length or over-cap length prefix still closes the connection (the record reader enforces it).
Peer identity is authenticated by the connection and deliberately absent from the record.

Test vectors: `evals/fixtures/peer-transport-vectors.json`, generated by
`packages/antgrid-wire/scripts/gen-peer-transport-vectors.ts` (`bun run --filter antgrid-wire
gen:peer-vectors`) and consumed by both `packages/antgrid-wire/tests/peer-transport-vectors.test.ts` and
`packages/antgrid_peer_transport/test/peer_transport_vectors_test.dart`. Regenerate and commit the fixture
together with any change to the session-record or stream-open constants it pins.

## 5. Per-record caps, not per-channel flow control

Stage A wave A5 deleted the credit-window scheme this section used to describe (`flow.ts`, a cumulative
per-channel credit consumed by a plaintext `credit` session frame) along with the fragmentation it existed
to pace: once every purpose-specific stream (§1a-§1d) carries its own records directly, with no `{s,m}`
envelope to multiplex over, a credit window bought nothing a per-record size cap does not already bound.

What replaced it is a cap per record, asymmetric by direction and defined once per stream kind in
`packages/antgrid-wire` (session: `PEER_MAX_RECORD_BYTES`/`PEER_MAX_BRIDGE_RECORD_BYTES` in
`peer-authorization.ts`; project, terminal, tunnel and upload: `stream-open.ts`, §1b-§1e) — the app only
ever writes small control-plane records, so its cap is far below the bridge's, which is sized to
`MAX_TRANSFER_BYTES`. An upload stream's own cap, `STREAM_UPLOAD_BRIDGE_RECORD_MAX_BYTES`, bounds only
the one `file:upload-result`/`stream:refused` record it ever writes — the file's bytes carry no record
cap at all, since a raw read/write has no length prefix to check against (§1e). An app record whose
length prefix exceeds its stream's cap is a protocol violation and closes the connection. Backpressure is
a bounded per-stream write queue ahead of the native binding (`StreamRecordWriter`,
`bridge/src/peer/stream-records.ts`) rather than a credit window: a project, terminal, tunnel or upload
stream that fills its queue is reset — that stream alone, per D3 — instead of stalling every other stream
sharing what used to be one socket's window. The session stream is the one exception: it has nothing to
reopen, so its overflow retires the connection (`queue-full`, `native-host-connection.ts`). There is no
credit frame left on the wire, and `flow.ts`/`flow.dart` no longer exist.

A raw stream (an HTTP tunnel body or an upload's file bytes) carries no length-prefixed records at all,
so its pacing is per-read/per-write rather than per-record: `StreamRawReader.read()` asks for at most
`STREAM_RAW_READ_BYTES` (65 536) per native call, and `StreamRecordWriter.sendRaw()` slices anything
larger into writes of at most `STREAM_RECORD_SLICE_BYTES` (262 144) — both side-local constants in
`bridge/src/peer/stream-records.ts`, since neither is negotiated with the app.

## 6. Netwatch frame IDs

Both endpoints tag every frame with a hash of its payload bytes — `frameIdFor` (`bridge/src/netwatch.ts`),
hand-mirrored as `frameIdOf` (`packages/antgrid_relay_client/lib/src/frame.dart`) — and the joiner
(`joinCaptures`, `bridge/src/cli/netwatch.ts`) pairs same-hash occurrences across the two captures
**in the order they occur**, not by assuming a hash is unique — a ping, a pong, and a repeated
`stream-ready` with the same field values are byte-identical and legitimately recur. `NetwatchKind` names
`frame`/`hello` (formerly `sealed`/`handshake`) alongside `control`/`json`/`drop`/`lifecycle` — see the
type declaration for the current set, since it is a poor fit for a frozen list here.

`NetwatchEvent.channel` is the loopback socket's own `control`/`preview` JSON label (D2,
docs/iroh-reduction/ledger.md) and stays meaningful there; on `transport: "iroh"` it carries no
information — the `{s,m}` mux is gone (A4/A5), and every native record source writes `"control"`.
`NetwatchEvent.streamKind` (the open frame's `kind`, §1a-§1e) is what names a native record's stream
instead, and both ends now write it — the bridge from `streamLabelOf` (`bridge/src/peer/stream-dispatch.ts`),
the app from the same lookup in `antgrid_relay_client` — for every stream kind, terminal and tunnel
included; it is deliberately not part of the join key, since a hash-based pair (above) needs no extra key
to match on. `streamId` is a per-connection stream LABEL, not a QUIC stream id (`"0"` for the session
stream, the projectId for a project stream, the open frame's own `requestId`/`wsId` for a terminal,
tunnel or upload stream) — both ends write it for every stream kind, on the same terms as `streamKind`.
