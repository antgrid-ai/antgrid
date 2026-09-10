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
  /** Resolve after handing off, not after consumption. Aborting must remove
   * unsent plaintext from the transport queue before encryption/fragmentation. */
  send(message: ViewerMessage, signal: AbortSignal): Promise<void>;
  authorized(address: TerminalAddress): boolean;
}
interface Run {
  address: TerminalAddress;
  runId: string;
  source: TerminalFrameSource;
  lastCapture: number;
  capturedRevision: number;
  frame?: TerminalScreenFrame;
  finalRevision?: number;
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

  register(address: TerminalAddress, source: TerminalFrameSource, runId = crypto.randomUUID()): string {
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
    run.finalRevision = run.source.revision;
    run.exitCode = exitCode;
    this.tick();
  }

  remove(address: TerminalAddress): void {
    const run = this.runs.get(key(address));
    if (!run) return;
    this.runs.delete(key(address));
    run.detach();
    for (const connection of this.connections) connection.retireRun(run);
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
      try {
        const frame = run.source.capture(now);
        if (frame) {
          run.lastCapture = now;
          run.capturedRevision = frame.revision;
          run.frame = frame;
        }
      } catch (error) { run.failure = error instanceof Error ? error.message : String(error); }
    }
    return run.frame;
  }

  tick(): void {
    const now = this.now();
    for (const connection of this.connections) connection.tick(now);
  }

  schedule(): void {
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

  constructor(
    private readonly hub: TerminalFrameHub,
    private readonly transport: TerminalViewerTransport,
    private readonly now: () => number,
  ) {}

  get size(): number { return this.attachments.size; }
  get unacknowledgedBytes(): number { return this.bytes; }

  async subscribe(address: TerminalAddress, version: number, requestId: string): Promise<string | undefined> {
    if (this.closed || !this.transport.authorized(address)) return;
    if (version !== TERMINAL_PROTOCOL_VERSION) {
      await this.transport.send(createMessage("terminal:display:status", {
        ...wireAddress(address), requestId, code: "UPGRADE_REQUIRED",
        message: "Upgrade the app and bridge to use terminal screens.",
      }), new AbortController().signal);
      return;
    }
    const run = this.hub.find(address);
    if (!run) return;
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
      return attachment.id;
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
    }
    attachment.acknowledged = ack.sequence;
    attachment.progressAt = this.now();
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
      const run = attachment.run;
      if (!this.transport.authorized(run.address)) { this.retire(attachment); continue; }
      if (!attachment.ready || attachment.ended) continue;
      if (attachment.pending.size && now - attachment.progressAt >= TERMINAL_ACK_TIMEOUT_MS) {
        this.fail(attachment, "ACK_TIMEOUT", "Terminal viewing stalled. Reconnect to restore the current screen.");
        continue;
      }
      if (run.finalRevision !== undefined && attachment.revision >= run.finalRevision && !attachment.pending.size) {
        attachment.ended = true;
        void this.transport.send(createMessage("terminal:display:status", {
          ...wireAddress(run.address), runId: run.runId, attachmentId: attachment.id,
          code: "ENDED", message: "Terminal completed.", finalSequence: attachment.sequence, exitCode: run.exitCode,
        }), attachment.controller.signal).catch(() => this.retire(attachment));
        continue;
      }
      if (attachment.pending.size >= TERMINAL_VIEWER_MAX_FRAMES ||
          attachment.bytes >= TERMINAL_VIEWER_MAX_BYTES || this.bytes >= TERMINAL_CONNECTION_MAX_BYTES ||
          now - attachment.lastSent < TERMINAL_FRAME_INTERVAL_MS ||
          attachment.revision === run.source.revision) continue;
      const frame = this.hub.frame(run, now);
      if (run.failure) { this.fail(attachment, "DISPLAY_FAILED", run.failure); continue; }
      // The source keeps its last good frame, so an oversize capture is not
      // visible as a missing one — ask the source directly.
      if (run.source.oversize) { this.reportOversize(attachment); continue; }
      if (!frame || frame.revision <= attachment.revision) continue;
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
        continue;
      }
      if (attachment.bytes + bytes > TERMINAL_VIEWER_MAX_BYTES || this.bytes + bytes > TERMINAL_CONNECTION_MAX_BYTES) continue;
      if (!attachment.pending.size) attachment.progressAt = now;
      attachment.oversizeNotified = false;
      attachment.sequence++;
      attachment.pending.set(attachment.sequence, bytes);
      attachment.bytes += bytes;
      this.bytes += bytes;
      attachment.lastSent = now;
      attachment.revision = frame.revision;
      void this.transport.send(message, attachment.controller.signal).catch(() => this.retire(attachment));
    }
  }

  /** Says the screen was skipped, once per episode, WITHOUT retiring the
   *  attachment — unlike fail(). The viewer stays subscribed and the next screen
   *  that fits resumes it, which is why this is not a latch. */
  private reportOversize(attachment: Attachment): void {
    if (attachment.oversizeNotified) return;
    attachment.oversizeNotified = true;
    void this.transport.send(createMessage("terminal:display:status", {
      ...wireAddress(attachment.run.address), runId: attachment.run.runId, attachmentId: attachment.id,
      code: "DISPLAY_FAILED", message: "This screen is too large to send. Waiting for it to change.",
    }), attachment.controller.signal).catch(() => {});
  }

  private fail(attachment: Attachment, code: "ACK_TIMEOUT" | "DISPLAY_FAILED", message: string): void {
    this.retire(attachment);
    void this.transport.send(createMessage("terminal:display:status", {
      ...wireAddress(attachment.run.address), runId: attachment.run.runId, attachmentId: attachment.id,
      code, message: message.slice(0, 1024),
    }), new AbortController().signal).catch(() => {});
  }

  private retire(attachment: Attachment): void {
    if (!this.attachments.delete(attachment.id)) return;
    attachment.controller.abort();
    this.bytes -= attachment.bytes;
    attachment.pending.clear();
    attachment.bytes = 0;
    this.hub.schedule();
  }

  retireRun(run: Run): void {
    for (const attachment of this.attachments.values()) if (attachment.run === run) this.retire(attachment);
  }

  close(): void {
    this.closed = true;
    for (const attachment of this.attachments.values()) this.retire(attachment);
    this.hub.disconnect(this);
  }
}
