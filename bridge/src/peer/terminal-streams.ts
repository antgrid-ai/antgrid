/**
 * Terminal attachment streams (Stage A wave A2,
 * docs/iroh-reduction/stage-A-A2-contract.md §3.2). A terminal attachment gets
 * its own QUIC bidi stream: after the A0b open frame, each record is the raw
 * UTF-8 JSON of one frame-protocol `AbMessage` — no `{s, m}` envelope, no
 * channel label. Everything else (`terminal:input`, `terminal:resize`,
 * `terminal:start`, ...) stays on the project stream, unchanged.
 *
 * This registry is plugged into `PeerStreamAcceptor` as the `terminal`
 * handler and into `ProjectStreamRegistry` as `routeTerminal` +
 * `terminalHooks`. It never opens or promotes a core: `projectBinding` is a
 * lookup over whatever the registry already has attached.
 */

import { z } from "zod";
import {
  STREAM_MAX_TERMINAL_ATTACHMENTS_PER_PEER,
  STREAM_TERMINAL_APP_RECORD_MAX_BYTES,
  STREAM_TERMINAL_BRIDGE_RECORD_MAX_BYTES,
  type TerminalStreamOpen,
} from "antgrid-wire";
import { isSafeProjectId } from "../project-id";
import { createMessage, parseMessage, type AbMessage } from "../protocol";
import {
  StreamRecordReader,
  StreamRecordWriter,
  type StreamSendOutcome,
  type StreamWriteFailure,
} from "./stream-records";
import type {
  AcceptedBiStream,
  StreamAdmission,
  StreamHandler,
  StreamRefusal as DispatchStreamRefusal,
} from "./stream-dispatch";
import type { PeerSessionView, TerminalProjectBinding } from "../project-streams";

/** One viewer window (`TERMINAL_VIEWER_MAX_BYTES`) plus four history pages
 *  plus notices. Exceeding it resets only this stream (D3) — the app reopens
 *  and resyncs. */
export const TERMINAL_STREAM_MAX_QUEUED_BYTES = 3 * 1024 * 1024;
/** Above the session stream's binding default of 0 (§9 D-8: A4 must place
 *  project streams below it too). */
export const STREAM_PRIORITY_TERMINAL = 1;
// Reset/stop codes are bridge diagnostics only — Dart cannot read them back.
export const STREAM_RESET_TERMINAL = 0x13n;
export const STREAM_STOP_TERMINAL = 0x14n;

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

export interface TerminalStreamRegistryOptions {
  /** host-server `seenProjects.has`. Absent => every open is refused NOT_ALLOWED (fail closed). */
  projectCataloged?: (projectId: string) => boolean;
  /** `ProjectStreamRegistry.projectBinding`. Lookup only: never opens or promotes a core. */
  projectBinding: (projectId: string) => TerminalProjectBinding | null;
  peerSession: (peerId: string) => PeerSessionView | null;
  /** Retires the whole connection. Only ever called with "unauthorized" (writer) or
   *  "protocol-violation" (a malformed length prefix from StreamRecordReader). */
  retirePeer: (peerId: string, reason: "unauthorized" | "protocol-violation") => void;
  diagnostic?: (type: string, detail: Record<string, unknown>) => void;
}

interface Binding {
  readonly peerId: string;
  readonly requestId: string;
  readonly projectId: string;
  /** Normalized (absent => "main"); re-stamped from the bridge's own
   *  `terminal:subscribed` once it exists, though it never actually changes. */
  checkoutId: string;
  readonly stream: AcceptedBiStream;
  readonly writer: StreamRecordWriter;
  readonly reader: StreamRecordReader;
  readonly projectBinding: TerminalProjectBinding;
  attachmentId?: string;
  runId?: string;
  terminalId?: string;
  /** The app's send half ended (FIN or reset) before this binding was unbound. */
  appEnded: boolean;
  /** `writer.finish()` has been issued by `retired()`/`subscribeSettled()`. */
  retiring: boolean;
  /** Removed from every index and its cap slot freed. Doubles as the
   *  staleness guard a torn-down connection's late callbacks check: once a
   *  binding is unbound (by `dropPeer`, an unauthorized writer failure's
   *  eventual peer retirement, or its own lifecycle), nothing may act on it
   *  again — which is what keeps a lagging callback from a dead connection
   *  reaching into whatever now uses the same peerId. */
  unbound: boolean;
}

/** `(peerId, requestId | attachmentId) -> writer`, registered into
 *  `PeerStreamAcceptor`'s handler table as `{ terminal: registry.handler }`. */
export class TerminalStreamRegistry {
  private readonly byRequestId = new Map<string, Binding>();
  private readonly byAttachmentId = new Map<string, Binding>();
  private readonly peerBindings = new Map<string, Set<Binding>>();

  constructor(private readonly opts: TerminalStreamRegistryOptions) {}

  readonly handler: StreamHandler<TerminalStreamOpen> = (admission) => this.admit(admission);

  attachmentCount(peerId: string): number {
    return this.peerBindings.get(peerId)?.size ?? 0;
  }

  /** Every check is synchronous and runs before any read is issued on `recv`
   *  (carry-over 2): a handler that has started its read loop never returns a
   *  refusal again. */
  private admit(admission: StreamAdmission<TerminalStreamOpen>): DispatchStreamRefusal | undefined {
    const { peerId, open, stream, authorized } = admission;
    const { projectId, requestId } = open;
    const checkoutId = open.checkoutId ?? "main";

    if (this.attachmentCount(peerId) >= STREAM_MAX_TERMINAL_ATTACHMENTS_PER_PEER) {
      return { code: "CAP_EXCEEDED", message: "too many terminal attachments" };
    }
    if (!requestIdSchema.safeParse(requestId).success) {
      return { code: "INVALID", message: "requestId must be a uuid" };
    }
    if (!isSafeProjectId(projectId)) {
      return { code: "NOT_ALLOWED", message: "unsafe project id" };
    }
    if (!this.opts.projectCataloged || !this.opts.projectCataloged(projectId)) {
      return { code: "NOT_ALLOWED", message: "project not recognized" };
    }
    const projectBinding = this.opts.projectBinding(projectId);
    if (projectBinding === null) {
      return { code: "NOT_READY", message: "project is not attached" };
    }
    // A4: the project stream is the single per-peer admission point for a
    // projectId — this is what keeps root CLAUDE.md's "seenProjects +
    // isSafeProjectId are the only bound" true. Closing the project stream
    // does not unbind an already-open terminal stream.
    if (!projectBinding.hasOpenStream(peerId)) {
      return { code: "NOT_ALLOWED", message: "open the project stream first" };
    }
    const refusal = projectBinding.refusalFor(peerId);
    if (refusal) {
      return refusal.code === "UPDATE_REQUIRED"
        ? { code: "UPDATE_REQUIRED", message: refusal.message }
        : { code: "NOT_ALLOWED", message: refusal.message };
    }
    if (this.byRequestId.has(this.key(peerId, requestId))) {
      return { code: "INVALID", message: "duplicate requestId" };
    }

    // `binding` is referenced by the writer/reader failure closures below
    // before it is assigned; both only ever run after `admit` has returned.
    let binding!: Binding;
    const writer = new StreamRecordWriter(
      stream,
      authorized,
      (reason) => this.onWriterFailure(binding, reason),
      TERMINAL_STREAM_MAX_QUEUED_BYTES,
      STREAM_PRIORITY_TERMINAL,
      STREAM_RESET_TERMINAL,
    );
    const reader = new StreamRecordReader(
      stream,
      STREAM_TERMINAL_APP_RECORD_MAX_BYTES,
      () => {
        if (!binding.unbound) this.opts.retirePeer(peerId, "protocol-violation");
      },
    );
    binding = {
      peerId,
      requestId,
      projectId,
      checkoutId,
      stream,
      writer,
      reader,
      projectBinding,
      appEnded: false,
      retiring: false,
      unbound: false,
    };
    this.bindRequest(binding);
    void this.runLoop(binding);
    return undefined;
  }

  /** For each record: parse with full Zod, check it against the §1 rules,
   *  then hand it to `binding.projectBinding.dispatch`. A record that fails
   *  parsing/the rules, or a `dispatch` that returns false, is a STREAM
   *  breach: abort the writer, unbind, and stop the receive half — never the
   *  connection. The app's FIN or reset (a rejected `read()`) is routine and
   *  exits the loop without a `stop`. */
  private async runLoop(binding: Binding): Promise<void> {
    let first = true;
    for (;;) {
      let bytes: Uint8Array;
      try {
        bytes = await binding.reader.read();
      } catch {
        // A StreamProtocolViolation already retired the connection through
        // the reader's own onFailure (synchronously, before it threw), which
        // unbinds every one of this peer's bindings via dropPeer — so by the
        // time we get here `unbound` is already true for that case, and this
        // branch only ever does real work for the app's own FIN/reset.
        if (!binding.unbound) this.handleAppEnd(binding);
        return;
      }
      if (binding.unbound) {
        // Retired or settled while this read was outstanding. The read has
        // completed, so the recv lock is free: stop the half rather than
        // abandon it, or the stream keeps its QUIC stream slot until GC.
        void binding.stream.recv.stop(STREAM_STOP_TERMINAL).catch(() => {});
        return;
      }
      const msg = parseMessage(Buffer.from(bytes).toString("utf-8"));
      const ok = msg !== null && (first ? this.acceptsFirstRecord(binding, msg) : this.acceptsLaterRecord(binding, msg));
      if (!ok) {
        this.breach(binding);
        return;
      }
      first = false;
      if (!binding.projectBinding.dispatch(msg!, binding.peerId)) {
        this.breach(binding);
        return;
      }
    }
  }

  private breach(binding: Binding): void {
    binding.writer.abort();
    this.unbind(binding);
    void binding.stream.recv.stop(STREAM_STOP_TERMINAL).catch(() => {});
  }

  private acceptsFirstRecord(binding: Binding, msg: AbMessage): boolean {
    if (msg.type !== "terminal:subscribe") return false;
    if (msg.requestId !== binding.requestId) return false;
    if (msg.checkoutId !== binding.checkoutId) return false;
    binding.terminalId = msg.terminalId;
    return true;
  }

  private acceptsLaterRecord(binding: Binding, msg: AbMessage): boolean {
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

  /** The app's FIN or reset. If an attachment was already bound, synthesize
   *  the `terminal:unsubscribe` the app can no longer send itself, exactly as
   *  if it had (carry-over: FIN/reset means unsubscribe). Otherwise the
   *  binding stays indexed by requestId, marked `appEnded`, so a
   *  `terminal:subscribed` or `display:status` still in flight from the core
   *  resolves through `route()` instead of vanishing — see its handling —
   *  unless the subscribe itself never arrived. */
  private handleAppEnd(binding: Binding): void {
    const hadAttachment = binding.attachmentId !== undefined;
    // No subscribe was ever dispatched, so no `subscribed` or `subscribeSettled`
    // will come to unbind it: holding it would leak a cap slot per app close
    // that lands while its open is still resolving.
    const subscribeInFlight = binding.terminalId !== undefined;
    if (hadAttachment) {
      binding.projectBinding.dispatch(
        createMessage("terminal:unsubscribe", {
          terminalId: binding.terminalId!,
          runId: binding.runId!,
          attachmentId: binding.attachmentId!,
          checkoutId: binding.checkoutId,
        }),
        binding.peerId,
      );
    }
    binding.appEnded = true;
    binding.writer.abort();
    if (hadAttachment || !subscribeInFlight) this.unbind(binding);
  }

  private onWriterFailure(binding: Binding, reason: StreamWriteFailure): void {
    if (binding.unbound) return;
    if (reason === "unauthorized") {
      this.opts.retirePeer(binding.peerId, "unauthorized");
      return;
    }
    // "overflow" or "stream-lost": the writer has already reset its half.
    if (binding.attachmentId !== undefined) {
      binding.projectBinding.dispatch(
        createMessage("terminal:unsubscribe", {
          terminalId: binding.terminalId!,
          runId: binding.runId!,
          attachmentId: binding.attachmentId!,
          checkoutId: binding.checkoutId,
        }),
        binding.peerId,
      );
    }
    this.unbind(binding);
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
        const binding = this.byRequestId.get(this.key(peerId, msg.requestId));
        if (!binding) return undefined;
        binding.attachmentId = msg.attachmentId;
        binding.runId = msg.runId;
        binding.terminalId = msg.terminalId;
        binding.checkoutId = msg.checkoutId;
        this.indexByAttachment(binding);
        if (binding.appEnded || binding.retiring) {
          this.unbind(binding);
          return Promise.resolve("dropped");
        }
        return this.enqueue(binding, msg, signal);
      }
      case "terminal:display:status": {
        const binding =
          (msg.attachmentId ? this.byAttachmentId.get(this.key(peerId, msg.attachmentId)) : undefined) ??
          (msg.requestId ? this.byRequestId.get(this.key(peerId, msg.requestId)) : undefined);
        if (!binding) return undefined;
        return this.enqueue(binding, msg, signal);
      }
      case "terminal:frame":
      case "terminal:history:page": {
        const binding = this.byAttachmentId.get(this.key(peerId, msg.attachmentId));
        if (!binding) return undefined;
        return this.enqueue(binding, msg, signal);
      }
      default:
        return undefined;
    }
  }

  private enqueue(binding: Binding, msg: AbMessage, signal?: AbortSignal): Promise<StreamSendOutcome> {
    const bytes = textEncoder.encode(JSON.stringify(msg));
    // Unreachable while delivery caps frames at TERMINAL_VIEWER_MAX_BYTES
    // (1 MiB) — this cap is the app reader's, at twice that.
    if (bytes.length > STREAM_TERMINAL_BRIDGE_RECORD_MAX_BYTES) {
      this.opts.diagnostic?.("terminal-stream:oversized-record", {
        peerId: binding.peerId,
        type: msg.type,
        bytes: bytes.length,
      });
      return Promise.resolve("dropped");
    }
    return binding.writer.send(bytes, signal);
  }

  /** Delivery retired the attachment: drain what is already queued (the ENDED
   *  status included, carry-over 1), then FIN. A miss means the binding is
   *  already gone — the `appEnded`-before-`subscribed` path unbinds itself. */
  retired(peerId: string, attachmentId: string): void {
    const binding = this.byAttachmentId.get(this.key(peerId, attachmentId));
    if (!binding) return;
    binding.retiring = true;
    void binding.writer.finish();
    this.unbind(binding);
  }

  /** Ends a subscribe attempt that produced no attachment (UPGRADE_REQUIRED,
   *  UNKNOWN_TERMINAL, a failed attach, or a silent `break` in agent-core) by
   *  finishing and unbinding the stream — otherwise it would sit open until
   *  the app's own subscribe deadline. A no-op once the requestId already
   *  bound an attachment (the ordinary success path). */
  subscribeSettled(peerId: string, requestId: string, attachmentId: string | undefined): void {
    const binding = this.byRequestId.get(this.key(peerId, requestId));
    if (!binding) return;
    if (attachmentId === undefined && binding.attachmentId === undefined) {
      binding.retiring = true;
      void binding.writer.finish();
      this.unbind(binding);
    }
  }

  /** The project's last live `ProjectStreamRegistry` entry detached: its bus is
   *  gone, so every bound stream is aborted with no synthesized unsubscribe
   *  (there is nothing left to dispatch one to). */
  projectDetached(projectId: string): void {
    for (const set of this.peerBindings.values()) {
      for (const binding of [...set]) {
        if (binding.projectId !== projectId) continue;
        binding.writer.abort();
        this.unbind(binding);
      }
    }
  }

  /** Connection retired: unbind everything for the peer without dispatching
   *  anything — the peer is gone, so there is nobody to synthesize an
   *  unsubscribe for. `unbind`'s idempotence and the `unbound` guard every
   *  other method checks are what keep a callback still in flight for one of
   *  these bindings from doing anything once this has run. */
  dropPeer(peerId: string): void {
    const set = this.peerBindings.get(peerId);
    if (!set) return;
    for (const binding of [...set]) {
      binding.writer.abort();
      this.unbind(binding);
    }
  }

  private bindRequest(binding: Binding): void {
    this.byRequestId.set(this.key(binding.peerId, binding.requestId), binding);
    let set = this.peerBindings.get(binding.peerId);
    if (!set) {
      set = new Set();
      this.peerBindings.set(binding.peerId, set);
    }
    set.add(binding);
  }

  private indexByAttachment(binding: Binding): void {
    if (binding.attachmentId === undefined) return;
    this.byAttachmentId.set(this.key(binding.peerId, binding.attachmentId), binding);
  }

  /** Removes both index entries and frees the cap slot exactly once. */
  private unbind(binding: Binding): void {
    if (binding.unbound) return;
    binding.unbound = true;
    this.byRequestId.delete(this.key(binding.peerId, binding.requestId));
    if (binding.attachmentId !== undefined) {
      this.byAttachmentId.delete(this.key(binding.peerId, binding.attachmentId));
    }
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
