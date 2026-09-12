import { TerminalFrameSource, FRAME_INTERVAL_MS, type TerminalFrame } from "../terminal-frames/source";
export { TerminalFrameSource, FRAME_INTERVAL_MS, SYNC_OUTPUT_TIMEOUT_MS, TerminalFrameSchema, type TerminalFrame } from "../terminal-frames/source";

/** One in-flight frame and no frame queue. Call tick from the viewer's clock. */
export class TerminalFrameDelivery {
  private busy = false;
  private deliveredRevision = -1;
  private lastStarted = -Infinity;
  private lastAnsi: string | undefined;
  private lastSize = "";
  constructor(
    private readonly source: TerminalFrameSource,
    private readonly send: (frame: TerminalFrame) => Promise<void>,
  ) {}

  get pending(): boolean {
    return this.busy || this.source.hasPendingTail || this.source.revision !== this.deliveredRevision;
  }

  async tick(now: number): Promise<boolean> {
    if (this.busy || now - this.lastStarted < FRAME_INTERVAL_MS) return false;
    if (this.source.revision === this.deliveredRevision) return false;
    const frame = this.source.capture(now);
    if (!frame) return false;
    const size = `${frame.cols}x${frame.rows}`;
    if (frame.ansi === this.lastAnsi && size === this.lastSize) {
      this.deliveredRevision = frame.revision;
      return false;
    }
    this.busy = true;
    this.lastStarted = now;
    try {
      await this.send(frame);
      this.deliveredRevision = frame.revision;
      this.lastAnsi = frame.ansi;
      this.lastSize = size;
      return true;
    } finally { this.busy = false; }
  }
}
