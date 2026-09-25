# Stage A, wave A3: tunnel HTTP and WebSocket streams

This is the frozen contract for four parallel implementers: **bridge-src**, **bridge-tests**, **dart+app**
and **evals**. Each part builds against the names and shapes below. Nobody may rename or reshape anything
pinned here without the controller's say. If your half needs something this file does not provide, report it
as `outOfScopeNeeds`. Do not invent it.

Sources: `stage-A-waves.md` §3 "A3", the owner decisions in `ledger.md` (D1–D7, hazard J), and the A2 contract
(`stage-A-A2-contract.md`), whose registry pattern A3 mirrors. HEAD at authoring time is `8a13d83b`: A0a–A0d,
A1 and A2 are committed. Where this file and the spec disagree, this file wins for A3. The deviations are
listed in §9.

---

## 0. What A3 changes, in one screen

- **Every preview HTTP request and every preview WebSocket gets its own QUIC stream** on the native path. The
  app opens it with the A0b open frame, `{kind:"tunnel-http", projectId, requestId}` or
  `{kind:"tunnel-ws", projectId, wsId}`. Both open schemas are unchanged. The bridge admits the stream with two
  new handlers, `"tunnel-http"` and `"tunnel-ws"`, plugged into A1's `PeerStreamAcceptor`.
- **The legacy tunnel path is deleted, not kept alongside.** That means:
  - `tunnel:*` frames on the session stream (preview channel);
  - `StreamHandle.sendTunnel` and `AttachStreamOpts.onTunnel`;
  - agent-core's `handleTunnelMessage` and `setPlainHook`;
  - the outbox, the pre-open buffer, `seq`/`chunks`, `tunnel:http-cancel` and the app's lost-head retry.

  A `tunnel:*` frame that still arrives on the session stream is dropped (§3.4). There is no socket-path
  fallback, because loopback never tunnels: `preview_service.dart`'s `_open` serves a local tab straight from
  `localhost` (D2, §9 D-2).
- **Records are binary, not base64.** A record whose first byte is `{` (0x7B) is UTF-8 JSON. Any other record
  starts with a one-byte tag followed by raw bytes (§1). Gzip stays per record, one independent member each.
- **HTTP.**
  - App: open frame, one head record, then the request body as tagged records. It keeps its send half open
    until the response's end record arrives, then FINs.
  - Bridge: one head record, body records, one explicit `tunnel:http-end` record, then FIN.
  - The end record is required because Dart cannot tell FIN from reset (D4). A stream that closes without it
    is **truncated**, and the app fails the response instead of serving it short.
  - On an upstream error after the head, the bridge resets its send half and writes no end record.
- **Cancel (D4).**
  - The app resets its **send half** and keeps draining its receive half.
  - The bridge sees that reset through its pending `read()`. It aborts the upstream fetch, then resets its own
    send half (`writer.abort()`, which drops the queue and waits on at most one slice).
- **WebSocket.** One stream per socket, data in both directions, in order. A close is an optional
  `tunnel:ws-close` record followed by FIN. A close written after data arrives after that data, because one
  writer queue carries both.
- **Admission.** Admission needs a catalogued, safe projectId whose project is attached to the mux. The
  per-sender refusal and the per-receiver mute are re-read. Remote access and checkout routing are checked by
  the core at the head record. A stream open never opens or promotes a core.
- **Priority.** A tunnel stream's send half runs at `STREAM_PRIORITY_TUNNEL = -1`. That is below the session
  stream (0) and terminal streams (1), as the preview channel was below control.
- **`abortTunnelStreams` stays driven by session lifecycle** (`project-core.ts` `onPeerOnline`/`onPeerOffline`).
  It now aborts stream-backed runs through their `AbortSignal`, and each aborted run resets its stream.
- **`FRAME_VERSION`, the ALPN (`antgrid/peer/2`), every refusal code and `protocol.ts`'s message union are
  unchanged (D5).** The tunnel schemas were never `AbMessage`s.

---

## 1. Wire records

### 1.1 Record framing on a tunnel stream

Every record is `[u32 BE len][body]`, as on every stream (A0a). The body is discriminated by its first byte:

| First byte | Meaning | Payload |
|---|---|---|
| `0x7B` (`{`) | JSON control record | the whole body is UTF-8 JSON |
| `0x00` `TUNNEL_RECORD_TAG_BODY` | HTTP body bytes, identity | `body[1..]` |
| `0x01` `TUNNEL_RECORD_TAG_BODY_GZIP` | HTTP body bytes, one independent gzip member | `body[1..]`, which the reader inflates on its own |
| `0x02` `TUNNEL_RECORD_TAG_WS_TEXT` | one WebSocket text message | `body[1..]`, UTF-8 |
| `0x03` `TUNNEL_RECORD_TAG_WS_BINARY` | one WebSocket binary message | `body[1..]` |
| anything else | protocol breach **of that stream** (§3.2) | — |

- A data record carries at least 1 payload byte. An empty WS message is sent as a tag byte alone, so a
  body of length 1 is legal for tags 0x02/0x03 and illegal for 0x00/0x01.
- `STREAM_TUNNEL_DATA_MAX_BYTES` (1 MiB) caps the payload after the tag, so no record exceeds
  `STREAM_TUNNEL_RECORD_MAX_BYTES` (payload + 1). This holds in both directions.
- Gzip (`0x01`) is used **only bridge to app**, and only when the request's `acceptEncodings` contains
  `"gzip"`. The app never sends tag `0x01`, `0x02` or `0x03` on an HTTP stream, and never `0x00`/`0x01` on a
  WS stream. The bridge treats a wrong-kind tag as a breach.

### 1.2 Records (TS schemas in `bridge/src/tunnel-protocol.ts`; wire tags in `antgrid-wire`)

| Record | Direction, stream | TS | Dart | Status |
|---|---|---|---|---|
| Open frame `{kind:"tunnel-http", projectId, requestId}` | app→bridge, first record | `TunnelHttpStreamOpen` (wire) | `TunnelHttpStreamOpen` (`models/stream_open.dart`) | unchanged (A0b) |
| Open frame `{kind:"tunnel-ws", projectId, wsId}` | app→bridge, first record | `TunnelWsStreamOpen` (wire) | `TunnelWsStreamOpen` | unchanged (A0b) |
| `{type:"stream:refused", code, message}` | bridge→app, then FIN | `StreamRefused` | `StreamRefused.tryDecode` | unchanged (A1) |
| `{type:"tunnel:http-request", requestId, port, scheme?, method, path, headers?, acceptEncodings?, bodyLength, checkoutId}` | app→bridge, 2nd record on HTTP | `TunnelHttpRequest` | built by `TunnelHttpRequest.toHeadJson()` (`preview_models.dart`) | **CHANGED**: `body` removed; `bodyLength: z.number().int().nonnegative()` added, defaulting to 0 |
| `{type:"tunnel:http-head", requestId, status, headers, setCookies?, checkoutId}` | bridge→app, first record on HTTP | **NEW** `TunnelHttpHead` | **NEW** `TunnelHttpHead` (`tunnel_stream.dart`) | replaces `TunnelHttpStart` |
| `{type:"tunnel:http-end", requestId, checkoutId}` | bridge→app, last record before FIN | `TunnelHttpEnd` | parsed inside `tunnel_stream.dart` | **CHANGED**: `chunks` and `error` removed |
| `{type:"tunnel:ws-open", tunnelId, port, scheme?, path, headers?, checkoutId}` | app→bridge, 2nd record on WS | `TunnelWsOpen` | map literal in `preview_service.dart` | unchanged schema; `tunnelId` must equal `open.wsId` |
| `{type:"tunnel:ws-close", tunnelId, code?, reason?, checkoutId}` | either direction on WS, optional, then FIN | `TunnelWsClose` | parsed and written inside `tunnel_stream.dart` | unchanged schema |
| **DELETED** | | `TunnelHttpStart`, `TunnelHttpChunk`, `TunnelHttpCancel`, `TunnelWsData`, `parseTunnelMessage`, `isTunnelMessage` and the `TunnelMessage` union | `TunnelHttpStartMessage`, `TunnelHttpChunkMessage`, `TunnelHttpEndMessage`, `TunnelWsDataMessage`, `TunnelWsCloseMessage` (`preview_models.dart`) and their `ab_message.dart` parser cases | |

Every `checkoutId` above is `z.string().default("main")` in TS, and the app always sends it.

### 1.3 Rules the two sides share

- **HTTP, app side.** The app writes, in order:
  1. the open frame, which `openStream` writes together with `openBi` (a Dart stream is invisible until its
     first write);
  2. the head record, with `requestId === open.requestId`;
  3. zero or more `0x00` body records, each ≤ `STREAM_RECORD_SLICE_BYTES` (256 KiB) of payload, summing
     **exactly** `bodyLength`.

  It then leaves its send half open. When `tunnel:http-end` arrives, it `finish()`es. To cancel, it `reset()`s
  instead.
- **HTTP, bridge side.** The first record is `stream:refused` (then FIN) or `tunnel:http-head`. Then come
  `0x00`/`0x01` body records, then `tunnel:http-end`, then FIN. Anything else from the bridge is a breach, on
  which the app resets and fails with `PROTOCOL`.
- **`bodyLength` is authoritative, and both ends check it** (the truncation trap):
  - The app stamps `bodyLength = body.length` itself (§4.1). It sends body records only while every
    `PeerStream.send` returns `accepted`, and it checks that the bytes it sent equal `bodyLength`. On any
    other outcome it `reset()`s and fails. It never `finish()`es a short body.
  - The bridge refuses `INVALID` when:
    - `bodyLength > STREAM_TUNNEL_REQUEST_BODY_MAX_BYTES`;
    - the head's `headers` carry a `content-length` (case-insensitive) that parses to anything other than
      `bodyLength`;
    - a body record would take the running total past `bodyLength`;
    - a JSON or wrong-tag record arrives during the body.
  - A FIN or reset before `bodyLength` bytes have arrived abandons the request **without contacting the
    upstream**. The bridge never forwards a truncated body.
- **WS, app side.** The app writes the open frame, then the `tunnel:ws-open` head, then `0x02`/`0x03` records
  in browser order. At most one `tunnel:ws-close` follows, then `finish()`. An abort is `reset()` with no close
  record.
- **WS, bridge side.** The first record is `stream:refused` (then FIN) or a data record. Then come data records
  in upstream order and at most one `tunnel:ws-close`, then FIN. Upstream errors are `writer.abort()`.
- **Truncation, as the app reads it:**
  - An HTTP stream whose records end after the head but without `tunnel:http-end` is `TRUNCATED`.
  - One that ends before the head is `STREAM_ENDED`.
  - A WS stream that ends without a close record is a close with no code (`TunnelWsClosedByPeer(null, null)`).

---

## 2. Caps and constants: where they live

| Constant | Value | Home | Mirror |
|---|---|---|---|
| `STREAM_MAX_TUNNEL_STREAMS_PER_PEER` | 128 (A0b) | `packages/antgrid-wire/src/stream-open.ts` | `kStreamMaxTunnelStreamsPerPeer` (A0b). HTTP and WS share it. |
| `STREAM_TUNNEL_DATA_MAX_BYTES` (**NEW**) | `1_048_576` | `stream-open.ts`, exported by name from `index.ts` | Dart `kStreamTunnelDataMaxBytes` in `models/stream_open.dart`; fixture `streamOpen.tunnelRecords.maxDataBytes` |
| `STREAM_TUNNEL_RECORD_MAX_BYTES` (**NEW**) | `1_048_577` (data + tag) | same | `kStreamTunnelRecordMaxBytes`; fixture `streamOpen.tunnelRecords.maxRecordBytes` |
| `STREAM_TUNNEL_REQUEST_BODY_MAX_BYTES` (**NEW**) | `33_554_432` (`= MAX_TRANSFER_BYTES`, stated in a comment) | same | `kStreamTunnelRequestBodyMaxBytes`; fixture `streamOpen.tunnelRecords.requestBodyMaxBytes` |
| `TUNNEL_RECORD_TAG_BODY` / `_BODY_GZIP` / `_WS_TEXT` / `_WS_BINARY` (**NEW**) | `0x00` / `0x01` / `0x02` / `0x03` | same | `kTunnelRecordTagBody`, `kTunnelRecordTagBodyGzip`, `kTunnelRecordTagWsText`, `kTunnelRecordTagWsBinary`; fixture `streamOpen.tunnelRecords.tags` |
| `TUNNEL_STREAM_MAX_QUEUED_BYTES` (**NEW**) | `4 * 1024 * 1024` | `bridge/src/peer/tunnel-streams.ts` | none (side-local) |
| `STREAM_PRIORITY_TUNNEL` (**NEW**) | `-1` | `bridge/src/peer/tunnel-streams.ts` | none; Dart has no priority |
| `STREAM_RESET_TUNNEL` (**NEW**) | `0x15n` | `bridge/src/peer/tunnel-streams.ts` | none; Dart cannot read reset codes |
| `STREAM_STOP_TUNNEL` (**NEW**) | `0x16n` | `bridge/src/peer/tunnel-streams.ts` | none |
| `TUNNEL_BODY_SLICE_BYTES` (**RENAMED** from `TUNNEL_CHUNK_BYTES`) | `262_144` (was `196_608`) | `bridge/src/tunnel-protocol.ts` | none |
| `TUNNEL_CHUNK_FLUSH_MS` | 50 | `bridge/src/tunnel-protocol.ts` | unchanged |
| `TUNNEL_GZIP_ENCODING` | `"gzip"` (was `"gzip-base64"`) | `bridge/src/tunnel-protocol.ts` | Dart `kTunnelGzipEncoding = 'gzip'` (`preview_models.dart`); it is the `acceptEncodings` token and nothing else |
| `kTunnelStreamMaxQueuedBytes` (**NEW**) | `2_097_152` | `packages/antgrid_relay_client/lib/src/tunnel_stream.dart` | none (side-local) |

- The wire package states in a comment at `STREAM_TUNNEL_REQUEST_BODY_MAX_BYTES` that it equals
  `MAX_TRANSFER_BYTES`: a preview upload is bounded exactly as the session path bounded it.
- `TUNNEL_BODY_SLICE_BYTES` must stay ≤ `STREAM_RECORD_SLICE_BYTES` and ≤ `STREAM_TUNNEL_DATA_MAX_BYTES`.
  A slice that gzip would grow ships identity (`encodeChunk` already compares lengths), so no slice can
  exceed the cap.
- `TUNNEL_STREAM_MAX_QUEUED_BYTES` bounds one tunnel writer's queue. HTTP awaits every send, so it holds at
  most one slice plus the end record. WS cannot await (upstream messages are events), so 4 MiB is up to four
  maximum-size upstream messages waiting on a slow reader. Past that, only that stream is reset (D3) and the
  upstream socket is released with 1001.
- The generator (`packages/antgrid-wire/scripts/gen-peer-transport-vectors.ts`) adds this under `streamOpen`,
  and nothing else in the fixture changes:
  `"tunnelRecords": { "maxDataBytes": 1048576, "maxRecordBytes": 1048577, "requestBodyMaxBytes": 33554432, "tags": { "body": 0, "bodyGzip": 1, "wsText": 2, "wsBinary": 3 } }`.

### 2.1 Wire helpers (`packages/antgrid-wire/src/stream-open.ts`, new code written fresh, Apache-2.0)

```ts
export type TunnelDataTag = 0x00 | 0x01 | 0x02 | 0x03;
/** One tag byte + payload. Throws RangeError for an unknown tag or a payload over STREAM_TUNNEL_DATA_MAX_BYTES. */
export function encodeTunnelDataRecord(tag: TunnelDataTag, payload: Uint8Array): Uint8Array;
/** null for an empty record, an unknown tag, or a first byte of 0x7B whose body is not valid UTF-8. */
export function decodeTunnelRecord(record: Uint8Array):
  | { kind: "json"; text: string }
  | { kind: "data"; tag: TunnelDataTag; payload: Uint8Array }
  | null;
```

Dart mirrors both in `tunnel_stream.dart` as `encodeTunnelDataRecord(int tag, Uint8List payload)` and
`decodeTunnelRecord(Uint8List record)`, returning a sealed `TunnelRecord` (`TunnelJsonRecord(String text)` or
`TunnelDataRecord(int tag, Uint8List payload)`) or `null`. The payload is a view, not a copy.

---

## 3. Bridge API (bridge-src implements; bridge-tests tests against exactly this)

### 3.1 `bridge/src/localhost-fetch.ts` (bytes, not base64)

```ts
export interface TunnelBodySlice { bytes: Uint8Array; gzip: boolean; last: boolean }
export interface FetchLocalhostOpts { /* unchanged except */ body?: Uint8Array; }
export function encodeChunk(raw: Uint8Array, acceptGzip: boolean, last: boolean): TunnelBodySlice;
export function singleSlice(raw: Uint8Array, acceptGzip: boolean): TunnelBodySlice;
```

- `acceptGzip` is `acceptEncodings.includes(TUNNEL_GZIP_ENCODING)`. The gzip-pays comparison is on raw
  lengths, and `GZIP_MIN_BYTES` is unchanged.
- A body of length 0 is sent to the upstream as no body.
- `fetchLocalhost`, `UpstreamBodyError` and `isTlsOnlyPort` keep their semantics. The slicing loop yields
  slices of ≤ `TUNNEL_BODY_SLICE_BYTES`, flushed on `TUNNEL_CHUNK_FLUSH_MS`, as today.

### 3.2 `bridge/src/tunnel-manager.ts`

Deleted:
- the outbox (`retain`/`readOutbox`/`evictOutbox`/`replayStream`, `:183-193`, `:520-561`);
- the pre-open buffer (`bufferPreopenFrame`/`makeRoomForPreopen`/`armPreopenTimer`/`poisonPreopen`/
  `takePreopen` and its TTL option `wsPreopenTtlMs`, `:847-882`);
- `onHttpRequest`, `onHttpCancel`, `runInflight`, `emit`, `onWsOpen`, `onWsData`, `onWsClose`;
- the `sendTunnel` constructor option.

Kept as they are:
- `onPortsUpdate`, `getPreviewSnapshot`, `sendEncrypted`, `relayHost`, `connState`, `wsAbandonedMax`,
  `fetchOpts`;
- the connecting-state `pending` buffer (`WS_BUFFER_MAX_FRAMES`/`WS_BUFFER_MAX_BYTES`);
- `openUpstream` catching the constructor throw;
- `splitUpstreamWsHeaders`, the TLS exemption, the abandoned-socket park and the `vite-hmr` subprotocol
  warning.

```ts
import type { StreamSendOutcome } from "./peer/stream-records";
import type { TunnelBodySlice } from "./localhost-fetch";
import type { TunnelHttpRequest, TunnelWsOpen } from "./tunnel-protocol";

export interface TunnelHttpExchange {
  /** Aborted by the app's cancel, a failed/gated send, projectDetached, dropPeer, or abortHttpStreams. */
  readonly signal: AbortSignal;
  head(head: { status: number; headers: Record<string, string>; setCookies?: string[] }): Promise<StreamSendOutcome>;
  body(slice: TunnelBodySlice): Promise<StreamSendOutcome>;
  /** Writes tunnel:http-end, then finish(). Only after the upstream body completed without error. */
  end(): Promise<StreamSendOutcome>;
  /** writer.abort(): reset, no end record. Idempotent; a no-op after end(). */
  fail(reason: string): void;
}

export interface TunnelWsFrame { binary: boolean; bytes: Uint8Array }

export interface TunnelWsPeer {
  /** One upstream message toward the app. "dropped" means the stream is gone: release the upstream (1001). */
  send(frame: TunnelWsFrame): Promise<StreamSendOutcome>;
  /** Upstream closed: queue a tunnel:ws-close after every frame already sent, then FIN. Idempotent. */
  close(code?: number, reason?: string): void;
}

export interface TunnelWsUpstreamSink {
  /** One app message toward the upstream (buffered while CONNECTING, as today). */
  data(frame: TunnelWsFrame): void;
  /** The app closed (close record, FIN or reset) or the stream was torn down. Idempotent. */
  closed(code?: number, reason?: string): void;
}

export type TunnelAdmission =
  | { ok: false; refusal: { code: "UPDATE_REQUIRED" | "NOT_ALLOWED"; message: string } }
  | { ok: true; manager: TunnelManager };

/** What a project's mux entry exposes to the tunnel registry: AgentCore implements it. */
export interface TunnelStreamServer {
  admit(peerId: string, checkoutId: string): TunnelAdmission;
}

export class TunnelManager {
  /** Resolves when the run is over (end written, failed, or aborted). Never rejects. */
  serveHttp(req: TunnelHttpRequest, body: Uint8Array, exchange: TunnelHttpExchange): Promise<void>;
  serveWs(open: TunnelWsOpen, peer: TunnelWsPeer): TunnelWsUpstreamSink;
  /** Aborts every in-flight serveHttp run (each then calls exchange.fail). WS untouched. */
  abortHttpStreams(): void;
  /** Aborts every HTTP run, and closes every upstream WS with peer.close(1001). */
  stop(): void;
}
```

**`serveHttp` behaviour:**
- It combines `exchange.signal` with a per-run `AbortController` that is registered in `inflight` (now a
  `Set<AbortController>`) for `abortHttpStreams`. That combined signal is what it passes to `fetchLocalhost`.
  Aborting the fetch's signal is what closes the upstream on Bun.
- **Fetch failure before the head, or a first-slice failure:** it sends `head({status: 502, ...})`, one body
  slice with the message, then `end()`, exactly as today's synthesized 502.
- **After the head:** an upstream error or an `UpstreamBodyError` calls `fail()`, never `end()`.
- **Any outcome other than `"sent"`** aborts the run's controller and returns. The writer has already reset,
  or the registry aborted it.
- Every send is awaited before the next upstream read (the "keep awaiting each write" rule).
- Duplicate-requestId joining is gone, because the registry refuses a duplicate (§3.3).

**`serveWs` behaviour:**
- It opens the upstream, and returns a sink whose `data` goes through `sendUpstream` or the connecting-state
  `pending` buffer.
- Every upstream message goes to `peer.send({binary, bytes})`, text encoded as UTF-8. On `"dropped"`, the
  manager releases the upstream with 1001.
- An upstream message over `STREAM_TUNNEL_DATA_MAX_BYTES` releases the upstream with 1009 and calls
  `peer.close(1009)`.
- An upstream close calls `peer.close(code, reason)`.
- `sink.closed` tears the upstream down as `onWsClose` does today.
- The manager's live-socket set is keyed **by the sink object**, never by `tunnelId` alone. Two peers may
  choose the same `tunnelId`, and the registry only guarantees uniqueness per peer.

### 3.3 NEW `bridge/src/peer/tunnel-streams.ts`

```ts
import type { TunnelHttpStreamOpen, TunnelWsStreamOpen } from "antgrid-wire";
import type { StreamHandler } from "./stream-dispatch";
import type { TunnelProjectBinding } from "../stream-mux";

export const TUNNEL_STREAM_MAX_QUEUED_BYTES = 4 * 1024 * 1024;
export const STREAM_PRIORITY_TUNNEL = -1;
export const STREAM_RESET_TUNNEL = 0x15n;
export const STREAM_STOP_TUNNEL = 0x16n;

export interface TunnelStreamRegistryOptions {
  /** host-server `seenProjects.has`. Absent => every open is refused NOT_ALLOWED (fail closed). */
  projectCataloged?: (projectId: string) => boolean;
  /** `StreamMux.tunnelBinding`. Lookup only: never opens or promotes a core. */
  tunnelBinding: (projectId: string) => TunnelProjectBinding | null;
  /** Only ever "unauthorized" (a writer, or a per-record authorized() check on read) or
   *  "protocol-violation" (a malformed length prefix from StreamRecordReader). */
  retirePeer: (peerId: string, reason: "unauthorized" | "protocol-violation") => void;
  diagnostic?: (type: string, detail: Record<string, unknown>) => void;
  /** Timer seam for the head deadline; defaults to setTimeout/clearTimeout. */
  schedule?: (callback: () => void, ms: number) => () => void;
}

export class TunnelStreamRegistry {
  constructor(opts: TunnelStreamRegistryOptions);
  readonly httpHandler: StreamHandler<TunnelHttpStreamOpen>;
  readonly wsHandler: StreamHandler<TunnelWsStreamOpen>;
  /** Aborts every stream bound to that project: HTTP runs are aborted, WS sinks get closed(). */
  projectDetached(projectId: string): void;
  /** Connection retired: abort and unbind everything for the peer. Never calls retirePeer. */
  dropPeer(peerId: string): void;
  /** Live HTTP + WS bindings holding a cap slot for the peer. */
  streamCount(peerId: string): number;
}
```

**Handler contract.** It is the same as A2's. Every refusal the handler **returns** is decided synchronously,
before any read is issued. The checks, in order, are the same for both kinds (`id` is `requestId` or `wsId`):

| # | Check | Refusal |
|---|---|---|
| 1 | `streamCount(peerId) >= STREAM_MAX_TUNNEL_STREAMS_PER_PEER` | `CAP_EXCEEDED` |
| 2 | `!isSafeProjectId(projectId)` | `NOT_ALLOWED` |
| 3 | `projectCataloged` absent, or `!projectCataloged(projectId)` | `NOT_ALLOWED` |
| 4 | `tunnelBinding(projectId) === null` | `NOT_READY` |
| 5 | `binding.refusalFor(peerId)` non-null | `UPDATE_REQUIRED` when its code is `"UPDATE_REQUIRED"`, else `NOT_ALLOWED` |
| 6 | the peer already has a live binding of the same kind with this `id` | `INVALID` |
| 7 | `binding.tunnels() === null` | `NOT_ALLOWED` |

The acceptor has already covered authorization, the open-frame read, `NOT_READY` for an unestablished session
(hazard J: never parked) and the pending-open cap.

**After step 7**, the handler takes a cap slot and builds:
- `new StreamRecordWriter(stream, admission.authorized, onFailure, TUNNEL_STREAM_MAX_QUEUED_BYTES, STREAM_PRIORITY_TUNNEL, STREAM_RESET_TUNNEL)`;
- `new StreamRecordReader(stream, STREAM_TUNNEL_RECORD_MAX_BYTES, () => retirePeer(peerId, "protocol-violation"))`.

It then starts the async phase with `void`, and returns `undefined`.

**Async phase: head.**
1. Read one record under `STREAM_OPEN_DEADLINE_MS` (`schedule`). On the deadline:
   - `writer.abort()` and unbind;
   - `void recv.stop(STREAM_STOP_TUNNEL)` **only after that read settles**, never while it is pending (the
     binding mutex);
   - no refusal is written.
2. If `!admission.authorized()`, call `retirePeer(peerId, "unauthorized")`. This check is repeated before
   handling **every** inbound record.
3. Decode the record with `decodeTunnelRecord`. It must be JSON that parses as `TunnelHttpRequest` (HTTP) or
   `TunnelWsOpen` (WS), and its `requestId`/`tunnelId` must equal the open frame's `id`. For HTTP, the
   `bodyLength` and `content-length` rules of §1.3 apply. Any failure is refused `INVALID`.
4. Call `binding.tunnels()?.admit(peerId, head.checkoutId)`. A refusal is written with that code. `null`
   (the entry has gone since admission) is `NOT_ALLOWED`.

A refusal at step 3 or 4 is written with the exported `refuseStream(stream, refusal, authorized, onUnauthorized)`.
No read is outstanding at that point. The binding is marked unbound first, so `refuseStream`'s own writer is
the only one that touches the send half, and the registry's writer is never used.

**Async phase: HTTP body, then run.**
- Read `0x00` records until `bodyLength` bytes have arrived. The §1.3 violations are refused `INVALID`, which
  is still in-band because no read is outstanding. A rejection (FIN or reset) abandons: `writer.abort()` and
  unbind, with no upstream contact.
- Build the exchange:
  - `head`/`body`/`end` first check `binding.mayDeliverTo(peerId)` on every call. A false result aborts the
    run and `writer.abort()`s, and resolves `"dropped"`.
  - `head` writes `tunnel:http-head`, stamping `requestId` and `checkoutId`.
  - `body` writes a `0x00` or `0x01` record.
  - `end` writes `tunnel:http-end`, then `writer.finish()`, then unbinds.
  - `fail` calls `writer.abort()` and unbinds.
- Call `manager.serveHttp(head, body, exchange)`.
- **Cancel detection.** Once the body is complete, issue exactly one more `reader.read()` and keep it
  pending.
  - A **rejection** before `end()` has been written is the app's cancel (a reset, or a FIN, which we cannot
    tell apart and treat the same). Abort the exchange signal, then `writer.abort()`, then unbind.
  - A rejection after `end()` is the app's orderly FIN, and it is ignored.
  - A **record** is a stream breach: abort the run, `writer.abort()`, unbind, and
    `void recv.stop(STREAM_STOP_TUNNEL)`, which is legal because the read has just completed.
- **Slot.** The cap slot is freed at unbind: the run's end, failure or abort. It does not wait for the app's
  FIN (the same open item as A2 §9).

**Async phase: WS.**
- Build the peer:
  - `send` checks `mayDeliverTo`, then writes a `0x02`/`0x03` record.
  - `close` writes `tunnel:ws-close` (with `code`/`reason` when given), then `writer.finish()`, then unbinds.
- Call `sink = manager.serveWs(head, peer)`.
- Read loop:
  - `0x02`/`0x03` go to `sink.data`.
  - A `tunnel:ws-close` goes to `sink.closed(code, reason)`. The loop keeps reading only to observe FIN; any
    further record is a breach.
  - Any other record is a breach: `sink.closed(1002)`, `writer.abort()`, unbind, and `recv.stop`.
  - A rejection is `sink.closed()`, then `void writer.finish()` if the peer has not closed yet, then unbind.
- **Writer `onFailure`:**
  - `"unauthorized"` goes to `retirePeer`, the only connection-closing path.
  - `"overflow"` or `"stream-lost"` goes to `sink.closed()` (HTTP: abort the run), then unbind.

**`projectDetached` and `dropPeer`.** Both abort every run and close every sink for the scope, then
`writer.abort()` and unbind. Neither dispatches anything else. As in A2 §10, an `unbound` flag, not a
generation counter, makes every late callback a no-op.

### 3.4 `bridge/src/stream-mux.ts`, `bridge/src/peer-session-owner.ts`, `bridge/src/peer/native-host-connection.ts`

```ts
// stream-mux.ts
export interface StreamHandle {
  readonly streamId: string;
  detach(): void;
  sendTo(msg: unknown, channel: Channel, target: SendTarget): Promise<SendOutcome>;
  readonly terminalHooks?: TerminalStreamHooks;
}                                         // sendTunnel REMOVED

export interface AttachStreamOpts {       // onTunnel REMOVED
  /* ...existing members unchanged... */
  /** The project's tunnel server; absent => tunnel streams for this project are refused NOT_ALLOWED. */
  tunnels?: TunnelStreamServer;
}

export interface TunnelProjectBinding {
  readonly streamId: string;
  /** entry.opts.mayAcceptFrom(peerSession(peerId)), re-read per call; entry gone => NOT_ALLOWED. */
  refusalFor(peerId: string): StreamRefusal | null;
  /** Re-resolves the entry by streamId: false when it has gone; else mayDeliver() &&
   *  (mayDeliverTo absent || (peer resolves && mayDeliverTo(peer))). Re-read per outbound record. */
  mayDeliverTo(peerId: string): boolean;
  /** entry.opts.tunnels ?? null, re-resolved by streamId. */
  tunnels(): TunnelStreamServer | null;
}

export class StreamMux {
  /** Newest live entry for projectId, as projectBinding. Lookup only; never opens or promotes a core. */
  tunnelBinding(projectId: string): TunnelProjectBinding | null;
}
```

- **`dispatchInbound`** loses its `parseTunnelMessage` → `onTunnel` branch. A body that is not an `AbMessage`
  is dropped, exactly as any other unparseable frame. `unboundAtPeer` is neither read nor retracted by tunnel
  streams.
- **`peer-session-owner.ts`** loses:
  - the `parseTunnelMessage` import and its branch at `:691`;
  - the `onTunnelMessage` option;
  - `sendTunnel`;
  - `handleUndeliverableTunnel` and its call sites.

  A `tunnel:*` frame on the session stream now falls through to the ordinary drop. The
  `StreamMuxTransport.projectDetached` fan-out stays as it is.
- **`native-host-connection.ts`:**
  - `NativePeerSessions` builds `new TunnelStreamRegistry({ projectCataloged, tunnelBinding: (p) => this.mux.tunnelBinding(p), retirePeer: <guarded on nativePeers.has, like terminal>, diagnostic, schedule })`.
  - The acceptor's handlers become
    `{ terminal: ..., "tunnel-http": tunnels.httpHandler, "tunnel-ws": tunnels.wsHandler }`.
  - `retirePeer` calls `tunnels.dropPeer(peerId)` next to `terminalStreams.dropPeer`.
  - The `projectDetached` override calls `tunnels.projectDetached(projectId)` next to the terminal registry's.
- **`send-scheduler.ts`.** The `SendOutcome` doc says `"gated"` comes from `StreamHandle.sendTo` only. The
  type is unchanged, because `sendTo` still returns `"gated"`. Tunnel code imports `StreamSendOutcome` from
  `stream-records.ts` instead, and that is the spec's "`SendOutcome` moves".

### 3.5 `bridge/src/agent-core.ts`, `bridge/src/project-core.ts`, `bridge/src/host-server.ts`

- **`AgentCore` loses** `handleTunnelMessage`, `setPlainHook`, `sendPlain`, `busPlainHook`,
  `noteTunnelOrigin`, `tunnelTargetFor`, `tunnelRefOf`, `tunnelOriginByRef` and `TUNNEL_ORIGIN_TTL_MS`.
- **`AgentCore` gains** `readonly tunnelStreams: TunnelStreamServer`. Its `admit(peerId, checkoutId)` checks,
  in order:
  1. `!remoteFrameAllowed("relay")` → `NOT_ALLOWED` ("mobile access is disabled");
  2. `sessions?.hasIsolatedSessions() && !peerCanRouteCheckouts(peerId)` → `UPDATE_REQUIRED`;
  3. `checkoutRuntimes.runtime(checkoutId)` is null → `NOT_ALLOWED` ("unknown checkout");
  4. `runtime.tunnelManager` is null → `NOT_ALLOWED`.

  Otherwise it returns `{ ok: true, manager }`. These are the checks `handleTunnelMessage` made, now answered
  in-band instead of logged and dropped.
- `abortTunnelStreams()` is unchanged in shape and caller (§0).
- Both `TunnelManager` constructions (the checkout runtime at `:3580` and main at `:3882`) drop `sendTunnel`.
  The per-runtime `checkoutId` stamp moves to the registry, which stamps the head's `checkoutId` on every JSON
  record it writes.
- **`project-core.ts` `attachRelayStream`:**
  - drops `onTunnel` and `core.setPlainHook(...)`, and passes `tunnels: core.tunnelStreams`;
  - its two teardown blocks drop `core.setPlainHook(null)`. Detaching the stream is what removes
    `opts.tunnels`;
  - `onPeerOnline`/`onPeerOffline` keep calling `core.abortTunnelStreams()`.
- **`host-server.ts`:**
  - `remoteDepsFor`'s wrapper drops `sendTunnel` and forwards `attachStream`'s opts, including `tunnels`,
    untouched;
  - the `onTunnelMessage: () => {}` option at `:845` is deleted;
  - `seenProjects` already feeds `projectCataloged`, and the same value reaches the new registry.
- **`protocol.ts` `BODY_REDACTED_MESSAGE_TYPES`:** remove `"tunnel:http-start"` and `"tunnel:http-chunk"`,
  and add `"tunnel:http-head"` (it carries `setCookies`). `"tunnel:http-request"` and `"tunnel:ws-open"` stay.
  No `AbMessage` type is added or removed, and `CHECKOUT_VARIABLE_MESSAGE_TYPES` is unchanged.

### 3.6 Security invariants (none weakened; bridge-tests pins each)

- **Remote-access switch.**
  - Inbound, it is `admit`'s `remoteFrameAllowed`, plus `authorized()` checked per inbound record: the
    switch is part of `NativePeerSessions.authorized`.
  - Outbound, it is `mayDeliverTo` → `mayDeliver()` per record, plus the writer's per-slice `authorized()`.
- **projectId bound.** `isSafeProjectId` plus `projectCataloged` (`seenProjects`), at steps 2–3.
- **Checkout routing.** `mayAcceptFrom` at open (step 5) and the core's `UPDATE_REQUIRED` at the head.
  `mayDeliverTo` holds on every send.
- **No core side effects.** `tunnelBinding` is a lookup, so a stream for a stopped project is `NOT_READY` and
  starts nothing.

---

## 4. Dart API (dart+app)

### 4.1 NEW `packages/antgrid_relay_client/lib/src/tunnel_stream.dart` (written fresh; Apache-2.0)

No code may be moved or adapted into this file from `app/`. `preview_service.dart`'s queue and policy stay in
the app.

```dart
const int kTunnelStreamMaxQueuedBytes = 2097152;

final class TunnelHttpHead {
  final int status;
  final Map<String, String> headers;
  final List<String> setCookies;
}
final class TunnelBodyRecord { final Uint8List bytes; final bool gzip; }
final class TunnelWsFrame { final bool binary; final Uint8List bytes; }   // text = UTF-8 bytes

/// codes: REFUSED (refusal set), NOT_SUPPORTED, STREAM_UNBOUND, STREAM_OPEN_FAILED,
/// SEND_FAILED, STREAM_ENDED, TRUNCATED, PROTOCOL, CANCELLED, TRANSPORT_CLOSED
final class TunnelExchangeFailure implements Exception {
  final String code;
  final StreamRefused? refusal;
  final Object? error;
}

abstract interface class TunnelHttpExchange {
  String get requestId;
  /// Completes with the head, or errors with TunnelExchangeFailure. Never an unhandled error.
  Future<TunnelHttpHead> get head;
  /// Single-subscription. Done after tunnel:http-end; errors TunnelExchangeFailure
  /// (TRUNCATED / PROTOCOL / CANCELLED / TRANSPORT_CLOSED).
  Stream<TunnelBodyRecord> get body;
  /// Idempotent. Waiting for a slot: leave the queue and never open. Opening: reset once open.
  /// Open: stop the upload, reset() the send half, keep draining records.
  void cancel();
}

sealed class TunnelWsEnd {}
final class TunnelWsClosedByPeer extends TunnelWsEnd { final int? code; final String? reason; }
final class TunnelWsClosedLocally extends TunnelWsEnd {}
final class TunnelWsFailed extends TunnelWsEnd { final TunnelExchangeFailure failure; }

abstract interface class TunnelWsChannel {
  String get tunnelId;
  Stream<TunnelWsFrame> get frames;     // bridge → browser, in order; closes when done completes
  Future<TunnelWsEnd> get done;         // completes once, never errors
  /// Serialized in call order, including calls made before the stream opens. true = accepted.
  /// false = the channel is dead (it has already reset). A frame over kStreamTunnelDataMaxBytes resets it.
  Future<bool> send(TunnelWsFrame frame);
  /// Writes tunnel:ws-close after every queued frame, then finish(). Idempotent.
  void close({int? code, String? reason});
  /// reset() with no close record. Idempotent.
  void abort();
}
```

- **Every error path calls `reset()` explicitly**, because a dropped noq `SendStream` FINs and would hand the
  bridge a truncated clean end. That covers `SEND_FAILED`, `PROTOCOL`, a local frame-too-large, a
  `backpressured`, `closed` or `failed` outcome, and a thrown `send`. Every fire-and-forget
  `reset()`/`finish()` swallows its own rejection.
- **The records reader is capped** at `kStreamTunnelRecordMaxBytes`.
- **HTTP record handling.** The first record is decoded with `StreamRefused.tryDecode`: a hit fails
  `REFUSED`. Otherwise it must be JSON `tunnel:http-head` with a matching `requestId`. After the head:
  - `0x00`/`0x01` records are added to `body`;
  - JSON `tunnel:http-end` closes `body` and calls `finish()`;
  - anything else is `PROTOCOL`.
- **Head and body futures.** Internal completers attach a no-op error handler, so a caller that only reads
  `head` never surfaces an unhandled `body` error, and the reverse.

### 4.2 `AgentTransport`, `BufferedAgentTransport`, `FakeAgentTransport`

```dart
// agent_transport.dart — both return synchronously and never throw.
TunnelHttpExchange openTunnelHttp({
  required String requestId,
  required String checkoutId,
  /// The tunnel:http-request head, with type and requestId. The transport stamps bodyLength = body.length
  /// and checkoutId itself.
  required Map<String, dynamic> head,
  required Uint8List body,
});
TunnelWsChannel openTunnelWs({
  required String tunnelId,
  required String checkoutId,
  /// The tunnel:ws-open head; the transport stamps tunnelId and checkoutId.
  required Map<String, dynamic> open,
});
```

- **`BufferedAgentTransport` defaults.** Both calls fail at once with `TunnelExchangeFailure('NOT_SUPPORTED')`,
  and nothing is written to the socket. The head future errors, the body stream errors, and `done` completes
  `TunnelWsFailed`. `LocalTransport`, `DemoTransport` and the test subclasses inherit this. That is the D2
  "LocalTransport implementation" for a remote-only feature: loopback never tunnels, and the test in §6 pins
  that it stays silent.
- **`FakeAgentTransport`** gains:
  - `final List<FakeTunnelHttpExchange> tunnelHttpOpens` and `final List<FakeTunnelWsChannel> tunnelWsOpens`,
    which record every call's arguments;
  - `FakeTunnelHttpExchange` has `completeHead(TunnelHttpHead)`, `addBody(TunnelBodyRecord)`, `endBody()`,
    `failWith(TunnelExchangeFailure)` and `bool cancelled`;
  - `FakeTunnelWsChannel` has `emit(TunnelWsFrame)`, `closeFromPeer({code, reason})`, `sent`, `closedWith`
    and `aborted`.

  Both classes live in `app/lib/test_helpers/fake_agent_transport.dart`.

### 4.3 `machine_session.dart`: `MachineSession` and `StreamTransport`

- **`MachineSession` tunnel slots.** It gains a FIFO waiting slot pool of `kStreamMaxTunnelStreamsPerPeer`,
  shared by HTTP and WS: `Future<bool> _acquireTunnelSlot(Object owner)`, `void _cancelTunnelSlotWait(Object owner)`
  and `void _releaseTunnelSlot()`.
  - Unlike terminal attachments, an over-cap tunnel open **waits** instead of failing: a page load issues
    more parallel requests than any cap.
  - Session teardown resolves every waiter `false`, and those opens fail `TRANSPORT_CLOSED`.
- **`StreamTransport.openTunnelHttp`/`openTunnelWs`.** On a link that is not a `MultiStreamPeerLink`
  (`fake_live_relay.dart`), they fail `NOT_SUPPORTED`. Otherwise, in order:
  1. `projectIdForStream(streamId)`, where `null` fails `STREAM_UNBOUND`;
  2. acquire a slot;
  3. `link.openStream(TunnelHttpStreamOpen(projectId: ..., requestId: ...)` or
     `TunnelWsStreamOpen(projectId: ..., wsId: tunnelId)`,
     `maxRecordBytes: kStreamTunnelRecordMaxBytes, maxQueuedBytes: kTunnelStreamMaxQueuedBytes)`, where a
     throw fails `STREAM_OPEN_FAILED`;
  4. send the head record;
  5. HTTP only: send the body in ≤ 262144-byte `0x00` records, each awaited, and verify the sent total.
- **Slot release.** Once a stream exists, the slot is held until its `records` complete, including after
  `cancel()`, `close()` or `abort()`. This is the same rule as A2 §10.

### 4.4 `app/lib/services/preview_service.dart`, `preview_proxy_server.dart`, `preview_models.dart`, `tunnel_body.dart`

**`preview_service.dart` deletes:**
- `_pendingRequests`, `_cancelledIds`, `_cancelUnknown`, `_sendCancel` and `_maxRetries`;
- `_onHeadLost` (`:411-439`), `_handleTunnelStart`/`Chunk`/`End` and `_armIdle`'s seq logic;
- `_TunnelBody` and `_InFlightRequest.attempts`/re-keying;
- `_txSub`/`_onTransportMessage` for tunnel types;
- `_onReestablished` and its `preview:tunnel-reestablish` hydrator;
- `_handleWsData`/`_handleWsClose`.

**`proxyRequest(request, {timeout, chunkIdleTimeout})` keeps its signature and return type:**
- It opens `session.transport.openTunnelHttp(requestId: request.requestId, checkoutId: checkoutId, head: request.toHeadJson(), body: request.body ?? Uint8List(0))`.
- `head` is raced against `timeout`. On timeout it calls `exchange.cancel()` and throws `TimeoutException`,
  and the statistics counters are kept.
- It returns `TunnelHttpResponse` with `body` built from `exchange.body`:
  - each record goes through `decodeTunnelBody`;
  - a per-record idle timer of `chunkIdleTimeout` calls `cancel()`;
  - a failure becomes `TunnelStreamException(code)`;
  - the browser cancelling its subscription calls `cancel()`.
- `dispose()` cancels every live exchange and closes every WS channel with 1001.

**WS.** `_onWsConnect` opens `openTunnelWs(tunnelId, checkoutId, open: {type:'tunnel:ws-open', port, scheme, path, headers})`.
- Browser messages go through the **kept** `_WsOutboundQueue`. Its ceilings are unchanged (64 frames /
  1 MiB / 10 s send timeout / 2 s close grace), and it is retargeted from `transport.send` to
  `channel.send(TunnelWsFrame)`. A `false` from `channel.send` aborts it.
- `channel.frames` go to the browser sink, and `done` closes the browser sink through the unchanged
  `_forwardableCloseCode`/`_forwardableCloseReason`.
- Browser `onDone` calls `channel.close()`, and the outbound abort calls `channel.abort()`.

**`preview_models.dart`:**
- `TunnelHttpRequest.body` becomes `Uint8List?`, and `toJson` is replaced by `toHeadJson()`, which carries no
  body.
- `acceptEncodings` still defaults to `[kTunnelGzipEncoding]`, now `'gzip'`.
- The five inbound message classes are deleted, and so are the `ab_message.dart` cases at `:1687-1700`.

**`preview_proxy_server.dart`** reads the request body with `request.read()` into bytes, not `readAsString`.

**`tunnel_body.dart`:** `decodeTunnelSlice` is replaced by `Uint8List decodeTunnelBody(TunnelBodyRecord r)`,
which gunzips `r.bytes` when `r.gzip` and throws `FormatException` on a bad member.

**`project_message_classification.dart`:** the five tunnel entries leave `kUnroutedInboundTypes` in the same
commit as the parser cases, together with the doc comment at `:256-259`. `classification_gate_test.dart` fails
on a stale entry.

### 4.5 Eval client

`packages/antgrid_eval_client/lib/src/commands.dart` is **unchanged**. Evals drive tunnels from TypeScript
(§5).

---

## 5. Test seams after A3

| Seam | After A3 |
|---|---|
| `bridge/tests/test-peer-session-owner.ts` | **Unchanged.** It never referenced tunnel members. Tests that exercised `sendTunnel`/`onTunnelMessage` through it are deleted or retargeted (§6). |
| `packages/antgrid_relay_client/test/support/fake_live_relay.dart` | **Unchanged.** `PeerLink` only, so `StreamTransport` tunnel calls fail `NOT_SUPPORTED` over it. |
| `evals/helpers/relay-client.ts` | **DELETED:** `TunnelHttpResult`'s `frames`/`chunks`, `decodeTunnelSlice`, `waitForTunnelResponse`, the raw `tunnel:*` branch in `dispatchAbMessage`, and the `TUNNEL_GZIP_ENCODING` import. **NEW:** the two methods below. |
| `evals/support/` | **Unchanged.** |
| `packages/antgrid_eval_client/lib/src/commands.dart` | **Unchanged.** |

```ts
export interface TunnelHttpResult {
  status: number; headers: Record<string, string>; setCookies: string[]; body: Buffer; records: number;
}
export interface TunnelHttpStreamClient {
  readonly requestId: string;
  /** tunnel:http-head, or rejects with Error carrying `.refusal` (StreamRefused) when refused. */
  head(timeoutMs?: number): Promise<Record<string, any>>;
  /** Head + every body record (gunzipped per record) + the end record; rejects on refusal or truncation. */
  response(timeoutMs?: number): Promise<TunnelHttpResult>;
  bodyBytesSoFar(): number;
  /** Stops/restarts issuing reads, so QUIC flow control pushes back on the bridge. */
  pauseReading(): void;
  resumeReading(): void;
  /** send.reset(0n), not awaited; keeps draining. */
  cancel(): void;
  /** "end" = end record then FIN; "truncated" = FIN/reset after head without end; "refused"; "reset-before-head". */
  readonly ended: Promise<"end" | "truncated" | "refused" | "reset-before-head">;
}
/** openBi; writes the open frame, the head (bodyLength stamped from body), and 0x00 body records (≤256 KiB each).
 *  Reads with StreamRecordReader capped at STREAM_TUNNEL_RECORD_MAX_BYTES. Finishes its half on the end record. */
openTunnelHttpStream(opts: {
  projectId: string; requestId?: string; head: Record<string, unknown>; body?: Uint8Array;
}): Promise<TunnelHttpStreamClient>;

export type TunnelWsRecord =
  | { kind: "text"; text: string } | { kind: "binary"; bytes: Buffer }
  | { kind: "close"; code?: number; reason?: string } | { kind: "refused"; refusal: Record<string, any> };
export interface TunnelWsStreamClient {
  readonly tunnelId: string;
  readonly records: TunnelWsRecord[];        // unconsumed, in arrival order
  next(predicate: (r: TunnelWsRecord) => boolean, timeoutMs?: number): Promise<TunnelWsRecord>;
  sendText(text: string): Promise<void>;
  sendBinary(bytes: Uint8Array): Promise<void>;
  close(code?: number, reason?: string): Promise<void>;   // ws-close record, then finish
  reset(): void;
  readonly ended: Promise<void>;             // bridge half ended, by FIN or reset
}
openTunnelWsStream(opts: { projectId: string; tunnelId?: string; open: Record<string, unknown> }): Promise<TunnelWsStreamClient>;
```

---

## 6. Tests: added, changed, deleted

The spec's named cases map as follows:
- **A7 cancel against a stalled upstream through the real binding**: `gate-tunnel-streaming` row 3. It runs
  in evals, not against a fake.
- **Stream cap**:
  - the app semaphore holding is covered by `tunnel_stream_test.dart`;
  - the over-cap open refused in-band while the connection lives is `gate-tunnel-streaming` row 4, plus
    `tunnel-streams.test.ts`.
- **A WebSocket close after data arrives after the data**: `gate-tunnel-streaming` row 6, plus
  `tunnel-streams.test.ts` and `tunnel-manager-ws-order.test.ts`.
- **Truncation trap**: `tunnel-streams.test.ts` (content-length and body overflow), `tunnel_stream_test.dart`
  (sent length, FIN without an end record) and `gate-tunnel-streaming` row 5.

### bridge-tests

**NEW `bridge/tests/tunnel-streams.test.ts`.** It drives `TunnelStreamRegistry` with fakes. As in A2:
- the fake send half models the binding mutex, so `reset`, `finish` and `setPriority` await any pending
  `writeAll`;
- the fake recv half does the same for `stop` against a pending `readExact`;
- neither fake defines `stopped` or `receivedReset`.

The rows:
- each §3.3 refusal step, in order, with the step-1 cap shared across HTTP and WS, and a step-6 duplicate per
  kind;
- the head deadline resets the stream, frees the slot and calls `stop` only after the read settles;
- head mismatches are refused `INVALID` in-band: `requestId`/`tunnelId` differing from the open frame, a
  schema failure, `bodyLength` over the cap, a `content-length` disagreeing with `bodyLength`, and a body
  record past `bodyLength`;
- `admit` refusals are passed through in-band: `NOT_ALLOWED` for the switch off, `UPDATE_REQUIRED`, and an
  unknown checkout;
- a FIN or reset mid-body never calls `serveHttp`;
- the pending read's rejection before `end` aborts the exchange signal and resets; after `end`, it is ignored;
- an extra record after the body is a stream breach, and `retirePeer` is not called;
- `authorized()` false on an inbound record calls `retirePeer("unauthorized")`;
- a false `mayDeliverTo` on send resolves `"dropped"`, resets and aborts;
- a WS close record written after N queued data records arrives after them, and FIN follows;
- WS writer overflow closes the sink and resets that stream only;
- `projectDetached`/`dropPeer` abort only their scope and never call `retirePeer`;
- `setPriority(STREAM_PRIORITY_TUNNEL)` is called once, before the first write.

**`bridge/tests/tunnel-manager-stream.test.ts`: REWRITE** against `serveHttp` with a fake `TunnelHttpExchange`.
Rows:
- 502 synthesized before the head;
- an error after the head calls `fail`, not `end`;
- gzip only when accepted;
- each `body()` is awaited before the next upstream read;
- a `"dropped"` outcome aborts the upstream;
- `abortHttpStreams` aborts in-flight runs;
- a request body is forwarded as bytes.

**`bridge/tests/tunnel-manager-ws-order.test.ts`: REWRITE** against `serveWs` with a fake `TunnelWsPeer`.
Rows:
- sink data sent while CONNECTING is buffered and flushed in order;
- upstream messages then close reach the peer as sends, then `close`;
- `"dropped"` releases the upstream with 1001;
- an oversize upstream message closes with 1009;
- `stop()` closes every peer with 1001.

**`bridge/tests/tunnel-manager-ws-subprotocol.test.ts`** is retargeted from `sendTunnel`/`onWsOpen`/`onWsClose`
to `serveWs`/`sink.closed`. Its assertions keep their meaning.

**`bridge/tests/tunnel-manager-preview-url.test.ts`** only drops the `sendTunnel` option.

**DELETE:**
- `bridge/tests/tunnel-manager-outbox.test.ts`;
- `bridge/tests/relay-client-tunnel-send.test.ts`.

**`bridge/tests/tunnel-protocol.test.ts`: REWRITE.**
- `TunnelHttpRequest` accepts `bodyLength` (default 0, rejects a negative) and strips a legacy `body`.
- `TunnelHttpHead`/`TunnelHttpEnd` parse and default `checkoutId`.
- The `parseTunnelMessage` rows go.

**`bridge/tests/localhost-fetch.test.ts`** moves to the byte shape of `TunnelBodySlice`, and adds a byte-exact
binary round trip.

**`bridge/tests/stream-mux.test.ts`:**
- the `sendTunnel` rows (`:118-163`) become `tunnelBinding` rows:
  - `mayDeliverTo` false with the switch off;
  - a stale device is refused while a modern one passes;
  - an evicted peer and a detached entry both give false;
  - `tunnels()` re-resolves.
- `:287` becomes "a `tunnel:http-request` on a project stream is dropped and dispatches nothing", plus
  `tunnelBinding(...).refusalFor` refusing the incapable device.

**`bridge/tests/remote-access-gate.test.ts`:**
- `:281` becomes `core.tunnelStreams.admit` answering `NOT_ALLOWED` while the switch is off and `ok` once it
  is on;
- `:480`/`:548` become `serveHttp` runs with a fake exchange that `abortTunnelStreams()` aborts, with no `end`
  written;
- the `StreamHandle` literals drop `sendTunnel`.

**`bridge/tests/agent-core-checkout-routing.test.ts` `:651`:** `admit` refuses `UPDATE_REQUIRED` for a
non-routing peer while isolated sessions exist, and `NOT_ALLOWED` for an unknown checkout. A routing peer
gets the checkout runtime's own manager.

**`bridge/tests/handshake-pull.test.ts` `:89`/`:157`:** both rows become "a `tunnel:http-request` on the
session stream after establishment reaches no handler". The `onTunnelMessage` assignments go.

**`bridge/tests/relay-client-credit-window.test.ts` and `bridge/tests/native-session-send-scheduler.test.ts`:**
- `client.sendTunnel(tunnelChunk(id))` becomes `(client as any).sendAppEnvelope(CONTROL_STREAM_ID, previewFrame(id), "preview")`;
- `previewFrame` is any object with `type: "preview:test"`;
- the scheduler assertions do not change.

**`StreamHandle` literals: drop `sendTunnel` only.** That covers `control-plane-start`, `host-promotion`,
`host-server`, `pause-streams`, `project-core`, `push/push-multi-device-targeting`,
`push/push-restart-targeting` and `relay-promotion`.

**`bridge/tests/native-host-connection.test.ts`:** assert the handler table has all three kinds, and that
`retirePeer` drops the peer from both registries.

**`packages/antgrid-wire/tests/stream-open.test.ts`:** add the new constants, and
`encodeTunnelDataRecord`/`decodeTunnelRecord`:
- the round trip for each tag;
- 0x7B detection;
- `null` on an empty record or an unknown tag;
- `RangeError` over the cap.

**`packages/antgrid-wire/tests/peer-transport-vectors.test.ts`:** assert `streamOpen.tunnelRecords` equals the
wire constants, and `streamOpen.terminalRecords` too, which nothing checked after A2.

**`bridge/tests/stream-dispatch.test.ts`: no edit.** It builds its own handler tables.

### dart+app

**NEW `packages/antgrid_relay_client/test/tunnel_stream_test.dart`.** It uses a fake `MultiStreamPeerLink`,
written in this file after `terminal_attachment_test.dart`'s `_FakeMultiStreamLink`, not imported from it.
Rows:
- the open frame, then the head with `bodyLength` stamped, then body records of ≤ 262144 bytes tagged `0x00`;
- a refusal fails `REFUSED` and carries the refusal;
- head, body, then end: the body completes and `finish()` is called;
- records ending after the head without an end record give `TRUNCATED`;
- data before the head gives `PROTOCOL` and a reset;
- a `backpressured` send gives `SEND_FAILED`, a reset and no `finish`;
- a gzip record is passed through with `gzip: true`;
- `cancel()` while open resets the send half, keeps draining, and releases the slot only when `records` are
  done;
- the 129th concurrent open **waits**, and opens when one releases;
- `cancel()` while waiting never opens;
- disposing the session fails waiters with `TRANSPORT_CLOSED`;
- the socket-path default gives `NOT_SUPPORTED`;
- WS: frames in order; `close()` writes `tunnel:ws-close` after queued frames, then `finish`; the peer's close
  record surfaces its code and reason in `done`; a peer FIN without a close gives
  `TunnelWsClosedByPeer(null, null)`; an oversize send resets.

**NEW `packages/antgrid_relay_client/test/local_transport_tunnel_test.dart`:** `LocalTransport.openTunnelHttp`
and `openTunnelWs` fail `NOT_SUPPORTED` and write nothing to the socket (the D2 trap guard).

**`packages/antgrid_peer_transport/test/peer_transport_vectors_test.dart`:** check `streamOpen.tunnelRecords`
and `streamOpen.terminalRecords` against the Dart constants.

**`app/test/services/preview_service_test.dart`:**
- **Delete** the `seq`/`chunks`/lost-head/re-key/duplicate-start/reestablish rows, which are the `:348–:870`
  tunnel-frame rows.
- **Add:**
  - `proxyRequest` opens an exchange whose head carries `acceptEncodings`, `checkoutId` and no body;
  - a POST's bytes reach `openTunnelHttp.body` intact;
  - a head timeout cancels the exchange;
  - a body idle timeout cancels it;
  - the browser cancelling the body cancels it;
  - `TRUNCATED` surfaces as `TunnelStreamException`;
  - a gzip record is inflated;
  - `dispose` cancels every live exchange.
- **WS rows** move onto `FakeTunnelWsChannel`: ordering, close-code forwarding, the queue ceilings (kept), and
  `onDone` → `close()`.

**`app/test/services/tunnel_body_test.dart`** moves to `decodeTunnelBody`.

**`app/test/models/preview_models_test.dart`:**
- `toHeadJson` has no body;
- `acceptEncodings` defaults to `['gzip']`;
- the deleted message classes' rows go.

**`app/test/services/preview_proxy_server_test.dart`:** the body is bytes, and a binary POST round-trips.

**`app/test/services/preview_proxy_server_ws_test.dart` and `app/test/project/preview_channel_routing_test.dart`:**
verify only. Edit only if red. The routing test's `tunnel:http-chunk` sample must still classify as ignored
once its parser case is gone; if it does not, swap in another type that has no parser.

### evals

**`evals/tests/gate-tunnel-streaming.test.ts`: REWRITE**, using §5's helpers and a local upstream server:
1. A 6 MiB body crosses intact on its own stream while a control verb is answered on the session stream.
2. After `pauseReading()` mid-body, the bridge neither resets the stream nor retires the connection. A control
   verb is still answered, and `resumeReading()` completes the body intact.
3. **A7 cancel.** The upstream sends its head and 64 KiB, then stalls. The app side `cancel()`s:
   - `ended` settles `"truncated"` within 5 s;
   - the upstream server observes its request socket closed within 5 s;
   - a fresh request on a new stream succeeds;
   - the connection is alive.
4. **Stream cap.** 128 requests are held open against a stalling upstream:
   - the 129th open gets `stream:refused` `CAP_EXCEEDED`;
   - a control verb is answered;
   - after one `cancel()`, a new open succeeds.
5. Refusals in-band:
   - an uncatalogued project is `NOT_ALLOWED`;
   - a head whose `requestId` differs is `INVALID`;
   - a `content-length` that disagrees with `bodyLength` is `INVALID`, and the upstream sees no request.
6. **WS close order.** The upstream sends 50 messages, then closes with 4001 "bye". The client sees all 50 in
   order, then the close record with 4001 and "bye", then the end.
7. **WS toward the upstream.** Text and binary frames arrive upstream in order, and `close(1000)` reaches the
   upstream as a close.
8. A 1 MiB binary POST body is echoed back byte-exact.

**`evals/tests/sealed-preview-http.test.ts`:** its two rows move onto `openTunnelHttpStream(...).response()`.
The `TUNNEL_CHUNK_BYTES` import becomes `TUNNEL_BODY_SLICE_BYTES`, and the header comment is rewritten.

**`evals/fixtures/peer-transport-vectors.json`:** add `streamOpen.tunnelRecords` only (§2).

**No eval is deleted.** `gate-stream-admission`, `gate-terminal-streams` and `gate-terminal-frames` are
unedited.

### Gate (controller, once, after integration)

- `ALL`, `EVALS` and `INTEROP`, as `stage-A-waves.md` §3 defines them. `qualify:iroh-interop` is unchanged:
  its probe still opens a project-kind stream, which is still `NOT_ALLOWED`.
- `bun run --filter antgrid-wire gen:peer-vectors`, then `git diff` on the fixture must show only the
  `tunnelRecords` addition.
- One `flutter analyze` run, from the controller only.
- Known bridge red: 6 stale-runId failures (index-hook-subcommand ×1, plugin/antigravity-post-title ×3,
  plugin/opencode-notify ×2), plus the git-branches stash-pop and git-sync already-up-to-date timeouts under
  load.
- `gate-vectors.test.ts`'s git-clean guard is red on the uncommitted fixture until the wave commit.

---

## 7. Call sites found by grep (rename and delete sweep)

The pattern is `tunnel:http|tunnel:ws|TunnelHttp|TunnelWs|parseTunnelMessage|isTunnelMessage|sendTunnel|onTunnel|setPlainHook|handleTunnelMessage|abortTunnelStreams|TUNNEL_GZIP_ENCODING|TUNNEL_CHUNK|decodeTunnelSlice|TunnelBodySlice|encodeChunk|singleSlice|onTunnelMessage|handleUndeliverableTunnel|waitForTunnelResponse|kTunnelGzipEncoding|tunnel-reestablish|_WsOutboundQueue|TunnelStreamException|tunnel-http|tunnel-ws`
(`git grep`, excluding `docs/iroh-reduction/`). Every hit is in §8.

| Symbol | Hits | Owner and action |
|---|---|---|
| `sendTunnel` | `stream-mux.ts`, `peer-session-owner.ts`, `host-server.ts`, `project-core.ts`, `agent-core.ts` (TunnelManager options), `tunnel-manager.ts`, `send-scheduler.ts` (comment); 18 bridge test files | bridge-src deletes it from src; bridge-tests covers every test (§6) |
| `onTunnel` / `onTunnelMessage` | `stream-mux.ts`, `peer-session-owner.ts`, `host-server.ts:845`, `project-core.ts:613`; `stream-mux.test.ts`, `handshake-pull.test.ts`, `relay-client-tunnel-send.test.ts` | delete |
| `setPlainHook` / `handleTunnelMessage` | `agent-core.ts`, `project-core.ts` (`:616`, `:728`, `:768`); `agent-core-checkout-routing.test.ts`, `remote-access-gate.test.ts` | delete; tests retarget to `tunnelStreams.admit` / `serveHttp` |
| `parseTunnelMessage` / `isTunnelMessage` | `tunnel-protocol.ts`, `stream-mux.ts`, `peer-session-owner.ts`, `agent-core.ts`; `tunnel-protocol.test.ts` | delete |
| `TunnelHttpStart` / `Chunk` / `Cancel`, `TunnelWsData` | `tunnel-protocol.ts`, `tunnel-manager.ts`; `tunnel-protocol.test.ts` | delete; `TunnelHttpHead` is new |
| `TUNNEL_CHUNK_BYTES` | `tunnel-protocol.ts`, `localhost-fetch.ts`, `evals/tests/sealed-preview-http.test.ts` | rename to `TUNNEL_BODY_SLICE_BYTES` |
| `TUNNEL_GZIP_ENCODING` | `tunnel-protocol.ts`, `localhost-fetch.ts`, `tunnel-manager.ts`, `evals/helpers/relay-client.ts` | value becomes `"gzip"`; the evals helper stops importing it |
| `TunnelBodySlice` / `encodeChunk` / `singleSlice` | `localhost-fetch.ts`, `tunnel-manager.ts`; `localhost-fetch.test.ts`, `tunnel-manager-stream.test.ts` | reshape (§3.1) |
| `abortTunnelStreams` | `agent-core.ts`, `project-core.ts` | **kept**, same callers |
| `handleUndeliverableTunnel` | `peer-session-owner.ts` | delete |
| `tunnel:*` in `BODY_REDACTED_MESSAGE_TYPES` | `protocol.ts:3058-3061` | bridge-src (§3.5) |
| `waitForTunnelResponse` / `TunnelHttpResult` / `decodeTunnelSlice` (TS) | `evals/helpers/relay-client.ts`, `sealed-preview-http.test.ts`, `gate-tunnel-streaming.test.ts` | evals (§5) |
| Dart tunnel message classes / `decodeTunnelSlice` / `kTunnelGzipEncoding` | `preview_models.dart`, `ab_message.dart`, `preview_service.dart`, `preview_proxy_server.dart`, `tunnel_body.dart`, `project_message_classification.dart`; the five app tests | dart+app |
| `AgentTransport` implementers | `BufferedAgentTransport` (and its subclasses `LocalTransport`, `StreamTransport`, `DemoTransport`, `_TestTransport`, `_OutcomeTransport`), `FakeAgentTransport` | dart+app edits only `BufferedAgentTransport`, `StreamTransport` and `FakeAgentTransport`; the rest inherit |
| `tunnel-http` / `tunnel-ws` open kinds | `stream-open.ts`, `stream_open.dart`, vectors fixture/generator/tests, `stream-dispatch.test.ts` | unchanged, except the `tunnelRecords` fixture addition |
| Prose describing start/chunk/end or `sendTunnel` | `bridge/CLAUDE.md` (`:80`, `:88`), `app/CLAUDE.md` (`:24`, `:64`), `docs/architecture.md` (`:26`, preview tunneling section), `bridge/requirements.md` (`:307-314`), `docs/protocol/peer-session.md` (`:65`) | bridge-src owns the bridge/doc files; dart+app owns `app/CLAUDE.md` |
| `tunnel:http-response` as a generic sample | `packages/antgrid_relay_client/test/machine_session_flow_control_test.dart` | **no edit** (it is an opaque string there) |
| `docs/iroh-transport-reduction-plan.md` | planning record | **no edit** |

---

## 8. File ownership (disjoint and complete)

| File | Part | Change |
|---|---|---|
| `packages/antgrid-wire/src/stream-open.ts` | bridge-src | §2 constants, §2.1 helpers |
| `packages/antgrid-wire/src/index.ts` | bridge-src | named exports of the §2/§2.1 additions |
| `packages/antgrid-wire/scripts/gen-peer-transport-vectors.ts` | bridge-src | `streamOpen.tunnelRecords` |
| `bridge/src/tunnel-protocol.ts` | bridge-src | §1.2, §2 |
| `bridge/src/localhost-fetch.ts` | bridge-src | §3.1 |
| `bridge/src/tunnel-manager.ts` | bridge-src | §3.2 |
| `bridge/src/peer/tunnel-streams.ts` (NEW) | bridge-src | §3.3 |
| `bridge/src/stream-mux.ts` | bridge-src | §3.4 |
| `bridge/src/peer-session-owner.ts` | bridge-src | §3.4 |
| `bridge/src/peer/native-host-connection.ts` | bridge-src | §3.4 |
| `bridge/src/send-scheduler.ts` | bridge-src | comment only (§3.4) |
| `bridge/src/agent-core.ts` | bridge-src | §3.5 |
| `bridge/src/project-core.ts` | bridge-src | §3.5 |
| `bridge/src/host-server.ts` | bridge-src | §3.5 |
| `bridge/src/protocol.ts` | bridge-src | `BODY_REDACTED_MESSAGE_TYPES` only |
| `docs/protocol/peer-session.md` | bridge-src | new "Tunnel streams" subsection: the record table (§1.1), first-record rules, the end record, cancel, caps pointer |
| `docs/architecture.md` | bridge-src | preview-channel/tunnel sentences |
| `bridge/requirements.md` | bridge-src | tunnel message table (`:307-314`) |
| `bridge/CLAUDE.md` | bridge-src | the `tunnel-manager.ts` and `stream-mux.ts` bullets |
| `bridge/tests/tunnel-streams.test.ts` (NEW) | bridge-tests | §6 |
| `bridge/tests/tunnel-manager-stream.test.ts` | bridge-tests | rewrite |
| `bridge/tests/tunnel-manager-ws-order.test.ts` | bridge-tests | rewrite |
| `bridge/tests/tunnel-manager-ws-subprotocol.test.ts` | bridge-tests | retarget |
| `bridge/tests/tunnel-manager-preview-url.test.ts` | bridge-tests | drop option |
| `bridge/tests/tunnel-manager-outbox.test.ts` | bridge-tests | DELETE |
| `bridge/tests/relay-client-tunnel-send.test.ts` | bridge-tests | DELETE |
| `bridge/tests/tunnel-protocol.test.ts` | bridge-tests | rewrite |
| `bridge/tests/localhost-fetch.test.ts` | bridge-tests | byte shape |
| `bridge/tests/stream-mux.test.ts` | bridge-tests | §6 |
| `bridge/tests/remote-access-gate.test.ts` | bridge-tests | §6 |
| `bridge/tests/agent-core-checkout-routing.test.ts` | bridge-tests | §6 |
| `bridge/tests/handshake-pull.test.ts` | bridge-tests | §6 |
| `bridge/tests/relay-client-credit-window.test.ts` | bridge-tests | §6 |
| `bridge/tests/native-session-send-scheduler.test.ts` | bridge-tests | §6 |
| `bridge/tests/native-host-connection.test.ts` | bridge-tests | §6 |
| `bridge/tests/control-plane-start.test.ts` | bridge-tests | literal only |
| `bridge/tests/host-promotion.test.ts` | bridge-tests | literal only |
| `bridge/tests/host-server.test.ts` | bridge-tests | literal only |
| `bridge/tests/pause-streams.test.ts` | bridge-tests | literal only |
| `bridge/tests/project-core.test.ts` | bridge-tests | literal only |
| `bridge/tests/push/push-multi-device-targeting.test.ts` | bridge-tests | literal only |
| `bridge/tests/push/push-restart-targeting.test.ts` | bridge-tests | literal only |
| `bridge/tests/relay-promotion.test.ts` | bridge-tests | literal only |
| `packages/antgrid-wire/tests/stream-open.test.ts` | bridge-tests | §6 |
| `packages/antgrid-wire/tests/peer-transport-vectors.test.ts` | bridge-tests | §6 |
| `packages/antgrid_relay_client/lib/src/models/stream_open.dart` | dart+app | §2 Dart constants |
| `packages/antgrid_relay_client/lib/src/tunnel_stream.dart` (NEW) | dart+app | §4.1 |
| `packages/antgrid_relay_client/lib/antgrid_relay_client.dart` | dart+app | export `tunnel_stream.dart` |
| `packages/antgrid_relay_client/lib/src/agent_transport.dart` | dart+app | §4.2 |
| `packages/antgrid_relay_client/lib/src/buffered_agent_transport.dart` | dart+app | §4.2 |
| `packages/antgrid_relay_client/lib/src/machine_session.dart` | dart+app | §4.3 |
| `packages/antgrid_relay_client/test/tunnel_stream_test.dart` (NEW) | dart+app | §6 |
| `packages/antgrid_relay_client/test/local_transport_tunnel_test.dart` (NEW) | dart+app | §6 |
| `packages/antgrid_peer_transport/test/peer_transport_vectors_test.dart` | dart+app | §6 |
| `app/lib/services/preview_service.dart` | dart+app | §4.4 |
| `app/lib/services/preview_proxy_server.dart` | dart+app | §4.4 |
| `app/lib/services/tunnel_body.dart` | dart+app | §4.4 |
| `app/lib/models/preview_models.dart` | dart+app | §4.4 |
| `app/lib/models/ab_message.dart` | dart+app | remove the five tunnel cases |
| `app/lib/project/project_message_classification.dart` | dart+app | §4.4 |
| `app/lib/test_helpers/fake_agent_transport.dart` | dart+app | §4.2 |
| `app/lib/demo/demo_transport.dart` | dart+app | verify only (inherits `NOT_SUPPORTED`) |
| `app/CLAUDE.md` | dart+app | `:24` PreviewService sentence; `:64` `kUnroutedInboundTypes` clause and the `kTunnelGzipEncoding` value |
| `app/test/services/preview_service_test.dart` | dart+app | §6 |
| `app/test/services/tunnel_body_test.dart` | dart+app | §6 |
| `app/test/models/preview_models_test.dart` | dart+app | §6 |
| `app/test/services/preview_proxy_server_test.dart` | dart+app | §6 |
| `app/test/services/preview_proxy_server_ws_test.dart` | dart+app | verify only |
| `app/test/project/preview_channel_routing_test.dart` | dart+app | verify only; edit only if red |
| `evals/helpers/relay-client.ts` | evals | §5 |
| `evals/tests/gate-tunnel-streaming.test.ts` | evals | rewrite (§6) |
| `evals/tests/sealed-preview-http.test.ts` | evals | §6 |
| `evals/fixtures/peer-transport-vectors.json` | evals | `streamOpen.tunnelRecords` only |

These files are explicitly **not touched** in A3:
- `bridge/src/peer/stream-dispatch.ts`, `bridge/src/peer/stream-records.ts` and `bridge/src/peer/terminal-streams.ts`
- `bridge/src/message-bus.ts`, `bridge/src/local-listener.ts` and all loopback code (D2)
- `bridge/tests/test-peer-session-owner.ts`, `bridge/tests/stream-dispatch.test.ts` and `bridge/tests/terminal-streams.test.ts`
- `packages/antgrid_relay_client/lib/src/local_transport.dart` (it inherits), `peer_link.dart`,
  `terminal_attachment.dart`, `connection_handshake.dart`, `test/support/fake_live_relay.dart` and
  `test/machine_session_flow_control_test.dart`
- `packages/antgrid_peer_transport/lib/**`
- `packages/antgrid_eval_client/**` and `evals/helpers/dart-app-client.ts`
- `evals/support/**`, `gate-stream-admission.test.ts`, `gate-terminal-streams.test.ts` and `gate-terminal-frames.test.ts`
- `bridge/scripts/**` and `docs/iroh-transport-reduction-plan.md`

`docs/iroh-reduction/ledger.md` is updated by the controller at the wave commit and belongs to no part.

---

## 9. Deviations from the spec, and open items

- **D-1: an explicit end record.** The spec says "FIN means end". Dart's `records` closes the same way on FIN
  and on reset (D4), so without `tunnel:http-end` the app could not tell a complete body from one the bridge
  reset after an upstream error. That is the truncation trap in its purest form. FIN still follows the end
  record, and a reset still means an error.
- **D-2: no loopback implementation beyond `NOT_SUPPORTED`.** D2 asks every new app stream API to have a
  `LocalTransport` implementation. For tunnels that implementation is a loud, immediate refusal, because
  `preview_service.dart` never tunnels in local mode (`_open`'s `isLocal` branch). The new
  `local_transport_tunnel_test.dart` pins that it writes nothing to the socket.
- **D-3: the legacy session-stream tunnel is removed, not kept beside the streams.** Unlike A2's D-3, there is
  no fallback. An A2 app build cannot preview against an A3 bridge, and the reverse is also true. That
  mismatch is the pre-release flag day A1 already took with the ALPN bump.
- **D-4: no GET retry on reconnect.** The spec deletes the lost-head retry. `_onReestablished`'s re-send goes
  with it, because a stream's head cannot be lost without the stream ending. An in-flight request across a
  reconnect fails, and the WebView's own reload recovers.
- **D-5: an over-cap tunnel open waits in the app instead of failing.** Terminal attachments fail locally at
  their cap (A2). Tunnels queue FIFO at 128, because a page load's parallelism is not the user's error.
  `cancel()` and the head timeout bound the wait.
- **D-6: the remote-access switch now retires the connection for an open WS.** Before A3, a `"gated"` WS frame
  was dropped and the tunnel kept. On a stream, the writer's `authorized()` includes the switch (A0a), so
  turning it off ends every stream with the connection. The page's socket closes and reconnects later. This
  follows from the A0a writer contract and is not a new choice.
- **D-7: `checkoutId` rides the head, not the open frame.** The A0b open schemas are frozen and carry no
  `checkoutId`, so checkout resolution and the `UPDATE_REQUIRED` gate run when the head arrives (§3.3 step 4),
  still in-band.
- **D-8: the fixture grows**, gaining `streamOpen.tunnelRecords`. Both vector tests now also check A2's
  `terminalRecords`, which nothing consumed.
- **Open: `abortTunnelStreams` scope.** `onPeerOnline`/`onPeerOffline` abort every HTTP run on the core, not
  just the departing peer's. That is unchanged from before A3, and the spec keeps it on session lifecycle.
  A second phone establishing therefore still aborts the first phone's in-flight preview loads. It becomes
  per-peer once A4's per-peer project streams exist.
- **Open: slot accounting while the app lingers.** This is as A2's open item: a tunnel slot is freed at
  unbind, before the app's FIN, so a misbehaving app can hold QUIC streams beyond 128, but never beyond the
  256 bidi limit.
- **Integration: a non-empty body is always at least one body record.** The legacy protocol folded a
  one-slice body into its start frame. On a stream the head record never carries body bytes, so the small
  row of `sealed-preview-http.test.ts` expects exactly one `0x00` record before `tunnel:http-end`, not zero.
- **Integration: rows added after the parallel pass.** `tunnel-manager-stream.test.ts` gained the §6 rows
  "a request body is forwarded as bytes" and "gzip only when accepted". `tunnel-manager-ws-order.test.ts`
  gained "upstream messages then close reach the peer as sends, then `close`". The dropped legacy rows
  (pre-open TTL, duplicate-requestId joining, cross-tunnel interleave, replay pacing) test mechanisms A3
  deletes. Their replacements are the registry's duplicate refusal and cap rows in `tunnel-streams.test.ts`.
- **Integration: line references in §3–§8 drifted from the tree** while the four parts ran. Locate each edit
  site by symbol, not by the line numbers quoted here.
