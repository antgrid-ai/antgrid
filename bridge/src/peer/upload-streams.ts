/**
 * Upload streams (`docs/protocol/peer-session.md` §1e). Every remote file
 * upload gets its own QUIC bidi stream: after the open frame, the app writes
 * exactly `size` raw bytes with no framing at all, then FINs; the bridge
 * answers with exactly one length-prefixed JSON record (a refusal or
 * `file:upload-result`), then FINs its own half.
 *
 * Registered into `PeerStreamAcceptor` as the `upload` handler via
 * `handlerFor("upload")`. Admission (the per-peer cap, the safe-id/catalog
 * checks, the project's own binding lookup) lives once in
 * `ScopedStreamRegistry` (`stream-dispatch.ts`); this file owns only the
 * requestId shape, the raw byte-count read loop, and the one result record.
 */

import { STREAM_MAX_UPLOAD_STREAMS_PER_PEER, type UploadStreamOpen } from "antgrid-wire";
import { createMessage } from "../protocol";
import type { StreamUpload, UploadResultFields } from "../file-upload";
import {
  READ_ENDED,
  READ_UNBOUND,
  ScopedStreamRegistry,
  type ScopedBinding,
  type ScopedEndCause,
  type ScopedStreamOptions,
} from "./stream-dispatch";
import { STREAM_RAW_READ_BYTES, StreamRawReader } from "./stream-records";
import type { UploadProjectBinding } from "../project-streams";

export const UPLOAD_STREAM_MAX_QUEUED_BYTES = 65_536;
/** Below the session stream's binding default of 0, the same as tunnel
 *  traffic (`STREAM_PRIORITY_TUNNEL`): a background file transfer never needs
 *  to preempt a live terminal or project viewer. */
export const STREAM_PRIORITY_UPLOAD = -1;
// Reset/stop codes are bridge diagnostics only — Dart cannot read them back.
export const STREAM_RESET_UPLOAD = 0x1an;
export const STREAM_STOP_UPLOAD = 0x1bn;

const textEncoder = new TextEncoder();

function encodeJsonRecord(record: unknown): Uint8Array {
  return textEncoder.encode(JSON.stringify(record));
}

interface UploadBinding extends ScopedBinding<UploadProjectBinding> {
  readonly checkoutId: string;
  readonly fileName: string;
  readonly size: number;
  /** Set once `FileUploadManager.begin()` admits the file; an abnormal end
   *  cancels it here (`onEnded`). A result already delivered on its own
   *  releases the binding without ever reaching there. */
  upload?: StreamUpload;
}

export type UploadStreamRegistryOptions = ScopedStreamOptions<UploadProjectBinding>;

/** `(peerId, requestId) -> binding`, registered via `handlerFor("upload")`. */
export class UploadStreamRegistry extends ScopedStreamRegistry<UploadStreamOpen, UploadBinding, UploadProjectBinding> {
  constructor(opts: UploadStreamRegistryOptions) {
    super({
      kinds: ["upload"],
      cap: STREAM_MAX_UPLOAD_STREAMS_PER_PEER,
      capMessage: "too many uploads",
      priority: STREAM_PRIORITY_UPLOAD,
      resetCode: STREAM_RESET_UPLOAD,
      stopCode: STREAM_STOP_UPLOAD,
      maxQueuedBytes: UPLOAD_STREAM_MAX_QUEUED_BYTES,
    }, opts);
  }

  protected idOf(open: UploadStreamOpen): string {
    return open.requestId;
  }

  protected available(project: UploadProjectBinding) {
    return project.uploads() === null
      ? { code: "NOT_ALLOWED" as const, message: "uploads not available" }
      : undefined;
  }

  protected createBinding(base: ScopedBinding<UploadProjectBinding>, open: UploadStreamOpen): UploadBinding {
    return { ...base, checkoutId: open.checkoutId ?? "main", fileName: open.fileName, size: open.size };
  }

  protected serve(binding: UploadBinding): void {
    void this.continueAdmission(binding);
  }

  /** The upload has no other way to learn its stream is gone once it is mid
   *  transfer, so every abnormal cause cancels it alike. A result already
   *  delivered (success or failure) releases the binding on its own terms and
   *  never reaches here. */
  protected onEnded(binding: UploadBinding, _cause: ScopedEndCause): void {
    binding.upload?.cancel();
  }

  /** Past the shared gate: the project's own upload server can still go away
   *  between the synchronous admission and this await, so it is re-read here
   *  before admitting against it and handing off to `FileUploadManager.begin()`
   *  and the raw read loop. */
  private async continueAdmission(binding: UploadBinding): Promise<void> {
    const server = binding.project.uploads();
    if (server === null) {
      this.refuseInline(binding, { code: "NOT_ALLOWED", message: "uploads not available" });
      return;
    }
    const admission = await server.admit(binding.peerId, binding.checkoutId);
    if (!admission.ok) {
      this.refuseInline(binding, admission.refusal);
      return;
    }
    if (binding.unbound) {
      // Torn down while `admit()` was outstanding, before any reader existed:
      // nothing else will ever stop this receive half.
      this.stopRecv(binding);
      return;
    }
    if (!this.stillAuthorized(binding)) return;

    const began = admission.manager.begin(
      { requestId: binding.id, fileName: binding.fileName, size: binding.size },
      (result) => { void this.deliverResult(binding, result); },
    );
    if (!began.ok) {
      await this.deliverResult(binding, began.result);
      return;
    }
    binding.upload = began.upload;
    await this.runUploadBody(binding, began.upload);
  }

  /** Requests `remaining + 1` bytes each time: a well-behaved peer's every
   *  read resolves with at most `remaining` (there is nothing more to send),
   *  so a read that returns MORE than `remaining` is the overrun signal
   *  itself — there is no separate probe once the declared size is reached. */
  private async runUploadBody(binding: UploadBinding, upload: StreamUpload): Promise<void> {
    const raw = new StreamRawReader(binding.stream);
    let received = 0;
    for (;;) {
      if (binding.unbound) return;
      const remaining = binding.size - received;
      const want = Math.min(STREAM_RAW_READ_BYTES, remaining + 1);
      const bytes = await this.trackRead(binding, raw.read(want));
      if (bytes === READ_UNBOUND) return;
      if (bytes === READ_ENDED) {
        if (binding.unbound) return;
        this.diag(binding, "upload-stream:cancelled", { peerId: binding.peerId, requestId: binding.id, received });
        this.end(binding, "app-ended");
        return;
      }
      if (!this.stillAuthorized(binding)) return;
      if (bytes === null) {
        // A clean FIN: `upload.end()` reports ok or INCOMPLETE through the
        // same `onResult` callback `begin()` was given.
        upload.end();
        return;
      }
      if (bytes.byteLength > remaining) {
        this.diag(binding, "upload-stream:oversize", { peerId: binding.peerId, requestId: binding.id });
        this.end(binding, "breach");
        return;
      }
      received += bytes.byteLength;
      const outcome = upload.write(bytes);
      // "ok" continues the loop; "failed" has already delivered a WRITE_FAILED
      // result through `onResult`, and "oversize" cannot happen here — our own
      // `remaining` check above already catches every overrun before `write`
      // is ever called with it.
      if (outcome !== "ok") return;
    }
  }

  /** Sends the one result record a stream ever gets, FINs, and stops the
   *  receive half once whatever read is outstanding on it settles — never
   *  before, since `recv.stop()` would otherwise queue behind that read on
   *  the binding's shared per-stream mutex (stream-records.ts). A voluntary,
   *  graceful end on the upload's own terms: `release`, not `end` — the
   *  upload already concluded on its own and must not be cancelled again. */
  private async deliverResult(binding: UploadBinding, fields: UploadResultFields): Promise<void> {
    if (binding.unbound) return;
    if (!binding.project.mayDeliverTo(binding.peerId)) {
      binding.writer.abort();
      this.release(binding);
      return;
    }
    await binding.writer.send(encodeJsonRecord(createMessage("file:upload-result", {
      requestId: binding.id, checkoutId: binding.checkoutId, ...fields,
    })));
    this.diag(binding, "upload-stream:result",
      { peerId: binding.peerId, requestId: binding.id, ok: fields.ok, ...(fields.error ? { error: fields.error } : {}) });
    await binding.writer.finish();
    const pending = binding.pendingRead;
    this.release(binding);
    this.stopRecv(binding, pending);
  }
}
