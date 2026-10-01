import { hostname as osHostname } from "node:os";
import { Unicode11Addon } from "@xterm/addon-unicode11";
import { TerminalScreen } from "../terminal-screen";
import { logger } from "../logger";
import { TerminalModeTracker } from "../terminal-modes";
import { XtermFrameAdapter, type TerminalArchiveSink } from "./xterm-adapter";
import {
  TERMINAL_PROTOCOL_VERSION, TERMINAL_FRAME_MAX_ANSI_BYTES, TerminalScreenFrameSchema, encodedJsonBytes,
  type TerminalHistoryRow, type TerminalScreenFrame,
} from "./protocol";
import type { TerminalRunHistory } from "./history";
import { installTerminalQueries, OscQueryTerminators, type TerminalQueryColors } from "./queries";
import { detectLinks, type DetectRow } from "../terminal-links/detector";
import { parseOsc7, scanLine } from "../terminal-links/grammar";
import { normalizeBases, type LinkBases } from "../terminal-links/resolver";
import { sharedPathStatCache, type PathStatCache, type PathStatus } from "../terminal-links/stat-cache";
export { TERMINAL_FRAME_INTERVAL_MS as FRAME_INTERVAL_MS } from "./protocol";
export const TerminalFrameSchema = TerminalScreenFrameSchema;
export type { TerminalScreenFrame };
/** @deprecated NOT the `terminal:frame` wire message — that name is registered
 *  in bridge/src/protocol.ts, and a file importing both gets a silent collision.
 *  Retained only because the frozen prototype shim in ../experimental imports
 *  it; every new reader wants TerminalScreenFrame. */
export type TerminalFrame = TerminalScreenFrame;

const log = logger.child({ component: "terminal-frame-source" });

export const SYNC_OUTPUT_TIMEOUT_MS = 1000;
/**
 * Characters accepted but not yet parsed, past which a chunk is DROPPED.
 *
 * Sized against memory rather than against parser throughput, because a backlog
 * here is not a throughput deficit. bun-pty's read loop awaits only on an EMPTY
 * read (`_startReadLoop` in its `terminal.ts`) and its Rust half buffers into an
 * unbounded channel, while xterm drains its write buffer from a `setTimeout`. So
 * one guest burst arrives as a single uninterrupted synchronous drain with no
 * turn of the event loop in it, and this counter ends up equal to the whole
 * burst, whatever the burst's rate was.
 *
 * Kept well under xterm's own 50M-character watermark, whose `write()` throw
 * discards the chunk anyway: reaching that one first would put the same drop
 * beyond this class's reach and out of the history status.
 */
const MAX_PENDING_CHARS = 16_000_000;
/**
 * Largest string handed to one `term.write()`.
 *
 * xterm checks its 12 ms slice BETWEEN write-buffer entries and never inside
 * one, so a coalesced burst written as a single entry is parsed with no yield at
 * all and every timer, heartbeat and socket read on this process waits out the
 * whole parse. Splitting at this bound keeps that granularity while still
 * cutting the entry count — and with it the per-write callback, revision bump
 * and `onParsed` fan-out — down from one per 4 KB PTY read.
 */
const MAX_WRITE_CHARS = 65_536;
const OSC_CLOSE = "\x1b]8;;\x1b\\";
/** Rows above the viewport read for detection, so a path that hard-wrapped
 *  into the top row still joins with its head. */
const LINK_CONTEXT_ROWS = 8;
/** How far back a soft-wrapped top row is followed to the start of its line,
 *  so a mention that crosses the top edge is read whole. A run longer than
 *  this leaves its first row a continuation, which the detector will not link. */
const LINK_RUN_ROWS = 64;
const LIVE_LINK_BUDGET = { lookups: 2048, newStats: 64 };
/** A static screen has nothing else to wake it, so a lookup answered "missing"
 *  is retried this long after the last frame. */
const NEGATIVE_RECHECK_MS = 5000;
const SCAN_MEMO_MAX = 512;
/** A key is a whole logical line, and one endless soft-wrapped line makes every
 *  capture's key a little longer than the last, so the count alone would let a
 *  terminal hold hundreds of near-identical megabyte strings. */
const SCAN_MEMO_MAX_CHARS = 262_144;
/** Past this a line is scanned again each time rather than remembered: it is
 *  too large to be worth a slot, and too rare to be missed. */
const SCAN_MEMO_MAX_KEY = 16_384;
const NO_EXPLICIT_LINKS: readonly (string | undefined)[] = [];

export interface TerminalLinkOptions {
  /** The directory the terminal was started in. Never `process.cwd()`. */
  spawnCwd?: string;
  /** Detect inside the alternate screen too. Off for anything but an agent
   *  session: a detected link is an OSC 8 cell to the viewer, so under mouse
   *  reporting a click on it would never reach the program. */
  alternateScreen: boolean;
  cache?: PathStatCache;
  hostname?: string;
  timer?: (fn: () => void, ms: number) => { cancel(): void };
  frameBudgetBytes?: number;
  /** Tests only: the platform whose path rules apply. */
  platform?: NodeJS.Platform;
}

/** What the last capture's detection was waiting on or standing on. */
interface LinkDeps {
  pending: Set<string>;
  negatives: Set<string>;
  linked: Set<string>;
  refining: Set<string>;
  starved: boolean;
}

interface LinkState {
  readonly opts: TerminalLinkOptions;
  readonly cache: PathStatCache;
  readonly platform: NodeJS.Platform;
  readonly timer: (fn: () => void, ms: number) => { cancel(): void };
  readonly scanMemo: Map<string, ReturnType<typeof scanLine>>;
  /** Total length of the keys in `scanMemo`. */
  scanMemoChars: number;
  readonly detach: Array<() => void>;
  liveCwd?: string;
  checkoutRoot?: string;
  deps?: LinkDeps;
  depsRevision: number;
  recheckedRevision: number;
  recheck?: { cancel(): void };
  invalidateQueued: boolean;
}

function blankDetectRow(cols: number): DetectRow {
  return {
    text: "", colAt: new Int32Array(0), widthAt: new Uint8Array(cols), cols, wrapped: false, endCol: 0,
    explicit: NO_EXPLICIT_LINKS,
  };
}

const defaultLinkTimer =(fn: () => void, ms: number): { cancel(): void } => {
  const handle = setTimeout(fn, ms);
  handle.unref?.();
  return { cancel: () => clearTimeout(handle) };
};

/** What the row archive could not record faithfully, for the epoch the source
 *  is currently recording into. */
export interface TerminalHistoryStatus {
  /** True once history no longer describes what the buffer holds. */
  degraded: boolean;
  /** Rows that reached xterm's scrollback with no history row to match. */
  gaps: number;
  /** Column resizes. Archived rows keep their ORIGINAL geometry by design, so
   *  after one they no longer align with the live grid, and a column GROW
   *  rejoins rows already published under separate ids. */
  rewraps: number;
  /** Rows destroyed at the bottom edge or overpainted by DECALN. No terminal
   *  records these, so they are reported without degrading history. */
  discarded: number;
}


/** Independent display frames; no raw tail is ever written to the viewer. */
export class TerminalFrameSource extends TerminalScreen {
  private readonly adapter: XtermFrameAdapter;
  private detachArchive?: () => void;
  private detachQueries?: () => void;
  private atBoundary = false;
  private readonly listeners = new Set<() => void>();
  private readonly modes = new TerminalModeTracker();
  private readonly oscTerminators = new OscQueryTerminators();
  private pendingChars = 0;
  /** Accepted from the guest, not yet handed to xterm — see `MAX_WRITE_CHARS`.
   *  Distinct from the base class's `unparsed`, which is what xterm HOLDS; both
   *  are unparsed, and the two tail accessors below report them in that order. */
  private readonly batch: string[] = [];
  private flushQueued = false;
  /** Set while chunks are being dropped for backlog, so the episode logs once
   *  at each end rather than once per refused chunk. */
  private dropping = false;
  private droppedChars = 0;
  private failed: Error | undefined;
  private _revision = 0;
  private _oversize = false;
  private syncSince: number | undefined;
  private readonly keyboard = { normal: [0], alternate: [0] };
  private gaps = 0;
  private rewraps = 0;
  private discarded = 0;
  private readonly link?: LinkState;
  /** An OSC 8 reached the parser. Until one does no cell can carry a program's
   *  own link, and the overlay need not look at rows with nothing detected. */
  private sawHyperlink = false;

  constructor(cols: number, rows: number, private readonly history?: TerminalRunHistory, links?: TerminalLinkOptions) {
    super(cols, rows);
    this.term.loadAddon(new Unicode11Addon());
    this.term.unicode.activeVersion = "11";
    this.adapter = new XtermFrameAdapter(this.term);
    if (history) {
      const sink: TerminalArchiveSink = {
        row: (row) => this.archive(row),
        gap: (count) => { this.gaps += count; },
        discarded: (count) => { this.discarded += count; },
      };
      this.detachArchive = this.adapter.onArchiveRow(sink);
      // Both ED forms: xterm dispatches DECSED (`CSI ? J`) to the same erase, so
      // a handler keyed on the bare final would leave history describing a
      // scrollback the guest has already told the terminal to forget.
      for (const id of [{ final: "J" }, { prefix: "?", final: "J" }]) {
        this.term.parser.registerCsiHandler(id, (params) => {
          if (params[0] === 3 && this.term.buffer.active.type === "normal") this.clearHistory();
          return false;
        });
      }
    }
    // Input-affecting modes must be restated even before the guest changes one.
    this.modes.feed("\x1bc");
    for (const final of ["h", "l"]) {
      this.term.parser.registerCsiHandler({ prefix: "?", final }, (params) => {
        this.modes.feed(`\x1b[?${params.join(";")}${final}`);
        if (params.includes(2026) && (final === "l" || !this.term.modes.synchronizedOutputMode)) {
          this.syncSince = undefined;
        }
        return false;
      });
    }
    this.term.parser.registerEscHandler({ final: "c" }, () => {
      // RIS destroys the viewport and the scrollback together, so no archive can
      // describe it. The epoch bump IS the discontinuity the app reads.
      this.clearHistory();
      this.modes.feed("\x1bc");
      this.keyboard.normal = [0];
      this.keyboard.alternate = [0];
      return false;
    });
    this.term.parser.registerCsiHandler({ intermediates: "!", final: "p" }, () => {
      this.modes.feed("\x1b[!p");
      return false;
    });
    // xterm 6 does not parse Kitty's stack. Track it at the parser boundary,
    // separately per buffer, per https://sw.kovidgoyal.net/kitty/keyboard-protocol/.
    for (const prefix of [">", "=", "<"]) {
      this.term.parser.registerCsiHandler({ prefix, final: "u" }, (params) => {
        const stack = this.keyboard[this.term.buffer.active.type];
        const flags = typeof params[0] === "number" ? params[0] & 31 : 0;
        if (prefix === ">") {
          if (stack.length === 32) stack.shift();
          stack.push(flags);
        } else if (prefix === "<") {
          const count = typeof params[0] === "number" ? params[0] || 1 : 1;
          stack.splice(Math.max(0, stack.length - count));
          if (!stack.length) stack.push(0);
        } else {
          const mode = params[1] || 1;
          if (mode === 1) stack[stack.length - 1] = flags;
          else if (mode === 2) stack[stack.length - 1] |= flags;
          else if (mode === 3) stack[stack.length - 1] &= ~flags;
        }
        return true;
      });
    }
    this.term.parser.registerOscHandler(8, () => {
      this.sawHyperlink = true;
      // Handled by xterm's own link service, which is what stores the uri.
      return false;
    });
    if (links) {
      const cache = links.cache ?? sharedPathStatCache();
      const platform = links.platform ?? process.platform;
      const hostname = links.hostname ?? osHostname();
      const state: LinkState = {
        opts: links, cache, platform, timer: links.timer ?? defaultLinkTimer,
        scanMemo: new Map(), scanMemoChars: 0, detach: [], depsRevision: -1, recheckedRevision: -1, invalidateQueued: false,
      };
      this.link = state;
      this.term.parser.registerOscHandler(7, (data) => {
        try { state.liveCwd = parseOsc7(data, hostname, platform) ?? state.liveCwd; } catch { /* a cwd report is a hint */ }
        return true;
      });
      state.detach.push(
        cache.onChange((abs, status) => this.onLinkStatus(abs, status)),
        cache.onDrain(() => { if (state.deps?.starved) this.queueInvalidate(); }),
      );
    }
  }

  /** Ignores a root that is refused or not absolute; links are optional, so an
   *  unusable root only means relative paths stay unlinked. */
  setLinkRoot(root: string): void {
    const link = this.link;
    const usable = link ? normalizeBases({ checkoutRoot: root }, link.platform).checkoutRoot : undefined;
    if (!link || usable === undefined) return;
    const changed = link.checkoutRoot !== root;
    link.checkoutRoot = root;
    link.cache.trustVolume(root);
    // A source that already framed its screen did so without this root, and a
    // restored screen never parses again to prompt another capture.
    if (changed && link.depsRevision >= 0) this.queueInvalidate();
  }

  /** Waits, within `budgetMs`, for the stats the last capture is still
   *  waiting on, so a screen that is about to freeze gets its links. Resolves
   *  true only when the screen changed because of them, which is when a
   *  re-capture is worth taking. */
  async settleLinks(budgetMs: number): Promise<boolean> {
    const link = this.link;
    const pending = link?.deps?.pending;
    if (!link || !pending || pending.size === 0 || this.isDisposed || this.failed) return false;
    const before = this._revision;
    await link.cache.prefetch([...pending], budgetMs);
    // The change a stat produced is applied on a microtask of its own.
    await new Promise<void>((resolve) => queueMicrotask(resolve));
    return this._revision !== before;
  }

  /** The first rows of the normal screen, which is where the archive's output
   *  continues: the row after the newest archived one is the screen's top.
   *  `complete` is true when these are every row there is. */
  screenTop(count: number): { rows: Array<Omit<TerminalHistoryRow, "rowId">>; complete: boolean } {
    const normal = this.term.buffer.normal;
    const rows: Array<Omit<TerminalHistoryRow, "rowId">> = [];
    for (let i = 0; i < Math.min(count, this.term.rows); i++) {
      const row = this.adapter.normalRow(normal.baseY + i);
      if (!row) break;
      rows.push(row);
    }
    return { rows, complete: rows.length === this.term.rows };
  }

  /** The raw bases, unfiltered: each caller runs them through `normalizeBases`
   *  against the root it trusts. */
  linkBases(): LinkBases {
    return { liveCwd: this.link?.liveCwd, spawnCwd: this.link?.opts.spawnCwd, checkoutRoot: this.link?.checkoutRoot };
  }

  /** Re-frames the screen when a stat the last frame depended on changed. A
   *  status that moves a key nothing waited on, or a re-stat that came back the
   *  same, costs nothing. */
  private onLinkStatus(abs: string, status: PathStatus): void {
    const deps = this.link?.deps;
    if (!deps) return;
    const found = status === "file" || status === "dir";
    if (deps.pending.has(abs) || deps.refining.has(abs) || (found && deps.negatives.has(abs)) ||
        (!found && deps.linked.has(abs))) {
      this.queueInvalidate();
    }
  }

  /** Coalesced to one microtask: a cache settles many keys in the same turn. */
  private queueInvalidate(): void {
    const link = this.link;
    if (!link || link.invalidateQueued || this.isDisposed || this.failed) return;
    link.invalidateQueued = true;
    queueMicrotask(() => {
      link.invalidateQueued = false;
      this.invalidate();
    });
  }

  private invalidate(): void {
    if (this.isDisposed || this.failed) return;
    this._revision++;
    for (const l of this.listeners) this.guarded(l);
  }

  /** One timer per source, debounced: a lookup that came back "missing" is the
   *  only thing a static screen can still be waiting on, and nothing but this
   *  would ever ask the filesystem again. */
  private armRecheck(link: LinkState): void {
    link.recheck?.cancel();
    link.recheck = link.timer(() => {
      link.recheck = undefined;
      const deps = link.deps;
      if (this.isDisposed || this.failed || !deps) return;
      if (this._revision !== link.depsRevision || link.recheckedRevision === link.depsRevision) return;
      link.recheckedRevision = link.depsRevision;
      for (const key of deps.negatives) link.cache.request(key);
    }, NEGATIVE_RECHECK_MS);
  }

  /**
   * NEVER throws, at any depth, for any input — the base class's contract, and
   * it binds harder here than there: the only caller is the PTY data callback on
   * a bare `setTimeout` stack, so an exception is an `uncaughtException` and this
   * process answers one by shutting down every project, PTY and agent on the
   * machine. A verbose build log must not be able to do that.
   *
   * A backlog is DROPPED, never latched. What it describes is a burst the parser
   * has not reached yet rather than damage — xterm will parse everything already
   * queued — so the cost of refusing a chunk is a screen that is wrong until the
   * guest next repaints, which for a TUI is immediate and for a scrolling log is
   * one screenful. Latching instead spent the whole run's display on it, and a
   * viewer cannot recover a run: `TerminalManager` has no path that rebuilds a
   * source under a PTY that never stopped.
   */
  override feed(data: string): void {
    if (this.isDisposed || this.failed) return;
    if (this.pendingChars + data.length > MAX_PENDING_CHARS) {
      if (!this.dropping) {
        this.dropping = true;
        // The archive is fed from rows this chunk will now never scroll, so
        // history stops describing the buffer at exactly this point.
        this.noteHistoryGap();
        log.warn("VT backlog %d + %d chars past %d, dropping until it drains",
          this.pendingChars, data.length, MAX_PENDING_CHARS);
      }
      this.droppedChars += data.length;
      return;
    }
    if (this.dropping) {
      this.dropping = false;
      log.warn("VT backlog drained, dropped %d chars; screen is stale until the guest repaints",
        this.droppedChars);
      this.droppedChars = 0;
      // A drop that landed inside an OSC/DCS/APC string leaves the parser
      // swallowing everything after it as that string's payload — a frozen
      // screen rather than a lossy one. ST closes it, and is ignored in ground
      // state, so it costs nothing when the drop fell on a clean boundary.
      this.enqueue("\x1b\\");
    }
    this.enqueue(data);
  }

  /** Holds a chunk for the next flush. The PTY read loop hands over a whole
   *  burst without yielding, so coalescing here is what turns one 4 KB read per
   *  `term.write()` into one write per `MAX_WRITE_CHARS`. */
  private enqueue(data: string): void {
    this.batch.push(data);
    this.pendingChars += data.length;
    if (this.flushQueued) return;
    this.flushQueued = true;
    // A microtask, not a timer: it runs the moment that read loop finally
    // awaits, which is the earliest point at which xterm could parse anything.
    queueMicrotask(() => this.flushBatch());
  }

  /** Hands everything batched to xterm. Safe to call with nothing queued, which
   *  is what lets every barrier below call it unconditionally. */
  private flushBatch(): void {
    this.flushQueued = false;
    if (!this.batch.length) return;
    const queued = this.batch.splice(0);
    if (this.isDisposed || this.failed) {
      for (const chunk of queued) this.pendingChars -= chunk.length;
      return;
    }
    // Grouped as it goes, never joined whole and then sliced: at the ceiling one
    // join holds a SECOND full-size copy of the backlog alive for the length of
    // this loop, and MAX_PENDING_CHARS is sized on the assumption of one. Only
    // the chunk that straddles a bound is cut, which in production is none of
    // them — a PTY read is far smaller than MAX_WRITE_CHARS.
    let group: string[] = [];
    let size = 0;
    for (let i = 0; i < queued.length; i++) {
      const chunk = queued[i]!;
      // Dropped from `queued` as it is consumed, or the array pins every
      // original for the length of the loop while the joins pile up beside
      // them — the second full-size copy the grouping above exists to avoid.
      queued[i] = "";
      let at = 0;
      while (at < chunk.length) {
        const take = Math.min(MAX_WRITE_CHARS - size, chunk.length - at);
        group.push(take === chunk.length ? chunk : chunk.slice(at, at + take));
        size += take;
        at += take;
        if (size === MAX_WRITE_CHARS) {
          this.write(group.join(""));
          group = [];
          size = 0;
        }
      }
    }
    if (size) this.write(group.join(""));
  }

  private write(chunk: string): void {
    this.unparsed.push(chunk);
    try {
      if (this.detachQueries) this.oscTerminators.feed(chunk);
      this.term.write(chunk, () => {
        if (this.failed) return;
        // FIFO: xterm parses writes in order and fires their callbacks in the
        // same order, so the head is always the chunk this callback is for.
        this.unparsed.shift();
        this.pendingChars -= chunk.length;
        this._revision++;
        this.atBoundary = true;
        try {
          this.guarded(() => this.history?.flush());
          for (const listener of this.listeners) this.guarded(listener);
        } finally { this.atBoundary = false; }
      });
    } catch (error) {
      // `write()` throws before it queues anything, so the chunk this call just
      // pushed is still the last one. Its only throw is xterm's own watermark,
      // which MAX_PENDING_CHARS keeps out of reach — arriving here means that
      // bound moved, and a discarded chunk is still not worth the run's display.
      this.unparsed.pop();
      this.pendingChars -= chunk.length;
      this.noteHistoryGap();
      log.warn("VT write dropped, screen is stale until the guest repaints: %s", error);
    }
  }

  /** The base barrier is an empty write, which xterm would answer ahead of
   *  anything still sitting in the batch. */
  override settle(): Promise<void> {
    this.flushBatch();
    return super.settle();
  }

  override get hasPendingTail(): boolean {
    return this.batch.length > 0 || super.hasPendingTail;
  }

  override pendingTail(): string {
    return super.pendingTail() + this.batch.join("");
  }

  override resize(cols: number, rows: number): void {
    // Ahead of the barrier below, or the resize lands first and the batch is
    // then parsed against a grid it was never written for.
    this.flushBatch();
    this.term.write("", () => {
      if (this.isDisposed || this.failed) return;
      try {
        if (!this.history) {
          super.resize(cols, rows);
        } else {
          // The archive owns rows above the viewport. Keeping them in xterm
          // during resize would rejoin them with live rows or pull them back
          // into the viewport, violating the frame's history boundary.
          this.adapter.detachArchivedRows();
          const oldCols = this.term.cols;
          const oldRows = this.term.rows;
          const targetRows = Math.min(500, Math.max(1, Math.floor(rows) || 1));
          const targetCols = Math.min(1000, Math.max(2, Math.floor(cols) || 2));
          const buffer = this.term.buffer.normal;
          const shed = Math.max(0, oldRows - targetRows);
          const popped = Math.min(shed, oldRows - 1 - buffer.cursorY);
          const crossed = shed - popped;
          // A row shrink may recycle the whole ring in one call. Capture the
          // crossing rows at their original width before any mutation.
          for (let i = 0; i < crossed; i++) {
            const row = this.adapter.normalRow(i);
            if (row) this.archive(row);
          }
          for (let i = oldRows - popped; i < oldRows; i++) {
            if (buffer.getLine(i)?.translateToString(true)) this.discarded++;
          }
          super.resize(oldCols, targetRows);
          this.adapter.detachArchivedRows();
          if (targetCols !== oldCols) {
            const scrollback = this.term.options.scrollback!;
            this.term.options.scrollback =
                Math.ceil(oldCols * targetRows / targetCols) + targetRows;
            try {
              super.resize(targetCols, targetRows);
              for (let i = 0; i < this.term.buffer.normal.baseY; i++) {
                const row = this.adapter.normalRow(i);
                if (row) this.archive(row);
              }
              this.adapter.detachArchivedRows();
            } finally {
              this.term.options.scrollback = scrollback;
            }
          }
        }
        // After every branch, and after the archive work that only the second
        // one does: xterm leaves the alternate screen's rows at their old
        // width, and a frame serialized from them describes a grid nobody has.
        this.adapter.conformAlternateRows();
      } catch (error) {
        this.fail(error instanceof Error ? error : new Error(String(error)));
      }
      this._revision++;
      for (const listener of this.listeners) this.guarded(listener);
    });
  }

  get revision(): number { return this._revision; }
  /** True when the LAST capture was skipped for exceeding the display budget.
   *  Recoverable by construction — the sender reports it and keeps the
   *  attachment, and the next screen clears it. Never a latch: a display-sized
   *  problem must not destroy the authoritative VT or the row archive. */
  get oversize(): boolean { return this._oversize; }
  /** Latched for the lifetime of its PTY run, and raised by `capture()` so the
   *  hub turns it into one attachment's `DISPLAY_FAILED`. Only a resize can
   *  reach it: a resize rewrites the grid and the archive's geometry together,
   *  so a throw inside one leaves neither describing the guest. Backlog does
   *  NOT — see `feed()`. */
  get failure(): Error | undefined { return this.failed; }
  get historyStatus(): TerminalHistoryStatus {
    return {
      degraded: this.gaps > 0 || this.rewraps > 0,
      gaps: this.gaps, rewraps: this.rewraps, discarded: this.discarded,
    };
  }

  /** Records rows the archive will never hold, so the rows on either side of
   *  the loss do not join up. The count is unknowable — a loss is measured in
   *  characters, never in rows — so this takes none.
   *
   *  Only one of the three callers reaches here in practice: a chunk `feed()`
   *  dropped for backlog, which never reaches the parser and so scrolls nothing
   *  into the archive. The other two guard bounds that do not move today —
   *  xterm's discard watermark sits above MAX_PENDING_CHARS, and a real
   *  `TerminalRunHistory` disables itself rather than throwing out of `append`,
   *  which the app reads as `status: "disabled"` and not as a gap.
   *
   *  Told to the archive handle as well as counted here, and that is the half
   *  that reaches the app: `boundary()` restates it on every frame and every
   *  history page, where `historyStatus` below is local to this process. Row
   *  ids stay contiguous across a hole, so without it nothing a reader can
   *  measure says the output it is looking at is not continuous. */
  noteHistoryGap(): void {
    this.gaps++;
    this.history?.noteGap();
  }

  onParsed(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  }

  onBell(listener: () => void): () => void {
    const subscription = this.term.onBell(() => this.guarded(listener));
    return () => subscription.dispose();
  }

  /**
   * Installs the parser-boundary query responder (`terminal-frames/queries.ts`)
   * for everything except OSC 10/11/12 — see that file's header for why those
   * three stay with the byte-level responder instead.
   *
   * `reply` MUST be `TerminalSession.write` (the session's `PtySubmitQueue`),
   * NEVER a raw `pty.write`. The queue defers a submitted line's trailing CR
   * onto its own read so nothing can land between the two; a reply written
   * straight to the pty is the one thing that still could, landing inside an
   * injected line the instant after it went out and before its CR follows.
   *
   * Query protocols are FIFO, but this class only orders ITSELF — DA1, CPR,
   * DECRQM and Kitty all answer from here, in parser order. OSC 10/11/12
   * answer from the session's own byte-level responder instead (see
   * `queries.ts`'s header for why), which `TerminalSession` holds and
   * releases through `flushCapabilityReplies` at this class's own `onParsed`
   * boundary — installed by the caller, not by this class — specifically so
   * an OSC reply cannot leave ahead of a same-batch reply from here. Whether
   * that is exact byte-for-byte order against a query that arrived BEFORE the
   * OSC one in the same raw chunk is the caller's contract, not this one's.
   */
  answerQueries(reply: (data: string) => void, colors: TerminalQueryColors): void {
    this.detachQueries?.();
    this.detachQueries = installTerminalQueries(this.term, reply,
      () => this.keyboard[this.term.buffer.active.type].at(-1)!,
      () => this.adapter.margins().top, colors, (code) => this.oscTerminators.take(code));
  }

  /** `final` marks the capture published as the run's final frame, and
   *  waives only the synchronized-output hold. The wait exists so a half-drawn
   *  frame block is never published while its author is still drawing; a guest
   *  that has exited inside one is never going to close it, so holding out
   *  costs the viewer the screen the program died holding and buys nothing.
   *  The frame still reports `syncTimedOut` even though nothing timed out: what
   *  the flag tells a viewer is "published from inside an open block, so it may
   *  be half-drawn", and that is exactly true of a waived hold. A viewer
   *  distinguishing the two would be reading the elapsed timer, which no
   *  consumer wants and no frame carries. */
  capture(now: number, opts: { final?: boolean; detectedLinks?: boolean } = {}): TerminalScreenFrame | null {
    if (this.failed) throw this.failed;
    if (this.isDisposed || (this.hasPendingTail && !this.atBoundary)) return null;
    const syncing = this.term.modes.synchronizedOutputMode;
    if (syncing) this.syncSince ??= now;
    else this.syncSince = undefined;
    const syncTimedOut = syncing && (opts.final === true || now - this.syncSince! >= SYNC_OUTPUT_TIMEOUT_MS);
    if (syncing && !syncTimedOut) return null;

    const buffer = this.term.buffer.active;
    // Ghostty's saved-cursor restore can shift after overpainting wide linked
    // cells. Display frames end at an absolute grid coordinate and full margins;
    // the next frame is independent, so no guest-relative cursor state is needed.
    const cursor = `\x1b[?6l\x1b[r\x1b[${buffer.cursorY + 1};${Math.min(buffer.cursorX, this.term.cols - 1) + 1}H`;
    // Ghostty can retain blank-cell backgrounds when reusing the alternate
    // buffer. The serializer assumes entry clears it; make that clear explicit
    // under default attributes before replaying the alternate buffer's cells.
    const screen = this.serializeNow().replace("\x1b[?1049h\x1b[H", "\x1b[?1049h\x1b[0m\x1b[2J\x1b[H");
    // A source's unfinished OSC 8 span must not leak across independent frames.
    const head = "\x1b[?2026h\x1b[?1049l\x1b[3J" + OSC_CLOSE + screen;
    const detected = opts.detectedLinks !== false;
    const overlay = this.linkOverlay(detected);
    const tail = this.modes.supplementalPrelude()
      + cursor + `\x1b[=${this.keyboard[buffer.type].at(-1)};1u\x1b[?2026l`;
    let ansi = head + overlay + tail;
    // Measured as the transport will carry it, against the cap derived from the
    // same budget the sender checks — so a frame this accepts cannot be refused
    // downstream. A skip, never a latch: an oversize screen is a property of
    // this frame, and the source stays usable for every frame after it.
    const budget = this.link?.opts.frameBudgetBytes ?? TERMINAL_FRAME_MAX_ANSI_BYTES;
    this._oversize = encodedJsonBytes(ansi) > budget;
    if (this._oversize && this.link && detected) {
      // Detected links are decoration that can push a near-cap screen over the
      // limit; the program's own links alone are what the screen needs.
      ansi = head + this.linkOverlay(false) + tail;
      this._oversize = encodedJsonBytes(ansi) > budget;
    }
    if (this._oversize) return null;
    return {
      version: TERMINAL_PROTOCOL_VERSION, revision: this._revision, cols: this.term.cols, rows: this.term.rows,
      ansi, syncTimedOut,
      history: this.history?.boundary()
        // No archive at all, so there is no epoch for a hole to be in: a run
        // that records nothing is reported by `status`, and claiming a gap on
        // top of it would name rows that were never going to exist.
        ?? { epoch: 0, firstRowId: 0, nextRowId: 0, status: "disabled", gapped: false },
    };
  }

  /**
   * A write callback runs INSIDE xterm's parse loop, which retires the chunk
   * only after the callback returns: a throw that escapes one leaves the write
   * buffer permanently undrained, so the terminal parses nothing for the rest
   * of the process and every capture is a frozen screen with no error on it.
   * Each viewer is guarded on its own, so one failing does not silence the rest.
   */
  private guarded(work: () => void): void {
    try { work(); } catch { /* a viewer's failure is not the terminal's */ }
  }

  /** A flood still dropping when its run ends never reaches `feed()` again, so
   *  without this the opening line stands alone and the log never says how much
   *  was lost — the shape that reads as a drop that never stopped. */
  private closeDropEpisode(): void {
    if (!this.dropping) return;
    log.warn("VT backlog still dropping when the run ended, dropped %d chars", this.droppedChars);
    this.dropping = false;
    this.droppedChars = 0;
  }

  private fail(error: Error): void {
    if (this.failed) return;
    this.closeDropEpisode();
    this.failed = error;
    this._revision++;
    this.unparsed.length = 0;
    this.batch.length = 0;
    this.pendingChars = 0;
    for (const listener of this.listeners) this.guarded(listener);
  }

  private archive(row: Omit<TerminalHistoryRow, "rowId">): void {
    // Defence in depth, not the store-failure path: a real handle swallows its
    // own failures and disables itself, which surfaces as `status`, never as a
    // gap. This catch is for a `TerminalRunHistory` shim that does not.
    try { this.history?.append(row); } catch { this.noteHistoryGap(); }
  }


  /** A cleared history starts a fresh epoch, which is the app's discontinuity
   *  signal — so the gaps and rewraps describing the old one go with it. */
  private clearHistory(): void {
    // Both callers are parser handlers, and a store that has lost its disk
    // reports it through the failure callback its owner supplied — which runs
    // from in here. The counters below are this source's own and reset either
    // way: a history that could not be cleared is still not describing this
    // epoch.
    this.guarded(() => this.history?.clear());
    this.gaps = 0;
    this.rewraps = 0;
    this.discarded = 0;
  }

  /**
   * The links found in plain text, as one uri per viewport cell. Runs inside
   * `capture()`, so it only ever peeks the stat cache: a stat that is not
   * answered yet is requested and the screen is re-framed when it lands.
   *
   * Never throws. A throw out of `capture()` latches the whole run as
   * `DISPLAY_FAILED`, which is far worse than a screen without its decoration.
   */
  private detectLinkUris(): Array<Array<string | undefined> | undefined> | undefined {
    const link = this.link;
    if (!link) return undefined;
    const buffer = this.term.buffer.active;
    if (buffer.type !== "normal" && !link.opts.alternateScreen) {
      link.deps = undefined;
      return undefined;
    }
    try {
      const { cols, rows } = this.term;
      // The alternate screen has no scrollback to read above its viewport.
      let first = buffer.type === "normal" ? Math.max(0, buffer.baseY - LINK_CONTEXT_ROWS) : buffer.baseY;
      if (buffer.type === "normal") {
        while (first > 0 && buffer.baseY - first < LINK_CONTEXT_ROWS + LINK_RUN_ROWS && buffer.getLine(first)?.isWrapped === true) {
          first--;
        }
      }
      const context = buffer.baseY - first;
      const detectRows: DetectRow[] = [];
      for (let index = first; index < buffer.baseY + rows; index++) {
        const line = buffer.getLine(index);
        detectRows.push(line ? this.adapter.detectRow(line, cols, buffer.getLine(index + 1)) : blankDetectRow(cols));
      }
      const memoScan = (text: string): ReturnType<typeof scanLine> => {
        if (text.length > SCAN_MEMO_MAX_KEY) return scanLine(text, link.platform);
        let scanned = link.scanMemo.get(text);
        if (scanned) {
          // Re-inserted so the oldest entry is the least recently used one.
          link.scanMemo.delete(text);
        } else {
          scanned = scanLine(text, link.platform);
          link.scanMemoChars += text.length;
        }
        link.scanMemo.set(text, scanned);
        while (link.scanMemo.size > SCAN_MEMO_MAX || link.scanMemoChars > SCAN_MEMO_MAX_CHARS) {
          const oldest = link.scanMemo.keys().next().value!;
          link.scanMemo.delete(oldest);
          link.scanMemoChars -= oldest.length;
        }
        return scanned;
      };
      const result = detectLinks(detectRows, context, normalizeBases(this.linkBases(), link.platform), link.cache,
        LIVE_LINK_BUDGET, memoScan, link.platform);
      link.deps = {
        pending: result.pending, negatives: result.negatives, linked: result.linked, refining: result.refining,
        starved: result.starved,
      };
      link.depsRevision = this._revision;
      const uriAt: Array<Array<string | undefined> | undefined> = [];
      for (const span of result.spans) {
        const row = span.row - context;
        if (row < 0 || row >= rows) continue;
        const cells = (uriAt[row] ??= []);
        for (let col = span.startCol; col < span.endCol && col < cols; col++) cells[col] = span.uri;
      }
      if (result.negatives.size > 0) this.armRecheck(link);
      return uriAt;
    } catch {
      link.deps = undefined;
      return undefined;
    }
  }

  private linkOverlay(detected: boolean): string {
    const buffer = this.term.buffer.active;
    const parts: string[] = [];
    const detectedAt = detected ? this.detectLinkUris() : undefined;
    for (let row = 0; row < this.term.rows; row++) {
      const found = detectedAt?.[row];
      // With no OSC 8 ever parsed, a row holding no detected link has nothing
      // to repaint.
      if (!found && !this.sawHyperlink) continue;
      const line = buffer.getLine(buffer.baseY + row);
      if (!line) continue;
      let lastId = "";
      let lastStyle = "";
      for (let col = 0; col < this.term.cols; col++) {
        const cell = this.adapter.cellAt(line, col);
        // A detected link never covers a cell that already has the program's
        // own link: the detector drops such a mention.
        const id = found?.[col] ?? (cell && this.sawHyperlink ? this.adapter.link(cell) ?? "" : "");
        if (!cell || cell.getWidth() === 0) continue;
        if (!id) { if (lastId) parts.push(OSC_CLOSE); lastId = ""; lastStyle = ""; continue; }
        // `adapter.link()` has already rejected control characters and anything
        // past 8192 bytes, so an id that arrives here is safe to emit verbatim.
        if (lastId !== id) parts.push(`\x1b[${row + 1};${col + 1}H\x1b]8;;${id}\x1b\\`);
        const style = this.adapter.style(cell);
        if (style !== lastStyle) parts.push(style);
        parts.push(cell.getChars() || " ");
        lastId = id;
        lastStyle = style;
      }
      if (lastId) parts.push(OSC_CLOSE);
    }
    if (!parts.length) return "";
    // Overpainting carries native OSC 8 metadata into Ghostty. Save/restore
    // protects SGR; insert/origin/wrap would change placement. The final frame
    // places the cursor explicitly after this overlay.
    return "\x1b7\x1b[4l\x1b[?6l\x1b[?7l" + parts.join("") + OSC_CLOSE + "\x1b8"
      + `\x1b[4${this.term.modes.insertMode ? "h" : "l"}`
      + `\x1b[?7${this.term.modes.wraparoundMode ? "h" : "l"}`;
  }

  override dispose(): void {
    this.closeDropEpisode();
    this.detachQueries?.();
    this.detachArchive?.();
    if (this.link) {
      for (const detach of this.link.detach) detach();
      this.link.detach.length = 0;
      this.link.recheck?.cancel();
      this.link.recheck = undefined;
    }
    this.listeners.clear();
    // TerminalManager disposes every screen in one bare loop, so a throw here
    // would abandon it and leak every xterm instance behind this one.
    this.guarded(() => this.history?.flush());
    super.dispose();
  }

  visibleLines(): string[] {
    const buffer = this.term.buffer.active;
    return Array.from({ length: this.term.rows }, (_, row) =>
      buffer.getLine(buffer.baseY + row)?.translateToString(true) ?? "");
  }

  normalHistoryLines(): string[] {
    const buffer = this.term.buffer.normal;
    return Array.from({ length: buffer.length }, (_, row) => buffer.getLine(row)?.translateToString(true) ?? "");
  }

  setHistoryLimit(lines: number): void { this.term.options.scrollback = lines; }
}
