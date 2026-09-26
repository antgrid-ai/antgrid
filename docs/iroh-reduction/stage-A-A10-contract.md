# Stage A, wave A10: frozen implementer contract

Base: `7ac22642` (A0 to A9 committed). Four parts build in parallel and do not
talk to each other: **bridge-src**, **bridge-tests**, **dart+app** and
**evals**. This file is the only coordination between them. If it disagrees
with the code, the code wins, and the disagreement goes in your
`outOfScopeNeeds`. Do not guess the other part's side.

`stage-A-waves.md` has no A10 section, so this file is the whole spec. The
product has no users, so no compatibility shim, dual path or version check may
survive this wave.

## 0. What A10 does

1. **Deletes the chunked loopback upload.** The
   `file:upload-start/ready/chunk/ack/done` protocol goes, and one loopback-only
   request, `file:upload-local`, replaces it. The bridge copies a local file
   into the same staging directory the `upload` stream uses.
2. **Collapses `PeerLink` and `MultiStreamPeerLink` into one Dart interface.**
   All the fallbacks for a link without streams are deleted.
3. **Trims A7's growth** in `machine_session.dart` and
   `bridge/src/peer/tunnel-streams.ts`, together with the admission duplication
   A7 copied into the upload and terminal registries. Behaviour does not change.
4. **Prunes tests** that pin implementation details or re-test QUIC or binding
   guarantees.
5. **Stabilises the soak's RSS sample** by running `Bun.gc(true)` before every
   sample.

### Acceptance: net source line count

- **Target:** the net source change of A7 plus A10 must be negative.
- **A7's net is +1,915.** That figure was re-verified with the command below at
  `63b1dca3^..63b1dca3`, which gives 2584 added and 669 removed.
- **So A10's net must be below -1,915.**

The integrator measures with exactly this command, and no other pathspec:

```bash
git diff --numstat 7ac22642 HEAD -- . ':!**/test/**' ':!**/tests/**' ':!evals/**' \
  ':!**/*.md' ':!**/test_helpers/**' ':!**/scripts/**' ':!**/*.json' \
  | awk '{a+=$1;d+=$2} END{print a,d,a-d}'
```

**Projection, stated plainly:** the contract's author expects roughly -1,100 to
-1,450, which misses the target by about 500 to 800 lines. The per-part targets
below add up to about -1,450.

- The integrator records the measured number in the ledger, whatever it is.
- If the target is missed, the ledger says `A7+A10 net = +N, target missed`.
- **Do not pad the number.** No part may delete unrelated code to reach it.
  Dead-code removal outside this wave's scope belongs to A11.

| Part | Source target (net) | Main contributors |
|---|---|---|
| bridge-src | ≤ -550 | Socket upload path in `file-upload.ts`. Five schemas in `protocol.ts`. Shared admission gate across terminal, tunnel and upload. Merged tunnel HTTP/WS admission and head parse. |
| dart+app | ≤ -900 | `SocketUploads` (about -290). One slot pool. Shared exchange bookkeeping and raw pump in `machine_session.dart` (at least -350 there). `MultiStreamPeerLink` branches. |
| evals | 0 source (tests only) | |

---

## 1. Wire records

### 1.1 Deleted everywhere

**Message types.** These five types are deleted everywhere:

- `file:upload-start`
- `file:upload-ready`
- `file:upload-chunk`
- `file:upload-ack`
- `file:upload-done`

**Bridge (`bridge/src/protocol.ts`).** Delete:

- the five `FileUpload{Start,Ready,Chunk,Ack,Done}Message` schemas;
- `MAX_UPLOAD_CHUNK_DATA`;
- their five `AbMessageSchema` union entries;
- their five exported types: `FileUploadStart`, `FileUploadReady`,
  `FileUploadChunk`, `FileUploadAck` and `FileUploadDone`;
- their `KNOWN_TYPES` entries;
- their `CHECKOUT_VARIABLE_MESSAGE_TYPES` entries;
- the whole of `LOOPBACK_UPLOAD_MESSAGE_TYPES`.

**Dart.** Delete:

- the five entries from `kCheckoutVariableMessageTypes`;
- `file:upload-ready` and `file:upload-ack` from the status-tier set in
  `app/lib/project/project_message_classification.dart`.

`file:upload-result` stays in both sets.

### 1.2 New: `file:upload-local` (app → bridge, loopback only)

TS, in `bridge/src/protocol.ts`, placed where `FileUploadStartMessage` was:

```ts
const FileUploadLocalMessage = BaseMessage.extend({
  type: z.literal("file:upload-local"),
  projectId: z.string(),
  requestId: z.string(),
  fileName: z.string(),
  sourcePath: z.string(), // absolute path on THIS machine; loopback-only (see §2)
  mimeType: z.string().optional(),
  ...CheckoutScoped,
});
export type FileUploadLocal = z.infer<typeof FileUploadLocalMessage>;
```

- **Registration.** Add it to:
  - `AbMessageSchema`;
  - `KNOWN_TYPES`;
  - `CHECKOUT_VARIABLE_MESSAGE_TYPES`;
  - `handleAbMessage`'s switch;
  - the Dart mirror `kCheckoutVariableMessageTypes`.
- **Not in the status tier.** It is app → bridge only.
- **Dart side.** It needs no model class. The app builds the map literal in the
  loopback exchange (§3.3):

  ```dart
  {'type':'file:upload-local','projectId':…,'requestId':…,'checkoutId':…,
   'fileName':…,'sourcePath':…, if (mimeType!=null) 'mimeType':…}
  ```

### 1.3 Reply: `file:upload-result` (unchanged schema)

- **The schema itself.** `FileUploadResultMessage` keeps every field:
  `requestId`, `uploadId?`, `ok`, `path?`, `relPath?`, `mimeType?`, `error?`,
  `message?` and the checkout-scoped fields. The `upload` stream already uses
  it.
- **Schema comment.** Only the `error` comment's code list changes, to:

  ```
  TOO_LARGE | INVALID_NAME | INVALID_SOURCE | NOT_ALLOWED | WRITE_FAILED | TIMEOUT | BUSY | INCOMPLETE
  ```

- **How the loopback reply is sent.** It is published only to the loopback
  owner, with `sendAbTo(result, "loopback")`, and stamped
  `checkoutId: runtime.checkout.id` (the same stamping the old socket path
  did).
- **Dart parsing.** Dart parses it with the existing
  `UploadStreamResult.tryParse(json, requestId)`.

### 1.4 Error codes

`UploadErrorCode` in `bridge/src/file-upload.ts` becomes:

```ts
export type UploadErrorCode = "TOO_LARGE" | "INVALID_NAME" | "INVALID_SOURCE" | "NOT_ALLOWED"
  | "WRITE_FAILED" | "TIMEOUT" | "BUSY" | "INCOMPLETE";
```

- **Removed:** `UPLOAD_NOT_FOUND`, `BAD_SEQUENCE` and `SIZE_MISMATCH`. Only the
  socket path emitted them.
- **Added:** `INVALID_SOURCE` and `NOT_ALLOWED`.
- **Display copy.** The app has no copy arm for either new code, and it gets
  none, so `uploadErrorText`'s default copy renders them. In practice the app
  only ever names a temp file it has just written, so neither code is reachable
  from the UI.
- `TIMEOUT` stays because the app-side exchange produces it.

### 1.5 Stream kinds, open frames and caps: no change

- Stream kinds stay as they are: session, project, terminal, tunnel-http,
  tunnel-ws and upload.
- Open-frame fields, ALPN `antgrid/peer/2`, `FRAME_VERSION`, `stream:refused`
  plus FIN, and `StreamRefusedCode` are all unchanged.
- Caps and where they live are unchanged:

| Cap | Value | TS | Dart |
|---|---|---|---|
| QUIC bidi | 256 | bridge endpoint config | Iroh binding |
| projects / peer | 32 | `stream-dispatch.ts` `STREAM_MAX_PROJECT_STREAMS_PER_PEER` | `kStreamMaxProjectsPerPeer` (`models/stream_open.dart`) |
| terminals / peer | 64 | `STREAM_MAX_TERMINAL_STREAMS_PER_PEER` | `kStreamMaxTerminalsPerPeer` |
| tunnels / peer | 128 | `STREAM_MAX_TUNNEL_STREAMS_PER_PEER` | `kStreamMaxTunnelsPerPeer` |
| uploads / peer | 4 | `STREAM_MAX_UPLOAD_STREAMS_PER_PEER` | `kStreamMaxUploadsPerPeer` |
| pending opens | 16 | peer transport | `peer_stream_opener.dart` D7 constant |
| upload size | 20 MiB | `MAX_UPLOAD_BYTES` (`file-upload.ts`) | `kMaxUploadBytes` (`upload_service.dart`) |
| upload concurrency / manager | 4 | `MAX_CONCURRENT_UPLOADS` (`file-upload.ts`), **now also counted by `copyLocal`** | none |
| Dart raw slice | 262144 | none | `kUploadStreamSliceBytes` (`upload_stream.dart`) |
| Dart upload result timeout | 30 s | none | `kUploadResultTimeout` (`upload_stream.dart`), **also used by the loopback exchange** |

Use the constant names as they exist in the code. If a name in this table is
spelled differently in the source, the source wins. No constant moves file and
no value changes.

---

## 2. Bridge: `file:upload-local` admission (security, non-negotiable)

Order of checks, with the first failure winning:

1. **Source gate, before anything else touches the frame's content.** In
   `attachTransport`'s inbound handler (`bridge/src/agent-core.ts`), replace
   the deleted `LOOPBACK_UPLOAD_MESSAGE_TYPES` drop at the same position with:

   ```ts
   if (source !== "loopback" && msg.type === "file:upload-local") {
     log.warn("Dropping inbound %s: it names a local path and is accepted only from loopback (project %s)", msg.type, project.id);
     return;
   }
   ```

   - **Position.** It stays after `remoteFrameAllowed(source)` and
     `peerBusReachAllowed`, and **before** the `CHECKOUT_VARIABLE_MESSAGE_TYPES`
     branch. That means a remote frame never reaches `checkoutRuntimes.resolve`,
     `prepareCheckoutRuntime` or `handleAbMessage`.
   - **No reply.** The drop sends nothing: no `file:upload-result` and no
     `control:result`.
   - **Why this one check covers every native path.** It is the only
     chokepoint that a relay-sourced frame reaches:
     - The project stream reaches it through `dispatchJson` →
       `dispatchInbound(msg,"control","relay",peerId)`.
     - The terminal stream is refused earlier, by the
       `TERMINAL_STREAM_INBOUND_TYPES` allowlist. `file:upload-local` must NOT
       be added to that allowlist.
     - The session stream goes to the host control-plane bus, which never
       forwards file verbs to a core.
     - Tunnel and upload streams dispatch no `AbMessage` at all.
2. **Defense in depth, inside `handleAbMessage`:**

   ```ts
   case "file:upload-local": {
     if (client !== "loopback") break;
     …
   }
   ```

3. **Project match.** If `msg.projectId !== project.id`, reply `ok:false`,
   `error:"NOT_ALLOWED"`. The loopback socket belongs to one core, and that
   core was admitted through `seenProjects` and `isSafeProjectId` when it
   opened, so `projectId` selects nothing. The check only refuses a
   mismatched frame.
4. **Checkout routing.** This is the existing `CHECKOUT_VARIABLE` path,
   unchanged:
   - it refuses `CHECKOUT_DELETING` and `UNKNOWN_CHECKOUT` with
     `control:result`;
   - it lazily prepares the runtime;
   - it calls `handleAbMessage({...msg, checkoutId})`.

   If `runtime.uploadManager` is null, reply `ok:false`, `error:"NOT_ALLOWED"`.
5. **`FileUploadManager.copyLocal`** (§2.1) is the **only** code that ever reads
   `sourcePath`. `stat` and every other filesystem call happen inside it,
   after steps 1 to 4.

### 2.1 `FileUploadManager` after A10 (`bridge/src/file-upload.ts`)

```ts
export class FileUploadManager {
  constructor(opts: { projectId: string; projectPath: string });   // `send` option REMOVED
  begin(…): …;                // unchanged (stream path)
  streamUploadFor / writeStreamChunk / endStreamUpload / cancelStreamUpload  // unchanged signatures
  copyLocal(req: { requestId: string; fileName: string; sourcePath: string }): Promise<UploadResultFields>;
  startSweeper(): void; sweepStale(): Promise<void>; stop(): void;  // unchanged
}
```

**Deleted:** `handleStart`, `handleChunk`, `handleDone`, the socket
`UploadSession` fields (`nextSeq`, `onResult`), `sendResult`, `deliverResult`,
the `send` option and every inactivity-timer branch that exists only for socket
sessions. Keep whatever the stream path still uses.

`copyLocal` runs these steps in order:

1. **Source checks.** If `!path.isAbsolute(sourcePath)`, return
   `INVALID_SOURCE`. Then run `fs.promises.lstat(sourcePath)`. If it throws, or
   the result is not `isFile()` (a directory, symlink, FIFO or device), return
   `INVALID_SOURCE`. **No `open` or `read` of the source happens before this.**
2. **Size cap.** If `st.size > MAX_UPLOAD_BYTES`, return `TOO_LARGE`, still
   before anything is read.
3. **Name.** If `sanitizeUploadFileName(fileName)` fails, return
   `INVALID_NAME`.
4. **Concurrency.** Count against the same active-upload limit `begin` uses.
   Over the limit, return `BUSY`.
5. **Copy and finalize.**
   - Stage exactly as the stream path does: the same staging directory
     (`<checkout path>/.antgrid/uploads` with its self-ignoring `.gitignore`),
     the same `${uploadId}.part` temp name and the same finalize function
     (renamed to `${uploadId.slice(0,8)}-${name}`).
   - Copy asynchronously with `fs.promises.copyFile`, or a stream pipe that
     stops at `MAX_UPLOAD_BYTES + 1` bytes.
   - Then `stat` the `.part` file again. A copy larger than `MAX_UPLOAD_BYTES`
     means the file grew after step 2: delete the `.part` and return
     `TOO_LARGE`.
   - **Extract one shared finalize helper** for the stream path and
     `copyLocal`. Two copies of it is a failed trim.
6. **Errors.** A failure in any staging, copy or rename step returns
   `WRITE_FAILED` and leaves no `.part` behind.
7. **Success.** Return `{ uploadId, ok:true, path, relPath, mimeType }`. These
   come from exactly the fields and helpers the stream path uses (`relPath`
   relative to `projectPath`, `mimeType` via `renderableBinaryMime`).

The destination is derived entirely from the runtime's checkout path plus the
sanitized name. No client-supplied string other than the sanitized name reaches
it, so the destination rules (checkout routing, the staging floor) match the
upload stream exactly. The destructive-path floor sees no new write target.

**Callers of the constructor.** `agent-core.ts` constructs the manager in two
places, the per-checkout runtime and main. Both drop the `send:` argument and
the comment attached to it.

---

## 3. Dart and app

### 3.1 One link interface (`packages/antgrid_relay_client/lib/src/peer_link.dart`)

- **Merge the interfaces.** `MultiStreamPeerLink` is deleted, and its method
  moves onto `PeerLink`:

  ```dart
  abstract interface class PeerLink {
    // …every existing member unchanged…
    Future<PeerStream> openStream(StreamOpen open,
        {required int maxRecordBytes, required int maxQueuedBytes, int? rawAfterRecords});
  }
  ```

  `PeerStream`, `PeerStreamReset` and `StreamOpen` are unchanged.
- **Implementers.** `IrohPeerLink` drops `implements MultiStreamPeerLink`, and
  `LeasedPeerLink` delegates `openStream` to its inner link with no type test.
  `interop_app.dart` drops its cast.
- **In `machine_session.dart`, delete:**
  - every `is MultiStreamPeerLink`, `is! MultiStreamPeerLink` and
    `as MultiStreamPeerLink`;
  - `_attemptBind`'s `STREAM_UNSUPPORTED` branch;
  - the `super.openTerminalAttachment`, `openTunnelHttp` and `openTunnelWs`
    fallbacks in `StreamTransport`;
  - the `FailedUploadExchange(NOT_SUPPORTED)` fallback in
    `StreamTransport.openUpload`;
  - the `link:` constructor parameter and field on all four exchange classes,
    which use `session.relay` or an equivalent single accessor instead.
- **Test fakes.** Every test fake that `implements PeerLink` gains an
  `openStream` that throws `UnimplementedError()` (or a real fake, where the
  test already has one). This covers the fakes listed in §5.3.

### 3.2 `BufferedAgentTransport` (`buffered_agent_transport.dart`)

- **Delete** `socketUploads` and the `socketUploads.dispatch(json)` divert in
  `dispatchDecoded`.
- **Base default.** `openUpload` now returns
  `FailedUploadExchange(const UploadFailure('NOT_SUPPORTED'))`. It stays only
  for test subclasses, which ignore uploads.
- **Tunnel defaults.** `openTunnelHttp` and `openTunnelWs` keep their
  `NOT_SUPPORTED` defaults, because `LocalTransport` and `DemoTransport` never
  tunnel.
- **Upload service.** `UploadService._mapFailure` keeps its
  `NOT_SUPPORTED → OFFLINE` arm.

### 3.3 `LocalTransport` loopback upload (`local_transport.dart`)

`LocalTransport` overrides `openUpload`. Its signature is unchanged from
`AgentTransport` and returns a private `_LocalUploadExchange implements
UploadExchange`:

1. **Temp file.** Call `Directory.systemTemp.createTemp('antgrid-upload-')` and
   write `bytes` to `<dir>/<fileName-basename>`. The bridge sanitizes the name
   again, so the app does no sanitizing. A temp write failure fails with
   `UploadFailure('WRITE_FAILED', message: e.toString())`.
2. **Register before sending.** Register a completer keyed by `requestId` in a
   `LocalTransport` map **before** the send. Then report `onProgress?.call(0,
   bytes.length)` and send the §1.2 map with `sourcePath` set to the temp
   file's absolute path.
3. **Claim the reply.** `LocalTransport` overrides `dispatchDecoded`. A
   `file:upload-result` whose `requestId` is in the map is claimed there and
   never reaches `messages`. Everything else goes to `super.dispatchDecoded`.
   Parse with `UploadStreamResult.tryParse(json, requestId)`. On `ok:true`,
   report `onProgress?.call(n, n)` first.
4. **Failure outcomes.**

   | Event | Failure code |
   |---|---|
   | `kUploadResultTimeout` elapses | `TIMEOUT` |
   | `cancel()` | `CANCELLED` |
   | `_ch == null` at send time, or `dispose()` | `TRANSPORT_CLOSED` |

   `dispose()` fails every waiting exchange before `failAllPending`.
5. **Temp cleanup.** The temp directory is deleted recursively, with errors
   swallowed, once the exchange settles. After a cancel it is deleted on the
   next settle, or when the timeout fires, because the bridge may still be
   copying from it.

User-visible behaviour does not change except that loopback progress is now
start then done. The error copy is unchanged because the result codes are the
same, and `UploadService` is not edited for this.

### 3.4 `upload_stream.dart` after A10

- **Kept:**
  - `kUploadStreamSliceBytes`, `kUploadStreamMaxQueuedBytes` and
    `kUploadResultTimeout`;
  - `UploadStreamResult` (with `tryParse`) and `UploadFailure`;
  - the `UploadExchange` interface and `FailedUploadExchange`.
- **Deleted:** `kSocketUploadChunkBytes`, `SocketUploads`,
  `_SocketUploadExchange`, `_isErrorReply`, `_resultFromReply`, `_uuidV4`,
  `_message`, plus the file-header prose about the two paths.

### 3.5 `DemoTransport` (`app/lib/demo/demo_transport.dart`)

- **Delete** its `case 'file:upload-start':`.
- **Override** `openUpload` to return:

  ```dart
  FailedUploadExchange(UploadFailure(kDemoRefusalCode, message: kDemoRefusalText))
  ```

  `_mapFailure`'s default arm passes code and message through, so the copy is
  identical to today's `ok:false` result.

### 3.6 Trims in `machine_session.dart` (behaviour-preserving, target ≥ -350 net in this file)

- **One slot pool.** Replace the three pools with one private `_StreamSlots`
  holding a cap, a FIFO waiter queue, `tryTake()`, `acquire()` →
  `Future<bool>`, `cancelWait` and `release()`. Terminal uses `tryTake`
  (fail-fast, `CAP_EXCEEDED`); tunnel and upload use `acquire` (FIFO wait). On
  session dispose, waiters fail `TRANSPORT_CLOSED` as they do today.
- **One helper for the four exchanges' shared bookkeeping.**
  - It covers: slot held until `_recordsDone`; first-record
    `StreamRefused.tryDecode` → tap → `finish`; a tap-then-`_quietly(reset())`
    pair; and the drain loop. Use a private mixin or base class for the four
    exchange classes.
  - Every Dart error path keeps its explicit reset, and nothing awaits
    `stopped()` or `receivedReset()`.
  - `openBi` still carries the open frame, the 256 KiB slice bound holds, and
    `setPriority` still runs once, before the first write.
- **One raw pump.** Upload and tunnel-http share one raw-body pump (slices of
  `kUploadStreamSliceBytes`, progress only after a write resolves,
  `_TunnelBodyPumpOutcome`).
- **Keep:** `_quietly`, `_quietlyAwait` and `_tryDecodeJsonRecord`. Do not
  inline them into each caller.

---

## 4. Bridge trims (behaviour-preserving)

- **`stream-records.ts`:** add
  `export function stopRecvWhenSettled(pending: Promise<unknown> | null, stop: () => void): void`.
  It replaces every hand-written "stop recv once the pending read settles"
  sequence: `endHttp`, `failHttp` and `readHeadRecord` in `tunnel-streams.ts`,
  and `deliverResult` in `upload-streams.ts`.
- **`stream-dispatch.ts`:** add one shared project-scoped admission gate plus
  binding index. The terminal, tunnel and upload registries each call it
  instead of their own copy.

  ```ts
  export function gateProjectStream<B>(args: {
    peerId: string; projectId: string; checkoutId: string;
    open: number; cap: number;                      // per-peer count for this kind
    projectCataloged: (projectId: string) => boolean;
    binding: (projectId: string) => B | undefined;
    hasOpenProjectStream: (peerId: string, projectId: string) => boolean;
  }): { ok: true; binding: B } | { ok: false; code: StreamRefusedCode; message: string };
  ```

  - **Check order (as today):** cap (`CAP_EXCEEDED`) → `isSafeProjectId` and
    `projectCataloged` (`NOT_ALLOWED`) → binding present → project stream open
    for this peer (`NOT_READY`).
  - **Refusal codes stay unchanged, per registry.** If two registries differ
    today in code or order, keep each one's current behaviour through a
    parameter rather than unifying it. The existing registry tests are the
    oracle.
  - **Terminal's extra check.** Terminal's uuid `requestId` check stays in
    terminal-streams.
  - **The core rule is unchanged.** A stream open never opens or promotes a
    core. `mayAcceptFrom` runs at open and `mayDeliverTo` on every send.
- **`tunnel-streams.ts` (target ≥ -150):**
  - Merge `admitHttp`/`admitWs` into one `admit(kind, …)`, and
    `runHttpHead`/`runWsHead` into one `parseHead(schema, record)`.
  - Add one `withDeadline(promise, ms)` for the `readHeadRecord` timeout race
    and `pullFresh`.
  - Add one `abandon(run)` for the repeated `exchangeAbort.abort();
    writer.abort(); unbind` sequence.
  - `TunnelRequestBodySource` keeps the 256 KiB replay for the scheme retry.
    Shrink it only where it duplicates `StreamRawReader`.
- **`upload-streams.ts` / `terminal-streams.ts`:** use the shared gate. If
  `project-streams.ts` has three `projectBinding`, `tunnelBinding` and
  `uploadBinding` lookups that differ only in field, collapse them into one
  `projectBinding(projectId)` that exposes the bus, `tunnels()` and
  `uploads()`.
- **Binding constraints stay exactly as §1.1 and §1.2 of
  `stage-A-waves.md`:**
  - `writeAll` slices are 256 KiB or smaller;
  - `setPriority` runs once, before the first write;
  - nothing awaits `stopped()` or `receivedReset()`;
  - `authorized()` is checked on every record;
  - an overflow resets only that stream.

---

## 5. Test seams and tests

### 5.1 Seams after A10

| Seam | After A10 |
|---|---|
| `bridge/tests/test-peer-session-owner.ts` | Unchanged. No upload verbs pass through it, so none are added. |
| `packages/antgrid_relay_client/test/support/fake_live_relay.dart` | Implements `PeerLink` only (not `MultiStreamPeerLink`). `openStream` behaviour is unchanged. |
| `evals/helpers/relay-client.ts`, `evals/support/` | Unchanged. |
| `evals/helpers/local-client.ts` (`LocalTestClient`) | Unchanged API. Evals send `file:upload-local` as a plain frame through it. |
| `evals/helpers/dart-app-client.ts` | Only the comment naming `MultiStreamPeerLink` changes. |
| eval client `packages/antgrid_eval_client/lib/src/commands.dart` | Unchanged. It has no upload command. |
| `app/lib/test_helpers/fake_agent_transport.dart` | Unchanged (`openUpload` → `FakeUploadExchange`). |

### 5.2 bridge-tests

**Add** (in `bridge/tests/file-upload-local.test.ts`, new, unless an existing
file fits better):

1. **Nothing is read for a relay-origin frame.** A relay-origin
   `file:upload-local` dispatched through the project-stream path
   (`bus.dispatchInbound(msg,"control","relay",peerId)` on a real
   `attachTransport` bus) produces:
   - no `file:upload-result` or `control:result`;
   - zero calls to `spyOn(FileUploadManager.prototype, "copyLocal")`;
   - zero `checkoutRuntimes.resolve` calls for it, if that is observable;
   - no file in the staging directory.

   The source file exists and would be valid.
2. **Terminal stream refusal.** The same frame arriving on a terminal stream is
   refused by the allowlist, and `copyLocal` is never called.
3. **Session stream.** The same frame on the session stream never reaches a
   core, and `copyLocal` is never called.
4. **`copyLocal` refusals.** Each is refused with no `.part` left behind:

   | Source | Code |
   |---|---|
   | a directory | `INVALID_SOURCE` |
   | missing | `INVALID_SOURCE` |
   | a relative path | `INVALID_SOURCE` |
   | over `MAX_UPLOAD_BYTES` | `TOO_LARGE`, with the source never opened (spy or read-count) |
   | a symlink | `INVALID_SOURCE` (skip on Windows if creating a symlink needs privilege) |

5. **`BUSY`.** `copyLocal` returns `BUSY` beyond the concurrency limit, if the
   limit is observable without timing.
6. **Loopback happy path.** It is byte-identical and returns `path`, `relPath`,
   `mimeType` and a `checkoutId` stamp, in both `main` and an isolated
   checkout. It lands under that checkout's `.antgrid/uploads`. Achieve this by
   rewriting `uploadThrough` in `agent-core-checkout-routing.test.ts` to send
   one `file:upload-local`.
7. **Project mismatch.** A `projectId` that does not match returns
   `NOT_ALLOWED`.

**Change:**

- `agent-core-checkout-routing.test.ts`: rewrite `uploadThrough`. Replace the
  test "a relay-origin file:upload-start is dropped with a warning, while the
  identical loopback frame still uploads" with the same assertion for
  `file:upload-local`.
- `file-upload-protocol.test.ts`: keep only the `file:upload-result` and
  `file:upload-local` schema and `KNOWN_TYPES` assertions. Assert that
  `file:upload-local` is in `CHECKOUT_VARIABLE_MESSAGE_TYPES` and that none of
  the five deleted types parses.
- `file-upload.test.ts`: construct `FileUploadManager` without `send`.

**Delete (name: reason):**

- `file-upload.test.ts`, every test driving `handleStart`, `handleChunk` or
  `handleDone` (the socket-path block at ~68–163 and ~283–304): the code under
  test is deleted.
- `file-upload-protocol.test.ts`, the tests on the chunk, ack, ready and done
  schemas and on `LOOPBACK_UPLOAD_MESSAGE_TYPES`: those schemas are deleted.
- `stream-records.test.ts`:
  - "setPriority runs once even across several sends": pins a call count, a
    binding rule (§1.1) and no rule of ours.
  - "sendRaw and send() share one queue and are written in submission order":
    re-tests in-order delivery.
- `stream-records.test.ts` "writes a single-slice record once, after setting
  priority": change it rather than delete it, to assert only that the bytes
  written equal the framed record. The call ordering it currently pins is an
  implementation detail.
- `upload-streams.test.ts` "the writer sets priority once, at
  STREAM_PRIORITY_UPLOAD, before its first write": pins a call count.
- `tunnel-streams.test.ts`:
  - both priority-once tests (~558, ~605): pin call counts;
  - "…reassembled byte-exact" (~646): re-tests byte integrity through a fake;
  - "WS data records reach the sink in order" (~915): re-tests in-order
    delivery.
- `terminal-streams.test.ts` "an admitted stream sets STREAM_PRIORITY_TERMINAL
  once": pins a call count.

**KEEP:**

- every admission and refusal-code test;
- authorization rechecks;
- caps and size enforcement;
- cancel cleanup;
- "reset only that stream";
- `StreamRawReader` clamp tests (they enforce our cap);
- every `stream-dispatch` test;
- every test of the switch, catalog or `isSafeProjectId`.

Add any further deletion only if it clearly fits one of the two prune
categories. List it by name in your report.

### 5.3 dart+app tests

**Delete (name: reason):**

- `test/socket_uploads_test.dart`, the whole file: `SocketUploads` is deleted.
- `test/local_transport_upload_test.dart` "openUpload rides the socket exchange
  in chunks and settles from the replies, which never reach messages":
  rewrite it rather than delete it, per the list below.
- `upload_stream_test.dart`, group "StreamTransport.openUpload over a
  non-multi-stream link", "falls back to NOT_SUPPORTED": that fallback is
  deleted.
- `tunnel_stream_test.dart`, group "StreamTransport over a non-multi-stream
  link", "openTunnelHttp and openTunnelWs both fall back to NOT_SUPPORTED":
  that fallback is deleted.
- `terminal_attachment_test.dart` "the control transport falls back to the
  socket path over a PeerLink that is not multi-stream": that fallback is
  deleted.
- `machine_session_project_stream_test.dart`, group `STREAM_UNSUPPORTED`, "a
  ready project on a link with no purpose-specific streams fails without ever
  calling openStream": that branch is deleted.
- `_PlainPeerLink` or `_PlainLink` fakes that served only those tests are
  deleted with them. The `leased_peer_link_stream_test.dart` test(s) asserting
  a non-multi-stream inner link is refused: that branch is deleted.
- `tunnel_stream_test.dart` "frames arrive on frames in record order": re-tests
  in-order delivery.
- `terminal_attachment_test.dart` "records arrive on messages in record order
  (hazards A and B)": delete it only if hazards A and B are covered elsewhere
  (they are ordering guarantees of QUIC). Otherwise keep it and say so.
- `upload_stream_test.dart` "lifecycle tap events tag every step
  streamKind:upload, streamId: requestId": pins the tap's private event
  sequence. Keep it if netwatch depends on those tags.
- `native_peer_stream_test.dart` "frames a small record as one writeAll call":
  pins a call count. "slices a record larger than the slice bound" and the
  `writeRecordInSlices` group STAY, because they enforce the 256 KiB bound.

**Change:**

- Every fake that implements `PeerLink` gains `openStream`. These are:
  - `_StubRelay` (`peer_connection_session_binding_test`);
  - `_Payload` (`peer_transport_integration_test`);
  - `_NoopPayloadLink` (`fixed_peer_connector.dart`);
  - `_TestPayloadLink` (`test_peer_runtime.dart`);
  - `_RecordingRelay` (`agent_transport_identity_test`,
    `connection_handshake_test`);
  - `FakeLink` (`connection_attempt_test`);
  - `_QueuedLink` (`leased_peer_link_lifecycle_test`);
  - `_Peer` (`peer_link_test`);
  - any other the analyzer names.
- `fixed_peer_connector.dart`, `project_session_stream_events_test.dart`,
  `relay_connection_open_test.dart`, `leased_peer_link_stream_test.dart`,
  `terminal_attachment_test.dart`, `tunnel_stream_test.dart` and
  `upload_stream_test.dart`: drop the `MultiStreamPeerLink` type references.
- `local_transport_upload_test.dart`, rewritten. Over the loopback test
  socket, `openUpload`:
  - sends exactly one `file:upload-local`;
  - names a temp file whose bytes equal the upload;
  - never sends a chunk frame;
  - settles from a `file:upload-result`, which never reaches `messages`.

  Add cases:
  - `TIMEOUT` (with a fake clock or short override);
  - `CANCELLED`;
  - `TRANSPORT_CLOSED` on dispose;
  - the temp directory is gone after settle.
- `app/test/project/classification_completeness_test.dart`,
  `project_message_classification_test.dart` (status-set length 21 → 19) and
  `app/test/demo/demo_fixture_contract_test.dart`: follow §1.1 and §3.5. The
  demo test asserts that `openUpload` fails with `kDemoRefusalCode` and
  `kDemoRefusalText`, instead of the `file:upload-start` reply.
- `app/test/services/upload_service_test.dart`: unchanged unless it references
  `SocketUploads`.

**KEEP:** every refusal, cap, `CAP_EXCEEDED`, slot-held-until-drain, cancel,
`SEND_FAILED`, `TRUNCATED`, `PROTOCOL`, `STREAM_ENDED`, `TRANSPORT_CLOSED`,
oversize and authorization test, and every `peer_stream_opener_test` test.

### 5.4 evals

- **`evals/tests/file-upload.test.ts`:**
  - Replace "a relay-origin file:upload-start is dropped: no file:upload-ready
    follows it" with "a relay-origin file:upload-local is dropped: no result
    follows and nothing is staged". The source file is real, and the staging
    directory must stay empty.
  - Replace "a multi-chunk loopback upload still lands byte-identical" with "a
    loopback file:upload-local lands byte-identical". Use a file larger than
    512 KiB, send it through `LocalTestClient`, and read it back through
    `file:read` with the returned `relPath`.
  - Keep every native-stream upload test.
- **`evals/soak/native-fault-soak.test.ts`:** call `Bun.gc(true)` on the line
  immediately before `const initialRss = process.memoryUsage().rss` and
  immediately before the per-cycle RSS read. The 128 MiB bound
  (`128 * 1024 * 1024`) is unchanged, and no other change is made.
- **`evals/helpers/dart-app-client.ts`:** only the comment changes.

---

## 6. Docs and ledger

- **`docs/protocol/peer-session.md` and `docs/architecture.md`** (bridge-src):
  - Remove the chunked loopback upload and the "non-multi-stream link" wording.
  - Describe `file:upload-local`: it is loopback only, dropped from any native
    source before the filesystem is touched, stats the source before copying,
    and replies with `file:upload-result`.
- **`bridge/CLAUDE.md` and `bridge/requirements.md`** (bridge-src): update any
  sentence naming the socket upload or `LOOPBACK_UPLOAD_MESSAGE_TYPES`.
- **`packages/antgrid_relay_client/CLAUDE.md`** (dart+app):
  - The `upload_stream.dart` bullet becomes: native path via
    `StreamTransport.openUpload`, loopback via `LocalTransport`'s
    `file:upload-local`.
  - The `machine_session.dart` bullet drops "when the link is a
    `MultiStreamPeerLink`".
- **`app/CLAUDE.md`** (dart+app): only if it mentions either.
- **`docs/iroh-reduction/ledger.md`** (evals writes the row skeleton; the
  integrator fills the numbers). Add:
  - an A10 status row;
  - gate evidence (wire, bridge, relay, relay_client, peer_transport, app,
    evals, `test:evals:native-soak` final RSS delta and
    `test:evals:dart-terminal`);
  - the measured `A7+A10 net = N` from the §0 command;
  - the soak open item marked resolved, if the soak passes under
    `Bun.gc(true)`.

## 7. Gates (integrator)

```bash
bun run --filter antgrid-wire test
bun run --filter antgrid-bridge test > .tmp/a10-bridge.log 2>&1; grep "(fail)" .tmp/a10-bridge.log
bun run --filter antgrid-relay test
cd packages/antgrid_relay_client && dart test
cd packages/antgrid_peer_transport && dart test
cd app && flutter test -j 2
bun run --filter antgrid-evals test:evals
bun run --filter antgrid-evals test:evals:native-soak
bun run --filter antgrid-evals test:evals:dart-terminal
flutter analyze      # once, alone, never concurrently
```

**Pre-existing red that is not A10's:**

- Six stale-runId bridge failures:
  - `index-hook-subcommand` (1);
  - `plugin/antigravity-post-title` (3);
  - `plugin/opencode-notify` (2).
- The `git-branches` stash pop and the `git-sync` already-up-to-date tests can
  time out under load.

## 8. Hard rules for every part

- Edit only the files you own (§9). Everything else goes in `outOfScopeNeeds`.
- Never use `git stash`, `checkout`, `reset` or `restore`.
- Run Bun tests per workspace only. Never run a bare `bun test` at the root.
- Comments are WHY-only: no narration of this wave and no "was socket, now
  stream".
- Every security invariant stays as it is:
  - `remoteFrameAllowed` inbound and `mayDeliver` outbound;
  - `seenProjects` and `isSafeProjectId`;
  - `mayDeliverTo` on every send and `mayAcceptFrom` at open;
  - a stream open never opens or promotes a core.
- Owner decisions D1 to D7 and hazard J stand.

## 9. File ownership (disjoint; every touched file has exactly one owner)

| File | Owner |
|---|---|
| `bridge/src/protocol.ts` | bridge-src |
| `bridge/src/file-upload.ts` | bridge-src |
| `bridge/src/agent-core.ts` | bridge-src |
| `bridge/src/peer/upload-streams.ts` | bridge-src |
| `bridge/src/peer/tunnel-streams.ts` | bridge-src |
| `bridge/src/peer/terminal-streams.ts` | bridge-src |
| `bridge/src/peer/stream-records.ts` | bridge-src |
| `bridge/src/peer/stream-dispatch.ts` | bridge-src |
| `bridge/src/project-streams.ts` | bridge-src |
| `bridge/CLAUDE.md` | bridge-src |
| `bridge/requirements.md` | bridge-src |
| `docs/protocol/peer-session.md` | bridge-src |
| `docs/architecture.md` | bridge-src |
| `bridge/tests/file-upload-local.test.ts` (new) | bridge-tests |
| `bridge/tests/file-upload.test.ts` | bridge-tests |
| `bridge/tests/file-upload-protocol.test.ts` | bridge-tests |
| `bridge/tests/agent-core-checkout-routing.test.ts` | bridge-tests |
| `bridge/tests/upload-streams.test.ts` | bridge-tests |
| `bridge/tests/tunnel-streams.test.ts` | bridge-tests |
| `bridge/tests/terminal-streams.test.ts` | bridge-tests |
| `bridge/tests/stream-records.test.ts` | bridge-tests |
| `bridge/tests/stream-dispatch.test.ts` (only if the gate helper needs direct cases) | bridge-tests |
| `bridge/tests/test-peer-session-owner.ts` (only if a constructor signature forces it) | bridge-tests |
| `packages/antgrid_relay_client/lib/src/peer_link.dart` | dart+app |
| `packages/antgrid_relay_client/lib/src/machine_session.dart` | dart+app |
| `packages/antgrid_relay_client/lib/src/upload_stream.dart` | dart+app |
| `packages/antgrid_relay_client/lib/src/buffered_agent_transport.dart` | dart+app |
| `packages/antgrid_relay_client/lib/src/local_transport.dart` | dart+app |
| `packages/antgrid_relay_client/lib/src/terminal_attachment.dart` (comment) | dart+app |
| `packages/antgrid_relay_client/lib/antgrid_relay_client.dart` (exports, if `SocketUploads`/`MultiStreamPeerLink` are exported) | dart+app |
| `packages/antgrid_relay_client/CLAUDE.md` | dart+app |
| `packages/antgrid_relay_client/test/socket_uploads_test.dart` (delete) | dart+app |
| `packages/antgrid_relay_client/test/local_transport_upload_test.dart` | dart+app |
| `packages/antgrid_relay_client/test/upload_stream_test.dart` | dart+app |
| `packages/antgrid_relay_client/test/tunnel_stream_test.dart` | dart+app |
| `packages/antgrid_relay_client/test/terminal_attachment_test.dart` | dart+app |
| `packages/antgrid_relay_client/test/machine_session_project_stream_test.dart` | dart+app |
| `packages/antgrid_relay_client/test/support/fake_live_relay.dart` | dart+app |
| every other `packages/antgrid_relay_client/test/**` file with a `PeerLink` fake | dart+app |
| `packages/antgrid_peer_transport/lib/src/iroh_peer_link.dart` | dart+app |
| `packages/antgrid_peer_transport/lib/src/leased_peer_link.dart` | dart+app |
| `packages/antgrid_peer_transport/bin/interop_app.dart` | dart+app |
| `packages/antgrid_peer_transport/test/**` (`leased_peer_link_stream_test`, `leased_peer_link_lifecycle_test`, `native_peer_stream_test`, `peer_link_test`, …) | dart+app |
| `app/lib/demo/demo_transport.dart` | dart+app |
| `app/lib/project/project_message_classification.dart` | dart+app |
| `app/lib/services/upload_service.dart` (only if a dead case must go) | dart+app |
| `app/CLAUDE.md` (only if it mentions either topic) | dart+app |
| `app/test/**` (`fixed_peer_connector.dart`, `test_peer_runtime.dart`, `project_session_stream_events_test`, `relay_connection_open_test`, `peer_connection_session_binding_test`, `peer_transport_integration_test`, `agent_transport_identity_test`, `connection_handshake_test`, `connection_attempt_test`, `classification_completeness_test`, `project_message_classification_test`, `demo_fixture_contract_test`, …) | dart+app |
| `evals/tests/file-upload.test.ts` | evals |
| `evals/soak/native-fault-soak.test.ts` | evals |
| `evals/helpers/dart-app-client.ts` (comment) | evals |
| `docs/iroh-reduction/ledger.md` | evals (skeleton), integrator (numbers) |

**Not touched, even though a grep hits them:**

- `packages/antgrid-agents/src/agents/claude-code/chat-backend.ts`: its
  `handleChunk` is an unrelated private method.
- `app/lib/widgets/attachment_preview_dialog.dart`: it names
  `file:upload-result`, which stays.

**Symbols to grep before finishing:**

- `file:upload-start`, `file:upload-ready`, `file:upload-chunk`,
  `file:upload-ack`, `file:upload-done`;
- `LOOPBACK_UPLOAD_MESSAGE_TYPES`, `SocketUploads`, `socketUploads`,
  `kSocketUploadChunkBytes`;
- `MultiStreamPeerLink`, `STREAM_UNSUPPORTED`;
- `handleStart`, `handleChunk`, `handleDone`;
- `UPLOAD_NOT_FOUND`, `BAD_SEQUENCE`, `SIZE_MISMATCH`;
- `new FileUploadManager(`.

Outside `docs/iroh-reduction/` history, each must return zero hits, or only
hits in files this table assigns to you.

---

## 10. As built (integrator reconciliation)

Where this section and §1-§9 disagree, this section describes the code.

### 10.1 Acceptance

- Measured with the §0 command against the working tree: **A10 net = -516**
  (843 added, 1359 removed). **A7+A10 net = +1,399; target missed.** No
  padding was added to close the gap; the remaining A7 growth is the upload
  stream and raw tunnel body code itself (`upload-streams.ts`, the Dart
  stream exchanges, `stream_open.dart`), which this wave keeps.

### 10.2 Deviations from §1-§4

- **§2 / §4 shared gate.** `gateProjectStream` (`peer/stream-dispatch.ts`)
  takes `(peerId, projectId, {open, max, message}, projectCataloged, lookup)`
  and also runs the binding's `refusalFor` (UPDATE_REQUIRED passes through,
  anything else maps to NOT_ALLOWED), which all three registries had copied.
  No `checkoutId` or `hasOpenProjectStream` parameter: the binding's own
  `hasOpenStream` is read.
- **Terminal admission order.** The uuid `requestId` check now runs before the
  cap check (it used to run after it). Only a peer that is both at the cap and
  sending a non-uuid id sees a different code (`INVALID` instead of
  `CAP_EXCEEDED`).
- **`project-streams.ts`.** One public `projectBinding(projectId): ProjectBinding | null`.
  `tunnelBinding`/`uploadBinding` are gone. `native-host-connection.ts` passes
  it to all three registries. The registries keep their option names, typed by
  the `Pick<ProjectBinding, …>` aliases.
- **`withDeadline`** covers `readHeadRecord` only. `pullFresh` keeps its own
  race: the helper's extra microtask hop lets a retry's `awaitIdle()` run
  before `received` is updated (the retry-ordering test fails with it).
- **§3.3 loopback upload.** The temp file is always named `upload` inside its
  own temp dir, because the bridge stages under the request's `fileName`. Each
  in-flight request is a reply `Completer` in `LocalTransport`. `failAllPending`
  fails those `TRANSPORT_CLOSED`, which covers both `dispose()` and a socket
  close. `cancel()` settles the result at once, and the temp dir is deleted
  only after the bridge answers, the timeout fires, or the transport closes.
- **`copyLocal` never rejects (review fix).** The loopback socket parses with
  `parseMessageFast`, which checks `type` alone, so `sourcePath`/`fileName`
  reach `copyLocal` unvalidated, and a failed staging-dir create threw out of
  it. Either rejection reached `index.ts`'s `unhandledRejection` hook, which
  shuts the host down. A non-string `sourcePath` now answers `INVALID_SOURCE`,
  a non-string `fileName` `INVALID_NAME`, a staging-dir failure `WRITE_FAILED`
  (as `begin()` already did), and the `agent-core.ts` handler adds a `.catch`.
  A test also pins that the size cap is read from the stat before any staging
  step (over-cap with staging made impossible still answers `TOO_LARGE`).
- **§3.6 trims.** A private `_StreamExchange` base class holds the slot,
  `_ended`/`_recordsDone`/`_stream`, the lifecycle tap, `_reset`, and the
  first-record refusal decode for all four exchanges. The upload exchange
  settles through one `_settle`. **Not done:** the shared raw pump between
  upload and tunnel-http. Their cancel, progress and error-message semantics
  differ, so a shared pump would change behaviour for about 15 lines.

### 10.3 Tests deleted (name: reason)

Bridge:
- `stream-records` "setPriority runs once even across several sends": pins a call count.
- `stream-records` "sendRaw and send() share one queue and are written in submission order": re-tests in-order delivery.
- `stream-records` "writes a single-slice record once, after setting priority": rewritten to assert only the written bytes.
- `upload-streams` "the writer sets priority once, at STREAM_PRIORITY_UPLOAD, before its first write": pins a call count.
- `terminal-streams` "an admitted stream sets STREAM_PRIORITY_TERMINAL once, before its first write": pins a call count.
- `tunnel-streams` both "…sets STREAM_PRIORITY_TUNNEL once…" tests: pin call counts (serveHttp/serveWs hand-off is covered by the other tests).
- `tunnel-streams` "WS data records reach the sink in order…": re-tests in-order delivery.
- `file-upload` every `handleStart`/`handleChunk`/`handleDone` test, and "MAX_CONCURRENT_UPLOADS is shared between the socket path and the stream path": code deleted (replaced by `copyLocal` cases).
- `file-upload-protocol` "rejects a chunk whose base64 data exceeds the wire cap" and the `LOOPBACK_UPLOAD_MESSAGE_TYPES` test: schemas deleted.

**Kept, although §5.2 listed it for deletion:** `tunnel-streams` "a request
body arriving across several raw reads is reassembled byte-exact, even split
at odd boundaries". Reassembly across pending raw reads is
`TunnelRequestBodySource`'s own code, not a QUIC guarantee.

Dart:
- `socket_uploads_test.dart`, whole file: `SocketUploads` deleted.
- `upload_stream_test` "falls back to NOT_SUPPORTED", `tunnel_stream_test` "openTunnelHttp and openTunnelWs both fall back to NOT_SUPPORTED", `terminal_attachment_test` "the control transport falls back to the socket path over a PeerLink that is not multi-stream", `machine_session_project_stream_test` STREAM_UNSUPPORTED "a ready project on a link with no purpose-specific streams…", `leased_peer_link_stream_test` "openStream throws UnsupportedError when inner has no multi-stream support": the non-multi-stream branch is deleted.
- `tunnel_stream_test` "frames arrive on frames in record order": re-tests in-order delivery.
- `native_peer_stream_test` "frames a small record as one writeAll call": pins a call count.
- `local_transport_upload_test` socket-chunk test: rewritten for `file:upload-local` (plus TIMEOUT, CANCELLED, TRANSPORT_CLOSED).
- Kept: `terminal_attachment_test` "records arrive on messages in record order (hazards A and B)", because no other suite covers hazards A and B; and the upload lifecycle-tap test, because netwatch reads those tags.
