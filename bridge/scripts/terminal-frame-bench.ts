// Repeatable performance harness for the serialized-terminal-frame pipeline
// (Wave 9 of the frame-mode rollout — see docs/terminal-frame-implementation-plan.md
// "Validation and release gates"). Run before a rollout, save the --json output as
// the baseline, and diff a later run against it. A missed gate sets a non-zero exit
// status, so a CI step can act on a regression instead of a human squinting at a
// table.
//
// Drives the REAL production classes — TerminalFrameSource, TerminalFrameHub,
// TerminalViewerConnection, TerminalHistoryStore — the same way agent-core wires
// them, so the throttling, coalescing and eviction behavior measured here is
// whatever those classes actually do today, not a reimplementation of it. No PTY
// or relay is stood up (see terminal-frame-fixtures.ts for the same idiom): each
// workload feeds scripted bytes straight into a headless VT.
//
// BenchTransport is a VIEWER, not a sink. It acknowledges every frame the way the
// app's `terminal:ack` does, and it observes `retired` and `terminal:display:status`.
// A transport that only counts arrivals fills the four-frame in-flight window
// (TERMINAL_VIEWER_MAX_FRAMES) on its fourth frame and never drains it again; every
// rate printed after that is a measurement of a wedged pipeline reporting itself as
// comfortably inside budget.
//
// Every comparable number is a RATE over the output window, never a total. A total
// is a function of --duration-ms, so two runs at different durations cannot be
// diffed, and a numerator pinned by a stall hides behind a denominator that keeps
// growing with the flag.
import { parseArgs } from "node:util";
import { mkdtempSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomBytes } from "node:crypto";
import { E2eTransport } from "../src/e2e/transport";
import { TerminalFrameSource } from "../src/terminal-frames/source";
import { TerminalFrameHub, type TerminalAddress, type TerminalViewerTransport } from "../src/terminal-frames/delivery";
import { TerminalHistoryStore, TerminalRunHistory, type HistoryPage } from "../src/terminal-frames/history";
import {
  TERMINAL_FRAME_INTERVAL_MS, TERMINAL_HISTORY_RUN_BYTES, TERMINAL_PROTOCOL_VERSION,
  TERMINAL_VIEWER_MAX_BYTES, TERMINAL_VIEWER_MAX_FRAMES, encodedJsonBytes,
  type TerminalHistoryRow, type TerminalScreenFrame,
} from "../src/terminal-frames/protocol";
import type { AbMessage, TerminalDisplayStatus, TerminalFrame } from "../src/protocol";

const DEFAULT_DURATION_MS = 3000;
/** Read before any workload runs, so the process-wide figures the report ends
 *  with have a floor that is the harness itself rather than the first
 *  workload's. */
const processRssStartMb = process.memoryUsage().rss / (1024 * 1024);

// ---------------------------------------------------------------------------
// Budgets. Every one is DERIVED from a production constant or justified against
// a user-visible symptom, so a budget cannot silently drift away from what the
// pipeline actually promises.

/** The plan's hard ceiling, read off the interval rather than restated: the
 *  producer side gates on `now - last >= TERMINAL_FRAME_INTERVAL_MS`, so a
 *  half-open one-second window admits exactly this many and no more. */
const MAX_EVENTS_PER_SECOND = 20;
/** How long a viewer may go without a new screen while the guest is still
 *  printing. Ten frame slots: shorter than that is jitter a person cannot see,
 *  longer is the stall that reads as a frozen terminal. */
const MAX_SEND_GAP_MS = TERMINAL_FRAME_INTERVAL_MS * 10;
/** A history page answers a scroll gesture. Slower than the pane's own frame
 *  cadence and the scroll visibly catches. */
const MAX_PAGE_LATENCY_MS = TERMINAL_FRAME_INTERVAL_MS;
/** Ceiling on how long the pipeline may take to settle onto the final screen
 *  once output stops. Generous on purpose — this bounds a failure, it is not a
 *  budget anything is expected to approach. */
const DRAIN_TIMEOUT_MS = 2000;
/** Retention budget for the `evict` workloads, small enough that a few seconds
 *  of scrollback crosses it. The production budget is measured in hundreds of
 *  megabytes, which no bench-length run will ever reach, so eviction would
 *  never execute and the gate would be decorative. */
const EVICT_RUN_BYTES = 64 * 1024;
/** Percentiles below this sample count degenerate: p95 of twenty or fewer
 *  samples IS the maximum, whatever the arithmetic says. Reported rather than
 *  hidden — see the `*` marker in the table. */
const MIN_SAMPLES_FOR_P95 = 20;

/** One PTY read's worth of bytes. Mirrors `BATCH_MAX_BYTES` in
 *  bridge/src/terminal-session.ts — that is the size at which the legacy
 *  batcher stops coalescing and ships an envelope, so feeding in these units is
 *  what makes the raw baseline below priced the way the product actually sends
 *  it. Keep the two in lockstep. */
const PTY_READ_BYTES = 4096;
/** Legacy `terminal:output` coalescing window, mirrored from the same file. */
const LEGACY_BATCH_INTERVAL_MS = 16;
/** Repaint rate a fullscreen TUI drives itself at. The ACHIEVED rate is what
 *  the report prints — timer granularity on some hosts cannot reach this, and a
 *  target a run silently missed by 3x is worse than no target. */
const TUI_TARGET_WRITES_PER_SEC = 60;

// ---------------------------------------------------------------------------
// Deterministic content. Every workload's byte sequence is a pure function of
// its position in the sequence, never of Date.now()/Math.random() — the exact
// NUMBER of chunks a run fits still depends on real wall-clock speed (the
// point of a --duration-ms window is to measure real throttling against real
// time), but what those chunks CONTAIN never does, so two runs on the same
// machine converge to the same shape and only genuine perf drift moves the
// numbers.
function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a |= 0; a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
function seedFor(id: string): number {
  let h = 2166136261;
  for (let i = 0; i < id.length; i++) { h ^= id.charCodeAt(i); h = Math.imul(h, 16777619); }
  return h >>> 0;
}

interface Grid { name: string; cols: number; rows: number }
const GRIDS: Grid[] = [
  { name: "small", cols: 80, rows: 24 },
  { name: "large", cols: 202, rows: 60 },
];

type ContentKind = "idle" | "burst" | "tui" | "scrollback" | "evict";
interface NamedWorkload { id: string; grid: Grid; content: ContentKind }
const WORKLOADS: NamedWorkload[] = (["idle", "burst", "tui", "scrollback", "evict"] as const)
  .flatMap((content) => GRIDS.map((grid): NamedWorkload => ({ id: `${content}-${grid.name}`, grid, content })));

/** A log-burst line: sustained output, no idle gap between chunks. */
function burstLine(seq: number, rng: () => number): string {
  const color = [31, 32, 33, 34, 35, 36][seq % 6];
  return rng() > 0.85
    ? `\x1b[${color}mwarning\x1b[0m: module ${(seq * 7) % 41} uses a deprecated api (step ${seq})\r\n`
    : `\x1b[${color}mbuild\x1b[0m module ${(seq * 7) % 41} ${seq % 100}% complete (step ${seq})\r\n`;
}
/** One small cursor-addressed repaint, as a fullscreen TUI status line does. */
function tuiChunk(seq: number, grid: Grid): string {
  const row = 3 + (seq % Math.max(1, grid.rows - 3));
  const spinner = "|/-\\"[seq % 4];
  return `\x1b[${row};1H\x1b[2K\x1b[38;2;${40 + (seq % 180)};160;220mworker ${row - 2} ${spinner} ${(seq * 13) % 1000}\x1b[0m`;
}
/** Short plain lines, tuned to maximize distinct rows scrolled into history
 *  within the window rather than to look like real output. */
function scrollbackLine(seq: number): string {
  return `row ${seq} ${"-".repeat(6 + (seq % 30))}\r\n`;
}

// ---------------------------------------------------------------------------
/** The raw-streaming baseline, reproducing `TerminalSession`'s output batcher
 *  (bridge/src/terminal-session.ts) rather than charging one envelope per PTY
 *  read. Legacy mode coalesces until PTY_READ_BYTES or LEGACY_BATCH_INTERVAL_MS,
 *  so a per-read envelope prices a shape the product never puts on the wire —
 *  for the one-repaint-per-write TUI workload that is most of the measurement.
 *
 *  Fixed id/timestamp rather than createMessage(): the baseline must be exactly
 *  as deterministic as the content it wraps, and the ENVELOPE is what a
 *  comparison against terminal:frame's encodedJsonBytes needs to match units
 *  with — not the bare PTY payload. */
class LegacyOutputBatcher {
  private static readonly ENVELOPE_ID = "00000000-0000-4000-8000-000000000000";
  private static readonly ENVELOPE_TS = 1_700_000_000_000;
  private chunks: string[] = [];
  private chars = 0;
  private timer?: ReturnType<typeof setTimeout>;
  envelopes = 0;
  wireBytes = 0;
  encryptedBytes = 0;
  payloadBytes = 0;

  constructor(private readonly terminalId: string, private readonly cipher: E2eTransport) {}

  enqueue(data: string): void {
    this.chunks.push(data);
    this.chars += data.length;
    if (this.chars >= PTY_READ_BYTES) { this.flush(); return; }
    this.timer ??= setTimeout(() => this.flush(), LEGACY_BATCH_INTERVAL_MS);
  }

  flush(): void {
    if (this.timer) { clearTimeout(this.timer); this.timer = undefined; }
    if (!this.chunks.length) return;
    const data = this.chunks.length === 1 ? this.chunks[0] : this.chunks.join("");
    this.chunks = [];
    this.chars = 0;
    this.envelopes++;
    this.payloadBytes += encodedJsonBytes(data);
    const envelope = {
      id: LegacyOutputBatcher.ENVELOPE_ID, timestamp: LegacyOutputBatcher.ENVELOPE_TS,
      type: "terminal:output", terminalId: this.terminalId, checkoutId: "main", data,
    };
    this.wireBytes += encodedJsonBytes(envelope);
    this.encryptedBytes += this.cipher.seal(JSON.stringify(envelope)).byteLength;
  }
}

// ---------------------------------------------------------------------------
// Fault injection. A gate nothing can trip is indistinguishable from a gate
// that was never wired — which is how an in-flight window that filled after
// four frames survived a full harness run reporting "all gates passed". Each
// fault below deliberately breaks one property so the matching gate is SEEN to
// fail; `--help` maps them.
const FAULTS = ["no-ack", "idle-poke", "retire-mid", "fast-clock", "no-evict", "slow-page", "oversize"] as const;
type Fault = (typeof FAULTS)[number];
/** Enough to let the throttle admit roughly four times as many events per real
 *  second as the budget allows, while leaving TERMINAL_ACK_TIMEOUT_MS — scaled
 *  by the same factor — far out of reach of a viewer that is still acking. */
const FAST_CLOCK_FACTOR = 4;
const SLOW_PAGE_SPIN_MS = MAX_PAGE_LATENCY_MS + 10;

// ---------------------------------------------------------------------------
// Production classes expose no "how long did this take" hook — TerminalFrameHub
// only ever asks for a frame when its own throttle already decided one is due,
// and TerminalRunHistory's counters describe the current epoch only. These wrap
// the methods for the life of the bench process rather than adding timing and
// lifetime-total paths to src/ that nothing else would ever call.
interface CaptureEvent { atMs: number; durationMs: number; ok: boolean }
let captureEvents: CaptureEvent[] = [];
/** Capture ATTEMPTS that read the source's oversize flag — not distinct screens.
 *  `capture()` returns early on three paths (disposed, pending tail, a held
 *  DECSET 2026) before it re-measures the flag, so a stale `true` is counted
 *  again. It is still what `screenWithinDisplayBudget` reads, because delivery
 *  emits one DISPLAY_FAILED per episode however many screens were skipped: only
 *  the source-side count moves with load. */
let oversizeCaptures = 0;
let historyStats = { rowsArchived: 0, epochTurnovers: 0 };
let clockOrigin = 0;
const capturedAt = new Map<number, number>();
let slowPages = false;
let forceOversize = false;

/** The `oversize` fault has to move BOTH halves the delivery path reads — the
 *  null capture and the source's own flag — because `tick` asks the source
 *  directly (`run.source.oversize`) after the capture comes back empty. A
 *  capture that merely returns null reproduces a source that had nothing new to
 *  say, which is a different thing entirely. */
const oversizeAccessor = Object.getOwnPropertyDescriptor(TerminalFrameSource.prototype, "oversize");
const originalOversize = oversizeAccessor?.get;
if (!originalOversize) throw new Error("bench: TerminalFrameSource.oversize is no longer a prototype getter");
Object.defineProperty(TerminalFrameSource.prototype, "oversize", {
  ...oversizeAccessor,
  get(this: TerminalFrameSource): boolean { return forceOversize || originalOversize.call(this); },
});

const originalCapture = TerminalFrameSource.prototype.capture;
TerminalFrameSource.prototype.capture = function (
  this: TerminalFrameSource, now: number, opts?: { final?: boolean },
): TerminalScreenFrame | null {
  const t0 = performance.now();
  let ok = false;
  try {
    // The real call runs under the fault too: an oversize screen is one the
    // source serialized in full and then declined to hand over, so skipping the
    // work would price the fault cheaper than the thing it stands in for.
    const captured = originalCapture.call(this, now, opts ?? {});
    const result = forceOversize ? null : captured;
    ok = result !== null;
    if (result) {
      capturedAt.set(result.revision, t0);
      if (capturedAt.size > 32) capturedAt.delete(capturedAt.keys().next().value!);
    }
    if (this.oversize) oversizeCaptures++;
    return result;
  } finally {
    captureEvents.push({ atMs: t0 - clockOrigin, durationMs: performance.now() - t0, ok });
  }
};

const originalAppend = TerminalRunHistory.prototype.append;
TerminalRunHistory.prototype.append = function (this: TerminalRunHistory, row: Omit<TerminalHistoryRow, "rowId">): void {
  historyStats.rowsArchived++;
  originalAppend.call(this, row);
};
const originalClear = TerminalRunHistory.prototype.clear;
TerminalRunHistory.prototype.clear = function (this: TerminalRunHistory): void {
  historyStats.epochTurnovers++;
  originalClear.call(this);
};
const originalPage = TerminalRunHistory.prototype.page;
TerminalRunHistory.prototype.page = function (this: TerminalRunHistory, epoch: number, beforeRowId: number): HistoryPage {
  if (slowPages) { const until = performance.now() + SLOW_PAGE_SPIN_MS; while (performance.now() < until) { /* occupy the thread */ } }
  return originalPage.call(this, epoch, beforeRowId);
};

// ---------------------------------------------------------------------------
type Phase = "output" | "drain" | "probe" | "exit" | "done";
interface FrameEvent { atMs: number; bytes: number; encryptedBytes: number; ageMs: number; revision: number; sequence: number }
interface StatusEvent { atMs: number; phase: Phase; code: TerminalDisplayStatus["code"] }

/** Acknowledges frames on a timer, as the app does over the relay, rather than
 *  inline: `acknowledge` re-enters the hub's tick, and a viewer whose ack is
 *  already on the stack of the send it is acking cannot exercise the in-flight
 *  window the transport contract exists to bound. */
class BenchTransport implements TerminalViewerTransport {
  connection?: { acknowledge(address: TerminalAddress, ack: { runId: string; attachmentId: string; sequence: number }): boolean };
  phase: Phase = "output";
  origin = 0;
  readonly frames: FrameEvent[] = [];
  readonly statuses: StatusEvent[] = [];
  readonly retirements: StatusEvent[] = [];
  private readonly ackTimers = new Set<ReturnType<typeof setTimeout>>();
  private stopped = false;
  private linkAvailableAt = 0;

  readonly cipher = new E2eTransport({ sendKey: randomBytes(32), recvKey: randomBytes(32) });
  constructor(
    private readonly acks: boolean, private readonly ackDelayMs: number,
    private readonly bandwidthBytesPerSec: number,
  ) {}

  authorized(): boolean { return true; }

  retired(_address: TerminalAddress, _attachmentId: string): void {
    this.retirements.push({ atMs: performance.now() - this.origin, phase: this.phase, code: "ENDED" });
  }

  async send(message: TerminalFrame | TerminalDisplayStatus | AbMessage, signal: AbortSignal): Promise<void> {
    if (signal.aborted) return;
    if (message.type === "terminal:display:status") {
      this.statuses.push({ atMs: performance.now() - this.origin, phase: this.phase, code: message.code });
      return;
    }
    if (message.type !== "terminal:frame") return;
    const captured = capturedAt.get(message.revision) ?? performance.now();
    if (this.bandwidthBytesPerSec > 0) {
      await Bun.sleep(Math.max(0, this.linkAvailableAt - performance.now()));
      if (signal.aborted || this.stopped) return;
    }
    const encryptedBytes = this.cipher.seal(JSON.stringify(message)).byteLength;
    const wireTimeMs = this.bandwidthBytesPerSec > 0 ? encryptedBytes * 1000 / this.bandwidthBytesPerSec : 0;
    this.linkAvailableAt = performance.now() + wireTimeMs;
    this.frames.push({
      atMs: performance.now() - this.origin, bytes: encodedJsonBytes(message),
      encryptedBytes, ageMs: performance.now() - captured,
      revision: message.revision, sequence: message.sequence,
    });
    if (!this.acks || this.stopped) return;
    const { runId, attachmentId, sequence, checkoutId, terminalId } = message;
    const timer = setTimeout(() => {
      this.ackTimers.delete(timer);
      if (this.stopped) return;
      this.connection?.acknowledge({ projectId: "bench", checkoutId, terminalId }, { runId, attachmentId, sequence });
    }, this.ackDelayMs + wireTimeMs);
    this.ackTimers.add(timer);
  }

  /** Cancels acks still in flight. Without it a pending timer outlives the
   *  connection it would ack and keeps the process alive past the last run. */
  stop(): void {
    this.stopped = true;
    for (const timer of this.ackTimers) clearTimeout(timer);
    this.ackTimers.clear();
    this.cipher.zeroize();
  }

  lastRevision(): number { return this.frames.at(-1)?.revision ?? -1; }
  /** Drops the attach frame and NOTHING else. Statuses and retirements survive:
   *  nothing benign is emitted during a subscribe, so anything recorded before
   *  the window opened is a failure that happened to arrive early — and a
   *  DISPLAY_FAILED is emitted exactly once per episode, so clearing the list
   *  here would erase the only notice an already-oversize screen ever sends. */
  dropAttachFrame(): void { this.frames.length = 0; }
}

// ---------------------------------------------------------------------------
/** Nearest-rank, so p95 is the 95th-percentile SAMPLE rather than
 *  `sorted[floor(0.95 * len)]`, which indexes the maximum for every len <= 20
 *  and quietly turns a tail metric into a peak metric. `p95IsMax` reports the
 *  sample sizes at which the two are the same number regardless. */
function percentile(sortedAsc: number[], p: number): number {
  if (!sortedAsc.length) return 0;
  return sortedAsc[Math.min(sortedAsc.length - 1, Math.max(0, Math.ceil(p * sortedAsc.length) - 1))];
}
interface Summary { p50: number; p95: number; max: number; count: number; p95IsMax: boolean }
function summarize(values: number[]): Summary {
  const sorted = [...values].sort((a, b) => a - b);
  return {
    p50: percentile(sorted, 0.5), p95: percentile(sorted, 0.95), max: sorted.at(-1) ?? 0,
    count: values.length, p95IsMax: values.length < MIN_SAMPLES_FOR_P95,
  };
}

/** The busiest any ONE second got, sliding rather than bucketed. Fixed buckets
 *  keyed on `floor(t / 1000)` split a burst that straddles a boundary and
 *  report each half — thirty events packed into 985..1015 ms read as fifteen
 *  and pass a ceiling of twenty, which is precisely the shape the ceiling
 *  exists to catch. */
function maxPerSlidingSecond(timestampsMs: number[]): number {
  const sorted = [...timestampsMs].sort((a, b) => a - b);
  let max = 0;
  let left = 0;
  for (let right = 0; right < sorted.length; right++) {
    while (sorted[right] - sorted[left] >= 1000) left++;
    max = Math.max(max, right - left + 1);
  }
  return max;
}

/** Longest silence a viewer saw while the guest was still printing, including
 *  the wait for the first frame and the tail after the last one. A pipeline
 *  that delivers a handful of frames and then wedges is indistinguishable from
 *  a healthy one by count alone; it is obvious by gap. */
function maxGapMs(timestampsMs: number[], windowMs: number): number {
  let previous = 0;
  let max = 0;
  for (const t of timestampsMs) {
    if (t > windowMs) break;
    max = Math.max(max, t - previous);
    previous = t;
  }
  return Math.max(max, windowMs - previous);
}

// ---------------------------------------------------------------------------
interface DriveResult { writes: number; windowMs: number }

async function driveContent(
  source: TerminalFrameSource, workload: NamedWorkload, durationMs: number,
  rng: () => number, batcher: LegacyOutputBatcher, midpoint: () => void,
): Promise<DriveResult> {
  const start = performance.now();
  const half = start + durationMs / 2;
  let firedMidpoint = false;
  const feed = (chunk: string) => { batcher.enqueue(chunk); source.feed(chunk); };
  // ED 3 mid-run on the retention workloads. A cleared archive starts a fresh
  // epoch, and the boundary a frame carries then describes that epoch alone —
  // so a run that never turns one over cannot tell a lifetime row count from a
  // boundary subtraction, and the two disagreeing is the whole point of
  // reporting the first.
  const turnover = () => { if (workload.content === "evict") feed("\x1b[3J"); };
  const checkMidpoint = () => {
    if (firedMidpoint || performance.now() < half) return;
    firedMidpoint = true;
    turnover();
    midpoint();
  };

  if (workload.content === "idle") {
    while (performance.now() - start < durationMs) { await Bun.sleep(10); checkMidpoint(); }
    return { writes: 0, windowMs: performance.now() - start };
  }
  if (workload.content === "tui") { feed("\x1b[?1049h\x1b[2J\x1b[H\x1b[?25l"); await source.settle(); }

  const tuiPeriodMs = 1000 / TUI_TARGET_WRITES_PER_SEC;
  let nextWriteAt = start + tuiPeriodMs;
  let writes = 0;
  let seq = 0;
  while (performance.now() - start < durationMs) {
    if (workload.content === "tui") {
      feed(tuiChunk(seq++, workload.grid));
    } else {
      // One PTY read, not one line. A real read coalesces many lines; feeding
      // one line per call starves the VT of work and prices the raw baseline at
      // an envelope per line, where the envelope outweighs the payload it
      // wraps — see `raw env%` in the report for what the shape actually costs.
      const line = workload.content === "burst" ? burstLine : scrollbackLine;
      let chunk = "";
      while (chunk.length < PTY_READ_BYTES) chunk += line(seq++, rng);
      feed(chunk);
    }
    writes++;
    // settle() is the real barrier: it also lets TerminalFrameHub's onParsed-
    // driven tick (wired in register()) run for this write before the next one,
    // which is what produces genuine capture throttling rather than a queue of
    // writes the VT parses in one uninterrupted burst.
    await source.settle();
    checkMidpoint();
    if (workload.content !== "tui") continue;
    // Paced against a moving deadline rather than a fixed sleep per iteration:
    // a fixed sleep adds the write's own cost and the host's timer granularity
    // on top of the period, which is how a 16 ms sleep yields 22 writes/s.
    const wait = nextWriteAt - performance.now();
    if (wait > 1) await Bun.sleep(wait);
    nextWriteAt = Math.max(nextWriteAt + tuiPeriodMs, performance.now());
  }
  batcher.flush();
  return { writes, windowMs: performance.now() - start };
}

/** Polls a condition on the hub's OWN interval, never calling `hub.tick()`.
 *  The interval is armed by `subscribe` and is what production relies on to
 *  deliver a screen after output has stopped; driving it by hand here would
 *  prove only that the harness can call a method. */
async function waitUntil(condition: () => boolean, timeoutMs: number): Promise<boolean> {
  const deadline = performance.now() + timeoutMs;
  while (performance.now() < deadline) {
    if (condition()) return true;
    await Bun.sleep(5);
  }
  return condition();
}

// ---------------------------------------------------------------------------
interface WorkloadResult {
  id: string; content: ContentKind; grid: { cols: number; rows: number };
  requestedDurationMs: number; outputWindowMs: number;
  input: { writes: number; writesPerSec: number; ptyReadBytes: number };
  capture: {
    attempts: number; successes: number; attemptsAfterWindow: number; attemptsPerSec: number;
    oversizeCaptures: number; timeMs: Summary; maxPerSlidingSecond: number;
  };
  frames: {
    sentInWindow: number; sentPerSec: number; maxPerSlidingSecond: number;
    bytes: Summary; bytesPerSec: number; maxSendGapMs: number; ageMs: Summary;
  };
  bandwidth: {
    frameBytesPerSec: number; rawWireBytesPerSec: number; rawPayloadBytesPerSec: number;
    rawEnvelopeOverheadPct: number; frameToRawRatio: number; frameModeIsWorse: boolean;
    encryptedFrameBytesPerSec: number; encryptedRawBytesPerSec: number;
  };
  history: {
    rowsArchivedAllEpochs: number; rowsRetainedInEpoch: number; epochTurnovers: number;
    accountedBytes: number; retentionBudgetBytes: number; sqliteFileBytes: number;
    pageLatencyMs: Summary; evictedCursorExpired: boolean | null;
  };
  /** Process-wide, and only ever reported as such: every workload runs in ONE
   *  process, so a peak recorded during the eighth is standing on whatever the
   *  first seven left behind, and a per-workload delta taken from it says an
   *  idle terminal that fed nothing cost megabytes. */
  memory: { processRssPeakMb: number };
  processing: { cpuUserMs: number; cpuSystemMs: number; parserBacklogCharsPeak: number };
  lifecycle: {
    attachmentLiveAfterDrain: boolean; unexpectedRetirements: number;
    failureStatuses: string[]; endedAfterExit: boolean;
    finalRevisionDelivered: boolean; exitRevisionDelivered: boolean;
    probeFramesDelivered: number | null;
  };
  gates: Record<string, boolean | null>;
}

async function runWorkload(
  workload: NamedWorkload, durationMs: number, fault: Fault | undefined, ackDelayMs: number,
  bandwidthBytesPerSec: number,
): Promise<WorkloadResult> {
  const tmpDir = mkdtempSync(join(tmpdir(), "terminal-frame-bench-"));
  const dbPath = join(tmpDir, "history.sqlite");
  const evicting = workload.content === "evict" && fault !== "no-evict";
  const store = new TerminalHistoryStore(dbPath, evicting ? { runBytes: EVICT_RUN_BYTES } : {});
  const runId = crypto.randomUUID();
  const history = store.openRun(runId);
  const source = new TerminalFrameSource(workload.grid.cols, workload.grid.rows, history);
  const transport = new BenchTransport(fault !== "no-ack", ackDelayMs, bandwidthBytesPerSec);
  // The hub's clock is the only thing every throttle in delivery.ts measures
  // against, so running it fast is a faithful stand-in for a throttle that has
  // stopped working, while the gates keep measuring real wall-clock rates.
  const hub = fault === "fast-clock"
    ? new TerminalFrameHub(() => performance.now() * FAST_CLOCK_FACTOR)
    : new TerminalFrameHub();
  const address: TerminalAddress = { projectId: "bench", checkoutId: "main", terminalId: workload.id };
  hub.register(address, source, runId);
  const connection = hub.connect(transport);
  transport.connection = connection;
  // Zeroed BEFORE the attach, unlike the counters reset just inside the try: the
  // attach tick is the one and only chance to see a screen that was already too
  // large to send when the viewer arrived.
  oversizeCaptures = 0;
  let rssTimer: ReturnType<typeof setInterval> | undefined;
  let sqliteFileBytes = 0;
  let tornDown = false;
  /** Called from the happy path as well as from the `finally`: the result object
   *  reports `sqliteFileBytes`, which is measured in here, so a teardown left to
   *  the `finally` alone reports every run as a zero-byte database. */
  const teardown = () => {
    if (tornDown) return;
    tornDown = true;
    if (rssTimer) clearInterval(rssTimer);
    transport.stop();
    store.close();
    // After close(), before the rmSync below: until the close the database is
    // split across a -wal sidecar this size does not count.
    try { sqliteFileBytes = statSync(dbPath).size; } catch { /* best-effort measurement */ }
    connection.close();
    hub.dispose();
    source.dispose();
    try { rmSync(tmpDir, { recursive: true, force: true }); } catch { /* best-effort cleanup */ }
  };
  try {
    const attachmentId = await connection.subscribe(address, TERMINAL_PROTOCOL_VERSION, crypto.randomUUID());
    if (!attachmentId) throw new Error(`bench: subscribe failed for workload ${workload.id}`);
    if (!forceOversize) await waitUntil(() => transport.frames.length > 0, DRAIN_TIMEOUT_MS);

    // Reset AFTER the attach: subscribe() itself drives one capture+send (the
    // "here is the current screen" frame every fresh viewer gets, from the
    // hub.tick() inside TerminalViewerConnection.subscribe), which is not output
    // the workload produced. Counting it would fail the idle gates on a frame
    // that has nothing to do with idleness, and would offset every other
    // workload's rate by one fixed frame unrelated to its content.
    captureEvents = [];
    capturedAt.clear();
    historyStats = { rowsArchived: 0, epochTurnovers: 0 };
    const origin = performance.now();
    clockOrigin = origin;
    transport.origin = origin;
    transport.phase = "output";
    transport.dropAttachFrame();
    const rssSamples: number[] = [];
    let parserBacklogCharsPeak = 0;
    const cpuStart = process.cpuUsage();
    rssTimer = setInterval(() => {
      rssSamples.push(process.memoryUsage().rss);
      parserBacklogCharsPeak = Math.max(parserBacklogCharsPeak,
        (source as unknown as { pendingChars: number }).pendingChars);
    }, 10);

    const batcher = new LegacyOutputBatcher(workload.id, transport.cipher);
    const rng = mulberry32(seedFor(workload.id));
    const drive = await driveContent(source, workload, durationMs, rng, batcher, () => {
      if (fault === "retire-mid") connection.unsubscribe(address, runId, attachmentId);
      if (fault === "idle-poke" && workload.content === "idle") source.feed("poked\r\n");
    });
    batcher.flush();
    const outputWindowMs = drive.windowMs;
    const cpu = process.cpuUsage(cpuStart);
    await source.settle();

    // Drain: output has stopped, so the hub's own interval is the only thing that
    // can still move the last screen out. What it converges to is the claim — a
    // viewer left on a stale screen after the guest fell quiet is the failure
    // this phase exists to catch.
    transport.phase = "drain";
    const finalRevision = source.revision;
    const finalRevisionDelivered = await waitUntil(
      () => transport.lastRevision() >= finalRevision, DRAIN_TIMEOUT_MS,
    );
    const attachmentLiveAfterDrain = connection.hasAttachment(attachmentId);

    // Idle terminals need the opposite proof: silence is only a pass if delivery
    // was armed the whole time. A single write here, answered by a frame, is what
    // separates "correctly quiet" from "quietly broken".
    let probeFramesDelivered: number | null = null;
    if (workload.content === "idle") {
      transport.phase = "probe";
      const before = transport.frames.length;
      source.feed("idle probe\r\n");
      await source.settle();
      await waitUntil(() => transport.frames.length > before, DRAIN_TIMEOUT_MS);
      probeFramesDelivered = transport.frames.length - before;
    }

    // Exit: the last screen a program printed on its way out has to reach the
    // viewer, and the viewer has to be told the run is over.
    transport.phase = "exit";
    // Ceiling samples are taken BEFORE finish(). The final capture is deliberately
    // unthrottled — the run will never produce another revision, so one serialize
    // outside the budget is the contract, not a violation of it — and the frame it
    // produces is exempt from the pacing interval for the same reason. Counting
    // either against a per-second ceiling would make the exit path fail a gate it
    // is defined to be outside of.
    const ceilingCaptureSamples = captureEvents.map((c) => c.atMs);
    const ceilingFrameSamples = transport.frames.map((f) => f.atMs);
    await hub.finish(address, runId, 0);
    const exitRevision = source.revision;
    const endedAfterExit = await waitUntil(
      () => transport.statuses.some((s) => s.phase === "exit" && s.code === "ENDED"), DRAIN_TIMEOUT_MS,
    );
    const exitRevisionDelivered = transport.lastRevision() >= exitRevision;
    transport.phase = "done";
    clearInterval(rssTimer);
    transport.stop();

    // boundary()/page() before teardown(): the store close in there retires every
    // open handle, after which page() answers empty rather than reading the run
    // it still has on disk.
    const boundary = history.boundary();
    const pageLatenciesMs: number[] = [];
    let cursor = boundary.nextRowId;
    for (let i = 0; i < 20 && cursor > boundary.firstRowId; i++) {
      const t0 = performance.now();
      const page = history.page(boundary.epoch, cursor);
      pageLatenciesMs.push(performance.now() - t0);
      if (!page.rows.length || page.expired) break;
      cursor = page.beforeRowId;
    }
    // Load-bearing, not redundant: the `rowsArchived > retained` conjunct beside
    // it is satisfied on a run where nothing was evicted at all. The ED 3 these
    // workloads fire mid-run turns the epoch over, so the lifetime archive
    // counter outruns what the current epoch retains while `firstRowId` is still
    // 0 — `--fault=no-evict` is that run. This term is what requires an evicted
    // front, and with it the contract the archived-scrollback view leans on: a
    // cursor below that front is refused, never answered with rows.
    const evictedCursorExpired = workload.content === "evict"
      ? boundary.firstRowId > 0 && history.page(boundary.epoch, boundary.firstRowId - 1).expired
      : null;
    const accountedBytes = store.record(runId)?.bytes ?? 0;
    teardown();

    // Windowed, not cumulative: the idle probe and the exit capture both land
    // after output stopped, and counting them against a workload's own rates
    // turns "an idle terminal serialized nothing" into a failure of the probe
    // that proves it was listening.
    const capturesInWindow = captureEvents.filter((c) => c.atMs <= outputWindowMs);
    const inWindow = transport.frames.filter((f) => f.atMs <= outputWindowMs);
    const windowSeconds = outputWindowMs / 1000;
    const perSec = (value: number) => (windowSeconds > 0 ? value / windowSeconds : 0);
    const frameBytesInWindow = inWindow.reduce((total, f) => total + f.bytes, 0);
    const frameBytesPerSec = perSec(frameBytesInWindow);
    const rawWireBytesPerSec = perSec(batcher.wireBytes);
    const failureStatuses = transport.statuses
      .filter((s) => s.code !== "ENDED" || s.phase !== "exit")
      .map((s) => `${s.code}@${s.phase}`);
    // Retirements from "exit" and "done" are the two the harness itself causes —
    // the ENDED that follows finish(), and the connection close in teardown. What
    // this counts is a viewer dropped while it was still supposed to be watching.
    const unexpectedRetirements = transport.retirements
      .filter((r) => r.phase !== "exit" && r.phase !== "done").length;
    const captureCeiling = maxPerSlidingSecond(ceilingCaptureSamples);
    const sendCeiling = maxPerSlidingSecond(ceilingFrameSamples);
    const pageLatency = summarize(pageLatenciesMs);
    const isIdle = workload.content === "idle";

    return {
      id: workload.id, content: workload.content, grid: { cols: workload.grid.cols, rows: workload.grid.rows },
      requestedDurationMs: durationMs, outputWindowMs,
      input: { writes: drive.writes, writesPerSec: perSec(drive.writes), ptyReadBytes: PTY_READ_BYTES },
      capture: {
        attempts: capturesInWindow.length, successes: capturesInWindow.filter((c) => c.ok).length,
        attemptsAfterWindow: captureEvents.length - capturesInWindow.length,
        attemptsPerSec: perSec(capturesInWindow.length), oversizeCaptures,
        timeMs: summarize(capturesInWindow.map((c) => c.durationMs)), maxPerSlidingSecond: captureCeiling,
      },
      frames: {
        sentInWindow: inWindow.length, sentPerSec: perSec(inWindow.length), maxPerSlidingSecond: sendCeiling,
        bytes: summarize(inWindow.map((f) => f.bytes)), bytesPerSec: frameBytesPerSec,
        ageMs: summarize(inWindow.map((f) => f.ageMs)),
        maxSendGapMs: isIdle ? 0 : maxGapMs(inWindow.map((f) => f.atMs), outputWindowMs),
      },
      bandwidth: {
        frameBytesPerSec, rawWireBytesPerSec, rawPayloadBytesPerSec: perSec(batcher.payloadBytes),
        rawEnvelopeOverheadPct: batcher.wireBytes > 0
          ? (100 * (batcher.wireBytes - batcher.payloadBytes)) / batcher.wireBytes : 0,
        frameToRawRatio: rawWireBytesPerSec > 0 ? frameBytesPerSec / rawWireBytesPerSec : 0,
        frameModeIsWorse: rawWireBytesPerSec > 0 && frameBytesPerSec > rawWireBytesPerSec,
        encryptedFrameBytesPerSec: perSec(inWindow.reduce((sum, f) => sum + f.encryptedBytes, 0)),
        encryptedRawBytesPerSec: perSec(batcher.encryptedBytes),
      },
      history: {
        rowsArchivedAllEpochs: historyStats.rowsArchived,
        rowsRetainedInEpoch: boundary.nextRowId - boundary.firstRowId,
        epochTurnovers: historyStats.epochTurnovers,
        // The budget the store was actually constructed with, which is what the
        // report's `budget KB` column names. NOT the ceiling `evictionEnforced`
        // compares against: that gate is fixed on EVICT_RUN_BYTES whatever the
        // store was built with, so a run that kept the production budget is
        // measured against the bench one and its miss line has to say so.
        accountedBytes, retentionBudgetBytes: evicting ? EVICT_RUN_BYTES : TERMINAL_HISTORY_RUN_BYTES,
        sqliteFileBytes,
        pageLatencyMs: pageLatency, evictedCursorExpired,
      },
      memory: { processRssPeakMb: rssSamples.length ? Math.max(...rssSamples) / (1024 * 1024) : 0 },
      processing: { cpuUserMs: cpu.user / 1000, cpuSystemMs: cpu.system / 1000, parserBacklogCharsPeak },
      lifecycle: {
        attachmentLiveAfterDrain, unexpectedRetirements, failureStatuses, endedAfterExit,
        finalRevisionDelivered, exitRevisionDelivered, probeFramesDelivered,
      },
      gates: {
        idleQuiet: isIdle ? capturesInWindow.length === 0 && inWindow.length === 0 : null,
        idleArmed: isIdle ? (probeFramesDelivered ?? 0) > 0 && attachmentLiveAfterDrain : null,
        captureCeiling: captureCeiling <= MAX_EVENTS_PER_SECOND,
        sendCeiling: sendCeiling <= MAX_EVENTS_PER_SECOND,
        // Delivery only: the attachment outlived the run and nothing failed it.
        // An oversize screen does reach here as a DISPLAY_FAILED, but only as a
        // symptom — the notice latches per episode (delivery.ts), so its count
        // says nothing about how many screens were skipped, and on its own it
        // reads exactly like the stall the same run also trips.
        deliveryLive: attachmentLiveAfterDrain && unexpectedRetirements === 0 && failureStatuses.length === 0,
        // A screen over TERMINAL_FRAME_MAX_ANSI_BYTES never becomes a frame —
        // `capture()` returns null — so no assertion on delivered frame SIZES
        // can ever fail, and every delivery-side symptom of one reads as a
        // stall. This gate is the one that names the cause.
        screenWithinDisplayBudget: oversizeCaptures === 0,
        sendGap: isIdle ? null : maxGapMs(inWindow.map((f) => f.atMs), outputWindowMs) <= MAX_SEND_GAP_MS,
        finalFrameDelivered: isIdle ? null : finalRevisionDelivered,
        exitFrameDelivered: endedAfterExit && exitRevisionDelivered,
        evictionEnforced: workload.content === "evict"
          ? evicting && historyStats.rowsArchived > boundary.nextRowId - boundary.firstRowId
            && accountedBytes <= EVICT_RUN_BYTES && evictedCursorExpired === true
          : null,
        pageLatency: pageLatency.count > 0 ? pageLatency.p95 <= MAX_PAGE_LATENCY_MS : null,
      },
    };
  } finally {
    // Teardown is a finally, not a tail. A throw anywhere above — the harness's
    // own `subscribe failed` included — otherwise leaves the hub interval and
    // the ack timers arming the process, the SQLite handle open with its
    // -wal/-shm pair unflushed, and the temp directory on disk for good: one
    // aborted workload is one directory nothing will ever come back for.
    teardown();
  }
}

// ---------------------------------------------------------------------------
function renderTable(headers: string[], rows: string[][]): string {
  const widths = headers.map((h, i) => Math.max(h.length, ...rows.map((r) => r[i]?.length ?? 0)));
  const line = (cells: string[]) => cells.map((c, i) => c.padEnd(widths[i])).join(" | ");
  return [line(headers), widths.map((w) => "-".repeat(w)).join("-|-"), ...rows.map(line)].join("\n");
}
const fmt = (n: number, digits = 1) => n.toFixed(digits);
const kb = (bytes: number) => (bytes / 1024).toFixed(1);
/** A percentile triple is only readable next to the sample count that produced
 *  it; `*` marks the sizes at which p95 cannot differ from the maximum. */
const triple = (s: Summary, digits: number, scale = (n: number) => n): string =>
  `${fmt(scale(s.p50), digits)}/${fmt(scale(s.p95), digits)}${s.p95IsMax ? "*" : ""}/${fmt(scale(s.max), digits)} n=${s.count}`;

function printHumanReport(results: WorkloadResult[], misses: string[], fault: Fault | undefined): void {
  console.log(`\nterminal-frame-bench — ceiling ${MAX_EVENTS_PER_SECOND}/s, interval ${TERMINAL_FRAME_INTERVAL_MS}ms, window ${TERMINAL_VIEWER_MAX_FRAMES} frames${fault ? `, FAULT INJECTED: ${fault}` : ""}\n`);
  console.log(renderTable(
    ["workload", "win(s)", "writes/s", "cap att/ok", "cap/s", "cap ms p50/p95/max", "frames/s", "cap|snd per 1s", "frame KB p50/p95/max", "gap ms"],
    results.map((r) => [
      r.id, fmt(r.outputWindowMs / 1000, 2), fmt(r.input.writesPerSec),
      `${r.capture.attempts}/${r.capture.successes}`, fmt(r.capture.attemptsPerSec),
      r.capture.timeMs.count ? triple(r.capture.timeMs, 2) : "n/a",
      fmt(r.frames.sentPerSec), `${r.capture.maxPerSlidingSecond}|${r.frames.maxPerSlidingSecond}`,
      r.frames.bytes.count ? triple(r.frames.bytes, 1, (n) => n / 1024) : "n/a",
      fmt(r.frames.maxSendGapMs, 0),
    ]),
  ));
  console.log();
  console.log(renderTable(
    ["workload", "frame KB/s", "raw KB/s", "raw env%", "ratio", "verdict"],
    results.map((r) => [
      r.id, kb(r.bandwidth.frameBytesPerSec), kb(r.bandwidth.rawWireBytesPerSec),
      fmt(r.bandwidth.rawEnvelopeOverheadPct),
      r.bandwidth.rawWireBytesPerSec > 0 ? `${fmt(r.bandwidth.frameToRawRatio, 2)}x` : "n/a",
      r.bandwidth.rawWireBytesPerSec === 0 ? "no raw traffic"
        : r.bandwidth.frameModeIsWorse ? "frame WORSE than raw" : "frame cheaper than raw",
    ]),
  ));
  console.log();
  console.log(renderTable(
    ["workload", "rows arch/ret", "epochs", "store KB", "budget KB", "sqlite KB", "page ms p50/p95/max", "rss peak MB"],
    results.map((r) => [
      r.id, `${r.history.rowsArchivedAllEpochs}/${r.history.rowsRetainedInEpoch}`,
      String(r.history.epochTurnovers), kb(r.history.accountedBytes),
      r.history.retentionBudgetBytes === TERMINAL_HISTORY_RUN_BYTES ? "prod" : kb(r.history.retentionBudgetBytes),
      kb(r.history.sqliteFileBytes),
      r.history.pageLatencyMs.count ? triple(r.history.pageLatencyMs, 3) : "n/a",
      fmt(r.memory.processRssPeakMb),
    ]),
  ));
  console.log("\n* p95 equals max at this sample size. `rows arch` counts every row ever handed to the archive, across");
  console.log("  epochs; `rows ret` is what the CURRENT epoch still holds, so the two diverge once eviction or an ED 3");
  console.log("  has run. rss peak is PROCESS-wide and every workload shares one process, so it belongs to no single");
  console.log(`  row: RSS was ${fmt(processRssStartMb)} MB before the first workload and ${fmt(process.memoryUsage().rss / (1024 * 1024))} MB after the last.\n`);

  const gateNames = [...new Set(results.flatMap((r) => Object.keys(r.gates)))];
  console.log(renderTable(
    ["workload", ...gateNames],
    results.map((r) => [r.id, ...gateNames.map((g) => {
      const value = r.gates[g];
      return value === null || value === undefined ? "-" : value ? "PASS" : "FAIL";
    })]),
  ));
  console.log();
  if (misses.length) {
    console.log(`BUDGET MISSES (${misses.length}):`);
    for (const m of misses) console.log(`  - ${m}`);
  } else {
    console.log("All gates passed.");
  }
}

function collectMisses(results: WorkloadResult[]): string[] {
  const misses: string[] = [];
  for (const r of results) {
    for (const [gate, value] of Object.entries(r.gates)) {
      if (value !== false) continue;
      misses.push(`${r.id}: ${gate} — ${explain(gate, r)}`);
    }
  }
  return misses;
}
function explain(gate: string, r: WorkloadResult): string {
  switch (gate) {
    case "idleQuiet": return `idle terminal serialized (captures=${r.capture.attempts}, frames=${r.frames.sentInWindow})`;
    case "idleArmed": return `probe write produced ${r.lifecycle.probeFramesDelivered} frames, attachment live=${r.lifecycle.attachmentLiveAfterDrain}`;
    case "captureCeiling": return `${r.capture.maxPerSlidingSecond} captures in one second (max ${MAX_EVENTS_PER_SECOND})`;
    case "sendCeiling": return `${r.frames.maxPerSlidingSecond} sends in one second (max ${MAX_EVENTS_PER_SECOND})`;
    case "deliveryLive": return `attachment live=${r.lifecycle.attachmentLiveAfterDrain}, retirements=${r.lifecycle.unexpectedRetirements}, statuses=[${r.lifecycle.failureStatuses.join(",")}]`;
    case "screenWithinDisplayBudget": return `${r.capture.oversizeCaptures} captures found the screen over TERMINAL_FRAME_MAX_ANSI_BYTES and served nothing (attempts, not distinct screens: the source re-reads the flag only when it serializes)`;
    case "sendGap": return `${fmt(r.frames.maxSendGapMs, 0)}ms without a frame while output continued (max ${MAX_SEND_GAP_MS}ms)`;
    case "finalFrameDelivered": return `viewer never reached the final revision within ${DRAIN_TIMEOUT_MS}ms of output stopping`;
    case "exitFrameDelivered": return `ended=${r.lifecycle.endedAfterExit}, final screen delivered=${r.lifecycle.exitRevisionDelivered}`;
    case "evictionEnforced": return `archived=${r.history.rowsArchivedAllEpochs}, retained=${r.history.rowsRetainedInEpoch}, bytes=${r.history.accountedBytes} (max ${EVICT_RUN_BYTES}), stale cursor expired=${r.history.evictedCursorExpired}`;
    case "pageLatency": return `page p95 ${fmt(r.history.pageLatencyMs.p95, 2)}ms over ${r.history.pageLatencyMs.count} samples (max ${MAX_PAGE_LATENCY_MS}ms)`;
    default: return "budget missed";
  }
}

// ---------------------------------------------------------------------------
async function main(): Promise<void> {
  const { values } = parseArgs({
    args: process.argv.slice(2),
    options: {
      workload: { type: "string" }, "duration-ms": { type: "string" },
      "ack-delay-ms": { type: "string" }, fault: { type: "string" },
      "bandwidth-bytes-sec": { type: "string" },
      json: { type: "boolean" }, help: { type: "boolean" },
    },
  });
  if (values.help) {
    console.log([
      "terminal-frame-bench [--workload=<name>] [--duration-ms=N] [--ack-delay-ms=N] [--bandwidth-bytes-sec=N] [--fault=<name>] [--json]",
      "",
      `workloads: ${WORKLOADS.map((w) => w.id).join(", ")}`,
      `default duration: ${DEFAULT_DURATION_MS}ms of output per workload`,
      "",
      "Exit status is 1 when any gate is missed, 2 on a harness error.",
      "",
      "--fault deliberately breaks one property so the matching gate is seen to fail.",
      "A gate reads `-` where it does not apply to a workload, and a `-` is never",
      "counted as a miss: idleQuiet/idleArmed off the idle workloads and",
      "evictionEnforced off the evict ones, sendGap/finalFrameDelivered ON the idle",
      "workloads, pageLatency wherever the epoch retained no rows to page (idle, tui).",
      "",
      "  no-ack      viewer never acknowledges  -> sendGap, finalFrameDelivered, exitFrameDelivered",
      "  idle-poke   writes during the idle window -> idleQuiet",
      "  retire-mid  unsubscribes mid-run        -> deliveryLive, exitFrameDelivered, plus",
      "              idleArmed on the idle workloads and sendGap/finalFrameDelivered on",
      "              the rest",
      "  fast-clock  hub clock runs 4x real time -> captureCeiling, sendCeiling (on the",
      "              workloads that produce output; an idle one serializes nothing)",
      "  no-evict    evict workloads keep the production retention budget -> evictionEnforced",
      "  slow-page   history paging spins        -> pageLatency",
      "  oversize    every screen is too large to serialize -> screenWithinDisplayBudget,",
      "              plus, downstream of it, deliveryLive/exitFrameDelivered everywhere,",
      "              idleArmed on the idle workloads and sendGap/finalFrameDelivered on",
      "              the rest: an oversize screen looks exactly like a stall from the",
      "              delivery side, which is why it needs a gate that names the cause",
    ].join("\n"));
    return;
  }
  const durationMs = Number(values["duration-ms"] ?? DEFAULT_DURATION_MS);
  if (!Number.isFinite(durationMs) || durationMs <= 0) throw new Error("--duration-ms must be a positive number");
  // A window shorter than the ceiling's own measuring period cannot contain a
  // full second to count events in, and is dominated by first-write warmup —
  // the rates are still printed, but they are not the ones to baseline against.
  if (durationMs < 1000) {
    console.error(`terminal-frame-bench: --duration-ms=${durationMs} is under one second; rates are warmup-dominated and the per-second ceilings have no full window to measure.`);
  }
  const ackDelayMs = Number(values["ack-delay-ms"] ?? 0);
  if (!Number.isFinite(ackDelayMs) || ackDelayMs < 0) throw new Error("--ack-delay-ms must be a non-negative number");
  const bandwidthBytesPerSec = Number(values["bandwidth-bytes-sec"] ?? 0);
  if (!Number.isFinite(bandwidthBytesPerSec) || bandwidthBytesPerSec < 0) throw new Error("--bandwidth-bytes-sec must be a non-negative number (0 means unlimited)");
  const fault = values.fault as Fault | undefined;
  if (fault && !FAULTS.includes(fault)) throw new Error(`unknown --fault=${fault}; choices: ${FAULTS.join(", ")}`);
  slowPages = fault === "slow-page";
  forceOversize = fault === "oversize";
  let selected = WORKLOADS;
  if (values.workload) {
    selected = WORKLOADS.filter((w) => w.id === values.workload);
    if (!selected.length) {
      throw new Error(`unknown --workload=${values.workload}; choices: ${WORKLOADS.map((w) => w.id).join(", ")}`);
    }
  }
  const results: WorkloadResult[] = [];
  for (const workload of selected) results.push(await runWorkload(workload, durationMs, fault, ackDelayMs, bandwidthBytesPerSec));
  const misses = collectMisses(results);

  if (values.json) {
    // stdout carries only the machine-comparable capture; the human table goes
    // to stderr so an interactive run still shows both and `> baseline.json`
    // captures exactly what a diff wants.
    console.log(JSON.stringify({
      generatedBy: "terminal-frame-bench", schemaVersion: 4, durationMs, ackDelayMs, bandwidthBytesPerSec,
      measurementScope: {
        encryption: "actual AES-GCM application envelopes; excludes route headers and fragmentation",
        network: "bandwidth serialization plus acknowledgment delay; no real relay",
        frameAge: "capture start to simulated-link handoff; not paint or input-to-paint latency",
        cpu: "whole benchmark process, including raw baseline encryption and history",
        parserBacklog: "sampled private parser queue in UTF-16 characters; 10 ms sampling can miss peaks",
      },
      fault: fault ?? null, frameIntervalMs: TERMINAL_FRAME_INTERVAL_MS,
      ceilingPerSecond: MAX_EVENTS_PER_SECOND, budgets: {
        maxSendGapMs: MAX_SEND_GAP_MS, maxPageLatencyMs: MAX_PAGE_LATENCY_MS,
        maxFrameBytes: TERMINAL_VIEWER_MAX_BYTES, evictRunBytes: EVICT_RUN_BYTES,
      },
      misses, workloads: results,
    }));
    const realLog = console.error.bind(console);
    const stdoutLog = console.log; console.log = realLog;
    try { printHumanReport(results, misses, fault); } finally { console.log = stdoutLog; }
  } else {
    printHumanReport(results, misses, fault);
  }
  if (misses.length) process.exitCode = 1;
}

try {
  await main();
} catch (error) {
  console.error(`terminal-frame-bench: ${error instanceof Error ? error.stack ?? error.message : String(error)}`);
  process.exitCode = 2;
}
