import { createMessage } from "../protocol";
// The wire message types come from the registry, not from ./protocol — that
// file owns the payload sub-schemas and the budgets, and registration made
// bridge/src/protocol.ts the single home of the eight envelopes.
import type {
  TerminalAck, TerminalDisplayStatus, TerminalFrame, TerminalSubscribed,
} from "../protocol";
import type { TerminalFrameSource } from "./source";
import {
  TERMINAL_ACK_TIMEOUT_MS, TERMINAL_CONNECTION_MAX_BYTES, TERMINAL_FRAME_INTERVAL_MS,
  TERMINAL_PROTOCOL_VERSION, TERMINAL_VIEWER_MAX_BYTES, TERMINAL_VIEWER_MAX_FRAMES,
  encodedJsonBytes, type TerminalScreenFrame,
} from "./protocol";

export interface TerminalAddress { projectId: string; checkoutId: string; terminalId: string }
/** `projectId` is hub-local keying and is deliberately NOT on the wire: a frame
 *  already travels a per-project stream, and none of the eight schemas declares
 *  the field, so spreading the whole address would hand Zod a key it silently
 *  strips at parseMessage. Destructuring makes that a decision rather than a
 *  loss nobody sees. */
const wireAddress = ({ checkoutId, terminalId }: TerminalAddress) => ({ checkoutId, terminalId });
type ViewerMessage = TerminalFrame | TerminalSubscribed | TerminalDisplayStatus;
export interface TerminalViewerTransport {
  /** Shared by project streams on the same authenticated machine connection. */
  budget?: { bytes: number };
  /** Resolve after handing off, not after consumption. Aborting must remove
   * unsent plaintext from the transport queue before encryption/fragmentation. */
  send(message: ViewerMessage, signal: AbortSignal): Promise<void>;
  authorized(address: TerminalAddress): boolean;
  /** This attachment is gone for good and nothing will be sent under its id
   *  again — ack timeout, a failed capture, an unsubscribe, the run being
   *  removed, or the connection closing. REQUIRED for any owner that gates
   *  other traffic on "someone is watching frames for this terminal": most
   *  retirements happen inside this file, on the hub's own clock, so an owner
   *  that only watches the inbound verbs it dispatched will keep suppressing
   *  a stream nothing is replacing. Never fired for a merely paused
   *  attachment (see `pause`), which resumes on its own. */
  retired?(address: TerminalAddress, attachmentId: string): void;
}
interface Run {
  address: TerminalAddress;
  runId: string;
  source: TerminalFrameSource;
  lastCapture: number;
  capturedRevision: number;
  frame?: TerminalScreenFrame;
  finalRevision?: number;
  released?: boolean;
  exitCode?: number | null;
  failure?: string;
  detach: () => void;
}
interface Attachment {
  id: string;
  run: Run;
  controller: AbortController;
  ready: boolean;
  sequence: number;
  acknowledged: number;
  revision: number;
  bytes: number;
  progressAt: number;
  lastSent: number;
  pending: Map<number, number>;
  unsent?: { sequence: number; revision: number; controller: AbortController };
  awaitingConsumption?: boolean;
  ended: boolean;
  oversizeNotified: boolean;
}
const key = (address: TerminalAddress) => JSON.stringify([address.projectId, address.checkoutId, address.terminalId]);

/** Shared capture cache for all authenticated connections on this machine. */
export class TerminalFrameHub {
  private readonly runs = new Map<string, Run>();
  private readonly connections = new Set<TerminalViewerConnection>();
  private timer?: ReturnType<typeof setInterval>;

  constructor(private readonly now: () => number = () => performance.now()) {}

  // runId is minted by TerminalManager.spawn() and is the history store's
  // key (see terminal-manager.ts / terminal-frames/history.ts) — a
  // hub-minted id would name a run the history store has never heard of, so
  // every terminal:history:request for it comes back empty. No default: a
  // caller that forgets to pass one must fail to compile, not silently get
  // an orphaned run.
  register(address: TerminalAddress, source: TerminalFrameSource, runId: string): string {
    const existing = this.runs.get(key(address));
    if (existing && existing.runId === runId) {
      // Same run, new emulator: `TerminalManager.ensureLiveScreen` rebuilds a
      // source that latched a parse failure and re-registers it under the run
      // the PTY is STILL running (see `onRunStarted`'s doc there). Removing
      // and re-adding would retire every viewer of a terminal that never
      // stopped, so the Run is kept and only what belongs to the old emulator
      // is reset. Revision counters restart at 0 in the replacement, so every
      // attachment's high-water mark has to go with them or no frame ever
      // clears `frame.revision <= attachment.revision` again.
      // `finalRevision` counts in the OLD emulator's numbering, which the
      // replacement's counter — restarting at 0 like every other revision
      // counter reset here — can never reach. Left standing it makes
      // `tickAttachment`'s ENDED branch unreachable and its `lastFrame`
      // exemption permanent, so the viewer is never retired and never paced
      // again. Re-derived instead of dropped: the run really did finish, and
      // `finish` is what re-reads it off the emulator that now holds the
      // screen.
      const finishedWith = existing.finalRevision !== undefined ? existing.exitCode ?? null : undefined;
      existing.finalRevision = undefined;
      existing.detach();
      existing.source = source;
      existing.lastCapture = -Infinity;
      existing.capturedRevision = -1;
      existing.frame = undefined;
      existing.failure = undefined;
      existing.detach = source.onParsed(() => this.tick());
      for (const connection of this.connections) connection.resetRun(existing);
      this.tick();
      // Caught, not voided: `index.ts` shuts the host down on an unhandled
      // rejection.
      if (finishedWith !== undefined) void this.finish(address, runId, finishedWith).catch(() => {});
      return runId;
    }
    this.remove(address);
    const run: Run = { address, runId, source, lastCapture: -Infinity, capturedRevision: -1, detach: () => {} };
    this.runs.set(key(address), run);
    run.detach = source.onParsed(() => this.tick());
    return runId;
  }

  async finish(address: TerminalAddress, runId: string, exitCode: number | null): Promise<void> {
    const run = this.runs.get(key(address));
    if (!run || run.runId !== runId) return;
    await run.source.settle();
    if (this.runs.get(key(address)) !== run) return;
    // The final revision shares the live capture budget, then remains cached
    // until viewers acknowledge it or their attachments expire.
    if (run.capturedRevision !== run.source.revision) {
      const delay = TERMINAL_FRAME_INTERVAL_MS - (this.now() - run.lastCapture);
      if (delay > 0) await new Promise<void>((resolve) => setTimeout(resolve, delay));
      if (this.runs.get(key(address)) !== run) return;
      if (run.capturedRevision !== run.source.revision) this.captureInto(run, this.now(), true);
    }
    run.finalRevision = run.source.revision;
    run.exitCode = exitCode;
    this.tick();
  }

  releaseFinished(address: TerminalAddress, runId: string, exitCode?: number | null): void {
    const run = this.runs.get(key(address));
    if (!run || run.runId !== runId) return;
    // The immutable final frame outlives the emulator while slow viewers drain.
    // Respawn and deletion still remove it explicitly.
    if (run.finalRevision === undefined) this.remove(address, exitCode);
    else {
      run.released = true;
      run.detach();
      this.schedule();
    }
  }

  /** `exitCode` is carried only so the ENDED notice each viewer gets can name
   *  it. Absent means the run is over for a reason that is not an exit — a
   *  same-id respawn taking the slot, or `forget()` — where the viewer still
   *  has to be told its attachment is finished. */
  remove(address: TerminalAddress, exitCode?: number | null): void {
    const run = this.runs.get(key(address));
    if (!run) return;
    this.runs.delete(key(address));
    run.detach();
    for (const connection of this.connections) connection.retireRun(run, exitCode);
  }

  connect(transport: TerminalViewerTransport): TerminalViewerConnection {
    const connection = new TerminalViewerConnection(this, transport, this.now);
    this.connections.add(connection);
    return connection;
  }

  find(address: TerminalAddress): Run | undefined { return this.runs.get(key(address)); }

  frame(run: Run, now: number): TerminalScreenFrame | undefined {
    if (run.failure) return undefined;
    if (run.capturedRevision !== run.source.revision && now - run.lastCapture >= TERMINAL_FRAME_INTERVAL_MS) {
      this.captureInto(run, now);
    }
    return run.frame;
  }

  /** Serializes the source into `run.frame`, charging the throttle on the
   *  ATTEMPT, never on the result. `capture()` returns null on three routine
   *  paths — an oversize screen, synchronized output (DECSET 2026, which modern
   *  TUIs hold continuously) and a pending tail off a parse boundary — and the
   *  live caller runs on every `onParsed` as well as on the interval, so a
   *  throttle that only advanced on success let a busy PTY drive a full
   *  serialize per parse event. The oversize path is the expensive one:
   *  serializeNow() + linkOverlay() + encodedJsonBytes() all run before the
   *  size check returns null. */
  private captureInto(run: Run, now: number, final = false): void {
    run.lastCapture = now;
    const attemptedRevision = run.source.revision;
    try {
      const frame = run.source.capture(now, { final });
      if (frame) {
        run.capturedRevision = frame.revision;
        run.frame = frame;
      } else if (run.source.oversize) {
        // Nothing about re-serializing an UNCHANGED screen can make it fit,
        // so this revision is considered done. The other two null paths are
        // transient and must be retried, which the interval above bounds.
        run.capturedRevision = attemptedRevision;
      }
    } catch (error) { run.failure = error instanceof Error ? error.message : String(error); }
  }

  tick(): void {
    const now = this.now();
    for (const connection of this.connections) {
      try {
        connection.tick(now);
      } catch {
        // This drives a bare setInterval (see schedule()) with nothing above
        // it to catch — an escaped throw here kills the host process. Each
        // connection guards its own attachments already (see
        // TerminalViewerConnection.tick); this is the backstop for a failure
        // above that per-attachment guard. Leave the connection attached and
        // move on to the rest: one bad connection skips this tick, every
        // other connection still gets its frames, and a transient cause
        // (rather than a systemic one) heals on the next tick.
      }
    }
  }

  schedule(): void {
    for (const [address, run] of this.runs) {
      if (run.released && ![...this.connections].some((connection) => connection.watches(run))) {
        this.runs.delete(address);
      }
    }
    const needed = [...this.connections].some((connection) => connection.size > 0);
    if (needed && !this.timer) {
      this.timer = setInterval(() => this.tick(), TERMINAL_FRAME_INTERVAL_MS);
      this.timer.unref();
    } else if (!needed && this.timer) { clearInterval(this.timer); this.timer = undefined; }
  }

  disconnect(connection: TerminalViewerConnection): void {
    this.connections.delete(connection);
    this.schedule();
  }

  dispose(): void {
    for (const connection of [...this.connections]) connection.close();
    for (const run of this.runs.values()) run.detach();
    this.runs.clear();
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
  }
}

/** Connection identity is this object, allocated by authenticated transport
 * establishment. No connection/project identity from a wire payload is trusted. */
export class TerminalViewerConnection {
  private readonly attachments = new Map<string, Attachment>();
  private bytes = 0;
  private cursor = 0;
  private closed = false;
  private readonly budget: { bytes: number };

  constructor(
    private readonly hub: TerminalFrameHub,
    private readonly transport: TerminalViewerTransport,
    private readonly now: () => number,
  ) { this.budget = transport.budget ?? { bytes: 0 }; }

  get size(): number { return this.attachments.size; }

  watches(run: Run): boolean {
    return [...this.attachments.values()].some((attachment) => attachment.run === run);
  }
  get unacknowledgedBytes(): number { return this.bytes; }
  /** Whether this attachment is still live. For an owner recording state
   *  against a subscription across a microtask boundary: `retired` may already
   *  have fired for an id `subscribe` is only now resolving with, and a mark
   *  set after its own release is never cleared. */
  hasAttachment(attachmentId: string): boolean { return this.attachments.has(attachmentId); }

  async subscribe(address: TerminalAddress, version: number, requestId: string): Promise<string | undefined> {
    if (this.closed || !this.transport.authorized(address)) return;
    if (version !== TERMINAL_PROTOCOL_VERSION) {
      // Best-effort notice: there is no attachment yet to retire, and the
      // requester's own retry/timeout is what recovers a lost reply.
      try {
        await this.transport.send(createMessage("terminal:display:status", {
          ...wireAddress(address), requestId, code: "UPGRADE_REQUIRED",
          message: "Upgrade the app and bridge to use terminal screens.",
        }), new AbortController().signal);
      } catch { /* no attachment to retire; requester retries on no reply */ }
      return;
    }
    const run = this.hub.find(address);
    if (!run) {
      await this.transport.send(createMessage("terminal:display:status", {
        ...wireAddress(address), requestId, code: "UNKNOWN_TERMINAL",
        message: "Terminal no longer available.",
      }), new AbortController().signal);
      return;
    }
    for (const attachment of this.attachments.values()) {
      if (key(attachment.run.address) === key(address)) this.retire(attachment);
    }
    const attachment: Attachment = {
      id: crypto.randomUUID(), run, controller: new AbortController(), ready: false,
      sequence: 0, acknowledged: 0, revision: -1, bytes: 0, progressAt: this.now(),
      lastSent: -Infinity, pending: new Map(), ended: false, oversizeNotified: false,
    };
    this.attachments.set(attachment.id, attachment);
    try {
      await this.transport.send(createMessage("terminal:subscribed", {
        ...wireAddress(address), requestId, runId: run.runId, attachmentId: attachment.id,
        version: TERMINAL_PROTOCOL_VERSION,
      }), attachment.controller.signal);
      if (!this.attachments.has(attachment.id)) return;
      attachment.ready = true;
      this.hub.schedule();
      this.hub.tick();
      // That tick can retire this attachment before it is ever reported (a
      // transport that throws, an already-failed source). Returning the id
      // anyway would hand the caller a subscription that no `retired` notice
      // is coming for, since the notice fired before the caller recorded it.
      return this.attachments.has(attachment.id) ? attachment.id : undefined;
    } catch { this.retire(attachment); return; }
  }

  acknowledge(address: TerminalAddress, ack: Pick<TerminalAck, "runId" | "attachmentId" | "sequence">): boolean {
    const attachment = this.attachments.get(ack.attachmentId);
    if (!attachment || key(address) !== key(attachment.run.address) || ack.runId !== attachment.run.runId ||
        !this.transport.authorized(address) || !Number.isSafeInteger(ack.sequence) ||
        ack.sequence <= attachment.acknowledged || ack.sequence > attachment.sequence) return false;
    for (const [sequence, bytes] of attachment.pending) {
      if (sequence > ack.sequence) break;
      attachment.pending.delete(sequence);
      attachment.bytes -= bytes;
      this.bytes -= bytes;
      this.budget.bytes -= bytes;
    }
    attachment.acknowledged = ack.sequence;
    attachment.progressAt = this.now();
    attachment.awaitingConsumption = attachment.pending.size > 0;
    this.hub.tick();
    return true;
  }

  unsubscribe(address: TerminalAddress, runId: string, attachmentId: string): void {
    const attachment = this.attachments.get(attachmentId);
    if (attachment?.run.runId === runId && key(address) === key(attachment.run.address)) this.retire(attachment);
  }

  tick(now: number): void {
    const attachments = [...this.attachments.values()];
    if (!attachments.length) return;
    const start = this.cursor++ % attachments.length;
    for (let index = 0; index < attachments.length; index++) {
      const attachment = attachments[(start + index) % attachments.length];
      if (!this.attachments.has(attachment.id)) continue;
      try {
        this.tickAttachment(attachment, now);
      } catch {
        // Also driven off the bare setInterval in TerminalFrameHub.schedule():
        // createMessage() (Zod), encodedJsonBytes(), and transport.authorized()
        // can all throw synchronously here, on top of the send-throws-before-
        // returning-a-promise gap safeSend() closes below. Retire rather than
        // limp on: the same input would fail identically every tick, so
        // retrying is a spin, and a message that failed to build or a
        // transport whose invariants broke is not one we can trust with a
        // best-effort status notice either. Other attachments on this
        // connection, and every other connection, are unaffected — the
        // client's existing resubscribe path recovers this one.
        this.retire(attachment);
      }
    }
  }

  private tickAttachment(attachment: Attachment, now: number): void {
    const run = attachment.run;
    // D5's "retire pending viewer work" on a revocation edge, and no more than
    // that. The common cause here is `connState.suppressed` — the app
    // backgrounded, or the peer went briefly offline — which is an everyday
    // event that ends by itself, so destroying the attachment would freeze the
    // terminal for a viewer that is about to come back and holds a
    // runId/attachmentId it still believes is live. A cause that really is
    // permanent (the socket died, the run ended, the checkout was deleted)
    // reaches this class as `close()` or `remove()` instead, both of which
    // retire and say so.
    if (!this.transport.authorized(run.address)) { this.pause(attachment); return; }
    if (!attachment.ready || attachment.ended) return;
    if (attachment.pending.size && now - attachment.progressAt >= TERMINAL_ACK_TIMEOUT_MS) {
      this.fail(attachment, "ACK_TIMEOUT", "Terminal viewing stalled. Reconnect to restore the current screen.");
      return;
    }
    if (run.finalRevision !== undefined && attachment.revision >= run.finalRevision && !attachment.pending.size) {
      attachment.ended = true;
      // A fresh signal, and retired straight after: there is nothing left to
      // send under this attachment, and leaving it alive would hold every
      // "someone is watching frames here" gate its owner keeps (see the
      // `retired` hook) open for a run that has finished. `retire` aborts the
      // attachment's own controller, which is why this notice cannot use it.
      this.safeSend(createMessage("terminal:display:status", {
        ...wireAddress(run.address), runId: run.runId, attachmentId: attachment.id,
        code: "ENDED", message: "Terminal completed.", finalSequence: attachment.sequence, exitCode: run.exitCode,
      }), new AbortController().signal, () => {});
      this.retire(attachment);
      return;
    }
    if (attachment.unsent && attachment.unsent.revision < run.source.revision &&
        now - attachment.lastSent >= TERMINAL_FRAME_INTERVAL_MS) {
      const unsent = attachment.unsent;
      attachment.unsent = undefined;
      unsent.controller.abort();
      const bytes = attachment.pending.get(unsent.sequence) ?? 0;
      attachment.pending.delete(unsent.sequence);
      attachment.bytes -= bytes;
      this.bytes -= bytes;
      this.budget.bytes -= bytes;
    }
    if (attachment.pending.size >= TERMINAL_VIEWER_MAX_FRAMES ||
        attachment.bytes >= TERMINAL_VIEWER_MAX_BYTES || this.budget.bytes >= TERMINAL_CONNECTION_MAX_BYTES ||
        now - attachment.lastSent < TERMINAL_FRAME_INTERVAL_MS ||
        attachment.revision === run.source.revision) return;
    const frame = this.hub.frame(run, now);
    if (run.failure) { this.fail(attachment, "DISPLAY_FAILED", run.failure); return; }
    // The source keeps its last good frame, so an oversize capture is not
    // visible as a missing one — ask the source directly.
    if (run.source.oversize) { this.reportOversize(attachment); return; }
    if (!frame || frame.revision <= attachment.revision) return;
    const message = createMessage("terminal:frame", {
      ...wireAddress(run.address), ...frame, runId: run.runId, attachmentId: attachment.id,
      sequence: attachment.sequence + 1,
    });
    const bytes = encodedJsonBytes(message);
    if (bytes > TERMINAL_VIEWER_MAX_BYTES) {
      // Unreachable while the capture cap is derived from this budget, and
      // kept as the backstop for the day something else builds a frame. Marks
      // the revision considered so the next tick does not re-measure it, and
      // leaves the attachment open — one dense screen must not end a session.
      attachment.revision = frame.revision;
      this.reportOversize(attachment);
      return;
    }
    if (attachment.bytes + bytes > TERMINAL_VIEWER_MAX_BYTES || this.budget.bytes + bytes > TERMINAL_CONNECTION_MAX_BYTES) return;
    if (!attachment.awaitingConsumption) attachment.progressAt = now;
    attachment.awaitingConsumption = true;
    attachment.oversizeNotified = false;
    attachment.sequence++;
    attachment.pending.set(attachment.sequence, bytes);
    attachment.bytes += bytes;
    this.bytes += bytes;
    this.budget.bytes += bytes;
    attachment.lastSent = now;
    attachment.revision = frame.revision;
    const unsent = {
      sequence: attachment.sequence, revision: frame.revision, controller: new AbortController(),
    };
    attachment.unsent = unsent;
    const owner = attachment.controller.signal;
    const abort = () => unsent.controller.abort();
    owner.addEventListener("abort", abort, { once: true });
    const settled = () => {
      owner.removeEventListener("abort", abort);
      if (attachment.unsent === unsent) attachment.unsent = undefined;
    };
    try {
      void this.transport.send(message, unsent.controller.signal).then(settled, () => {
        settled();
        if (!unsent.controller.signal.aborted) this.retire(attachment);
      });
    } catch {
      settled();
      this.retire(attachment);
    }
  }

  /** Treats a transport that throws SYNCHRONOUSLY the same as one whose
   *  returned promise rejects — a bare `.catch()` on the call expression
   *  never attaches when `send` itself throws before returning anything, so
   *  that failure shape would otherwise escape every call site below
   *  uncaught. `onFailure` encodes each call site's own recovery: retire the
   *  attachment, or (reportOversize) do nothing and let the next tick retry. */
  private safeSend(message: ViewerMessage, signal: AbortSignal, onFailure: () => void): void {
    try {
      void this.transport.send(message, signal).catch(onFailure);
    } catch {
      onFailure();
    }
  }

  /** Says the screen was skipped, once per episode, WITHOUT retiring the
   *  attachment — unlike fail(). The viewer stays subscribed and the next screen
   *  that fits resumes it, which is why this is not a latch. */
  private reportOversize(attachment: Attachment): void {
    if (attachment.oversizeNotified) return;
    attachment.oversizeNotified = true;
    this.safeSend(createMessage("terminal:display:status", {
      ...wireAddress(attachment.run.address), runId: attachment.run.runId, attachmentId: attachment.id,
      code: "DISPLAY_FAILED", message: "This screen is too large to send. Waiting for it to change.",
    }), attachment.controller.signal, () => {});
  }

  private fail(attachment: Attachment, code: "ACK_TIMEOUT" | "DISPLAY_FAILED", message: string): void {
    this.retire(attachment);
    this.safeSend(createMessage("terminal:display:status", {
      ...wireAddress(attachment.run.address), runId: attachment.run.runId, attachmentId: attachment.id,
      code, message: message.slice(0, 1024),
    }), new AbortController().signal, () => {});
  }

  /** Drops what is queued for a viewer that cannot receive right now, WITHOUT
   *  ending its subscription. The frames are abandoned rather than held: the
   *  transport contract says an abort removes unsent plaintext, and a screen
   *  from before a pause is worthless next to the one that will exist on
   *  resume. `revision` goes with them — those frames were counted as
   *  delivered when they were queued, so without this the viewer resumes with
   *  a stale screen and no further frame until the guest happens to repaint. */
  private pause(attachment: Attachment): void {
    if (!attachment.pending.size) return;
    attachment.controller.abort();
    attachment.controller = new AbortController();
    this.bytes -= attachment.bytes;
    this.budget.bytes -= attachment.bytes;
    attachment.bytes = 0;
    attachment.pending.clear();
    attachment.unsent = undefined;
    attachment.awaitingConsumption = false;
    attachment.revision = -1;
    attachment.oversizeNotified = false;
    attachment.progressAt = this.now();
  }

  /** Undoes an attachment's delivery high-water mark so the replacement
   *  emulator's revision numbering, which restarts at 0, still produces a
   *  frame — see `TerminalFrameHub.register`'s same-run branch. */
  resetRun(run: Run): void {
    for (const attachment of this.attachments.values()) {
      if (attachment.run !== run) continue;
      attachment.revision = -1;
      attachment.oversizeNotified = false;
    }
  }

  private retire(attachment: Attachment): void {
    if (!this.attachments.delete(attachment.id)) return;
    attachment.controller.abort();
    this.bytes -= attachment.bytes;
    this.budget.bytes -= attachment.bytes;
    attachment.pending.clear();
    attachment.bytes = 0;
    this.hub.schedule();
    // Last, and guarded: an owner gating other traffic on this subscription
    // has to learn about the retirements this class performs on its own clock
    // (see the field's doc). A throwing observer must not leave the
    // attachment half-removed, and this runs inside `tick`'s own catch.
    try { this.transport.retired?.(attachment.run.address, attachment.id); } catch { /* not this class's failure */ }
  }

  retireRun(run: Run, exitCode?: number | null): void {
    for (const attachment of this.attachments.values()) {
      if (attachment.run !== run) continue;
      // Told before it is dropped, unless the graceful `finish()` path already
      // sent its own ENDED. Without this the viewer is silently unsubscribed
      // by a respawn or an exit and sits on a frozen screen — the frame
      // protocol says nothing, and `terminal:started`/`terminal:exited` are
      // the only cues, neither of which names the attachment that died.
      if (!attachment.ended) {
        attachment.ended = true;
        this.safeSend(createMessage("terminal:display:status", {
          ...wireAddress(run.address), runId: run.runId, attachmentId: attachment.id,
          code: "ENDED", message: "Terminal completed.",
          finalSequence: attachment.sequence, exitCode: exitCode ?? null,
        }), new AbortController().signal, () => {});
      }
      this.retire(attachment);
    }
  }

  close(): void {
    this.closed = true;
    for (const attachment of this.attachments.values()) this.retire(attachment);
    this.hub.disconnect(this);
  }
}
