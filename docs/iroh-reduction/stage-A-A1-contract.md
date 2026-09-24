# Stage A, wave A1: multi-stream admission (flag day, ALPN `antgrid/peer/2`)

This is the frozen contract for four parallel implementers: **bridge-src**, **bridge-tests**, **dart+app**
and **evals**. Each part builds against the names and shapes below. Nobody may rename or reshape anything
pinned here without the controller's say. If your half needs something this file does not provide, report it
as `outOfScopeNeeds`. Do not invent it.

Sources: `stage-A-waves.md` §1.1, §1.2, §2 and §3 "A1", and the owner decisions in `ledger.md` (D1–D7 and
hazard J). HEAD at authoring time is `7c97b72c`: A0a–A0d are committed, and so are Stages C and B. Where this
file and the spec disagree, this file wins for A1. The deviations are listed in §9.

---

## 0. What A1 changes, in one screen

- **ALPN.** `antgrid/peer/1` becomes `antgrid/peer/2` on both sides. `FRAME_VERSION` stays `0x04` (D5), and so do
  `peer-frame.ts` and `frame.dart`.
- **Open frames.** Every native bidi stream now starts with one open-frame record, `[u32 BE len][UTF-8 JSON StreamOpen]`.
  The body is raw JSON, **not** a peer frame (no `encodePeerFrame`). This is the A0c/A0b encoding.
- **The session stream.** The first stream the bridge accepts must declare `{"kind":"session"}`. After that record
  it carries today's full protocol, unchanged: `PeerRecords` on the bridge, `IrohPeerLink`'s own reader and writer
  on the app, peer frames, the `{s,m}` mux, credits and frag.
- **Later streams.** Each is admitted in **its own task** by a new `PeerStreamAcceptor`
  (`bridge/src/peer/stream-dispatch.ts`). The task enforces a pending-open cap, a 5s open-frame deadline and a
  Zod parse under `STREAM_OPEN_MAX_BYTES`, then looks up a `kind → handler` table. **The table is empty in A1**,
  so every well-formed non-session open from an established peer is refused in-band with `NOT_ALLOWED`.
- **QUIC limit.** The bridge calls `connection.setMaxConcurrentBiStreams(256n)` on every connection that passes
  the ALPN check.
- **Guards.** The bridge's second-`acceptBi` protocol-violation guard is deleted and its `acceptUni` guard is kept.
  On the Dart side the `acceptBi` `EXTRA_STREAM` guard is deleted and the `acceptUni` guard is kept.
- **Refusals** are in-band `stream:refused` records followed by FIN (D4). A refused or timed-out stream never
  costs the connection (D3).

---

## 1. Wire records (all already defined by A0b unless marked NEW)

| Record | TS (`packages/antgrid-wire/src/stream-open.ts`) | Dart (`packages/antgrid_relay_client/lib/src/models/stream_open.dart`) |
|---|---|---|
| Open frame, union on `kind` | `StreamOpen` (z.discriminatedUnion) | `sealed class StreamOpen` with `static StreamOpen? fromJson(Map)` |
| `{kind:"session"}` | `SessionStreamOpen` | `SessionStreamOpen()` (const) |
| `{kind:"project", projectId}` | `ProjectStreamOpen` | `ProjectStreamOpen(projectId)` (positional) |
| `{kind:"terminal", projectId, checkoutId?, requestId}` | `TerminalStreamOpen` | `TerminalStreamOpen` |
| `{kind:"tunnel-http", projectId, requestId}` | `TunnelHttpStreamOpen` | `TunnelHttpStreamOpen` |
| `{kind:"tunnel-ws", projectId, wsId}` | `TunnelWsStreamOpen` | `TunnelWsStreamOpen` |
| `{type:"stream:refused", code, message}` | `StreamRefused`, `StreamRefusedCode` | `StreamRefused`, `enum StreamRefusedCode` |

Refusal codes are unchanged: `NOT_READY`, `UPDATE_REQUIRED`, `NOT_ALLOWED`, `CAP_EXCEEDED`, `INVALID`.
A1 emits only these four:

| Code | When A1 emits it |
|---|---|
| `INVALID` | The open frame is unparseable, zero-length, fails Zod, or has a length prefix over `STREAM_OPEN_MAX_BYTES`. Also used for a second `session`-kind stream. |
| `CAP_EXCEEDED` | The peer already has `STREAM_MAX_PENDING_OPENS_PER_PEER` streams whose open frame has not been read yet. |
| `NOT_READY` | A non-session open from a peer whose session is not established yet. |
| `NOT_ALLOWED` | A well-formed non-session kind from an established peer. There are no handlers in A1. |

`message` is free text of at most 200 chars. Tests assert on `code` only.

**Record framing on a stream.** Each record is `[u32 BE length][body]`. On a later stream the body is UTF-8
JSON in both directions for A1: the open frame goes app → bridge, the refusal bridge → app. On the session
stream only the **first** app → bridge record is raw JSON. Every record after it, in both directions, is an
`encodePeerFrame` record, exactly as today. The bridge writes nothing on the session stream before the peer's
first peer-frame, and there is no open acknowledgement.

### 1.1 NEW TS helpers (bridge-src adds them to `stream-open.ts` and exports them by name from `index.ts`)

```ts
/** StreamOpen.parse(open) then UTF-8 JSON. Throws (ZodError) on schema-invalid input. */
export function encodeStreamOpen(open: StreamOpen): Uint8Array;
/** null if bytes.length > STREAM_OPEN_MAX_BYTES, not valid UTF-8 (fatal decoder), not JSON,
 *  or StreamOpen.safeParse fails. Never throws. */
export function decodeStreamOpen(bytes: Uint8Array): StreamOpen | null;
/** StreamRefused.parse(refused) then UTF-8 JSON. */
export function encodeStreamRefused(refused: StreamRefused): Uint8Array;
/** null on bad UTF-8 / JSON / StreamRefused.safeParse failure. Never throws. */
export function decodeStreamRefused(bytes: Uint8Array): StreamRefused | null;
```

These are new code written inside the Apache package. Nothing moves across the licence boundary.

### 1.2 NEW Dart helpers (dart+app)

- `packages/antgrid_relay_client/lib/src/models/stream_open.dart`:
  `static StreamRefused? StreamRefused.tryDecode(Uint8List record)`. It runs a strict UTF-8 decode, then
  `jsonDecode`, requires a `Map<String, dynamic>`, then calls `fromJson`. Any exception gives `null`.
- `packages/antgrid_peer_transport/lib/src/iroh_peer_link.dart`: top-level
  `Uint8List encodeStreamOpenFrame(StreamOpen open)`.
  - It returns the UTF-8 JSON **body** (`utf8.encode(jsonEncode(open.toJson()))`) with no length prefix.
  - If the body is longer than `kStreamOpenMaxBytes` it throws `PeerConnectionFailure('STREAM_OPEN_TOO_LARGE', terminal: true)`.
  - `PeerStreamOpener.open` must call it instead of its inline encode. Behaviour is unchanged.

### 1.3 ALPN

- TS: `PEER_ALPN = "antgrid/peer/2"` in `packages/antgrid-wire/src/peer-authorization.ts`.
- Dart: `const peerAlpn = 'antgrid/peer/2';` in `iroh_peer_link.dart`.
- Fixture: `evals/fixtures/peer-transport-vectors.json` has `"alpn": "antgrid/peer/2"`. This must be the only diff
  in that file. `bun run --filter antgrid-wire gen:peer-vectors` must reproduce it byte for byte once
  bridge-src's change lands.
- Hard-coded `"antgrid/peer/1"` literals in tests and scripts are replaced with the `PEER_ALPN` import (§7).

---

## 2. Caps and constants: where they live

The D7 caps already exist and nothing new is added to either mirror:
- TS in `stream-open.ts`: `STREAM_MAX_BIDI_STREAMS_PER_CONNECTION` (256), `STREAM_MAX_PROJECTS_PER_PEER` (32),
  `STREAM_MAX_TERMINAL_ATTACHMENTS_PER_PEER` (64), `STREAM_MAX_TUNNEL_STREAMS_PER_PEER` (128),
  `STREAM_MAX_PENDING_OPENS_PER_PEER` (16), `STREAM_OPEN_MAX_BYTES` (4096).
- Dart in `stream_open.dart`: the `kStream*` equivalents.

A1 enforces two of them:
- **QUIC bidi limit** (bridge only): `connection.setMaxConcurrentBiStreams(BigInt(STREAM_MAX_BIDI_STREAMS_PER_CONNECTION))`.
- **Pending opens per peer**: on the bridge in `PeerStreamAcceptor`. On the app this is the existing
  `PeerStreamOpener` semaphore (`kStreamMaxPendingOpensPerPeer`), which stays as it is.

The project, terminal and tunnel caps come in with their handlers (A2–A4).

**NEW bridge-only constants**, exported from `bridge/src/peer/stream-dispatch.ts`:

```ts
export const STREAM_OPEN_DEADLINE_MS = 5_000;
export const STREAM_STOP_REFUSED = 0x10n;        // recv.stop() after an in-band refusal
export const STREAM_RESET_OPEN_TIMEOUT = 0x11n;  // send.reset() when an open frame misses its deadline
export const STREAM_RESET_REFUSED = 0x12n;       // resetCode of the refusal writer, if the refusal write itself fails
export const STREAM_REFUSAL_MAX_QUEUED_BYTES = 8_192;
```

Reset and stop codes are for bridge diagnostics only. Dart cannot read them (spec §1.2).

---

## 3. Bridge API (bridge-src implements; bridge-tests tests against exactly this)

### 3.1 `bridge/src/peer/stream-records.ts` (A0a file, extended)

```ts
export interface StreamSend {
  writeAll(bytes: number[]): Promise<void>;
  setPriority(p: number): Promise<void>;
  reset(errorCode: bigint): Promise<void>;
  finish(): Promise<void>;                       // NEW
}
export class StreamRecordWriter {
  // existing constructor/send unchanged
  /** NEW. Resolves once every record queued before the call has been written and
   *  send.finish() has been issued (its rejection swallowed). A no-op if the writer
   *  already stopped (overflow, stream-lost, unauthorized) or finish() already ran.
   *  send() after finish() resolves "dropped". Never awaits stopped()/receivedReset(). */
  finish(): Promise<void>;
}
```

`StreamRecv` and `StreamRecordReader` are unchanged. `StreamRecordReader` is **not** used for open frames,
because its length violations are connection-fatal and an open-frame violation must not be.

### 3.2 NEW `bridge/src/peer/stream-dispatch.ts`

```ts
import type { StreamOpen, StreamOpenKind, StreamRefusedCode } from "antgrid-wire";
import type { StreamRecv, StreamSend } from "./stream-records";

/** Structural subset of @number0/iroh BiStream; the real one satisfies it. */
export interface AcceptedBiStream {
  send: StreamSend;
  recv: StreamRecv & { stop(errorCode: bigint): Promise<void> };
}

export type StreamOpenRead =
  | { ok: true; open: StreamOpen }
  | { ok: false; reason: "oversize" | "invalid" };

/** Exactly: recv.readExact(4); a short prefix, or length 0, gives "invalid"; a length
 *  over STREAM_OPEN_MAX_BYTES gives "oversize" WITHOUT reading the body; otherwise ONE
 *  recv.readExact(length) call; a short body gives "invalid"; decodeStreamOpen(body)
 *  === null gives "invalid". A native readExact rejection (peer FIN/reset, connection
 *  gone) propagates as a throw. No deadline inside; callers wrap it. */
export function readStreamOpen(recv: StreamRecv): Promise<StreamOpenRead>;

export interface StreamRefusal { code: StreamRefusedCode; message: string }

/** Fire-and-forget; the caller never awaits it. It builds a StreamRecordWriter(stream,
 *  authorized, onFailure, STREAM_REFUSAL_MAX_QUEUED_BYTES, 0, STREAM_RESET_REFUSED),
 *  sends encodeStreamRefused({type:"stream:refused", ...refusal}), calls writer.finish(),
 *  then calls stream.recv.stop(STREAM_STOP_REFUSED).catch(() => {}) WITHOUT awaiting it.
 *  onFailure("unauthorized") calls onUnauthorized(); other failures are stream-local
 *  and ignored. It is only ever called when no read is outstanding on stream.recv, so
 *  stop() cannot queue behind the binding's recv mutex. */
export function refuseStream(stream: AcceptedBiStream, refusal: StreamRefusal,
  authorized: () => boolean, onUnauthorized: () => void): void;

export interface StreamAdmission<O extends StreamOpen = StreamOpen> {
  peerId: string;
  open: O;
  stream: AcceptedBiStream;
  authorized: () => boolean;
}
/** A handler owns the stream when it returns undefined. When it returns a refusal, the
 *  acceptor writes that refusal. When it throws, the acceptor refuses NOT_ALLOWED. */
export type StreamHandler<O extends StreamOpen> =
  (admission: StreamAdmission<O>) => StreamRefusal | undefined | Promise<StreamRefusal | undefined>;
export type StreamHandlers = {
  [K in Exclude<StreamOpenKind, "session">]?: StreamHandler<Extract<StreamOpen, { kind: K }>>;
};

export type StreamDiagnosticType = "peer:stream-refused" | "peer:stream-open-timeout";

export interface PeerStreamAcceptorOptions {
  connection: { acceptBi(): Promise<AcceptedBiStream> };
  peerId: string;
  isCurrent: () => boolean;      // this connection still owns peerId and is not retired
  authorized: () => boolean;     // NativePeerSessions.authorized(peerId, endpointId)
  established: () => boolean;    // this.sessions.has(peerId)
  onUnauthorized: () => void;    // retirePeer(peerId, "unauthorized") if still current
  handlers?: StreamHandlers;     // A1 passes {} (or omits it)
  schedule?: (callback: () => void, ms: number) => () => void; // default: unref'd setTimeout
  diagnostic?: (type: StreamDiagnosticType, detail: { code?: StreamRefusedCode; kind?: string; pending: number }) => void;
  maxPendingOpens?: number;      // default STREAM_MAX_PENDING_OPENS_PER_PEER; tests may lower it
}

export class PeerStreamAcceptor {
  constructor(options: PeerStreamAcceptorOptions);
  /** Starts the accept loop, `while (!stopped && isCurrent()) { const s = await acceptBi();
   *  void this.admit(s); }`. The loop NEVER awaits admit(). It ends quietly when
   *  acceptBi rejects. */
  start(): void;
  /** Ends the loop. In-flight admissions drop without writing. Idempotent. */
  stop(): void;
  /** Streams accepted whose open-frame read has not settled. */
  get pendingOpens(): number;
}
```

**Admission order for one later stream** (`admit`, which runs in its own task):

0. If `stopped` or `!isCurrent()`: drop. Nothing is written, because the connection is going.
1. If `pendingOpens >= maxPendingOpens`: `refuseStream(CAP_EXCEEDED)`. The stream is not read and not counted.
2. `pendingOpens++`. Race `readStreamOpen(recv)` against `STREAM_OPEN_DEADLINE_MS` via `schedule`.
   - **Deadline fires**: `pendingOpens--`. Call `stream.send.reset(STREAM_RESET_OPEN_TIMEOUT).catch(() => {})` without
     awaiting it, and **do not** call `recv.stop`, because the read is still pending and holds the recv mutex.
     Emit `peer:stream-open-timeout`. A late settle of that read is ignored, and its promise has a catch attached.
   - **Read throws**: `pendingOpens--`, then drop silently. The peer ended the stream or the connection is gone.
3. `pendingOpens--` as soon as the read settles.
4. If `!isCurrent()`: drop.
5. If `!authorized()`: call `onUnauthorized()`, write nothing, stop.
6. If `!ok` (invalid or oversize): refuse `INVALID`.
7. If `open.kind === "session"`: refuse `INVALID`, because the session stream is already open.
8. If `!established()`: refuse `NOT_READY`.
9. If there is no handler for `open.kind`: refuse `NOT_ALLOWED`. **This is every kind in A1.**
10. Otherwise await `handler(admission)`, and apply the handler contract above.

Every refusal also emits `peer:stream-refused {code, kind?, pending}`. It never includes ids or payload.

Hard constraints (spec §1.1):
- Nothing in this file calls `stopped()` or `receivedReset()`.
- Nothing awaits `reset()` or `stop()`.
- Every write goes through `StreamRecordWriter`, which checks `authorized()` per record and per slice.
- A refused or timed-out stream never closes the connection. Only `onUnauthorized` does that.

### 3.3 `bridge/src/peer/native-host-connection.ts`: the new `acceptPeer` order

1. The ALPN check is unchanged in code, but now compares against `antgrid/peer/2`. A mismatch gives
   `connection.close(2n, [])`, returned before any stream is touched.
2. **NEW**: `connection.setMaxConcurrentBiStreams(BigInt(STREAM_MAX_BIDI_STREAMS_PER_CONNECTION))`, called
   synchronously right after the ALPN check and before any await.
3. Identity, lease, unknown-endpoint throttle, newest-wins and capacity checks are unchanged. The peer is registered
   in `nativePeers`.
4. `stream = await deadline(connection.acceptBi(), …)` is unchanged.
5. The existing post-accept checks are unchanged: stopped, generation, remote access, `lease.allows` and
   `nativePeers.get(peerId) === peer`. On failure call `retireOwnAttempt`. **These checks run before the open
   frame is read.**
6. **NEW**: `opened = await deadline(readStreamOpen(stream.recv), () => connection.close(1n, []), schedule)`.
   - If the deadline fires or the read throws: `retireOwnAttempt(peerId, peer)` (code 1n), then return.
   - If `!opened.ok` or `opened.open.kind !== "session"`: if the attempt is still current, call
     `retirePeer(peerId, "protocol-violation")`, which closes with code 2n. Otherwise call
     `connection.close(2n, [])`. Then return. **The first stream is never refused in-band.**
7. **NEW**: repeat step 5's checks, because the read awaited.
8. `admitPeer`, `new PeerRecords(stream, …)` on the **same** stream (the open record has been fully consumed),
   the hello timer and the `peer:native-accepted` diagnostic are unchanged.
9. **DELETE** `void connection.acceptBi().then(() => records.close("protocol-violation"), …)`.
   **KEEP** the `acceptUni` guard exactly as it is.
10. The `closed()` handler and the session read loop are unchanged.
11. **NEW**: create `peer.streams = new PeerStreamAcceptor({ connection, peerId, isCurrent, authorized, established,
    onUnauthorized, handlers: {}, schedule: this.nativeOpts.lifecycle?.schedule, diagnostic })`, then call
    `peer.streams.start()` after the read loop is launched.
    - `diagnostic` maps to `recordDiagnostic({dir:"event", kind:"lifecycle", transport:"iroh", msgType: type, detail})`.
    - `NativePeerContext` gains `streams?: PeerStreamAcceptor`.
    - `retirePeer` calls `peer.streams?.stop()`.

No other bridge file changes in A1. Unchanged: `peer-session-owner.ts`, `stream-mux.ts`, `records.ts`,
`host-server.ts`, `project-core.ts` and `protocol.ts`. **No message type is added or removed**, so the
"Adding a message type" rule is not triggered. `stream:refused` is a stream-level record, outside
`AbMessageSchema` / `KNOWN_TYPES`, like `session:hello`.

The security invariants are untouched: no handler exists, so no stream can reach a core, a project or a
dispatch path. `remoteFrameAllowed`, `mayDeliver`, `mayDeliverTo`, `mayAcceptFrom`, `seenProjects` and
`isSafeProjectId` are not edited.

---

## 4. Dart API (dart+app)

`packages/antgrid_peer_transport/lib/src/iroh_peer_link.dart`:
- `peerAlpn = 'antgrid/peer/2'`.
- `encodeStreamOpenFrame` as in §1.2. `PeerStreamOpener.open` uses it.
- `NativeEndpointOwner.dial` keeps its signature (`Future<IrohPeerLink> dial({endpointId, authorized, ipAddresses, diagnostic})`).
  After `connection.openBi()` and the existing `authorized()` recheck, and **before** `emitPeerLifecycle` and
  `IrohPeerLink._(…)`, it issues ONE call:
  `await send.writeAll(prefixed)`, where `prefixed` is `[u32 BE body.length][body]` and
  `body = encodeStreamOpenFrame(const SessionStreamOpen())`.
  - It sits inside the existing try, so any failure closes the connection with `errorCode: 1` and rethrows.
  - The bytes are the same ones `PeerStreamOpener` writes for a stream's first record.
  - The session stream's I/O then stays on `IrohPeerLink`'s existing reader and writer. The 5s `WRITE_TIMEOUT`,
    the `kSocketInflightBytes` backpressure and the peer-frame validation are untouched until A5 (see §9, D-1).
- `IrohPeerLink._start()`: **delete** the `_connection.acceptBi()` → `_fail('EXTRA_STREAM', false)` block and **keep**
  the `acceptUni()` block with code `'EXTRA_STREAM'`.
- `openStream` / `PeerStreamOpener` / `NativePeerStream` / `LeasedPeerLink` are otherwise unchanged.

`packages/antgrid_relay_client`: only `StreamRefused.tryDecode` (§1.2). Unchanged: the `PeerLink` and
`MultiStreamPeerLink` interfaces, `frame.dart` (FRAME_VERSION `0x04`), `machine_session.dart` and
`connection_handshake.dart`.

`app/`: **no changes**. `peer_runtime.dart` calls `dial`, and the open frame is written inside it.

---

## 5. Test seams after A1

| Seam | After A1 |
|---|---|
| `bridge/tests/test-peer-session-owner.ts` | **Unchanged.** It drives `PeerSessionOwner` above the native connection (`injectPeerPayload`), so there is no open frame to add. |
| Fake `Connection` in `native-host-connection.test.ts` and `peer-session-hello.test.ts` | `alpn()` returns `PEER_ALPN`. **New** `setMaxConcurrentBiStreams(n: bigint)` records its argument. `acceptBi()` serves the first stream, then streams from a per-test queue; the default queue never resolves. The default first stream serves `[u32 len]{"kind":"session"}` through `readExact(4)` then `readExact(len)`, and after that behaves as the test's stream did before. Each file gets a small helper (`withSessionOpen(recv)` or similar) so custom streams prepend the open record. `pausableStream` and `scriptedStream` serve the open record first and gate the frames after it. |
| `packages/antgrid_relay_client/test/support/fake_live_relay.dart` | **Unchanged.** It implements `PeerLink` only; the open frame is below that interface. |
| `evals/helpers/relay-client.ts` | `dialNative()`: right after `new PeerRecords(stream, …)` and before the read loop or any hello, call `void records.send(encodeStreamOpen({ kind: "session" }))`. `PeerRecords` queues in order, so it is written first. **NEW public methods** are listed below this table. |
| `evals/support/` (`openProjectStream` / `sendOnStream`) | **Unchanged.** Project streams still ride the `{s,m}` mux over the session stream until A4. |
| Eval client `packages/antgrid_eval_client/lib/src/commands.dart` | **Unchanged.** It dials through `NativeEndpointOwner.dial`, which now writes the open frame. |
| `evals/helpers/dart-app-client.ts` | **Unchanged.** |

The new public methods on the evals `RelayClient`:

```ts
/** Opens one extra bidi stream on the live native connection. It writes `bytes` framed as
 *  [u32 BE len][bytes] (framed: true, the default) or verbatim (framed: false, for a
 *  hand-built oversize prefix), then reads with recv.readToEnd(65_536) under timeoutMs
 *  (default 5_000) and splits the result into [u32 len] records. Finally it calls
 *  send.reset(0n) without awaiting it. `ended` is "fin" if readToEnd resolved, "error"
 *  if it rejected, and "timeout" if the timer won. */
openNativeStreamRaw(bytes: Uint8Array, opts?: { framed?: boolean; timeoutMs?: number }):
  Promise<{ records: Uint8Array[]; ended: "fin" | "error" | "timeout" }>;
/** Connects from the configured native endpoint to the configured target with `alpn`.
 *  Returns "refused" if connect rejects or the connection closes within timeoutMs,
 *  otherwise "connected" (and closes it). */
probeNativeAlpn(alpn: string, timeoutMs?: number): Promise<"refused" | "connected">;
/** connection.stableId() of the live native connection, or null. */
get nativeConnectionId(): number | null;
```

---

## 6. Tests: added, changed, deleted

The spec names four A1 cases (§3, "A1"). They map here as follows:
- "invalid or oversized open frame is refused, and the connection survives" is covered by
  `stream-dispatch.test.ts` and `gate-stream-admission`.
- "a peer over the pending cap is reset" is **amended**. Per D4 it is an in-band `CAP_EXCEEDED` refusal followed
  by FIN, not a reset (§9, D-2).
- "a stale ALPN is refused" is covered by `native-host-connection.test.ts` and `gate-stream-admission`.
- "stream N+1 is not blocked by stream N with no open frame" is covered by `stream-dispatch.test.ts`.

### bridge-tests

**NEW `bridge/tests/stream-dispatch.test.ts`** exercises `PeerStreamAcceptor`, `readStreamOpen` and `refuseStream`
with fakes. The fake send half **models the binding mutex**: `reset`, `finish` and `setPriority` await any pending
`writeAll`. The fake defines no `stopped` or `receivedReset`, so a call to either throws. The cases:
- `an unparseable open frame is refused INVALID in-band, then FIN, and the connection lives`
- `an oversized open-frame length prefix is refused INVALID without reading the body`
- `a zero-length open frame is refused INVALID`
- `a later session-kind open is refused INVALID`
- `every non-session kind is refused NOT_ALLOWED once established (A1 has no handlers)`. This covers
  project, terminal, tunnel-http and tunnel-ws.
- `a non-session open before the session is established is refused NOT_READY`
- `an open over the pending-open cap is refused CAP_EXCEEDED without being read, and the connection lives`
- `a pending slot is released when its open frame arrives and when its deadline fires`
- `an open frame missing its 5s deadline resets the send half and never calls recv.stop`. Uses a fake `schedule`.
- `stream N+1 is admitted while stream N has not sent its open frame`. Stream 2 hangs and stream 3 is refused
  before stream 2's deadline.
- `a stream whose peer is no longer authorized writes nothing and retires the connection as unauthorized`
- `a refusal stops the receive half without awaiting it`
- `a registered handler receives the parsed open and owns the stream; a returned refusal is written in-band; a throwing handler is refused NOT_ALLOWED`. This is the seam A2 plugs into.
- `after stop(), an accepted stream is dropped without a write`

**`bridge/tests/stream-records.test.ts`**:
- Add `finish` to the fakes.
- NEW `finish() writes every queued record, then finishes the send half once`.
- NEW `finish() after an overflow reset is a no-op`.
- NEW `send() after finish() is dropped`.

**`bridge/tests/native-host-connection.test.ts`**:
- Update the fakes (§5). Every existing test keeps its assertions.
- NEW `setMaxConcurrentBiStreams(256n) is called before the first acceptBi`.
- NEW `a connection on the stale ALPN antgrid/peer/1 is closed with code 2 before any stream is accepted`.
- NEW `a first stream declaring a non-session kind closes the connection with code 2`.
- NEW `a first stream with an unparseable or oversized open frame closes the connection with code 2`.
- NEW `a first stream with no open frame within 5s retires the attempt`. Uses a fake `lifecycle.schedule`.
- NEW `a second bidi stream no longer retires the connection`. It is refused in-band `NOT_ALLOWED` or `NOT_READY`,
  and the connection close count stays 0.
- NEW `a uni stream still retires the connection as a protocol violation`.

**`bridge/tests/peer-session-hello.test.ts`**: update the fakes (§5) and use `PEER_ALPN`. The existing close-code
assertions stay as they are.

**`packages/antgrid-wire/tests/stream-open.test.ts`**:
- NEW `encodeStreamOpen round-trips every kind through decodeStreamOpen`.
- NEW `encodeStreamOpen throws on schema-invalid input`.
- NEW `decodeStreamOpen returns null for oversize, bad UTF-8, bad JSON, unknown kind and extra keys`.
- NEW `encodeStreamRefused/decodeStreamRefused round-trip; decode rejects an unknown code`.

**`bridge/scripts/iroh-host-smoke.ts`**: import `PEER_ALPN` and `encodeStreamOpen`. Right after the `PeerRecords`
is built, call `void records.send(encodeStreamOpen({ kind: "session" }))`.

**`bridge/scripts/iroh-interop-smoke.ts`**: after `await next("established")`, add
`const refused = await next("stream-refused"); assert.equal(refused.code, "NOT_ALLOWED");`.

### dart+app

**`packages/antgrid_peer_transport/bin/native_smoke.dart`**:
- In every scenario, the smoke server's first record read on the accepted session stream must decode via
  `StreamOpen.fromJson` to `SessionStreamOpen`, or the smoke throws `StateError('session open frame missing')`.
  Only after that does it read the peer frame as today.
- Scenarios become `['echo', 'oversize', 'refused-stream', 'extra-uni-stream', 'revoked']`.
- **`refused-stream`** replaces `extra-stream`. Its steps:
  1. The app calls `link.openStream(const ProjectStreamOpen('smoke'), maxRecordBytes: kStreamOpenMaxBytes, maxQueuedBytes: 2 * kStreamOpenMaxBytes)`.
  2. The server calls `remote.acceptBi()`, reads one record, and asserts it is `ProjectStreamOpen('smoke')`.
  3. The server writes `[u32][jsonEncode(StreamRefused(code: StreamRefusedCode.invalid, message: 'smoke').toJson())]`, then `finish()`.
  4. The app collects `records.toList()` (5s timeout). It must be exactly one record, and
     `StreamRefused.tryDecode` of it must have code `invalid`.
  5. The app calls `await stream.reset()`.
  6. The session link still round-trips an echo, and `failureStream` has not fired.

  This validates the app half: in-band refusal, FIN and the connection surviving. The real bridge's refusal of a
  truly invalid frame is covered by bridge-tests and evals.
- **`extra-uni-stream`**: the server calls `remote.openUni()` and writes `[1]`. The app's failure code must be
  `'EXTRA_STREAM'`.

**`packages/antgrid_peer_transport/bin/interop_app.dart`**:
- Right after `_emit({'check': 'established'})`, open
  `active.openStream(ProjectStreamOpen(<first project id>), maxRecordBytes: kStreamOpenMaxBytes, maxQueuedBytes: 2 * kStreamOpenMaxBytes)`.
- Collect its records (5s timeout) and require exactly one, decoding via `StreamRefused.tryDecode`.
- Call `await stream.reset()`, then emit `{'check': 'stream-refused', 'code': refused.code.wireValue}`.
- The rest of the flow proves that the session survived.

**`packages/antgrid_peer_transport/test/peer_stream_opener_test.dart`**:
- NEW `encodeStreamOpenFrame is the exact body the opener writes as the first record`.
- NEW `encodeStreamOpenFrame throws STREAM_OPEN_TOO_LARGE past kStreamOpenMaxBytes`.

**NEW `packages/antgrid_relay_client/test/stream_open_test.dart`**:
- `StreamRefused.tryDecode accepts a valid record and returns null for bad UTF-8, bad JSON, a non-map, a wrong type and an unknown code`.

`peer_transport_vectors_test.dart` is unchanged. It already asserts `peerAlpn == fixture.alpn`.

### evals

**NEW `evals/tests/gate-stream-admission.test.ts`**. It uses `setupTestEnv()` and the native app client. After
each refusal, "the session stays up" means `app.nativeConnectionId` is unchanged **and** a `state.snapshot`
request on the session stream answers `ok`. The cases:
- `an unparseable open frame is refused INVALID in-band and the session stays up`
- `an oversized open-frame length prefix is refused INVALID and the session stays up`. Uses `framed: false`
  with prefix `0x00100000`.
- `a project-kind open is refused NOT_ALLOWED and the session stays up`. This case is A1-specific, and A4 flips it.
- `a second session-kind stream is refused INVALID`
- `a dial on the stale ALPN antgrid/peer/1 is refused`. Uses `probeNativeAlpn`.

**`evals/tests/gate-inventory-miss.test.ts`** and **`evals/tests/gate-iroh-host-authorization.test.ts`**: right
after the `PeerRecords` is built, call `void records.send(encodeStreamOpen({ kind: "session" }))`. Replace the
literal `"antgrid/peer/1"` with `PEER_ALPN`.

**`evals/helpers/relay-client.ts`**: see §5.

**`evals/fixtures/peer-transport-vectors.json`**: set `alpn` to `antgrid/peer/2`, and change nothing else.

**No tests are deleted** in A1. The only removed assertion is `native_smoke`'s bidi `EXTRA_STREAM`, which is
replaced as described above.

### Gate (controller, once, after integration)

- `ALL`, as defined in `stage-A-waves.md` §3.
- `bun run --filter antgrid-evals test:evals`.
- `bun run --filter antgrid-bridge qualify:iroh-interop` and `qualify:iroh-host`.
- `dart run bin/native_smoke.dart` in `packages/antgrid_peer_transport`.
- `bun run --filter antgrid-wire gen:peer-vectors` must leave `git diff` on the fixture empty.
- One `flutter analyze` run, from the controller only.
- Known bridge red: 6 stale-runId failures plus the two git-test flakes.
- `gate-vectors.test.ts`'s "is committed and git-clean" guard fails on an uncommitted fixture by design; it
  is red on the integrated working tree and clears at the wave commit. `gen:peer-vectors` reproduces the
  fixture with only the `alpn` line changed.

---

## 7. Call sites found by grep (rename and delete sweep)

| Symbol / literal | Hits | Owner |
|---|---|---|
| `"antgrid/peer/1"` literal | `bridge/scripts/iroh-host-smoke.ts:31`, `bridge/tests/native-host-connection.test.ts:65`, `bridge/tests/peer-session-hello.test.ts:155`, `evals/tests/gate-iroh-host-authorization.test.ts:102`, `docs/architecture.md:57` | bridge-tests, bridge-tests, bridge-tests, evals, bridge-src |
| `PEER_ALPN` (value changes, code does not) | `native-host-connection.ts`, `evals/helpers/relay-client.ts`, `gate-inventory-miss`, `gate-iroh-relay-authorization` (endpoint-to-endpoint only, **no edit**), `gen-peer-transport-vectors.ts` (**no edit**) | none |
| `peerAlpn` | `iroh_peer_link.dart`, `native_smoke.dart:43` (**no edit**, it follows the constant), `peer_transport_vectors_test.dart` (**no edit**) | dart+app |
| raw `connection.openBi()` session dialers | `evals/helpers/relay-client.ts:434`, `gate-inventory-miss:100`, `gate-iroh-host-authorization:103`, `bridge/scripts/iroh-host-smoke.ts:32`, Dart `iroh_peer_link.dart:96` | evals ×3, bridge-tests, dart+app |
| second-`acceptBi` guard | `native-host-connection.ts:302` | bridge-src |
| `EXTRA_STREAM` | `iroh_peer_link.dart:165,171` (delete only the bidi guard), `native_smoke.dart:112` | dart+app |
| fakes with `acceptBi` / `acceptUni` | `native-host-connection.test.ts`, `peer-session-hello.test.ts` | bridge-tests |
| "one reliable bidirectional stream … Additional application streams are rejected" | `docs/architecture.md:56-60` | bridge-src |

---

## 8. File ownership (disjoint and complete)

| File | Part | Change |
|---|---|---|
| `packages/antgrid-wire/src/peer-authorization.ts` | bridge-src | `PEER_ALPN` set to `/2` |
| `packages/antgrid-wire/src/stream-open.ts` | bridge-src | §1.1 helpers |
| `packages/antgrid-wire/src/index.ts` | bridge-src | named exports of the §1.1 helpers |
| `bridge/src/peer/stream-records.ts` | bridge-src | `StreamSend.finish`, `StreamRecordWriter.finish` |
| `bridge/src/peer/stream-dispatch.ts` (NEW) | bridge-src | §3.2 |
| `bridge/src/peer/native-host-connection.ts` | bridge-src | §3.3 |
| `docs/architecture.md` | bridge-src | ALPN `/2`; session stream plus later streams admitted per §3.2 |
| `docs/protocol/peer-session.md` | bridge-src | new §1a "Streams": open frame, first stream = session, admission order, refusal codes, caps pointer |
| `bridge/tests/stream-dispatch.test.ts` (NEW) | bridge-tests | §6 |
| `bridge/tests/stream-records.test.ts` | bridge-tests | §6 |
| `bridge/tests/native-host-connection.test.ts` | bridge-tests | §5, §6 |
| `bridge/tests/peer-session-hello.test.ts` | bridge-tests | §5, §6 |
| `packages/antgrid-wire/tests/stream-open.test.ts` | bridge-tests | §6 |
| `bridge/scripts/iroh-host-smoke.ts` | bridge-tests | open frame, `PEER_ALPN` |
| `bridge/scripts/iroh-interop-smoke.ts` | bridge-tests | expects `stream-refused` |
| `packages/antgrid_peer_transport/lib/src/iroh_peer_link.dart` | dart+app | §4 |
| `packages/antgrid_peer_transport/bin/native_smoke.dart` | dart+app | §6 |
| `packages/antgrid_peer_transport/bin/interop_app.dart` | dart+app | §6 |
| `packages/antgrid_peer_transport/test/peer_stream_opener_test.dart` | dart+app | §6 |
| `packages/antgrid_relay_client/lib/src/models/stream_open.dart` | dart+app | `StreamRefused.tryDecode` |
| `packages/antgrid_relay_client/test/stream_open_test.dart` (NEW) | dart+app | §6 |
| `evals/helpers/relay-client.ts` | evals | §5 |
| `evals/tests/gate-stream-admission.test.ts` (NEW) | evals | §6 |
| `evals/tests/gate-inventory-miss.test.ts` | evals | open frame, `PEER_ALPN` |
| `evals/tests/gate-iroh-host-authorization.test.ts` | evals | open frame, `PEER_ALPN` |
| `evals/fixtures/peer-transport-vectors.json` | evals | `alpn` only |

These files are explicitly **not touched** in A1:
- `peer-frame.ts`, `frame.dart` (FRAME_VERSION stays)
- `peer-session-owner.ts`, `stream-mux.ts`, `records.ts`, `protocol.ts`, `host-server.ts`, `project-core.ts`
- `bridge/tests/test-peer-session-owner.ts`
- `fake_live_relay.dart`, `leased_peer_link.dart`, `peer_link.dart`, `machine_session.dart`
- `packages/antgrid_eval_client/**`, `evals/support/**`, `evals/helpers/dart-app-client.ts`
- `gate-iroh-relay-authorization.test.ts`, `gen-peer-transport-vectors.ts`
- all of `app/`

`app/` has nothing in A1, so dart+app owns only package files. `docs/iroh-reduction/ledger.md` is updated by
the controller at the wave commit and belongs to no part.

---

## 9. Deviations from the spec, and open items

- **D-1: Dart session dial.** The task says to "open with `{kind:"session"}` through the A0c MultiStreamPeerLink".
  The contract routes it through the A0c **open-frame encoder** (`encodeStreamOpenFrame`, the exact bytes
  `PeerStreamOpener` writes) but keeps the session stream's I/O on `IrohPeerLink`'s legacy engine.
  - Rebasing the session stream onto `NativePeerStream` now would turn a session-stream `backpressured` outcome
    into a stream **reset**, per D3, and so into a dead session.
  - It would also remove the 5s write timeout on the one stream that still carries credits and frag.
  - The spec schedules that rebase for A5, when `records.ts` goes.
- **D-2: pending-open cap.** The spec says the over-cap stream "is reset". D4 says every refusal the app acts on
  is in-band, and a well-behaved app can transiently exceed the bridge's count, because the app releases its
  semaphore slot on its local write while the bridge counts until its read. So A1 refuses with `CAP_EXCEEDED`
  followed by FIN.
- **D-3: first-stream faults close the connection.** A first stream with an invalid frame or a non-session kind
  closes the connection (2n) rather than being refused in-band, because there is no session to keep alive. Only
  later streams get in-band refusals.
- **D-4: stale-ALPN coverage.** `native_smoke` cannot exercise the bridge's refusal of a **malformed** frame,
  because its server is a raw Dart endpoint. The real bridge's refusal is covered by `stream-dispatch.test.ts`
  (fakes that model the mutex), by `gate-stream-admission` (real binding), and, for a well-formed kind, by
  `qualify:iroh-interop` (cross-binding).
- **D-5: stale refusal in the fixture test.** `gate-stream-admission`'s `NOT_ALLOWED` project-kind case is
  A1-only. A4 must change it to "admitted after `stream-ready`".

### As built (integration notes)

- `StreamRecordWriter.finish()` also resolves its waiters when the writer stops for another reason
  (overflow, stream-lost, unauthorized), so `refuseStream`'s `finish().then(stop)` can never hang on a stream
  that dies under it. Not observable by any §6 case.
- `openNativeStreamRaw` maps a `readToEnd` rejection to `ended: "error"` (the first draft let it throw out
  of the race) and swallows the unawaited `send.reset(0n)` rejection.
- The fake `Connection` in `peer-session-hello.test.ts` takes an already-wrapped first stream from its
  callers; its default first stream is wrapped with `withSessionOpen`, so a test whose peer never sends a
  hello still gets past the open-frame read.
- `interop_app.dart` casts `active` to `MultiStreamPeerLink` for `openStream`, because `establish()` returns
  it typed as `PeerLink`. Its probe resets the stream in a `finally`, so a failed probe resets too.
- §3.2 step 2 amended: after a missed deadline, the acceptor stops the receive half once the late read
  settles (the recv mutex is then free). A late open frame is still never admitted; without the stop, a
  peer answering after the deadline could park up to a stream window of data on a stream nothing reads.
- The fake `Connection` in `native-host-connection.test.ts` serves later streams through a waiter queue, so
  a stream pushed after `acceptPeer` reaches the acceptor's already-pending `acceptBi`. The first draft of
  "a second bidi stream no longer retires the connection" pushed onto a queue nobody read again, and passed
  with the old guard restored. It now asserts the in-band `NOT_READY` refusal.
