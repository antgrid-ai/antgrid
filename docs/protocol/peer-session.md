# Peer session protocol (native Iroh payload path)

**Frame version:** `FRAME_VERSION` in `packages/antgrid-wire/src/peer-frame.ts` (currently `0x04`; bumped
together with the app, never grep-replaced — `0x03` and other small values are reused by unrelated
protocols, notably the central hello signature version in `relay-auth.ts`/`relay_auth.dart`).

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
rest of this document unchanged: peer frames, the hello (§2), credits (§5) and frag, all on the same
stream, with no open acknowledgement.

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
`{kind:"tunnel-ws"}` (§1c). Project streams arrive with theirs in a later wave. The QUIC-level cap
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
`(peerId, attachmentId)`. A message with no bound stream falls back to the legacy session path unchanged —
this is how the app's own `terminal:subscribe` on the project stream (still accepted; the app itself never
sends one there) and older builds keep working.

**Ends.** When delivery retires the attachment, the bridge `finish()`es its send half; the app reads that
FIN as a plain retirement, not an ENDED status. When the app FINs or resets its send half, the bridge
synthesizes `terminal:unsubscribe` for whatever attachment was bound. An overflow or a lost stream resets
only that one stream (every other attachment and the connection are untouched); only `unauthorized` closes
the connection, exactly as in §1a.

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

**Record framing.** Every record on a tunnel stream is `[u32 BE len][body]`; the body's first byte
discriminates a JSON control record from a tagged binary data record:

| First byte | Meaning |
|---|---|
| `0x7B` (`{`) | UTF-8 JSON control record — the whole body is one JSON object |
| `0x00` | HTTP body slice, identity encoding |
| `0x01` | HTTP body slice, gzip encoding |
| `0x02` | WebSocket frame, text |
| `0x03` | WebSocket frame, binary |

Codecs and tag constants: `encodeTunnelDataRecord`/`decodeTunnelRecord`, `TUNNEL_RECORD_TAG_BODY`/
`_BODY_GZIP`/`_WS_TEXT`/`_WS_BINARY` (`packages/antgrid-wire/src/stream-open.ts`). A data record's tag
selects the compression or frame kind; nothing else on the stream needs to.

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

**The end record.** An HTTP stream's response ends with a JSON `tunnel:http-end` (naming `requestId` and
`checkoutId`) immediately before the bridge FINs its send half — unlike a terminal stream's plain FIN
(§1b), because Dart cannot tell a clean end from a reset apart on this stream and the app has to be told
explicitly which one happened. A WS stream ends with `tunnel:ws-close` (optional `code`/`reason`) then
FIN, mirroring a real WebSocket close frame.

**Cancel.** The app cancels by resetting (or FIN-ing) its own send half; the bridge's pending read on that
half fails, which it treats as the app's cancel — aborting the upstream fetch or WS and then closing its
own send half in turn, exactly as if it had reached the end on its own. A record arriving after the
declared body length, or after the app's own end, is a stream breach. Failure isolation matches §1b: an
overflow or a lost stream resets only that one stream — every other tunnel, attachment and the connection
are untouched — and only `unauthorized` (or a first-stream protocol violation, §1a) closes the connection.

**Caps.** `STREAM_MAX_TUNNEL_STREAMS_PER_PEER`, `STREAM_TUNNEL_DATA_MAX_BYTES` (a data record's payload,
after its tag byte), `STREAM_TUNNEL_RECORD_MAX_BYTES` (payload + tag, what the reader checks against) and
`STREAM_TUNNEL_REQUEST_BODY_MAX_BYTES` (an HTTP request body, bounded the same as a session-path transfer)
are defined once in `packages/antgrid-wire/src/stream-open.ts` beside every other stream cap (§1a).

## 2. The hello

One plaintext hello establishes a session per connection:

```
peer → host : session:hello   { attemptId, capabilities? }
host → peer : established     { attemptId }
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
- **Pre-establishment frames are dropped per peer, fail closed** — `receivePeerFrame`'s only way in for
  a session-less peer is a control-channel `session:hello`; everything else is dropped before it can
  reach dispatch, frag reassembly, the session bus or a stream. This is enforced independently of the
  transport, because nothing above the QUIC layer proves a connected peer has said hello.
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

There is no live-session key material to rotate, so what used to be "rekey" is now "close the link":
a phone-side liveness failure (missed pongs, a run of consecutive RPC
timeouts while established) closes the `PeerLink` (`MachineSession.notifyRpcResult` /
the ping/pong path, `machine_session.dart`) and the connection supervisor redials, going through
admission (§1) and the hello (§2) again. Symmetrically, the bridge declares a session dead on missed
pongs and drops it (`peer-session-owner.ts`), which the peer observes as its connection closing.

This makes every liveness failure and every credit-window wedge a full re-dial, including the
authorization lease refresh — there is no cheaper in-connection recovery path left. `MachineSession`
fences sends/receives across a reconnect with a per-connection generation token
(`_SessionGeneration`/`_generation`, `machine_session.dart`), not a key identity check, since there are
no keys to compare.

`session-takeover` and the base class's capacity eviction are gone from the native path: `acceptPeer`'s
own capacity cap (§1) is the only admission-time bound, and nothing sends a takeover notice any more.

## 4. Frame layout

Wire layout, `FrameKind` and `FRAME_VERSION` are defined in `packages/antgrid-wire/src/peer-frame.ts`
(canonical) and hand-mirrored in `packages/antgrid_relay_client/lib/src/frame.dart`. `FrameKind` carries
a single value on purpose — there is no `sealed`/`handshake` split left to distinguish, and the kind
byte is kept only so a future framing change (Stage A) does not have to re-introduce the field. Peer
identity is authenticated by the connection and deliberately absent from the frame record.

Test vectors: `evals/fixtures/peer-transport-vectors.json`, generated by
`packages/antgrid-wire/scripts/gen-peer-transport-vectors.ts` (`bun run --filter antgrid-wire
gen:peer-vectors`) and consumed by both `packages/antgrid-wire/tests/peer-transport-vectors.test.ts` and
`packages/antgrid_peer_transport/test/peer_transport_vectors_test.dart`. Regenerate and commit the fixture
together with any change to the frame or flow-control constants it pins.

## 5. Per-channel flow control

Each direction of a session carries a cumulative credit window per channel (`control`, `preview`) plus one in-flight cap per socket,
credited by a plaintext `credit { channel, consumed }` session frame. The accounting
counts plaintext payload bytes only — there is no per-frame overhead to add or subtract, and both the sender and the receiver must agree on that in the same change, or the window drains a
fixed amount per frame until the next resync. Constants live in `packages/antgrid-wire/src/flow.ts`
(canonical) and are hand-mirrored in `packages/antgrid_relay_client/lib/src/flow.dart`; read them there
rather than here, since they move independently of this document.

## 6. Netwatch frame IDs

Both endpoints tag every frame with a hash of its payload bytes — `frameIdFor` (`bridge/src/netwatch.ts`),
hand-mirrored as `frameIdOf` (`packages/antgrid_relay_client/lib/src/frame.dart`) — and the joiner
(`joinCaptures`, `bridge/src/cli/netwatch.ts`) pairs same-hash occurrences across the two captures
**in the order they occur**, not by assuming a hash is unique — a ping, a pong, and a credit
frame with the same field values are byte-identical and legitimately recur. `NetwatchKind` names
`frame`/`hello` (formerly `sealed`/`handshake`) alongside `control`/`json`/`drop`/`lifecycle` — see the
type declaration for the current set, since it is a poor fit for a frozen list here.
