/**
 * Terminal attachment streams. A terminal attachment gets its own QUIC bidi
 * stream: after the open frame, each record is the raw UTF-8 JSON of one
 * frame-protocol `AbMessage`, with no channel label. Everything else
 * (`terminal:input`, `terminal:resize`, `terminal:start`, ...) stays on the
 * project stream.
 *
 * This registry is plugged into `PeerStreamAcceptor` (via `handlerFor`) as the
 * `terminal` handler and into `ProjectStreamRegistry` as `routeTerminal` +
 * `terminalHooks`. Admission (the per-peer cap, the safe-id/catalog checks,
 * the project's own binding lookup) lives once in `ScopedStreamRegistry`
 * (`stream-dispatch.ts`); this file owns only the requestId shape and the
 * body: which record must come first, how later records are validated, and
 * what ending a binding for any reason means for this kind (a synthesized
 * `terminal:unsubscribe`).
 */

import { z } from "zod";
import {
  STREAM_MAX_TERMINAL_ATTACHMENTS_PER_PEER,
  STREAM_TERMINAL_APP_RECORD_MAX_BYTES,
  STREAM_TERMINAL_BRIDGE_RECORD_MAX_BYTES,
  type TerminalStreamOpen,
} from "antgrid-wire";
import { createMessage, parseMessage, type AbMessage } from "../protocol";
import { StreamRecordReader, type StreamSendOutcome } from "./stream-records";
import {
  READ_ENDED,
  READ_UNBOUND,
  ScopedStreamRegistry,
  STREAM_RESET_SCOPED,
  STREAM_STOP_SCOPED,
  type ScopedBinding,
  type ScopedEndCause,
  type ScopedStreamOptions,
} from "./stream-dispatch";
import type { TerminalProjectBinding } from "../project-streams";

/** One viewer window (`TERMINAL_VIEWER_MAX_BYTES`) plus four history pages
 *  plus notices. Exceeding it resets only this stream — the app reopens
 *  and resyncs. */
export const TERMINAL_STREAM_MAX_QUEUED_BYTES = 3 * 1024 * 1024;
/** Below session (2), above project (0) and tunnel (-1), so a live terminal
 *  viewer never waits behind bulk file transfer or preview traffic. */
export const STREAM_PRIORITY_TERMINAL = 1;

export const TERMINAL_STREAM_INBOUND_TYPES: ReadonlySet<string> = new Set([
  "terminal:subscribe",
  "terminal:ack",
  "terminal:unsubscribe",
  "terminal:history:request",
]);

export const TERMINAL_STREAM_OUTBOUND_TYPES: ReadonlySet<string> = new Set([
  "terminal:subscribed",
  "terminal:frame",
  "terminal:display:status",
  "terminal:history:page",
]);

const requestIdSchema = z.string().uuid();
const textEncoder = new TextEncoder();

export type TerminalStreamRegistryOptions = ScopedStreamOptions<TerminalProjectBinding>;

interface TerminalBinding extends ScopedBinding<TerminalProjectBinding> {
  /** Normalized (absent => "main"); re-stamped from the bridge's own
   *  `terminal:subscribed` once it exists, though it never actually changes. */
  checkoutId: string;
  readonly reader: StreamRecordReader;
  attachmentId?: string;
  runId?: string;
  terminalId?: string;
  /** The app's send half ended (FIN or reset) while a subscribe was still
   *  resolving: the binding stays indexed and bound until `route()` or
   *  `subscribeSettled()` learns the outcome — see `handleAppEnd`. */
  appEnded: boolean;
  /** `writer.finish()` has been issued by `retired()`/`subscribeSettled()`. */
  retiring: boolean;
}

/** `(peerId, requestId | attachmentId) -> binding`, registered into
 *  `PeerStreamAcceptor`'s handler table via `handlerFor("terminal")`. */
export class TerminalStreamRegistry extends ScopedStreamRegistry<TerminalStreamOpen, TerminalBinding, TerminalProjectBinding> {
  private readonly byRequestId = new Map<string, TerminalBinding>();
  private readonly byAttachmentId = new Map<string, TerminalBinding>();

  constructor(opts: TerminalStreamRegistryOptions) {
    super({
      kinds: ["terminal"],
      cap: STREAM_MAX_TERMINAL_ATTACHMENTS_PER_PEER,
      capMessage: "too many terminal attachments",
      priority: STREAM_PRIORITY_TERMINAL,
      resetCode: STREAM_RESET_SCOPED,
      stopCode: STREAM_STOP_SCOPED,
      maxQueuedBytes: TERMINAL_STREAM_MAX_QUEUED_BYTES,
    }, opts);
  }

  protected validateOpen(open: TerminalStreamOpen) {
    if (!requestIdSchema.safeParse(open.requestId).success) {
      return { code: "INVALID" as const, message: "requestId must be a uuid" };
    }
    return undefined;
  }

  protected idOf(open: TerminalStreamOpen): string {
    return open.requestId;
  }

  protected createBinding(base: ScopedBinding<TerminalProjectBinding>, open: TerminalStreamOpen): TerminalBinding {
    let binding!: TerminalBinding;
    const reader = new StreamRecordReader(
      base.stream,
      STREAM_TERMINAL_APP_RECORD_MAX_BYTES,
      () => { if (!binding.unbound) this.opts.retirePeer(base.peerId, "protocol-violation"); },
    );
    binding = { ...base, checkoutId: open.checkoutId ?? "main", reader, appEnded: false, retiring: false };
    this.byRequestId.set(this.indexKey(binding.peerId, binding.id), binding);
    return binding;
  }

  protected serve(binding: TerminalBinding): void {
    void this.runLoop(binding);
  }

  /** Kind cleanup for every abnormal end: an attachment already bound (an
   *  app-side end or a writer overflow/loss) is reported to the core as an
   *  unsubscribe the app can no longer send itself. A breach, a project
   *  detach or a peer drop synthesize nothing — the loop below already
   *  refused a breach before dispatch, and detach/drop have no bus, or nobody,
   *  left to tell. */
  protected onEnded(binding: TerminalBinding, cause: ScopedEndCause): void {
    this.deindex(binding);
    if (cause !== "app-ended" && cause !== "overflow" && cause !== "stream-lost") return;
    if (binding.attachmentId === undefined) return;
    binding.project.dispatch(
      createMessage("terminal:unsubscribe", {
        terminalId: binding.terminalId!,
        runId: binding.runId!,
        attachmentId: binding.attachmentId!,
        checkoutId: binding.checkoutId,
      }),
      binding.peerId,
    );
  }

  /** For each record: parse with full Zod, check it against the terminal record rules,
   *  then hand it to `binding.project.dispatch`. A record that fails
   *  parsing/the rules, or a `dispatch` that returns false, is a STREAM
   *  breach: abort the writer, unbind, and stop the receive half — never the
   *  connection. The app's FIN or reset (a rejected `read()`) is routine and
   *  exits the loop without a `stop`. */
  private async runLoop(binding: TerminalBinding): Promise<void> {
    let first = true;
    for (;;) {
      if (binding.unbound) return;
      const bytes = await this.trackRead(binding, binding.reader.read());
      if (bytes === READ_UNBOUND) return;
      if (bytes === READ_ENDED) {
        // A protocol violation already retired the connection (and so
        // unbound this) before the read threw; only the app's own FIN/reset
        // reaches handleAppEnd.
        if (!binding.unbound) this.handleAppEnd(binding);
        return;
      }
      // Re-checked per record: a lease revoked mid-stream must not keep
      // dispatching whatever the peer already had in flight.
      if (!this.stillAuthorized(binding)) return;
      const msg = parseMessage(Buffer.from(bytes).toString("utf-8"));
      const ok = msg !== null && (first ? this.acceptsFirstRecord(binding, msg) : this.acceptsLaterRecord(binding, msg));
      if (!ok) {
        this.end(binding, "breach");
        return;
      }
      first = false;
      if (!binding.project.dispatch(msg!, binding.peerId)) {
        this.end(binding, "breach");
        return;
      }
    }
  }

  private acceptsFirstRecord(binding: TerminalBinding, msg: AbMessage): boolean {
    if (msg.type !== "terminal:subscribe") return false;
    if (msg.requestId !== binding.id) return false;
    if (msg.checkoutId !== binding.checkoutId) return false;
    binding.terminalId = msg.terminalId;
    return true;
  }

  private acceptsLaterRecord(binding: TerminalBinding, msg: AbMessage): boolean {
    if (msg.type !== "terminal:ack" && msg.type !== "terminal:unsubscribe" && msg.type !== "terminal:history:request") {
      return false;
    }
    // A record naming another attachment, terminal or checkout — or one sent
    // before `subscribed` ever bound attachmentId/runId, since both are then
    // `undefined` on `binding` and can never equal a real uuid — fails here
    // and is a breach rather than silently misrouted.
    return msg.terminalId === binding.terminalId
      && msg.checkoutId === binding.checkoutId
      && msg.attachmentId === binding.attachmentId
      && msg.runId === binding.runId;
  }

  /** The app's FIN or reset. If an attachment was already bound, or none was
   *  ever requested, the binding is done now. Otherwise a subscribe is still
   *  resolving (`terminalId` set, no `attachmentId` yet): hold the binding —
   *  indexed and bound — so `subscribeSettled()`/`route()`'s eventual
   *  `terminal:subscribed` still finishes it, instead of leaking a cap slot
   *  per app close that lands while the subscribe is still in flight. */
  private handleAppEnd(binding: TerminalBinding): void {
    const subscribeInFlight = binding.attachmentId === undefined && binding.terminalId !== undefined;
    if (subscribeInFlight) {
      binding.appEnded = true;
      binding.writer.abort();
      return;
    }
    this.end(binding, "app-ended");
  }

  /** Routes one outbound terminal message onto its bound stream, called from
   *  `ProjectStreamRegistry`'s outbound subscriber (`routeTerminal`) after its
   *  own send gates. `undefined` means no stream is bound for this
   *  (peerId, message) and the caller falls back to the project-stream path —
   *  including history for an attachment already unbound. */
  route(peerId: string, msg: AbMessage, signal?: AbortSignal): Promise<StreamSendOutcome> | undefined {
    if (!TERMINAL_STREAM_OUTBOUND_TYPES.has(msg.type)) return undefined;
    switch (msg.type) {
      case "terminal:subscribed": {
        const binding = this.byRequestId.get(this.indexKey(peerId, msg.requestId));
        if (!binding) return undefined;
        binding.attachmentId = msg.attachmentId;
        binding.runId = msg.runId;
        binding.terminalId = msg.terminalId;
        binding.checkoutId = msg.checkoutId;
        this.indexByAttachment(binding);
        if (binding.appEnded || binding.retiring) {
          this.deindex(binding);
          this.release(binding);
          return Promise.resolve("dropped");
        }
        return this.enqueue(binding, msg, signal);
      }
      case "terminal:display:status": {
        const binding =
          (msg.attachmentId ? this.byAttachmentId.get(this.indexKey(peerId, msg.attachmentId)) : undefined) ??
          (msg.requestId ? this.byRequestId.get(this.indexKey(peerId, msg.requestId)) : undefined);
        if (!binding) return undefined;
        return this.enqueue(binding, msg, signal);
      }
      case "terminal:frame":
      case "terminal:history:page": {
        const binding = this.byAttachmentId.get(this.indexKey(peerId, msg.attachmentId));
        if (!binding) return undefined;
        return this.enqueue(binding, msg, signal);
      }
      default:
        return undefined;
    }
  }

  private enqueue(binding: TerminalBinding, msg: AbMessage, signal?: AbortSignal): Promise<StreamSendOutcome> {
    const bytes = textEncoder.encode(JSON.stringify(msg));
    // Unreachable while delivery caps frames at TERMINAL_VIEWER_MAX_BYTES
    // (1 MiB) — this cap is the app reader's, at twice that.
    if (bytes.length > STREAM_TERMINAL_BRIDGE_RECORD_MAX_BYTES) {
      this.diag(binding, "terminal-stream:oversized-record", { peerId: binding.peerId, type: msg.type, bytes: bytes.length });
      return Promise.resolve("dropped");
    }
    return binding.writer.send(bytes, signal);
  }

  /** Delivery retired the attachment: drain what is already queued (the ENDED
   *  status included), then FIN. A miss means the binding is
   *  already gone — the `appEnded`-before-`subscribed` path unbinds itself. */
  retired(peerId: string, attachmentId: string): void {
    const binding = this.byAttachmentId.get(this.indexKey(peerId, attachmentId));
    if (!binding) return;
    binding.retiring = true;
    void binding.writer.finish();
    this.deindex(binding);
    this.release(binding);
  }

  /** Ends a subscribe attempt that produced no attachment (UPGRADE_REQUIRED,
   *  UNKNOWN_TERMINAL, a failed attach, or a silent `break` in agent-core) by
   *  finishing and unbinding the stream — otherwise it would sit open until
   *  the app's own subscribe deadline. A no-op once the requestId already
   *  bound an attachment (the ordinary success path). */
  subscribeSettled(peerId: string, requestId: string, attachmentId: string | undefined): void {
    const binding = this.byRequestId.get(this.indexKey(peerId, requestId));
    if (!binding) return;
    if (attachmentId === undefined && binding.attachmentId === undefined) {
      binding.retiring = true;
      void binding.writer.finish();
      this.deindex(binding);
      this.release(binding);
    }
  }

  private indexByAttachment(binding: TerminalBinding): void {
    if (binding.attachmentId === undefined) return;
    this.byAttachmentId.set(this.indexKey(binding.peerId, binding.attachmentId), binding);
  }

  private deindex(binding: TerminalBinding): void {
    this.byRequestId.delete(this.indexKey(binding.peerId, binding.id));
    if (binding.attachmentId !== undefined) this.byAttachmentId.delete(this.indexKey(binding.peerId, binding.attachmentId));
  }

  private indexKey(peerId: string, id: string): string {
    return `${peerId}\u0000${id}`;
  }
}
