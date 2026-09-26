/**
 * Upload streams (`docs/protocol/peer-session.md` §1e). Every remote file
 * upload gets its own QUIC bidi stream: after the open frame, the app writes
 * exactly `size` raw bytes with no framing at all, then FINs; the bridge
 * answers with exactly one length-prefixed JSON record (a refusal or
 * `file:upload-result`), then FINs its own half.
 *
 * This registry is plugged into `PeerStreamAcceptor` as the `upload` handler.
 * It never opens or promotes a core: `uploadBinding` is a lookup over
 * whatever `ProjectStreamRegistry` already has attached, and the real
 * per-checkout authorization runs through `UploadStreamServer.admit` once the
 * open frame names a checkout.
 */

import { STREAM_MAX_UPLOAD_STREAMS_PER_PEER, type UploadStreamOpen } from "antgrid-wire";
import { createMessage } from "../protocol";
import type { StreamUpload, UploadResultFields } from "../file-upload";
import {
  gateProjectStream,
  refuseStream,
  type AcceptedBiStream,
  type StreamAdmission,
  type StreamHandler,
  type StreamRefusal as DispatchStreamRefusal,
} from "./stream-dispatch";
import { STREAM_RAW_READ_BYTES, StreamRawReader, StreamRecordWriter, stopRecvWhenSettled } from "./stream-records";
import type { UploadProjectBinding } from "../project-streams";
import type { NetwatchStreamKind } from "../netwatch";

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

interface UploadBinding {
  readonly peerId: string;
  /** The open frame's own `requestId`. */
  readonly id: string;
  readonly projectId: string;
  readonly checkoutId: string;
  readonly stream: AcceptedBiStream;
  readonly writer: StreamRecordWriter;
  readonly authorized: () => boolean;
  readonly projBinding: UploadProjectBinding;
  /** Set once `FileUploadManager.begin()` admits the file; the teardown paths
   *  (`projectDetached`/`dropPeer`/a writer failure) cancel it here. */
  upload?: StreamUpload;
  /** Removed from every index and its cap slot freed. The staleness guard
   *  every async step checks: once unbound, nothing may act on this binding
   *  again. */
  unbound: boolean;
  /** The raw read currently outstanding on `recv`, if any — lets a result
   *  delivered out of band (the manager's own inactivity timer) wait for the
   *  binding's shared per-stream mutex to free before calling `recv.stop()`,
   *  rather than queuing behind it (stream-records.ts's binding constraints). */
  pendingRead: Promise<unknown> | null;
}

export interface UploadStreamRegistryOptions {
  /** host-server `seenProjects.has`. Absent => every open is refused NOT_ALLOWED (fail closed). */
  projectCataloged?: (projectId: string) => boolean;
  /** `ProjectStreamRegistry.uploadBinding`. Lookup only: never opens or promotes a core. */
  uploadBinding: (projectId: string) => UploadProjectBinding | null;
  /** Only ever "unauthorized" — this stream carries no length-prefixed
   *  records to violate a framing protocol on. */
  retirePeer: (peerId: string, reason: "unauthorized") => void;
  /** `stream` names the record for `NetwatchEvent.streamKind`/`streamId`, the
   *  same way `TunnelStreamRegistry`'s does. */
  diagnostic?: (type: string, detail: Record<string, unknown>, stream?: { kind: NetwatchStreamKind; id: string }) => void;
}

/** `(peerId, requestId) -> binding`, registered into `PeerStreamAcceptor`'s
 *  handler table as `{ upload: registry.handler }`. */
export class UploadStreamRegistry {
  private readonly bindings = new Map<string, UploadBinding>();
  private readonly peerBindings = new Map<string, Set<UploadBinding>>();

  constructor(private readonly opts: UploadStreamRegistryOptions) {}

  readonly handler: StreamHandler<UploadStreamOpen> = (admission) => this.admitUpload(admission);

  /** Live bindings holding a cap slot for the peer. */
  streamCount(peerId: string): number {
    return this.peerBindings.get(peerId)?.size ?? 0;
  }

  // ---- Admission (steps 1-8, synchronous, before any read) ------------------

  private gate(
    peerId: string,
    open: UploadStreamOpen,
  ): { ok: true; projBinding: UploadProjectBinding } | { ok: false; refusal: DispatchStreamRefusal } {
    const gated = gateProjectStream(
      peerId,
      open.projectId,
      { open: this.streamCount(peerId), max: STREAM_MAX_UPLOAD_STREAMS_PER_PEER, message: "too many uploads" },
      this.opts.projectCataloged,
      (id) => this.opts.uploadBinding(id),
    );
    if (!gated.ok) return gated;
    const projBinding = gated.binding;
    if (this.bindings.has(this.key(peerId, open.requestId))) {
      return { ok: false, refusal: { code: "INVALID", message: "duplicate id" } };
    }
    if (projBinding.uploads() === null) {
      return { ok: false, refusal: { code: "NOT_ALLOWED", message: "uploads not available" } };
    }
    return { ok: true, projBinding };
  }

  private admitUpload(admission: StreamAdmission<UploadStreamOpen>): DispatchStreamRefusal | undefined {
    const { peerId, open, stream, authorized } = admission;
    const gate = this.gate(peerId, open);
    if (!gate.ok) return gate.refusal;

    // Referenced by the writer failure closure below before it is assigned;
    // it only ever runs after this function has returned.
    let binding!: UploadBinding;
    const writer = new StreamRecordWriter(
      stream,
      authorized,
      (reason) => this.onWriterFailure(binding, reason),
      UPLOAD_STREAM_MAX_QUEUED_BYTES,
      STREAM_PRIORITY_UPLOAD,
      STREAM_RESET_UPLOAD,
    );
    binding = {
      peerId,
      id: open.requestId,
      projectId: open.projectId,
      checkoutId: open.checkoutId ?? "main",
      stream,
      writer,
      authorized,
      projBinding: gate.projBinding,
      unbound: false,
      pendingRead: null,
    };
    this.bind(binding);
    void this.continueAdmission(binding, open);
    return undefined;
  }

  /** Steps 9-12: admit against the project's own upload server, then
   *  hand off to `FileUploadManager.begin()` and the raw read loop. */
  private async continueAdmission(binding: UploadBinding, open: UploadStreamOpen): Promise<void> {
    const server = binding.projBinding.uploads();
    if (server === null) {
      this.refuseInline(binding, "NOT_ALLOWED", "uploads not available");
      return;
    }
    const admission = await server.admit(binding.peerId, open.checkoutId ?? "main");
    if (!admission.ok) {
      this.refuseInline(binding, admission.refusal.code, admission.refusal.message);
      return;
    }
    if (binding.unbound) {
      void binding.stream.recv.stop(STREAM_STOP_UPLOAD).catch(() => {});
      return;
    }
    if (!binding.authorized()) {
      this.opts.retirePeer(binding.peerId, "unauthorized");
      return;
    }

    const began = admission.manager.begin(
      { requestId: open.requestId, fileName: open.fileName, size: open.size },
      (result) => { void this.deliverResult(binding, open.requestId, result); },
    );
    if (!began.ok) {
      await this.deliverResult(binding, open.requestId, began.result);
      return;
    }
    binding.upload = began.upload;
    await this.runUploadBody(binding, began.upload, open.size);
  }

  /** Unbinds first, so `refuseStream`'s own writer is the only one that
   *  touches the send half. No read is outstanding at either call site. */
  private refuseInline(binding: UploadBinding, code: DispatchStreamRefusal["code"], message: string): void {
    this.unbind(binding);
    refuseStream(
      binding.stream,
      { code, message },
      binding.authorized,
      () => this.opts.retirePeer(binding.peerId, "unauthorized"),
    );
  }

  // ---- The raw read loop -----------------------------------------------

  /** Requests `remaining + 1` bytes each time: a well-behaved peer's every
   *  read resolves with at most `remaining` (there is nothing more to send),
   *  so a read that returns MORE than `remaining` is the overrun signal
   *  itself — there is no separate probe once the declared size is reached. */
  private async runUploadBody(binding: UploadBinding, upload: StreamUpload, declaredSize: number): Promise<void> {
    const raw = new StreamRawReader(binding.stream);
    let received = 0;
    for (;;) {
      if (binding.unbound) return;
      const remaining = declaredSize - received;
      const want = Math.min(STREAM_RAW_READ_BYTES, remaining + 1);
      const readPromise = raw.read(want);
      binding.pendingRead = readPromise;
      let bytes: Uint8Array | null;
      try {
        bytes = await readPromise;
      } catch {
        binding.pendingRead = null;
        if (binding.unbound) return;
        this.opts.diagnostic?.("upload-stream:cancelled", { peerId: binding.peerId, requestId: binding.id, received },
          { kind: "upload", id: binding.id });
        upload.cancel();
        binding.writer.abort();
        this.unbind(binding);
        return;
      }
      binding.pendingRead = null;
      if (binding.unbound) return;
      if (!binding.authorized()) {
        this.opts.retirePeer(binding.peerId, "unauthorized");
        return;
      }
      if (bytes === null) {
        // A clean FIN: `upload.end()` reports ok or INCOMPLETE through the
        // same `onResult` callback `begin()` was given.
        upload.end();
        return;
      }
      if (bytes.byteLength > remaining) {
        this.opts.diagnostic?.("upload-stream:oversize", { peerId: binding.peerId, requestId: binding.id },
          { kind: "upload", id: binding.id });
        upload.cancel();
        binding.writer.abort();
        this.unbind(binding);
        void binding.stream.recv.stop(STREAM_STOP_UPLOAD).catch(() => {});
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
   *  the binding's shared per-stream mutex (stream-records.ts). */
  private async deliverResult(binding: UploadBinding, requestId: string, fields: UploadResultFields): Promise<void> {
    if (binding.unbound) return;
    if (!binding.projBinding.mayDeliverTo(binding.peerId)) {
      binding.writer.abort();
      this.unbind(binding);
      return;
    }
    await binding.writer.send(encodeJsonRecord(createMessage("file:upload-result", {
      requestId, checkoutId: binding.checkoutId, ...fields,
    })));
    this.opts.diagnostic?.("upload-stream:result",
      { peerId: binding.peerId, requestId, ok: fields.ok, ...(fields.error ? { error: fields.error } : {}) },
      { kind: "upload", id: binding.id });
    await binding.writer.finish();
    const pending = binding.pendingRead;
    this.unbind(binding);
    stopRecvWhenSettled(pending, () => { void binding.stream.recv.stop(STREAM_STOP_UPLOAD).catch(() => {}); });
  }

  // ---- Writer failures, teardown ----------------------------------------------

  private onWriterFailure(binding: UploadBinding, reason: "unauthorized" | "overflow" | "stream-lost"): void {
    if (binding.unbound) return;
    if (reason === "unauthorized") {
      this.opts.retirePeer(binding.peerId, "unauthorized");
      return;
    }
    // "overflow" or "stream-lost": the writer has already reset its own half.
    binding.upload?.cancel();
    this.unbind(binding);
  }

  /** The project's last live `ProjectStreamRegistry` entry detached: its
   *  upload server is gone, so every bound upload for it is cancelled with no
   *  result to report. */
  projectDetached(projectId: string): void {
    for (const set of this.peerBindings.values()) {
      for (const binding of [...set]) {
        if (binding.projectId !== projectId) continue;
        binding.upload?.cancel();
        binding.writer.abort();
        this.unbind(binding);
      }
    }
  }

  /** Connection retired: cancel and unbind everything for the peer. Never
   *  calls `retirePeer` — the peer is already gone. */
  dropPeer(peerId: string): void {
    const set = this.peerBindings.get(peerId);
    if (!set) return;
    for (const binding of [...set]) {
      binding.upload?.cancel();
      binding.writer.abort();
      this.unbind(binding);
    }
  }

  // ---- Indexing ----------------------------------------------------------------

  private bind(binding: UploadBinding): void {
    this.bindings.set(this.key(binding.peerId, binding.id), binding);
    let set = this.peerBindings.get(binding.peerId);
    if (!set) {
      set = new Set();
      this.peerBindings.set(binding.peerId, set);
    }
    set.add(binding);
  }

  /** Removes the index entry and frees the cap slot exactly once. */
  private unbind(binding: UploadBinding): void {
    if (binding.unbound) return;
    binding.unbound = true;
    this.bindings.delete(this.key(binding.peerId, binding.id));
    const set = this.peerBindings.get(binding.peerId);
    if (set) {
      set.delete(binding);
      if (set.size === 0) this.peerBindings.delete(binding.peerId);
    }
  }

  private key(peerId: string, id: string): string {
    return `${peerId}\u0000${id}`;
  }
}
