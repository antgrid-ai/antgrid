# Stage A, wave A7: raw upload streams and raw tunnel HTTP bodies

This is the frozen contract for four parallel implementers: **bridge-src**, **bridge-tests**, **dart+app**
and **evals**. Each part builds against the names and shapes below. Nobody may rename or reshape anything
pinned here without the controller's say. If your part needs something this file does not provide, report it
as `outOfScopeNeeds`. Do not invent it.

A7 deletes the last transport chunking done at the app layer on the native path:
- the remote `file:upload-start/ready/chunk/ack/done/result` exchange (512 KiB base64 chunks with stop-and-wait
  acks) is replaced by one new stream kind, `upload`;
- tunnel-http bodies become raw bytes in both directions. The tag byte, per-slice gzip and the
  `tunnel:http-end` record all go.

Sources:
- `stage-A-waves.md` §1.1 ("Binding constraints") and its traps;
- the owner decisions in `ledger.md` (D2 loopback unchanged, D3 overflow resets one stream, D4 in-band refusal +
  FIN, D7 caps);
- the A3 contract (tunnel registry, admission order) and the A5 contract (seams, ownership pattern);
- the Stage A follow-up at `848df2f2` (per-record authorization, netwatch stream tags).

HEAD at authoring time is `e46f0b1f`. ALPN stays `antgrid/peer/2` and `FRAME_VERSION` stays `0x04`: Stages
B and A ship as one release that was never published, so there is no older peer to negotiate with.

Evidence labels: **EXECUTED** means I ran it in this session. **READ** means I read the source and did not
run it.

## 0. Rules for every part

- Edit only the files your part owns (§10). Report anything else in `outOfScopeNeeds`.
- Never `git stash`, `checkout`, `reset` or `restore`.
- Bun tests per workspace only (`bun run --filter <name> test`), never bare `bun test` at the root. Send
  full-suite runs to a file and grep it for `(fail)`.
- CLAUDE.md applies:
  - comments say WHY and carry no change narration;
  - no comment may mention "A7", "was", "no longer", "used to" or the deleted gzip/tag/end-record path;
  - the "Adding a message type" checklist runs in reverse for anything removed. A7 removes **no `AbMessage`
    type**, though. `tunnel:http-end` (`TunnelHttpEnd`) was never in `AbMessageSchema`/`KNOWN_TYPES`; it was
    a tunnel-stream record (`tunnel-protocol.ts`). The six `file:upload-*` types stay in `AbMessageSchema`,
    `KNOWN_TYPES` and `CHECKOUT_VARIABLE_MESSAGE_TYPES`, and in the Dart `kCheckoutVariableMessageTypes`,
    because loopback still speaks them (D2).
- Binding constraints (spec §1.1), unchanged:
  - every bridge write is at most 256 KiB (`STREAM_RECORD_SLICE_BYTES`), and so is every Dart write
    (`kPeerStreamSliceBytes`). That covers raw writes too;
  - the bridge calls `setPriority` once, before the first write (`StreamRecordWriter` already does this);
  - never await `stopped()` or `receivedReset()`;
  - `authorized()` is checked per record on write, per record on read and, new in A7, **after every raw
    read**;
  - a Dart stream is invisible until its first write, so the open frame goes out in the same call as
    `openBi` (`PeerStreamOpener`, unchanged);
  - a dropped noq `SendStream` FINs, so **every Dart error path calls `reset()` explicitly**. A7 has a new trap
    here: an upload or a request body abandoned without a reset reaches the bridge as a clean FIN. For an
    upload that FIN produces an `INCOMPLETE` result. For a tunnel request body it produces a request that is
    too short.
- Security invariants, none weakened. bridge-tests pins each one on the new upload path (§9.1):
  - `remoteFrameAllowed` inbound (the upload admission re-checks it);
  - `mayDeliver`/`mayDeliverTo` on every send, including the upload result record;
  - `seenProjects` (`projectCataloged`) + `isSafeProjectId` bound the projectId an upload open may name;
  - `mayAcceptFrom` at open (`refusalFor`), and `checkoutRouting` via `peerCanRouteCheckouts`;
  - **a stream open never opens or promotes a core.** `uploadBinding(projectId)` is a lookup over already
    attached entries, exactly like `tunnelBinding`. Preparing an isolated checkout's runtime inside an open
    core is allowed, as the bus path already does it (`prepareCheckoutRuntime`); starting a core is not.
- Known red that is not yours:
  - the bridge suite's six stale-runId fixtures: `index-hook-subcommand` ×1, `plugin/antigravity-post-title`
    ×3 and `plugin/opencode-notify` ×2;
  - under load, the git-branches "stash pop" test and the git-sync "already up to date" test can time out.
  - Anything else red is real.
- **Proving a test.** Every new test must fail on the pre-A7 code. The wire change alone is not the proof: a
  tunnel test fails against old code merely because the framing changed. So each new test is also proven by
  breaking the specific mechanism it guards and then restoring it. Example: delete the oversize check, watch
  the oversize test fail, restore it. Each implementer lists the break they used, per test, in their report.

## 1. Decisions A7 makes

- **D-A7-1. Gzip is dropped from the tunnel.** Bun's `fetch` already decompresses the origin body
  transparently: `decompress` defaults to true. EXECUTED `scratchpad/probe3.ts` on Bun 1.3.14:
  - a gzip origin body of 308 bytes arrived as 60000 plaintext bytes;
  - the `content-encoding: gzip` and `content-length: 308` headers were still attached;
  - so `fetchLocalhost` must keep stripping them, which it does today.

  Re-compressing each slice was the only reason for the tag byte, `acceptEncodings`, `encodeChunk`, the
  precompressed-type tables and the Dart `decodeTunnelBody`. All of them are deleted. Only the tunnel's own
  gzip layer is dropped: the origin's own compression is still decoded by fetch, as today.
- **D-A7-2. `tunnel:http-end` is deleted.** Both ends can now tell a FIN from a reset:
  - Bridge (READ, `@number0/iroh` 1.1.0 `index.d.ts`): `RecvStream.read(sizeLimit)` resolves `[]` at FIN
    and rejects on reset. The Rust side maps `None` to 0.
  - Dart (READ, iroh_quic 1.0.3): `RecvStream.read(maxLen)` resolves `null` at FIN and throws
    `IrohStreamException` on reset.
  - `readExact` cannot make this distinction on either side, because it rejects on both.

  So a response ends with a bare FIN, and a reset after the head is an aborted response.
- **D-A7-3. `bodyLength` delimits the request body.** The app keeps its tunnel-http send half **open**
  until the response ends, so that a reset is still the cancel. A QUIC reset after `finish()` is unreliable,
  and Dart `stop()` queues behind a pending read on the same mutex, so a FIN'd send half would leave the app
  no way to cancel. `bodyLength` in the head (already present, `.default(0)`) is therefore the only body
  delimiter. After it, the app sends nothing until it has read the response's end:
  - a clean response FIN, with the whole body already written: `finish()`;
  - anything else: `reset()`.
- **D-A7-4. A browser body with no Content-Length is the one body the app buffers.** Chunked uploads from a
  WebView carry no length, and HTTP/1.1 browsers do not stream request bodies anyway (Chromium refuses to;
  Safari does not support it). The buffer is capped at `kStreamTunnelRequestBodyMaxBytes`, and over the cap
  the proxy answers 413 itself. A body that does carry a Content-Length is streamed and never buffered whole.
- **D-A7-5. The streamed request body and the scheme retry.** EXECUTED `scratchpad/probe.ts` and
  `probe2.ts` on Bun 1.3.14:
  - a `ReadableStream` body with `duplex: "half"` is streamed;
  - with a `content-length` header it goes out Content-Length-framed, and without one as
    `transfer-encoding: chunked`;
  - the origin saw its first chunk (~307 ms) while the stream was still producing;
  - a refused connection had pulled the body once before `ConnectionRefused`, and a reset one twice before
    `ECONNRESET`.

  So `fetchWithSchemeRecovery` cannot replay a body it has consumed. The source keeps a replay buffer of the
  bytes pulled by the first attempt, capped at `TUNNEL_BODY_REPLAY_MAX_BYTES` (256 KiB). A retry replays
  that buffer and then continues from the wire. Once more than the cap has been pulled the body is not
  replayable: a scheme-retryable failure then surfaces the original error (a synthesized 502) rather than
  retrying. The buffer is dropped as soon as the first attempt settles.
- **D-A7-6. The fetch head timer starts when the request body has been fully pulled** (or at fetch start
  when there is no body). Before A7 the body was fully received before `fetch` began. A 32 MiB POST over a
  slow link now legitimately takes longer than `FETCH_HEAD_TIMEOUT_MS` before the origin can answer. While
  the body is still arriving, the guard is instead a request-body idle timer: no bytes from the app for
  `FETCH_READ_IDLE_MS` errors the body with `"request body stalled"`.
- **D-A7-7. The upload result record is the existing `file:upload-result` JSON** (`createMessage`, with
  `requestId` = the open frame's `requestId` and `checkoutId` stamped). A7 adds one error code, `INCOMPLETE`.
  Per-file refusals travel as `ok:false` result records; admission refusals travel as in-band
  `stream:refused` (D4):
  - Per-file refusals: `BUSY`, `TOO_LARGE`, `INVALID_NAME`, `WRITE_FAILED`, `TIMEOUT`, `INCOMPLETE`.
  - Admission refusals: `NOT_READY`, `UPDATE_REQUIRED`, `NOT_ALLOWED`, `CAP_EXCEEDED`, `INVALID`.
- **D-A7-8. Relay-origin `file:upload-start/chunk/done` are dropped.** The socket upload types are
  loopback-only, in the same way `PREVIEW_CHANNEL_MESSAGE_TYPES` is:
  - new `LOOPBACK_UPLOAD_MESSAGE_TYPES` in `protocol.ts`, bridge-only;
  - `FileUploadManager`'s socket-path sends go to loopback only.

  No Dart mirror is added. The app only emits these types through `SocketUploads` (§6.3), which
  `StreamTransport` never uses, so there is nothing on the app side to drift against.
- **D-A7-9. `STREAM_OPEN_MAX_BYTES` stays 4096.** With `fileName` ≤ 255 and `mimeType` ≤ 127 characters and
  ids of the shape both apps mint (UUIDs and project ids), a valid upload open is under 2.5 KB. It stays
  under the limit even at the worst JSON escaping (6 bytes per control character in the name). The app
  pre-checks the lengths (§6.4), so a user's file is never refused as `INVALID`.
- **D-A7-10. Upload progress is the bytes the app has written.** A `sendRaw` future resolves only once
  `writeAll` has returned, so there is no ack.

## 2. Wire: the `upload` stream

### 2.1 Open frame

The same `[u32 BE len][UTF-8 JSON]` frame as every other kind.

```ts
// packages/antgrid-wire/src/stream-open.ts
export const STREAM_UPLOAD_MAX_FILE_NAME_LENGTH = 255;
export const STREAM_UPLOAD_MAX_MIME_TYPE_LENGTH = 127;

// One stream per file. `checkoutId` follows `TerminalStreamOpen`: absent means the main checkout.
export const UploadStreamOpen = z.strictObject({
  kind: z.literal("upload"),
  projectId: StreamId,
  checkoutId: StreamId.optional(),
  requestId: StreamId,
  fileName: z.string().min(1).max(STREAM_UPLOAD_MAX_FILE_NAME_LENGTH),
  size: z.number().int().nonnegative(),
  mimeType: z.string().min(1).max(STREAM_UPLOAD_MAX_MIME_TYPE_LENGTH).optional(),
});
export type UploadStreamOpen = z.infer<typeof UploadStreamOpen>;
// added as the last member of the StreamOpen discriminatedUnion, so StreamOpenKind gains "upload".
```

`size` is the declared byte count. Whether it exceeds `MAX_UPLOAD_BYTES` (20 MiB) is a per-file `TOO_LARGE`
result, not a schema rejection.

### 2.2 Records and ends

| Direction | Content |
|---|---|
| app → bridge | the open frame, then exactly `size` **raw** bytes (no prefix, no records), then FIN |
| bridge → app | exactly one length-prefixed JSON record, either a `stream:refused` (admission) or a `file:upload-result`, then FIN |

Bridge-side outcomes, one per stream:

| Situation | Bridge does | App sees |
|---|---|---|
| admission refused (§2.3) | `refuseStream` (in-band `stream:refused`, FIN, stop recv), as for every kind | refusal record, then end |
| per-file refusal at begin (`BUSY`/`TOO_LARGE`/`INVALID_NAME`/`WRITE_FAILED`) | result record, `finish()`, `recv.stop(STREAM_STOP_UPLOAD)` with no read outstanding | result, then end; the app stops writing and `reset()`s |
| FIN after exactly `size` bytes | rename to `<uploadId[0..8]>-<name>`, `ok:true` result, `finish()` | result, then end; the app has already FIN'd |
| FIN short of `size` | partial removed, `ok:false, error:"INCOMPLETE"` result (message `Declared N bytes, received M`), `finish()` | result |
| more than `size` bytes | partial removed, **no result**, `writer.abort()` (reset `STREAM_RESET_UPLOAD`), stop recv once the pending read settles, diagnostic `upload-stream:oversize` | `records` ends with no result → `STREAM_ENDED` |
| app reset (cancel) or connection loss | partial removed, no result, `writer.abort()` | n/a |
| inactivity (`INACTIVITY_MS`, 60 s, reset by every write) | partial removed, `TIMEOUT` result, `finish()`, stop recv once the pending read settles | result |
| a disk write fails, or the runtime stopped mid-upload | partial removed, `WRITE_FAILED` result (`Could not write to staging file` / `Upload interrupted`), `finish()`, stop recv | result |
| `authorized()` false after a read | `retirePeer(peerId, "unauthorized")`; `dropPeer` then cancels the upload (partial removed) | connection gone |
| `mayDeliverTo` false when the result would be sent | `writer.abort()`, unbind; an already renamed file is left to the sweeper | reset, no result |
| project detached, peer dropped | upload cancelled (partial removed), `writer.abort()`, unbind | reset |

Raw read size: `min(STREAM_RAW_READ_BYTES, remaining + 1)`, with `remaining = size - received`. The `+ 1`
detects an overrun without allocating a large buffer; at `remaining == 0` it is a `read(1)` that either sees
FIN or proves an overrun. `authorized()` is checked after every read before the bytes are written to disk.

### 2.3 Admission order

`UploadStreamRegistry.handler`. Steps 1-8 are synchronous and run before any read, returning a
`DispatchStreamRefusal` exactly as the tunnel `gate()` does:

1. `streamCount(peerId) >= STREAM_MAX_UPLOAD_STREAMS_PER_PEER` → `CAP_EXCEEDED` "too many uploads"
2. `!isSafeProjectId(projectId)` → `NOT_ALLOWED` "unsafe project id"
3. `!projectCataloged?.(projectId)` → `NOT_ALLOWED` "project not recognized" (absent option = fail closed)
4. `uploadBinding(projectId) === null` → `NOT_READY` "project is not attached"
5. `!binding.hasOpenStream(peerId)` → `NOT_ALLOWED` "open the project stream first"
6. `binding.refusalFor(peerId)` → `UPDATE_REQUIRED` as-is, anything else → `NOT_ALLOWED` with its message
7. `(peerId, requestId)` already bound → `INVALID` "duplicate id"
8. `binding.uploads() === null` → `NOT_ALLOWED` "uploads not available"
   → **bind** here, which takes the cap slot, then continue asynchronously. From this point refusals go
   in-band through the registry's `refuseInline` (unbind, then `refuseStream`), which is legal because no read
   has been issued yet.
9. `await server.admit(peerId, open.checkoutId ?? "main")` (§4.4) → its `refusal` in-band
10. `binding.unbound` → stop recv, return. `!authorized()` → `retirePeer(peerId, "unauthorized")`, return.
11. `manager.begin(...)`. An early result is written as in §2.2 row 2.
12. The raw loop.

The pending-open cap (`STREAM_MAX_PENDING_OPENS_PER_PEER`) and the QUIC bidi limit already count every open
in `PeerStreamAcceptor` and `PeerStreamOpener`, so an upload open counts against both with no new code.

### 2.4 Caps and codes

| Name | Value | Lives in |
|---|---|---|
| `STREAM_MAX_UPLOAD_STREAMS_PER_PEER` | 4 | `stream-open.ts`, beside the D7 caps |
| `kStreamMaxUploadStreamsPerPeer` | 4 | `stream_open.dart` |
| `STREAM_UPLOAD_BRIDGE_RECORD_MAX_BYTES` | 16_384 | `stream-open.ts` (the result record; app `maxRecordBytes`) |
| `kStreamUploadBridgeRecordMaxBytes` | 16384 | `stream_open.dart` |
| `STREAM_UPLOAD_MAX_FILE_NAME_LENGTH` / `kStreamUploadMaxFileNameLength` | 255 | both |
| `STREAM_UPLOAD_MAX_MIME_TYPE_LENGTH` / `kStreamUploadMaxMimeTypeLength` | 127 | both |
| `UPLOAD_STREAM_MAX_QUEUED_BYTES` | 65_536 | `bridge/src/peer/upload-streams.ts` |
| `STREAM_PRIORITY_UPLOAD` | -1 | `upload-streams.ts` |
| `STREAM_RESET_UPLOAD` / `STREAM_STOP_UPLOAD` | `0x1an` / `0x1bn` | `upload-streams.ts` (0x10-0x19 are taken) |
| `STREAM_RAW_READ_BYTES` | 65_536 | `bridge/src/peer/stream-records.ts` (`read(sizeLimit)` allocates `sizeLimit` per call) |
| `kPeerStreamRawReadBytes` | 65536 | `antgrid_peer_transport/lib/src/iroh_peer_link.dart` |
| `kUploadStreamSliceBytes` | 262144 | `antgrid_relay_client/lib/src/upload_stream.dart` |
| `kUploadStreamMaxQueuedBytes` | 524288 | `upload_stream.dart` |
| `kUploadResultTimeout` | 30 s | `upload_stream.dart` (after `finish()`) |
| `kSocketUploadChunkBytes` | 524288 | `upload_stream.dart` (loopback chunks, unchanged value) |

The cap comment in `stream-open.ts` states the sum invariant, which must now include uploads:
32 + 64 + 128 + 4 + 1 (session) = 229 < 256.

## 3. Wire: raw tunnel-http bodies

`tunnel-ws` is **unchanged**: tagged records with `TUNNEL_RECORD_TAG_WS_TEXT = 0x02` and
`TUNNEL_RECORD_TAG_WS_BINARY = 0x03`, whose values do not move, plus the JSON `tunnel:ws-open` and
`tunnel:ws-close` records.

| Direction | Content |
|---|---|
| app → bridge | open frame `{kind:"tunnel-http", projectId, requestId}` (unchanged); one length-prefixed JSON `tunnel:http-request` head (`TunnelHttpRequest`, unchanged except that `acceptEncodings` is deleted; `bodyLength` ≤ `STREAM_TUNNEL_REQUEST_BODY_MAX_BYTES`, default 0); then exactly `bodyLength` raw bytes; then **nothing** until the response has ended (D-A7-3), then `finish()` if the body was fully written, else `reset()` |
| bridge → app | one length-prefixed JSON record, either `stream:refused` or `tunnel:http-head` (`{type, requestId, status, headers, setCookies?, checkoutId}`, unchanged); then the response body as raw bytes; then FIN |

Head-record checks are unchanged and keep their in-band refusals: malformed → `INVALID`; `requestId`
mismatch → `INVALID`; `bodyLength` over the cap → `INVALID` "body too large", before any body byte is read and
before the upstream is contacted; a `content-length` header disagreeing with `bodyLength` → `INVALID`; then
`tunnels().admit`.

Bridge, request side (`tunnel-streams.ts`):
- `bodyLength > 0`: build a `TunnelRequestBody` (§4.5) over a `StreamRawReader`. `pull()` reads
  `min(STREAM_RAW_READ_BYTES, remaining)`, so it never over-reads the declared body. After every read:
  - `unbound` → error the body;
  - `!authorized()` → `retirePeer`;
  - `null` (FIN) or a rejection before `remaining` reaches 0 → **error** the `ReadableStream` (never `close`
    it; a closed short stream is a truncated request that looks complete), `exchangeAbort.abort()`,
    `writer.abort()`, unbind.

  At `remaining === 0`, `close()` the stream and start the cancel watcher.
- `bodyLength === 0`: `body` is `null` and the cancel watcher starts at once.
- **Cancel watcher**: one pending `raw.read(1)` for the rest of the run:
  - bytes → breach: abort the exchange, `writer.abort()`, stop recv, unbind (no in-band refusal, since the
    head may already be out);
  - `null` or a rejection before `ended` → cancel: abort the exchange, `writer.abort()`, unbind;
  - after `ended` → ignored (the app's orderly FIN or reset).
- The run ends while body bytes are still unread (the origin answered early) → `recv.stop(STREAM_STOP_TUNNEL)`
  chained on the pending read settling, never while a read is outstanding.
- Only one reader is ever active on `recv`, used in this order: `StreamRecordReader` for the head, then the
  body source, then the watcher. Switching is safe because `StreamRecordReader` reads with `readExact` only
  and never past a record's end.

Bridge, response side:
- the head is `writer.send(JSON)` as today;
- each body piece is `writer.sendRaw(bytes)`, at most `TUNNEL_BODY_SLICE_BYTES` (= 256 KiB) per piece;
- the end is `writer.finish()`;
- every send checks `mayDeliverTo` first, as today;
- an error after the head → `exchange.fail` → `writer.abort()` (reset `STREAM_RESET_TUNNEL`), **never** a FIN;
- a failure before the head is still a synthesized 502 with a text body and a FIN.

Response coalescing keeps the existing two clocks. `coalesceBody` (the renamed `chunkBody`) yields a pending
remainder once `TUNNEL_CHUNK_FLUSH_MS` (50 ms) has passed since its first byte was buffered, and never holds a
byte longer than that. SSE and long-poll bodies therefore stay live. A full 256 KiB is yielded at once.

App (§6.5):
- a reset after the head errors the body with `TunnelExchangeFailure('TRUNCATED')`, never a clean done;
- a reset or end before the head errors the head with `STREAM_ENDED`;
- the proxy lets a body error reach dart:io, so the browser sees an incomplete chunked response. This
  behaviour is unchanged.

## 4. Bridge APIs (bridge-src implements; bridge-tests and evals build against these)

### 4.1 `bridge/src/peer/stream-records.ts`

```ts
export const STREAM_RAW_READ_BYTES = 65_536;

/** The read half with the binding's `read`, which resolves `[]` at FIN and rejects on reset. */
export interface RawStreamRecv extends StreamRecv {
  read(sizeLimit: number): Promise<number[]>;
}

// StreamRecordWriter gains:
/** Raw bytes, no length prefix, through the same queue, overflow bound and per-slice authorized() check as
 *  send(). Written in STREAM_RECORD_SLICE_BYTES slices. Resolves "sent" once every slice has been written;
 *  a zero-length call resolves "sent" without writing. */
sendRaw(bytes: Uint8Array, signal?: AbortSignal): Promise<StreamSendOutcome>;

/** Raw reads off one receive half. */
export class StreamRawReader {
  constructor(stream: { recv: RawStreamRecv });
  /** `null` at FIN; rejects on reset or connection loss (rethrown as-is). `maxBytes` is clamped to
   *  [1, STREAM_RAW_READ_BYTES]. Never resolves an empty array. */
  read(maxBytes: number): Promise<Uint8Array | null>;
}
```

`stream-dispatch.ts`: `AcceptedBiStream.recv` becomes `RawStreamRecv & { stop(errorCode: bigint): Promise<void> }`.
`streamLabelOf` gains `case "upload": return { kind: open.kind, id: open.requestId };`.

### 4.2 `bridge/src/peer/upload-streams.ts` (new)

```ts
export const UPLOAD_STREAM_MAX_QUEUED_BYTES = 65_536;
export const STREAM_PRIORITY_UPLOAD = -1;
export const STREAM_RESET_UPLOAD = 0x1an;
export const STREAM_STOP_UPLOAD = 0x1bn;

export interface UploadStreamRegistryOptions {
  /** host-server `seenProjects.has`. Absent => every open is refused NOT_ALLOWED (fail closed). */
  projectCataloged?: (projectId: string) => boolean;
  /** `ProjectStreamRegistry.uploadBinding`. Lookup only: never opens or promotes a core. */
  uploadBinding: (projectId: string) => UploadProjectBinding | null;
  retirePeer: (peerId: string, reason: "unauthorized") => void;
  diagnostic?: (type: string, detail: Record<string, unknown>,
    stream?: { kind: NetwatchStreamKind; id: string }) => void;
}

export class UploadStreamRegistry {
  constructor(opts: UploadStreamRegistryOptions);
  readonly handler: StreamHandler<UploadStreamOpen>;
  streamCount(peerId: string): number;
  projectDetached(projectId: string): void;
  dropPeer(peerId: string): void;
}
```

Diagnostic types, each tagged `{ kind: "upload", id: requestId }`: `upload-stream:oversize`,
`upload-stream:cancelled`, `upload-stream:result` (detail `{ ok, error? }`).

### 4.3 `bridge/src/file-upload.ts`

```ts
export type UploadErrorCode = "TOO_LARGE" | "INVALID_NAME" | "WRITE_FAILED" | "UPLOAD_NOT_FOUND"
  | "BAD_SEQUENCE" | "SIZE_MISMATCH" | "TIMEOUT" | "BUSY" | "INCOMPLETE";
export interface UploadResultFields {
  uploadId?: string; ok: boolean; path?: string; relPath?: string; mimeType?: string;
  error?: UploadErrorCode; message?: string;
}
export type StreamUploadWrite = "ok" | "oversize" | "failed";
export interface StreamUpload {
  readonly uploadId: string;
  /** "oversize": partial removed, onResult NOT called (the caller resets). "failed": WRITE_FAILED already
   *  reported through onResult, partial removed. Touches the inactivity timer. */
  write(bytes: Uint8Array): StreamUploadWrite;
  /** The app FIN'd: reports ok (rename + path/relPath/mimeType as handleDone does), INCOMPLETE, or
   *  WRITE_FAILED through onResult, exactly once. */
  end(): void;
  /** Partial removed, onResult never called. Idempotent; a no-op once a result was reported. */
  cancel(): void;
}

export type UploadAdmission =
  | { ok: false; refusal: { code: "UPDATE_REQUIRED" | "NOT_ALLOWED"; message: string } }
  | { ok: true; manager: FileUploadManager };
/** What a core exposes to the upload registry; AgentCore implements it. Never rejects. */
export interface UploadStreamServer {
  admit(peerId: string, checkoutId: string): Promise<UploadAdmission>;
}

// FileUploadManager:
constructor(opts: { projectId: string; projectPath: string; send: (msg: AbMessage) => void;
  inactivityMs?: number /* test seam, default INACTIVITY_MS */ });
begin(start: { requestId: string; fileName: string; size: number },
  onResult: (result: UploadResultFields) => void):
  { ok: true; upload: StreamUpload } | { ok: false; result: UploadResultFields };
```

`begin` shares everything with `handleStart`: the `MAX_CONCURRENT_UPLOADS` map (so a stream upload and a
loopback upload both count), `MAX_UPLOAD_BYTES`, `sanitizeUploadFileName`, the staging dir and its
`.gitignore`, `.part` naming, the inactivity timer and the sweeper. `onResult` is called at most once per
upload. It is called synchronously from `write`/`end`, or asynchronously for `TIMEOUT`, or from `stop()`
(`WRITE_FAILED` "Upload interrupted"). `stop()` still removes every partial. `handleStart`/`handleChunk`/
`handleDone` are unchanged apart from the `INCOMPLETE` code joining the union; their `send` is now
loopback-only (§4.4).

`protocol.ts`:
- the `FileUploadResultMessage.error` comment lists `INCOMPLETE`;
- `LOOPBACK_UPLOAD_MESSAGE_TYPES = new Set(["file:upload-start","file:upload-ready","file:upload-chunk",
  "file:upload-ack","file:upload-done","file:upload-result"])`, with a doc comment in the style of
  `PREVIEW_CHANNEL_MESSAGE_TYPES`: the remote path is the `upload` stream, and loopback keeps these (D2).

### 4.4 `agent-core.ts`, `project-streams.ts`, `project-core.ts`, `native-host-connection.ts`

- `agent-core.ts`:
  - The inbound handler drops a non-loopback frame whose type is in `LOOPBACK_UPLOAD_MESSAGE_TYPES`, before
    the `CHECKOUT_VARIABLE_MESSAGE_TYPES` resolution, with
    `log.warn("Dropping inbound %s: a remote app uploads on its own stream (project %s)")`.
  - Both `FileUploadManager` constructions use a loopback-only send. The per-runtime one is
    `(m) => sendAbTo({ ...m, checkoutId: runtime.checkout.id } as AbMessage, "loopback")`; the main one is
    `(m) => sendAbTo(m, "loopback")`.
  - It returns a new `uploadStreams: UploadStreamServer`, whose `admit` runs, in order:
    1. `!remoteFrameAllowed("relay")` → `NOT_ALLOWED` "mobile access is disabled"
    2. `sessions?.hasIsolatedSessions() && !peerCanRouteCheckouts(peerId)` → `UPDATE_REQUIRED` "update the app
       to open this stream"
    3. `sessions?.isCheckoutDeleting(checkoutId)` → `NOT_ALLOWED` "checkout is being deleted"
    4. `await checkoutRuntimes.resolve(checkoutId)` null → `NOT_ALLOWED` "unknown checkout"
    5. deleting again (a delete that started during the await) → `NOT_ALLOWED` "checkout is being deleted"
    6. `checkoutId !== "main"` → `await prepareCheckoutRuntime(checkout)`
    7. the checkout's runtime (`checkoutRuntimes.runtime(checkoutId)`, `mainRuntime` for main) has no
       `uploadManager` → `NOT_ALLOWED` "uploads are not available for this checkout"
    8. `{ ok: true, manager }`. Any throw is caught → `NOT_ALLOWED` "checkout lookup failed" and logged.
- `project-streams.ts`:
  ```ts
  export interface UploadProjectBinding {
    hasOpenStream(peerId: string): boolean;
    refusalFor(peerId: string): StreamRefusal | null;
    mayDeliverTo(peerId: string): boolean;
    uploads(): UploadStreamServer | null;
  }
  // AttachStreamOpts gains: uploads?: UploadStreamServer;
  // ProjectStreamRegistry gains, with tunnelBinding's exact live()/latestEntryFor shape:
  uploadBinding(projectId: string): UploadProjectBinding | null;
  ```
- `project-core.ts` passes `uploads: core.uploadStreams` beside `tunnels: core.tunnelStreams`.
- `native-host-connection.ts`:
  - constructs `UploadStreamRegistry` beside `TunnelStreamRegistry`, with the same `projectCataloged`, the
    same guarded `retirePeer`, and `diagnostic` → `recordDiagnostic` with `streamKind`/`streamId`;
  - adds `upload: this.uploadStreams.handler` to the handler table;
  - calls `uploadStreams.projectDetached(projectId)` wherever `tunnelStreams.projectDetached` is called;
  - calls `uploadStreams.dropPeer(peerId)` wherever `tunnelStreams.dropPeer` is.

### 4.5 Tunnel: `localhost-fetch.ts`, `tunnel-manager.ts`, `tunnel-protocol.ts`, `peer/tunnel-streams.ts`

```ts
// tunnel-protocol.ts
export const TUNNEL_BODY_SLICE_BYTES = 262_144;       // unchanged value; now the max raw piece
export const TUNNEL_CHUNK_FLUSH_MS = 50;              // unchanged
export const TUNNEL_BODY_REPLAY_MAX_BYTES = 262_144;  // D-A7-5
// TunnelHttpRequest loses `acceptEncodings`. Deleted: TunnelHttpEnd, TUNNEL_GZIP_ENCODING.

// localhost-fetch.ts
export interface TunnelRequestBody {
  /** The declared `bodyLength`, > 0. Sent upstream as `content-length`. */
  readonly length: number;
  /** A fresh body per fetch attempt. A second call replays what the first attempt pulled, then continues
   *  from the wire. Returns null once more than TUNNEL_BODY_REPLAY_MAX_BYTES has been pulled. */
  stream(): ReadableStream<Uint8Array> | null;
  /** Resolves once all `length` bytes have been pulled; never rejects (stays pending on failure). */
  readonly complete: Promise<void>;
}
export interface FetchLocalhostOpts {
  url: string; method?: string; headers?: Record<string, string>;
  body?: TunnelRequestBody;            // replaces Uint8Array; acceptEncodings deleted
  signal?: AbortSignal;
  headTimeoutMs?: number; readIdleMs?: number; chunkBytes?: number; flushMs?: number; maxBodyBytes?: number;
}
export interface LocalhostFetchStream {
  status: number; headers: Record<string, string>; setCookies: string[];
  /** Raw pieces, each <= chunkBytes, in read order. Single consumer; return() cancels upstream. */
  body: AsyncGenerator<Uint8Array, void, void>;   // renamed from `slices`
}
export class UpstreamBodyError extends Error {}   // kept
```

`fetchLocalhost`:
- with a body, it sends `duplex: "half"` and `content-length: String(body.length)`, dropping any
  client-supplied `content-length`/`transfer-encoding` case-insensitively;
- the head timer is armed on `body.complete` (D-A7-6);
- the second scheme attempt uses `body.stream()`, and `null` rethrows the first error.

Deleted: `encodeChunk`, `singleSlice`, `TunnelBodySlice`, `GZIP_MIN_BYTES`, `PRECOMPRESSED_CONTENT_TYPES`,
`UNCOMPRESSED_MEDIA_CONTENT_TYPES` and `isPrecompressedContentType`. `chunkBody` is renamed `coalesceBody`
and yields `Uint8Array` with no `gzip`/`last` fields. The 403/413 answers yield one text piece.

```ts
// tunnel-manager.ts
export interface TunnelHttpExchange {
  readonly peerId: string;
  readonly signal: AbortSignal;
  head(head: { status: number; headers: Record<string, string>; setCookies?: string[] }): Promise<StreamSendOutcome>;
  body(bytes: Uint8Array): Promise<StreamSendOutcome>;   // raw, <= TUNNEL_BODY_SLICE_BYTES
  end(): Promise<StreamSendOutcome>;                     // FIN only
  fail(reason: string): void;                            // reset; no-op after end()
}
serveHttp(req: TunnelHttpRequest, body: TunnelRequestBody | null, exchange: TunnelHttpExchange): Promise<void>;
```

`runHttp` keeps its structure:
- peek the first piece before the head;
- a failure before the head → synthesized 502 (`sendSynthesizedError` writes the text as one `body()`);
- a failure after it → `fail`;
- `abortHttpStreams(peerId)` is unchanged.

The loop reads until `done`, since there is no `last` flag any more.

`tunnel-streams.ts`:
- `HttpBinding` keeps `ended`;
- `sendHttpBody(binding, bytes: Uint8Array)` → `writer.sendRaw`;
- `endHttp` sets `ended`, awaits `writer.finish()` and unbinds, with no record;
- `watchHttpCancel` becomes the raw watcher described in §3;
- the request-body source is a private class in this file implementing `TunnelRequestBody`, with a pull-based
  `ReadableStream` (`highWaterMark: 0`) and the replay buffer;
- its idle timer uses the registry's `schedule` seam and the `FETCH_READ_IDLE_MS` value exported by
  `localhost-fetch.ts`;
- `TunnelStreamRegistryOptions` gains `requestBodyIdleMs?: number`, a test seam defaulting to
  `FETCH_READ_IDLE_MS`.

## 5. Wire package and vectors (bridge-src)

`packages/antgrid-wire/src/stream-open.ts` + `index.ts` exports:
- add `UploadStreamOpen`, `STREAM_MAX_UPLOAD_STREAMS_PER_PEER`, `STREAM_UPLOAD_BRIDGE_RECORD_MAX_BYTES`,
  `STREAM_UPLOAD_MAX_FILE_NAME_LENGTH` and `STREAM_UPLOAD_MAX_MIME_TYPE_LENGTH`;
- delete `TUNNEL_RECORD_TAG_BODY` and `TUNNEL_RECORD_TAG_BODY_GZIP`;
- `TunnelDataTag` becomes `typeof TUNNEL_RECORD_TAG_WS_TEXT | typeof TUNNEL_RECORD_TAG_WS_BINARY`;
- `decodeTunnelRecord` returns `null` for `0x00` and `0x01` (now unknown tags);
- `STREAM_TUNNEL_DATA_MAX_BYTES`, `STREAM_TUNNEL_RECORD_MAX_BYTES` and `STREAM_TUNNEL_REQUEST_BODY_MAX_BYTES`
  keep their values. The first two now bound WS records and the tunnel-http JSON head; their comments say so;
- the `StreamRefusedCode` comment names upload in `NOT_ALLOWED`/`CAP_EXCEEDED`.

`scripts/gen-peer-transport-vectors.ts` → regenerate `evals/fixtures/peer-transport-vectors.json` with
`bun run --filter antgrid-wire gen:peer-vectors`:
- `streamOpen.caps.maxUploadStreamsPerPeer: 4`
- `streamOpen.uploadRecords: { bridgeMaxRecordBytes: 16384, maxFileNameLength: 255, maxMimeTypeLength: 127 }`
- `streamOpen.tunnelRecords.tags: { wsText: 2, wsBinary: 3 }`, with `body`/`bodyGzip` removed
- `opens` adds:
  - `upload`: `{kind:"upload", projectId:"proj-1", requestId:"req-1", fileName:"notes.txt", size:12}`
  - `upload-with-checkout-and-mime`: `{..., checkoutId:"chk-1", mimeType:"text/plain", size:0}`
- `rejectedOpens` adds:
  - `upload-missing-size`, `upload-negative-size` (-1), `upload-fractional-size` (1.5), `upload-string-size`
    ("12");
  - `upload-empty-file-name`, `upload-overlong-file-name` (256 × "a");
  - `upload-null-mime`, `upload-empty-checkout`, `upload-extra-field` (`uploadId:"u"`)
- **new** `streamOpen.labels: [{ name, open, streamKind, streamId }]`, one per kind:
  - session → `"0"`;
  - project → `"proj-1"`;
  - terminal → `"req-1"`;
  - tunnel-http → `"req-1"`;
  - tunnel-ws → `"ws-1"`;
  - upload → `"req-1"`.

  Every `open` is `StreamOpen.parse`d at generation. The expected labels are hand-written here because the
  bridge's `streamLabelOf` is ELv2 and must not move into this Apache package.

## 6. Dart APIs (dart+app implements; evals' Dart eval client is unaffected)

### 6.1 `antgrid_relay_client/lib/src/peer_link.dart`

```dart
/// Delivered as an error on [PeerStream.records] in the raw phase only: the peer reset its send half, or the
/// connection went, before FIN.
final class PeerStreamReset implements Exception { const PeerStreamReset(); }

abstract interface class PeerStream {
  Stream<Uint8List> get records;
  Future<PeerSendOutcome> send(Uint8List record);
  /// [bytes] with no length prefix, through the same queue and bound as [send]. Completes `accepted` only
  /// once every byte has been written to the native stream.
  Future<PeerSendOutcome> sendRaw(Uint8List bytes);
  Future<void> reset();
  Future<void> finish();
}

abstract interface class MultiStreamPeerLink {
  bool get isDispatchAllowed;
  /// [rawAfterRecords] (>= 1): after that many records, every later event on `records` is a raw chunk; FIN
  /// closes it cleanly, and a reset delivers [PeerStreamReset] and then closes it.
  Future<PeerStream> openStream(StreamOpen open,
      {required int maxRecordBytes, required int maxQueuedBytes, int? rawAfterRecords});
}
```

In record mode a reset still just closes `records`, as today. Only the raw phase distinguishes a reset.

### 6.2 `antgrid_peer_transport`

- `PeerStreamRecv` gains `Future<Uint8List?> read(int maxLength)` (null at FIN); `_IrohStreamRecv` forwards
  it to iroh_quic's `read`.
- `kPeerStreamRawReadBytes = 65536`.
- In `NativePeerStream`:
  - `sendRaw` queues the unprefixed bytes, written via `writeRecordInSlices`;
  - the read loop switches to `_recv.read(kPeerStreamRawReadBytes)` after `rawAfterRecords` records;
  - it checks `_authorized()` after every raw read and honours pause/resume;
  - in the raw phase, a thrown read adds `PeerStreamReset` and then closes.
- `IrohPeerLink.openStream` and `PeerStreamOpener.open` take `rawAfterRecords` and pass it through.
- `_LeasedPeerStream.sendRaw` gates on `_isDispatchAllowed()` as `send` does. `LeasedPeerLink.openStream`
  forwards `rawAfterRecords`.

### 6.3 Upload API (`antgrid_relay_client/lib/src/upload_stream.dart`, new, exported)

```dart
const int kUploadStreamSliceBytes = 262144;
const int kUploadStreamMaxQueuedBytes = 524288;
const int kSocketUploadChunkBytes = 524288;
const Duration kUploadResultTimeout = Duration(seconds: 30);

final class UploadStreamResult {
  final bool ok;
  final String? uploadId, path, relPath, mimeType, error, message;
  /// Null unless `type == 'file:upload-result'` and `requestId` matches.
  static UploadStreamResult? tryParse(Map<String, dynamic> json, {required String requestId});
}

/// REFUSED (with refusedCode) | NOT_SUPPORTED | STREAM_OPEN_FAILED | SEND_FAILED | STREAM_ENDED | PROTOCOL
/// | INVALID_NAME | CANCELLED | TIMEOUT | TRANSPORT_CLOSED
final class UploadFailure implements Exception {
  final String code; final StreamRefusedCode? refusedCode; final String? message;
  const UploadFailure(this.code, {this.refusedCode, this.message});
}

abstract interface class UploadExchange {
  String get requestId;
  /// The bridge's result (ok or not), or an [UploadFailure]. Never an unhandled error.
  Future<UploadStreamResult> get result;
  /// Idempotent. Resets the send half (or leaves the slot queue) and fails [result] with CANCELLED.
  void cancel();
}

final class FailedUploadExchange implements UploadExchange { FailedUploadExchange(String requestId, UploadFailure failure); }

/// Loopback: the start/ready/chunk/ack/done/result exchange over the transport's own send, with the
/// kSocketUploadChunkBytes base64 chunks, 30 s step timeout and progress-on-ack of the old UploadService.
class SocketUploads {
  SocketUploads(Future<void> Function(Map<String, dynamic> message) send);
  UploadExchange open({required String requestId, required String projectId, required String checkoutId,
      required String fileName, required Uint8List bytes, String? mimeType,
      void Function(int sent, int total)? onProgress});
  /// True when [json] was a ready/ack/result for an upload in flight and was consumed.
  bool dispatch(Map<String, dynamic> json);
}
```

`AgentTransport` gains:

```dart
UploadExchange openUpload({
  required String requestId, required String projectId, required String checkoutId,
  required String fileName, required Uint8List bytes, String? mimeType,
  void Function(int sent, int total)? onProgress,
});
```

`BufferedAgentTransport`:
- adds `late final SocketUploads socketUploads = SocketUploads((m) => send(m));`;
- its default `openUpload` is `socketUploads.open`, so `LocalTransport`, `DemoTransport` and the test
  subclasses inherit it;
- `dispatchDecoded` offers each decoded JSON of type `file:upload-ready|ack|result` to
  `socketUploads.dispatch` first and does not publish a consumed one.

If `DemoTransport`'s synthesized `file:upload-result` does not pass through `dispatchDecoded`, `DemoTransport`
routes it there. Its fixture reply is unchanged.

`StreamTransport.openUpload` has two branches. When the link is not a `MultiStreamPeerLink` it returns
`FailedUploadExchange(requestId, UploadFailure('NOT_SUPPORTED'))`; the bridge drops relay-origin socket
uploads, so the fallback must fail rather than hang. Otherwise it opens `_StreamUploadExchange`:
1. `fileName.length > kStreamUploadMaxFileNameLength` → `INVALID_NAME` with no open. A `mimeType` over
   `kStreamUploadMaxMimeTypeLength` is omitted.
2. Take a slot on `MachineSession`'s upload semaphore (`kStreamMaxUploadStreamsPerPeer`, beside
   `_acquireTunnelSlot`). A cancel while queued leaves the queue.
3. Call `openStream(UploadStreamOpen(...), maxRecordBytes: kStreamUploadBridgeRecordMaxBytes,
   maxQueuedBytes: kUploadStreamMaxQueuedBytes)`, in record mode. A throw → `STREAM_OPEN_FAILED`.
4. Listen to `records`:
   - a `stream:refused` → `REFUSED(code)`;
   - a result → complete `result`;
   - anything else first → `PROTOCOL` + `reset()`;
   - done with no result → `STREAM_ENDED` (or `SEND_FAILED` if a write was refused);
   - later records are ignored.
5. Write `bytes` in `kUploadStreamSliceBytes` pieces, one `await sendRaw` at a time, calling
   `onProgress(sent, total)` after each `accepted`. Stop at the first non-`accepted` outcome, or as soon as a
   result, refusal or cancel has settled `result`. A settle that happens before all bytes are written →
   `reset()`.
6. All bytes written and not settled → `finish()`, then start the `kUploadResultTimeout` timer. On expiry →
   `TIMEOUT` + `reset()`.
7. Release the slot when `records` ends, or on a local failure once `reset()` has been issued.
8. Connection loss → `TRANSPORT_CLOSED`.

`FakeAgentTransport` (`app/lib/test_helpers`) implements `openUpload` with a `FakeUploadExchange` double,
recorded in `uploadCalls`, which a test settles through `complete(UploadStreamResult)` / `fail(UploadFailure)`
and drives with `progress(sent)`.

### 6.4 `app/lib/services/upload_service.dart`

The public surface is unchanged: `UploadService.fromSession(session, {checkoutId})`,
`upload({fileName, bytes, mimeType, onProgress, cancelToken})`, `UploadException`, `UploadResult`,
`UploadCancelToken`, `uploadErrorText` and `kMaxUploadBytes`.

`kChunkBytes` and the status-stream listener are deleted; `preview_screenshot_script.dart` stops reading
`kChunkBytes`. `upload` keeps its local pre-checks (disposed → `OFFLINE`, over `kMaxUploadBytes` →
`TOO_LARGE`) and then calls `session.transport.openUpload(requestId: uuid, projectId: session.projectId,
checkoutId, ...)`. `cancelToken.whenCancelled` → `exchange.cancel()`. `dispose` cancels live exchanges and
fails them `OFFLINE`.

Mapping to `UploadException`, so the copy in `uploadErrorText` is unchanged:

| Outcome | Maps to |
|---|---|
| `result.ok` | `UploadResult(path!, relPath, mimeType)` |
| `!result.ok` | `UploadException(result.error ?? 'UNKNOWN', result.message ?? 'Upload failed')`; `INCOMPLETE` reads the default copy |
| `CANCELLED` | `'CANCELLED'` |
| `TIMEOUT` | `'TIMEOUT'` |
| `INVALID_NAME` | `'INVALID_NAME'` |
| `REFUSED` + `CAP_EXCEEDED` | `'BUSY'` |
| any other `REFUSED`, `NOT_SUPPORTED`, `STREAM_OPEN_FAILED`, `TRANSPORT_CLOSED` | `'OFFLINE'` |
| anything else | its own code |

### 6.5 Tunnel (Dart)

- `stream_open.dart`:
  - deletes `kTunnelRecordTagBody` and `kTunnelRecordTagBodyGzip`;
  - adds `UploadStreamOpen` (a sealed-family member with `fromJson`/`toJson`/`==`/`hashCode`, the validation
    of §2.1, and `size` accepted only as a non-negative `int`) plus the §2.4 constants;
  - adds `({String kind, String id}) streamLabelOf(StreamOpen open)` with the §5 labels (session `'0'`) and
    `const String kSessionStreamLabel = '0'`, replacing `MachineSession`'s private constant.
- `tunnel_stream.dart`:
  - deletes `TunnelBodyRecord`;
  - `TunnelHttpExchange.body` is `Stream<Uint8List>` (raw chunks), done after the bridge's FIN;
  - `encodeTunnelDataRecord`/`decodeTunnelRecord` keep the WS tags only.
- `AgentTransport.openTunnelHttp({required String requestId, required String checkoutId,
  required Map<String, dynamic> head, required int bodyLength, Stream<List<int>>? body})`, where `body` is
  null iff `bodyLength == 0`. The transport stamps `bodyLength` and `checkoutId` onto the head.
- `_StreamTunnelHttpExchange` (`machine_session.dart`):
  - opens with `rawAfterRecords: 1`, `maxRecordBytes: kStreamTunnelRecordMaxBytes` and
    `maxQueuedBytes: kTunnelStreamMaxQueuedBytes`, then sends the head record;
  - pumps `body`, pausing its subscription while a `sendRaw` is awaited and splitting chunks to 256 KiB. More
    than `bodyLength`, a short end, or a source error → `reset()` + `PROTOCOL`/`SEND_FAILED`. It does **not**
    `finish()` after the body;
  - the first record is a refusal (`REFUSED`) or `tunnel:http-head`; anything else → `PROTOCOL` + `reset()`.
    Raw chunks go to `body` as-is;
  - `records` done → `body` closes, then `finish()` if the pump completed, else `reset()`;
  - `PeerStreamReset` → `TRUNCATED` after the head (`STREAM_ENDED` before it), then `reset()`;
  - `cancel()` → `reset()` + `CANCELLED`, and keeps draining `records`.

  `_kTunnelBodySliceBytes` is deleted in favour of a slice constant in `tunnel_stream.dart`
  (`kTunnelBodySliceBytes = 262144`).
- `app/lib/models/preview_models.dart`:
  - `TunnelHttpRequest` replaces `Uint8List? body` with `int bodyLength = 0` and `Stream<List<int>>? body`;
  - `acceptEncodings` and `kTunnelGzipEncoding` are deleted;
  - `toHeadJson()` emits no body, `bodyLength` or `acceptEncodings`.
- `preview_proxy_server.dart`:
  - GET/HEAD → no body;
  - `request.contentLength != null`: over `kStreamTunnelRequestBodyMaxBytes` → a local 413 "Preview request
    too large to tunnel", with no exchange; otherwise `bodyLength = contentLength`, `body = request.read()`;
  - otherwise buffer to at most cap + 1 bytes (over → 413), and pass `Stream.value(bytes)`;
  - the response path already streams `response.body`, and the existing mid-body error handling is kept.
- `preview_service.dart` passes `bodyLength`/`body` through and adds each raw chunk to `bodyController`
  directly, with the idle timer per chunk as today.
- `app/lib/services/tunnel_body.dart` is deleted.

## 7. Netwatch: matching app and bridge labels

The bridge is unchanged apart from `streamLabelOf`'s upload case and the doc comment in `netwatch.ts`, which
stops saying the app writes no terminal or tunnel label. The app gains the same two fields:

- `app/lib/util/netwatch.dart`:
  - `NetwatchEvent` gains `final String? streamKind`, serialized as `'streamKind'` beside `'streamId'`;
  - `record(... streamKind)`, `annotate(frameId, {msgType, streamId, streamKind})` and the `tap` adapter read
    `event['streamKind']`;
  - both fields stay out of any join key, as on the bridge.
- `antgrid_relay_client`:
  - every tap event `MachineSession`/`StreamTransport` emits for a native stream carries `'streamKind'` and
    `'streamId'` from `streamLabelOf` (session `'session'`/`'0'`, project `'project'`/`projectId`);
  - each terminal attachment, tunnel-http, tunnel-ws and upload exchange emits `{'op':'frame', 'dir':'tx',
    'kind':'lifecycle', 'streamKind', 'streamId', 'reason'}`, where reason is one of `stream-open`,
    `stream-refused` (detail `{code}`), `stream-reset` (this side reset) or `stream-ended` (detail
    `{end: 'fin'|'reset'}`).
- The labels-match test is the shared `streamOpen.labels` vectors (§5). A bridge test asserts
  `streamLabelOf(open)` (`id ?? NETWATCH_SESSION_STREAM_LABEL`), and a Dart test asserts `streamLabelOf(open)`,
  against the same rows.

## 8. Test seams after the wave

| Seam | Owner | After A7 |
|---|---|---|
| `bridge/tests/test-peer-session-owner.ts` | bridge-tests | Its fake accepted streams gain `read(sizeLimit)` (resolve `[]` at FIN, reject on reset). No new protected hook is expected: the upload registry lives inside `NativeHostConnection`. If bridge-src adds one, mirror the `setProjectDetached` pattern. |
| bridge fakes of `AcceptedBiStream` in `stream-dispatch`, `native-host-connection`, `terminal-streams`, `tunnel-streams`, `peer-session-hello` and `stream-records` tests | bridge-tests | Gain `read`. A shared raw-capable fake stream (e.g. `bridge/tests/support/fake-bidi-stream.ts`) is allowed and owned by bridge-tests. |
| `packages/antgrid_relay_client/test/support/fake_live_relay.dart` | dart+app | `openStream(..., {int? rawAfterRecords})` is stored on `FakePeerStream`. `FakePeerStream` gains `sentRaw`, a `sendRaw` that records, an optional `sendRawGate` (Completer) to hold one write, `sendRawOutcome`, `injectRaw(Uint8List)` and `injectReset()` (adds `PeerStreamReset`, then closes). |
| other Dart `PeerStream`/`MultiStreamPeerLink` implementers (`app/test/helpers/fixed_peer_connector.dart`, `project_session_stream_events_test.dart`, `relay_connection_open_test.dart`, `terminal_attachment_test.dart`, `tunnel_stream_test.dart`, `leased_peer_link_stream_test.dart`, `native_peer_stream_test.dart`, `peer_stream_opener_test.dart`) | dart+app | Gain `sendRaw` and the optional parameter. |
| `evals/helpers/relay-client.ts` | evals | `openTunnelHttpStream`: <ul><li>writes raw body slices of at most `STREAM_RECORD_SLICE_BYTES` after the head;</li><li>keeps its send half open until the bridge's FIN is read, then `finish()`;</li><li>reads the first record with `StreamRecordReader` and then raw with `recv.read(65536)`: `[]` → `"end"`, a throw → `"truncated"` / `"reset-before-head"`;</li><li>`TunnelHttpResult.records` becomes `chunks`.</li></ul> New `openUploadStream({projectId, checkoutId?, requestId?, fileName, size?, mimeType?, bytes, finish?, sliceBytes?})` → `UploadStreamClient { requestId; bytesWritten(); result(timeoutMs); ended: Promise<"result"\|"refused"\|"reset"\|"fin-without-result">; refusal; writeMore(bytes); cancel() }`. The gzip/body-tag imports go; the WS tags stay. |
| `evals/support/` | evals | No change expected. |
| `packages/antgrid_eval_client/lib/src/commands.dart` and `evals/helpers/dart-app-client.ts` | dart+app / evals | No change; neither drives uploads or tunnels. The dart-terminal gate must stay green. |

## 9. Tests to add, change or delete

### 9.1 bridge-tests

- **New `bridge/tests/upload-streams.test.ts`**:
  - happy path: the raw bytes (> 256 KiB and not slice-aligned) land byte-exact; exactly one result record,
    then FIN; the `.part` file is gone;
  - truncation: a FIN short of `size` → `INCOMPLETE`, and neither a `.part` nor a final file remains;
  - oversize: `size + 1` bytes → reset `STREAM_RESET_UPLOAD`, no record, recv stopped, partial removed;
  - cancel: the app resets mid-body → partial removed, writer reset, slot freed;
  - unauthorized mid-stream: `authorized()` flips after the first read → `retirePeer("unauthorized")`, and no
    further byte reaches the file;
  - cap: a 5th concurrent open → `CAP_EXCEEDED`, and one finishing frees a slot;
  - not-ready and admission: no binding → `NOT_READY`; no project stream → `NOT_ALLOWED`; unsafe id and
    uncatalogued → `NOT_ALLOWED`; `refusalFor` `UPDATE_REQUIRED`; duplicate requestId → `INVALID`;
    `uploads()` null → `NOT_ALLOWED`; server admit refusal → in-band;
  - a stream open never opens a core: `uploadBinding` returning null makes no opener call;
  - inactivity (`inactivityMs` seam) → `TIMEOUT` result, then FIN;
  - early per-file result (`TOO_LARGE`, `BUSY`) is written before any read;
  - `mayDeliverTo` false at the result → reset, no record;
  - `projectDetached`/`dropPeer` → partial removed.
- `file-upload.test.ts`: `begin`/`StreamUpload` units covering `write`/`end`/`cancel`/`INCOMPLETE`/`stop()`,
  and the shared `MAX_CONCURRENT_UPLOADS` across socket and stream.
- `file-upload-protocol.test.ts` and `agent-core-checkout-routing.test.ts`:
  - a relay-origin `file:upload-start` is dropped (no reply, warn logged);
  - loopback keeps working, with replies sent to loopback only;
  - `uploadStreams.admit` in order: switch off, `UPDATE_REQUIRED`, deleting, unknown checkout, prepare
    for non-main (the file lands in that checkout's `.antgrid/uploads`), no manager, throw →
    `NOT_ALLOWED`.
- `stream-records.test.ts`:
  - `sendRaw`: no prefix; ≤ 256 KiB slices; authorized per slice; overflow; queued-order interleave with
    `send`; zero-length;
  - `StreamRawReader`: `[]` → null, a reject rethrown, clamping.
- `stream-dispatch.test.ts`: the upload handler is dispatched, `streamLabelOf` has an upload case, and the
  **labels vectors** row asserts every `streamOpen.labels` entry.
- `native-host-connection.test.ts`: the upload handler is wired; `projectDetached`/`dropPeer` reach the
  upload registry.
- `tunnel-streams.test.ts` (rewrite the body sections):
  - a raw request body (1 MiB + 17) reaches the origin byte-exact with `content-length = bodyLength`;
  - a raw response with FIN and no end record;
  - **a streamed response's first bytes reach the stream while the origin is still held open by a latch**;
  - a small read is written within `flushMs`, and every `writeAll` is ≤ 256 KiB;
  - a declared body over the cap → `INVALID` with the upstream never contacted;
  - more than declared → reset, with the upstream request aborted;
  - a FIN or reset short of declared → the upstream sees an errored body (never a complete one) and the
    stream resets;
  - **an error after the head resets the stream (no FIN)**;
  - request-body idle → aborted;
  - the app's FIN after the response end is ignored;
  - cancel during the response aborts the fetch.
- `localhost-fetch.test.ts`:
  - delete the gzip, `encodeChunk`, `singleSlice`, precompressed and `acceptEncodings` tests;
  - add: `coalesceBody` raw pieces with the flush and idle clocks kept; a streamed request body with
    `duplex`; the head timer anchored on `complete` (a body slower than `headTimeoutMs` still succeeds); a
    scheme retry replays a body ≤ the replay cap; > the cap → no retry (original error).
- `tunnel-manager-stream.test.ts`: `TunnelHttpExchange.body(Uint8Array)`; synthesized 502 as one piece;
  `serveHttp(req, null | TunnelRequestBody, ...)`.
- `tunnel-protocol.test.ts`: delete the `TunnelHttpEnd`/`TUNNEL_GZIP_ENCODING` cases; `acceptEncodings` is
  stripped; `TUNNEL_BODY_REPLAY_MAX_BYTES` is pinned.
- `packages/antgrid-wire/tests/stream-open.test.ts` and `peer-transport-vectors.test.ts`:
  - the upload schema accept/reject rows and the new caps;
  - the body tags are gone, and `0x00`/`0x01` decode to null;
  - `uploadRecords`, `labels`.
- `tunnel-manager-ws-order.test.ts`: no change expected (`STREAM_TUNNEL_DATA_MAX_BYTES` stays).

### 9.2 dart+app

- `native_peer_stream_test.dart`:
  - `sendRaw` has no prefix, ≤ 256 KiB slices, and completes on write;
  - raw phase after N records: chunks delivered, FIN closes cleanly, reset → `PeerStreamReset` then done;
  - authorized after every raw read.
- `leased_peer_link_stream_test.dart`: `sendRaw` is gated and `rawAfterRecords` forwarded.
- `peer_stream_opener_test.dart`: `rawAfterRecords` is passed through.
- **New `packages/antgrid_relay_client/test/upload_stream_test.dart`**:
  - **progress comes from written bytes with no ack record ever injected** (gate one `sendRaw` and assert
    that progress has not advanced past it);
  - **cancel resets the send half** and fails with `CANCELLED`;
  - refusal mapping;
  - an early result stops writing and resets;
  - end without a result → `STREAM_ENDED`;
  - the result timeout after `finish()`;
  - a fifth concurrent upload waits for a slot;
  - `NOT_SUPPORTED` on a non-multi-stream link;
  - lifecycle tap events carry `streamKind:'upload'`, `streamId: requestId`.
- **New `socket_uploads_test.dart`** (relay_client): the loopback chunk/ack/done path, dispatch consumption,
  and the dead-upload `requestId:""` result waking the right waiter.
- `tunnel_stream_test.dart`:
  - **raw response piping** (unaligned chunks forwarded as-is);
  - a reset mid-body → `TRUNCATED`, never a clean done;
  - the raw request body with a `bodyLength` mismatch → reset;
  - `finish()` only after the response FIN;
  - delete the body-tag/gzip/end-record cases.
- `peer_transport_vectors_test.dart`: the upload open accept/reject rows, the caps, `uploadRecords`, WS-only
  tags, and **the `labels` rows against Dart `streamLabelOf`**.
- `app/test/services/upload_service_test.dart`: re-based on `FakeAgentTransport.openUpload`, covering the
  §6.4 mapping table and the unchanged copy.
- `terminal_attach_test.dart`, `terminal_drop_test.dart`, `demo_fixture_contract_test.dart`: kept green (the
  demo refusal still surfaces its copy).
- `preview_proxy_server_test.dart`:
  - a request body streamed without buffering when `content-length` is present (assert the first chunk is
    sent before the browser body ends);
  - chunked is buffered, and over the cap → 413;
  - response bytes are piped.
- `preview_service_test.dart` and `preview_models_test.dart`: drop `acceptEncodings`/gzip, use raw chunks.
- Delete `app/test/services/tunnel_body_test.dart`.
- The app netwatch test: `streamKind` round-trips through `tap` → `toJson`.

### 9.3 evals

- `evals/tests/file-upload.test.ts` (rewrite):
  - **a native upload of 9 MiB + 13 bytes, with sha256 on disk equal to the payload**, landing under
    `.antgrid/uploads`, with `.antgrid/.gitignore` present;
  - declared > 20 MiB → `TOO_LARGE`;
  - no project stream → refused `NOT_ALLOWED`;
  - cancel mid-body → neither a final nor a `.part` file (poll ≤ 5 s);
  - a relay-origin `file:upload-start` gets no `file:upload-ready` within 2 s;
  - loopback multi-chunk upload via `LocalTestClient`, using the connect pattern of
    `gate-terminal-frames.test.ts`.
- `gate-tunnel-streaming.test.ts`:
  - every row moves to raw bodies;
  - the 1 MiB echo row becomes **a POST body of 1 MiB + 17 bytes (larger than one old slice), echoed
    byte-exact**;
  - the pause/resume and cancel rows keep their assertions;
  - the in-band refusal rows are unchanged.
- `sealed-preview-http.test.ts`: raw.
- Gates: `bun run --filter antgrid-evals test:evals` (or at least the three files above plus the other tunnel
  gates) and `bun run --filter antgrid-evals test:evals:dart-terminal`.

## 10. Docs (bridge-src and dart+app, per the table)

- `docs/protocol/peer-session.md`:
  - §1a: the stream catalogue gains `upload`;
  - new **§1e Upload streams** carrying §2 of this file;
  - §1c is rewritten for raw HTTP bodies: the tag table keeps WS only, and the end record and gzip are
    gone;
  - §5 per-record caps gain the upload record cap and raw reads;
  - §6 says the app now writes `streamKind`/`streamId` for every stream.
- `docs/architecture.md`: the upload flow now rides its own stream remotely and the socket messages locally,
  and tunnel bodies are raw.
- `bridge/CLAUDE.md`: in the `tunnel-manager.ts` paragraph, the tag-byte/gzip sentence becomes "bodies are
  raw bytes; a FIN is a clean end, a reset an aborted one". The component map gains
  `peer/upload-streams.ts` beside the tunnel registry.
- `bridge/requirements.md`: delete the `tunnel:http-end` row and add the upload stream rows.
- `app/CLAUDE.md`: delete the `acceptEncodings`/`kTunnelGzipEncoding` invariant sentence.
  `packages/antgrid_relay_client/CLAUDE.md`: add the `openUpload`/`SocketUploads` split if it describes
  transports.
- `docs/iroh-reduction/ledger.md`:
  - add the status row `| A | A7 raw upload streams and raw tunnel HTTP bodies | done | <hash> |` (the
    controller fills the hash);
  - mark the open item "A tunnel request body is reassembled in memory…" resolved: the body is now streamed,
    and at most `TUNNEL_BODY_REPLAY_MAX_BYTES` is buffered per stream;
  - amend the netwatch fixed item's last clause (the app now writes the terminal, tunnel and upload labels);
  - note under the owner decisions that A7 moves remote upload off the project stream.

## 11. Gates per part

| Part | Must run |
|---|---|
| bridge-src | `bun run --filter antgrid-wire gen:peer-vectors`; `bun run --filter antgrid-wire typecheck`; `bun run --filter antgrid-bridge typecheck` (test fakes may lag until bridge-tests lands; report which); `bun run --filter antgrid-relay typecheck` (the relay consumes the wire package) |
| bridge-tests | `bun run --filter antgrid-wire test`; `bun run --filter antgrid-bridge test > file`, grep `(fail)`, where only the known red is allowed |
| dart+app | `dart test` in `packages/antgrid_relay_client` and `packages/antgrid_peer_transport`; `cd app && flutter test -j 2`; `npm run check:font-tokens`; `analyze_files` while iterating. The controller runs `flutter analyze` once, never concurrently. |
| evals | `bun run --filter antgrid-evals typecheck`, the §9.3 files, `test:evals:dart-terminal` |

## 12. File ownership (disjoint and complete)

| File | Part |
|---|---|
| `packages/antgrid-wire/src/stream-open.ts`, `packages/antgrid-wire/src/index.ts`, `packages/antgrid-wire/scripts/gen-peer-transport-vectors.ts` | bridge-src |
| `evals/fixtures/peer-transport-vectors.json` (regenerated only, never hand-edited) | bridge-src |
| `bridge/src/peer/stream-records.ts`, `bridge/src/peer/stream-dispatch.ts`, `bridge/src/peer/upload-streams.ts` (new), `bridge/src/peer/tunnel-streams.ts`, `bridge/src/peer/native-host-connection.ts` | bridge-src |
| `bridge/src/project-streams.ts`, `bridge/src/project-core.ts`, `bridge/src/agent-core.ts`, `bridge/src/file-upload.ts`, `bridge/src/protocol.ts` | bridge-src |
| `bridge/src/tunnel-manager.ts`, `bridge/src/tunnel-protocol.ts`, `bridge/src/localhost-fetch.ts`, `bridge/src/netwatch.ts` | bridge-src |
| `bridge/CLAUDE.md`, `bridge/requirements.md`, `docs/protocol/peer-session.md`, `docs/architecture.md`, `docs/iroh-reduction/ledger.md` | bridge-src |
| `packages/antgrid-wire/tests/stream-open.test.ts`, `packages/antgrid-wire/tests/peer-transport-vectors.test.ts` | bridge-tests |
| `bridge/tests/upload-streams.test.ts` (new), `bridge/tests/file-upload.test.ts`, `bridge/tests/file-upload-protocol.test.ts`, `bridge/tests/agent-core-checkout-routing.test.ts` | bridge-tests |
| `bridge/tests/stream-records.test.ts`, `bridge/tests/stream-dispatch.test.ts`, `bridge/tests/native-host-connection.test.ts`, `bridge/tests/peer-session-hello.test.ts`, `bridge/tests/terminal-streams.test.ts`, `bridge/tests/test-peer-session-owner.ts` | bridge-tests |
| `bridge/tests/tunnel-streams.test.ts`, `bridge/tests/tunnel-manager-stream.test.ts`, `bridge/tests/tunnel-protocol.test.ts`, `bridge/tests/tunnel-manager-ws-order.test.ts`, `bridge/tests/localhost-fetch.test.ts` | bridge-tests |
| any other file under `bridge/tests/` (including a new `bridge/tests/support/*`) | bridge-tests |
| `packages/antgrid_peer_transport/**` (`lib/src/iroh_peer_link.dart`, `lib/src/leased_peer_link.dart`, `test/native_peer_stream_test.dart`, `test/leased_peer_link_stream_test.dart`, `test/peer_stream_opener_test.dart`, `test/peer_transport_vectors_test.dart`) | dart+app |
| `packages/antgrid_relay_client/**` (`lib/src/peer_link.dart`, `lib/src/models/stream_open.dart`, `lib/src/upload_stream.dart` (new), `lib/src/tunnel_stream.dart`, `lib/src/agent_transport.dart`, `lib/src/buffered_agent_transport.dart`, `lib/src/machine_session.dart`, `lib/src/local_transport.dart`, `lib/antgrid_relay_client.dart`, `test/support/fake_live_relay.dart`, `test/upload_stream_test.dart` (new), `test/socket_uploads_test.dart` (new), `test/tunnel_stream_test.dart`, `test/terminal_attachment_test.dart`, `test/local_transport_tunnel_test.dart`, `CLAUDE.md`) | dart+app |
| `packages/antgrid_eval_client/**` (no change expected) | dart+app |
| `app/**`, including `app/CLAUDE.md`, `lib/services/upload_service.dart`, `lib/services/preview_service.dart`, `lib/services/preview_proxy_server.dart`, `lib/services/tunnel_body.dart` (deleted), `lib/models/preview_models.dart`, `lib/util/netwatch.dart`, `lib/test_helpers/fake_agent_transport.dart`, `lib/demo/demo_transport.dart`, `lib/screens/preview_screenshot_script.dart`, and every `app/test/**` file named in §8 and §9.2 | dart+app |
| `evals/**` except `evals/fixtures/peer-transport-vectors.json`: `evals/helpers/relay-client.ts`, `evals/helpers/local-client.ts` (if needed), `evals/tests/file-upload.test.ts`, `evals/tests/gate-tunnel-streaming.test.ts`, `evals/tests/sealed-preview-http.test.ts`, `evals/support/**` | evals |

Nothing under `relay/`, `web/`, `site/` or `aspire/` changes. If a typecheck there turns red because a deleted
wire export was in use, report it as `outOfScopeNeeds`; the grep at authoring time found no such use.

Symbols deleted or renamed, and every file that must stop referencing them (grep at `e46f0b1f`, excluding
`docs/iroh-reduction/`):

| Symbol | Call sites |
|---|---|
| `TunnelHttpEnd`, `tunnel:http-end` | `bridge/src/peer/tunnel-streams.ts`, `bridge/src/tunnel-protocol.ts`, `bridge/src/tunnel-manager.ts`, `bridge/src/localhost-fetch.ts` (comment), `bridge/tests/tunnel-protocol.test.ts`, `bridge/requirements.md`, `docs/protocol/peer-session.md`, `evals/helpers/relay-client.ts`, `evals/tests/sealed-preview-http.test.ts`, `packages/antgrid_relay_client/lib/src/{machine_session,tunnel_stream}.dart`, `packages/antgrid_relay_client/test/tunnel_stream_test.dart`, `app/test/models/preview_models_test.dart` |
| `acceptEncodings`, `kTunnelGzipEncoding`, `TUNNEL_GZIP_ENCODING` | `bridge/src/{localhost-fetch,tunnel-manager,tunnel-protocol}.ts`, `bridge/tests/{localhost-fetch,tunnel-manager-stream,tunnel-protocol}.test.ts`, `app/CLAUDE.md`, `app/lib/models/preview_models.dart`, `app/test/models/preview_models_test.dart`, `app/test/services/{preview_proxy_server,preview_service}_test.dart` |
| `TUNNEL_RECORD_TAG_BODY`, `TUNNEL_RECORD_TAG_BODY_GZIP` | `packages/antgrid-wire/src/{stream-open,index}.ts`, `packages/antgrid-wire/scripts/gen-peer-transport-vectors.ts`, `packages/antgrid-wire/tests/{stream-open,peer-transport-vectors}.test.ts`, `bridge/src/peer/tunnel-streams.ts`, `bridge/src/localhost-fetch.ts`, `bridge/tests/tunnel-streams.test.ts`, `evals/helpers/relay-client.ts`, `docs/protocol/peer-session.md` |
| `kTunnelRecordTagBody`, `kTunnelRecordTagBodyGzip` | `packages/antgrid_relay_client/lib/src/{models/stream_open,machine_session,tunnel_stream}.dart`, `packages/antgrid_relay_client/test/tunnel_stream_test.dart`, `packages/antgrid_peer_transport/test/peer_transport_vectors_test.dart` |
| `TunnelBodyRecord`, `decodeTunnelBody` | `packages/antgrid_relay_client/lib/src/{machine_session,tunnel_stream}.dart`, `packages/antgrid_relay_client/test/tunnel_stream_test.dart`, `app/lib/services/{preview_service,tunnel_body}.dart`, `app/lib/test_helpers/fake_agent_transport.dart`, `app/test/services/{preview_service,tunnel_body}_test.dart` |
| `encodeChunk`, `singleSlice`, `TunnelBodySlice`, `isPrecompressedContentType`, `.slices` | `bridge/src/{localhost-fetch,tunnel-manager}.ts`, `bridge/tests/{localhost-fetch,tunnel-manager-stream}.test.ts`, `packages/antgrid_relay_client/lib/src/machine_session.dart` (comment) |
| `_kTunnelBodySliceBytes` | `packages/antgrid_relay_client/lib/src/machine_session.dart` |
| `UploadService.kChunkBytes` | `app/lib/services/upload_service.dart`, `app/lib/screens/preview_screenshot_script.dart`, `app/test/services/upload_service_test.dart` |
| `openTunnelHttp(body: Uint8List)` | `packages/antgrid_relay_client/lib/src/{agent_transport,buffered_agent_transport,machine_session}.dart`, `app/lib/services/preview_service.dart`, `app/lib/test_helpers/fake_agent_transport.dart`, and the relay_client/app tests that call it |

## 13. Integration corrections (after the four parts landed)

What the integrator changed where the parts or this contract disagreed with the code that runs. Code wins.

- `_StreamTunnelHttpExchange` (§6.5) closed `body` cleanly before deciding how the records ended, so a reset
  after the head surfaced as a complete response instead of `TRUNCATED`. The body is now settled by the
  branch that classifies the end. The same method released its tunnel slot only on the clean-FIN path, so a
  cancelled, reset or head-less exchange leaked its slot for good; every end now releases it once the
  records have drained.
- `_StreamUploadExchange` (§6.3): `cancel()` fails `result` with `CANCELLED` at once (the slot is still held
  until the bridge's half ends), `result` is marked ignored at construction so an abandoned exchange never
  raises an unhandled error, and a result or refusal that settles before every byte was written resets the
  send half (a clean FIN there would read as a complete body). Writing everything and then settling early
  finishes it.
- `UploadStreamRegistry` (§4.2) now emits `upload-stream:result` and `upload-stream:cancelled` as listed;
  only `upload-stream:oversize` had been wired.
- The label vectors (§5, §7) are asserted on both sides: `bridge/tests/stream-dispatch.test.ts` and
  `packages/antgrid_peer_transport/test/peer_transport_vectors_test.dart`, which also gained the upload
  open rows, `uploadRecords`, `caps.maxUploadStreamsPerPeer` and a WS-only tag set.
- The bridge fakes in `terminal-streams.test.ts` and `test-peer-session-owner.ts` gained `read` (§8).
- Two app widget tests (`terminal_view_wrapper_keys_test.dart`, `terminal_frame_mode_widget_test.dart`) drove
  uploads through `file:upload-*` messages on the fake transport; they now drive `FakeUploadExchange`.
- `preview_proxy_server.dart`'s over-cap 413 (§6.5) reaches the browser only after the declared body has
  been sent: dart:io drains an unread request body before it writes the response. The test sends the body.
