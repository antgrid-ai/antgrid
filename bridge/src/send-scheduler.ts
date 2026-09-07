import {
  MAX_SEND_QUEUE_BYTES,
  SEAL_OVERHEAD_BYTES,
  WINDOW_RESYNC_CREDITS,
} from "antgrid-wire";
import type { Channel } from "./message-bus";

/** One frame waiting to be sealed and written: either a whole envelope or one
 *  fragment of one. Plaintext, because sealing happens at dequeue — a frame
 *  queued across a rekey must go out under the keys live at that moment. */
export interface QueuedAppFrame {
  channel: Channel;
  /** `CONTROL_STREAM_ID` for the control plane. */
  streamId: string;
  plaintext: string;
  plaintextBytes: number;
  /** Diagnostic message type, carried through to netwatch. */
  type: string;
}

export interface SchedulerSink {
  /** Seal + write one frame NOW. Returns the sealed payload length that hit
   *  the wire, or null if it was dropped (no session, socket not open). */
  send(frame: QueuedAppFrame): number | null;
}

/** `idle` — nothing left to write. `held` — parked by the test seam.
 *  `blocked` — a queued head does not fit the window or the socket cap. */
export type DrainResult = "idle" | "held" | "blocked";

/**
 * Per-channel FIFO send queues with strict `control` > `preview` priority and
 * a cumulative credit window per channel plus one in-flight cap per socket.
 *
 * Pure and socket-free: the owner supplies the sink and is the only caller of
 * {@link drain}, so there is a single place where a frame reaches the wire.
 * `charge`, `uncharge` and `credit` never drain by themselves.
 *
 * Accounting is in SEALED payload bytes — the number the sender writes and the
 * receiver reads back — so a peer's cumulative credit and a relay drop report
 * are directly comparable with what was charged.
 */
export class SendScheduler {
  /** Mutable on purpose: tests shrink them. A null limit is no gate at all. */
  readonly limits = {
    window: null as number | null,
    socketCap: null as number | null,
    maxQueuedBytes: MAX_SEND_QUEUE_BYTES,
  };
  /** Test seam: drain() returns "held" and writes nothing while true. */
  hold = false;

  private queues: Record<Channel, QueuedAppFrame[]> = { control: [], preview: [] };
  private queuedBytes: Record<Channel, number> = { control: 0, preview: 0 };
  /** Cumulative sealed bytes written on this session, queued or bypassed. */
  private sent: Record<Channel, number> = { control: 0, preview: 0 };
  /** Clamped to `sent`: over-credit is discarded rather than banked, so
   *  in-flight can never exceed one window per channel. */
  private credited: Record<Channel, number> = { control: 0, preview: 0 };
  /** The peer's raw cumulative figure, for stale/duplicate detection. */
  private lastCreditSeen: Record<Channel, number> = { control: 0, preview: 0 };
  private chargedSinceCredit: Record<Channel, boolean> = { control: false, preview: false };
  private nonAdvancing: Record<Channel, number> = { control: 0, preview: 0 };
  private draining = false;

  /** When the channel's head first failed to fit; cleared once it fits or the
   *  queue empties. Read by the owner's stall log. */
  blockedSince: Partial<Record<Channel, number>> = {};

  constructor(private sink: SchedulerSink, private log?: (msg: string) => void) {}

  unacked(ch: Channel): number {
    return Math.max(0, this.sent[ch] - this.credited[ch]);
  }

  totalUnacked(): number {
    return this.unacked("control") + this.unacked("preview");
  }

  queued(ch: Channel): { frames: number; bytes: number } {
    return { frames: this.queues[ch].length, bytes: this.queuedBytes[ch] };
  }

  /** All-or-nothing: a fragment set is never split, so a set that would push
   *  the channel past `maxQueuedBytes` is refused whole and the caller drops
   *  the message with one visible record. */
  enqueue(frames: QueuedAppFrame[]): boolean {
    if (frames.length === 0) return true;
    const adding: Record<Channel, number> = { control: 0, preview: 0 };
    for (const f of frames) adding[f.channel] += f.plaintextBytes;
    for (const ch of ["control", "preview"] as const) {
      if (this.queuedBytes[ch] + adding[ch] > this.limits.maxQueuedBytes) return false;
    }
    for (const f of frames) this.queues[f.channel].push(f);
    for (const ch of ["control", "preview"] as const) this.queuedBytes[ch] += adding[ch];
    return true;
  }

  drain(): DrainResult {
    // Re-entrancy guard: nothing in the current send path re-enters, but a sink
    // that ever publishes back onto a bus would otherwise interleave two loops
    // and break per-channel order.
    if (this.draining) return "idle";
    this.draining = true;
    try {
      for (;;) {
        if (this.hold) return "held";
        const next = this.pick();
        if (!next) {
          if (this.queues.control.length === 0 && this.queues.preview.length === 0) {
            this.blockedSince = {};
            return "idle";
          }
          const now = Date.now();
          for (const ch of ["control", "preview"] as const) {
            if (this.queues[ch].length > 0) this.blockedSince[ch] ??= now;
          }
          return "blocked";
        }
        delete this.blockedSince[next];
        const frame = this.queues[next].shift()!;
        this.queuedBytes[next] -= frame.plaintextBytes;
        const n = this.sink.send(frame);
        // A frame the sink dropped never reached the peer, so crediting it back
        // would be impossible: leave it out of the accounting entirely.
        if (n !== null) {
          this.sent[next] += n;
          this.chargedSinceCredit[next] = true;
        }
      }
    } finally {
      this.draining = false;
    }
  }

  /** Bytes written OUTSIDE the queue (session frames): counted toward the gate,
   *  never gated by it. Charging them is what makes a relay drop report exact —
   *  the report names only a channel and a length, so bytes invisible to the
   *  accounting would un-charge something never charged. */
  charge(ch: Channel, sealedBytes: number): void {
    this.sent[ch] += sealedBytes;
    this.chargedSinceCredit[ch] = true;
  }

  /** The relay reported it discarded `bytes` of this sender's frames on `ch`.
   *  Those bytes are in `sent` and will never reach the peer's `consumed`, so
   *  without this every drop shrinks the channel's window for the session. */
  uncharge(ch: Channel, bytes: number): void {
    this.sent[ch] = Math.max(0, this.sent[ch] - bytes);
  }

  /** Cumulative bytes the peer says it has consumed on `ch`. Returns true iff
   *  the caller should drain (the window advanced, or it was resynced). */
  credit(ch: Channel, consumedTotal: number): boolean {
    if (consumedTotal > this.lastCreditSeen[ch]) {
      this.lastCreditSeen[ch] = consumedTotal;
      this.credited[ch] = Math.min(consumedTotal, this.sent[ch]);
      this.nonAdvancing[ch] = 0;
      this.chargedSinceCredit[ch] = false;
      return true;
    }
    if (this.unacked(ch) === 0) {
      this.nonAdvancing[ch] = 0;
      this.chargedSinceCredit[ch] = false;
      return false;
    }
    // The peer credits every liveness tick, so consecutive credits that do not
    // advance while this sender charged nothing in between mean what it wrote
    // never arrived — discarded somewhere no drop report covered. A false
    // positive costs one extra window in flight, never data. Keep in lockstep
    // with the Dart client's send_scheduler.dart: both peers must resync at
    // the same credit count.
    const chargedSince = this.chargedSinceCredit[ch];
    this.chargedSinceCredit[ch] = false;
    this.nonAdvancing[ch] += 1;
    if (!chargedSince && this.nonAdvancing[ch] >= WINDOW_RESYNC_CREDITS) {
      this.log?.(`window resync on ${ch}: ${this.unacked(ch)} uncredited bytes presumed lost`);
      this.sent[ch] = this.credited[ch];
      this.nonAdvancing[ch] = 0;
      return true;
    }
    return false;
  }

  /** New session: zero every counter on both channels. Queues untouched. */
  resetWindows(): void {
    for (const ch of ["control", "preview"] as const) {
      this.sent[ch] = 0;
      this.credited[ch] = 0;
      this.lastCreditSeen[ch] = 0;
      this.chargedSinceCredit[ch] = false;
      this.nonAdvancing[ch] = 0;
      delete this.blockedSince[ch];
    }
  }

  /** Drop everything; returns the dropped frames so the caller can record them. */
  clear(): QueuedAppFrame[] {
    const dropped: QueuedAppFrame[] = [];
    for (const ch of ["control", "preview"] as const) {
      dropped.push(...this.queues[ch]);
      this.queues[ch] = [];
      this.queuedBytes[ch] = 0;
      delete this.blockedSince[ch];
    }
    return dropped;
  }

  /** Drop queued frames for one stream (the stream detached). A detached
   *  stream's backlog must not occupy a window the live streams need. */
  dropStream(streamId: string): QueuedAppFrame[] {
    const dropped: QueuedAppFrame[] = [];
    for (const ch of ["control", "preview"] as const) {
      const kept: QueuedAppFrame[] = [];
      for (const f of this.queues[ch]) {
        if (f.streamId === streamId) {
          dropped.push(f);
          this.queuedBytes[ch] -= f.plaintextBytes;
        } else {
          kept.push(f);
        }
      }
      this.queues[ch] = kept;
      if (kept.length === 0) delete this.blockedSince[ch];
    }
    return dropped;
  }

  /** Control before preview, and a blocked control head never blocks preview. */
  private pick(): Channel | null {
    for (const ch of ["control", "preview"] as const) {
      const head = this.queues[ch][0];
      if (head && this.fits(head)) return ch;
    }
    return null;
  }

  private fits(f: QueuedAppFrame): boolean {
    const need = f.plaintextBytes + SEAL_OVERHEAD_BYTES;
    // The `=== 0` arms are the deadlock guards: a frame larger than a limit
    // still goes out when nothing is outstanding on it.
    const chOk =
      this.limits.window === null ||
      this.unacked(f.channel) === 0 ||
      this.unacked(f.channel) + need <= this.limits.window;
    const sockOk =
      this.limits.socketCap === null ||
      this.totalUnacked() === 0 ||
      this.totalUnacked() + need <= this.limits.socketCap;
    return chOk && sockOk;
  }
}
