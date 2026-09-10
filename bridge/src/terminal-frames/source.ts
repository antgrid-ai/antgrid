import { Unicode11Addon } from "@xterm/addon-unicode11";
import { TerminalScreen } from "../terminal-screen";
import { TerminalModeTracker } from "../terminal-modes";
import { XtermFrameAdapter, type TerminalArchiveSink } from "./xterm-adapter";
import {
  TERMINAL_FRAME_MAX_ANSI_BYTES, TerminalScreenFrameSchema, encodedJsonBytes,
  type TerminalHistoryRow, type TerminalScreenFrame,
} from "./protocol";
import type { TerminalRunHistory } from "./history";
import { installTerminalQueries, type TerminalQueryColors } from "./queries";
export { TERMINAL_FRAME_INTERVAL_MS as FRAME_INTERVAL_MS } from "./protocol";
export const TerminalFrameSchema = TerminalScreenFrameSchema;
export type { TerminalScreenFrame };
/** @deprecated NOT the `terminal:frame` wire message — that name is registered
 *  in bridge/src/protocol.ts, and a file importing both gets a silent collision.
 *  Retained only because the frozen prototype shim in ../experimental imports
 *  it; every new reader wants TerminalScreenFrame. */
export type TerminalFrame = TerminalScreenFrame;

export const SYNC_OUTPUT_TIMEOUT_MS = 1000;
const MAX_PENDING_CHARS = 1_000_000;
const OSC_CLOSE = "\x1b]8;;\x1b\\";

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

/** The pre-resize state a row shrink destroys before anything can read it. */
interface ResizeSnapshot {
  baseY: number;
  cols: number;
  rows: number;
  /** Normal-buffer cursor row. It decides how many rows a shrink pops off the
   *  bottom rather than scrolling into scrollback. */
  cursorY: number;
  /** Blank rows at the bottom of the normal buffer, which a shrink may take
   *  without losing anything. */
  blankTail: number;
}

/** Independent display frames; no raw tail is ever written to the viewer. */
export class TerminalFrameSource extends TerminalScreen {
  private readonly adapter: XtermFrameAdapter;
  private detachArchive?: () => void;
  private detachQueries?: () => void;
  private atBoundary = false;
  private readonly listeners = new Set<() => void>();
  private readonly modes = new TerminalModeTracker();
  private pendingChars = 0;
  private failed: Error | undefined;
  private _revision = 0;
  private _oversize = false;
  private syncSince: number | undefined;
  private readonly keyboard = { normal: [0], alternate: [0] };
  /** Rows a grow-resize pulled back OUT of scrollback, encoded, in the order
   *  they will leave again. */
  private restored: string[] = [];
  private gaps = 0;
  private rewraps = 0;
  private discarded = 0;

  constructor(cols: number, rows: number, private readonly history?: TerminalRunHistory) {
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
  }

  /**
   * NEVER throws, at any depth, for any input — the base class's contract, and
   * it binds harder here than there: the only caller is the PTY data callback on
   * a bare `setTimeout` stack, so an exception is an `uncaughtException` and this
   * process answers one by shutting down every project, PTY and agent on the
   * machine. A verbose build log must not be able to do that.
   *
   * A parser this cannot keep fed is a DISPLAY failure, not a process failure.
   * It latches here and is raised at `capture()`, where a viewer owns it and the
   * hub can turn it into one attachment's `DISPLAY_FAILED` instead of silently
   * shipping frames of a screen that no longer matches the guest.
   */
  override feed(data: string): void {
    if (this.isDisposed || this.failed) return;
    if (this.pendingChars + data.length > MAX_PENDING_CHARS) {
      this.fail(new Error("Terminal frame parser backlog exceeded; display unavailable"));
      return;
    }
    this.unparsed.push(data);
    this.pendingChars += data.length;
    try {
      this.term.write(data, () => {
        if (this.failed) return;
        // FIFO: xterm parses writes in order and fires their callbacks in the
        // same order, so the head is always the chunk this callback is for.
        this.unparsed.shift();
        this.pendingChars -= data.length;
        this._revision++;
        this.atBoundary = true;
        try {
          this.guarded(() => this.history?.flush());
          for (const listener of this.listeners) this.guarded(listener);
        } finally { this.atBoundary = false; }
      });
    } catch (error) {
      // `write()` throws before it queues anything, so the chunk this call just
      // pushed is still the last one.
      this.unparsed.pop();
      this.pendingChars -= data.length;
      this.fail(error instanceof Error ? error : new Error(String(error)));
    }
  }

  override resize(cols: number, rows: number): void {
    // A resize belongs BETWEEN writes, including writes not parsed yet.
    this.term.write("", () => {
      if (this.isDisposed || this.failed) return;
      try {
        const before = this.history ? this.resizeSnapshot() : undefined;
        super.resize(cols, rows);
        if (before) this.reconcileResize(before);
      } catch {
        // The one archive path that does not run under the adapter's own guard:
        // reconciliation calls `history.append()` directly, and a store that has
        // begun failing raises from inside this callback. Rows were evicted
        // either way and their count is no longer recoverable, so this degrades
        // history rather than reporting a clean geometry change.
        this.gaps++;
      }
      this._revision++;
    });
  }

  get revision(): number { return this._revision; }
  /** True when the LAST capture was skipped for exceeding the display budget.
   *  Recoverable by construction — the sender reports it and keeps the
   *  attachment, and the next screen clears it. Never a latch: a display-sized
   *  problem must not destroy the authoritative VT or the row archive. */
  get oversize(): boolean { return this._oversize; }
  get historyStatus(): TerminalHistoryStatus {
    return {
      degraded: this.gaps > 0 || this.rewraps > 0,
      gaps: this.gaps, rewraps: this.rewraps, discarded: this.discarded,
    };
  }

  onParsed(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  }

  answerQueries(reply: (data: string) => void, colors: TerminalQueryColors): void {
    this.detachQueries?.();
    this.detachQueries = installTerminalQueries(this.term, reply,
      () => this.keyboard[this.term.buffer.active.type].at(-1)!,
      () => this.adapter.margins().top, colors);
  }

  capture(now: number): TerminalScreenFrame | null {
    if (this.failed) throw this.failed;
    if (this.isDisposed || (this.hasPendingTail && !this.atBoundary)) return null;
    const syncing = this.term.modes.synchronizedOutputMode;
    if (syncing) this.syncSince ??= now;
    else this.syncSince = undefined;
    const syncTimedOut = syncing && now - this.syncSince! >= SYNC_OUTPUT_TIMEOUT_MS;
    if (syncing && !syncTimedOut) return null;

    const buffer = this.term.buffer.active;
    // Ghostty's saved-cursor restore can shift after overpainting wide linked
    // cells. Display frames end at an absolute grid coordinate and full margins;
    // the next frame is independent, so no guest-relative cursor state is needed.
    const cursor = `\x1b[?6l\x1b[r\x1b[${buffer.cursorY + 1};${Math.min(buffer.cursorX, this.term.cols - 1) + 1}H`;
    // A source's unfinished OSC 8 span must not leak across independent frames.
    const ansi = "\x1b[?2026h\x1b[?1049l\x1b[3J" + OSC_CLOSE + this.serializeNow()
      + this.linkOverlay() + this.modes.supplementalPrelude()
      + cursor + `\x1b[=${this.keyboard[buffer.type].at(-1)};1u\x1b[?2026l`;
    // Measured as the transport will carry it, against the cap derived from the
    // same budget the sender checks — so a frame this accepts cannot be refused
    // downstream. A skip, never a latch: an oversize screen is a property of
    // this frame, and the source stays usable for every frame after it.
    this._oversize = encodedJsonBytes(ansi) > TERMINAL_FRAME_MAX_ANSI_BYTES;
    if (this._oversize) return null;
    return {
      version: 1, revision: this._revision, cols: this.term.cols, rows: this.term.rows,
      ansi, syncTimedOut,
      history: this.history?.boundary() ?? { epoch: 0, firstRowId: 0, nextRowId: 0, status: "disabled" },
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

  private fail(error: Error): void {
    if (this.failed) return;
    this.failed = error;
    this.unparsed.length = 0;
    this.pendingChars = 0;
    this.restored = [];
  }

  /**
   * A grow-resize un-scrolls rows back into the viewport, and without this they
   * are archived a SECOND time under fresh ids when they leave again. They come
   * back out in the same order, so the repeat is matched by content and dropped;
   * a row the guest overwrote first will not match, and is archived normally.
   */
  private archive(row: Omit<TerminalHistoryRow, "rowId">): void {
    if (this.restored.length) {
      if (this.restored[0] === JSON.stringify(row)) { this.restored.shift(); return; }
      this.restored = [];
    }
    this.history?.append(row);
  }

  /** Read BEFORE the resize: everything it describes is what the resize is
   *  about to destroy, and afterwards neither the count nor the content of what
   *  xterm took is recoverable. */
  private resizeSnapshot(): ResizeSnapshot {
    const buffer = this.term.buffer.normal;
    let blankTail = 0;
    while (blankTail < this.term.rows
      && !buffer.getLine(buffer.length - 1 - blankTail)?.translateToString(true)) blankTail++;
    return {
      baseY: buffer.baseY, cols: this.term.cols, rows: this.term.rows,
      cursorY: buffer.cursorY, blankTail,
    };
  }

  /**
   * xterm moves rows into and out of scrollback inside `Buffer.resize` without
   * ever calling `BufferService.scroll`; `onResize` fires only after the
   * mutation and `onScroll`/`onLineFeed` never fire at all. This call site is
   * the sole interception point.
   *
   * A row shrink is the family `baseY` alone cannot describe. xterm sheds one
   * row per lost line, and each is either POPPED off the bottom — which it does
   * for as long as anything sits below the cursor, leaving `baseY` untouched —
   * or scrolled off the top; the cursor's row at the moment of the resize fixes
   * the split. Of the rows that went up, only the ones the emulator's ring still
   * holds can be read back: a ring already at its ceiling drops the rest inside
   * the same call, and those are the hole. Every other family — a grow pulling
   * rows back down, a reflow redistributing them — moves through `baseY` alone.
   */
  private reconcileResize(before: ResizeSnapshot): void {
    const buffer = this.term.buffer.normal;
    const rewrapped = this.term.cols !== before.cols;
    if (rewrapped) this.rewraps++;
    const shed = before.rows - this.term.rows;
    const popped = shed > 0 ? Math.max(0, Math.min(shed, before.rows - 1 - before.cursorY)) : 0;
    // The blank padding under a cursor parked mid-screen is what a shrink is
    // for; only rows that held something are a loss worth reporting.
    this.discarded += Math.max(0, popped - before.blankTail);
    const crossed = shed > 0 ? shed - popped : buffer.baseY - before.baseY;
    if (crossed > 0) {
      const readable = Math.min(crossed, buffer.baseY);
      // Read AFTER the resize: a column reflow changes the shape of the rows it
      // pushes out, so a pre-resize snapshot would archive the wrong geometry.
      for (let index = buffer.baseY - readable; index < buffer.baseY; index++) {
        const row = this.adapter.normalRow(index);
        if (row) this.archive(row);
        else this.gaps++;
      }
      this.gaps += crossed - readable;
    } else if (crossed < 0 && !rewrapped) {
      this.restored = Array.from({ length: -crossed }, (_, index) =>
        JSON.stringify(this.adapter.normalRow(buffer.baseY + index) ?? null));
    } else if (crossed < 0) {
      // A column grow REJOINS rows already published under separate ids into one
      // wider live row. Nothing an append-only history can say puts that back.
      this.gaps += -crossed;
    }
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
    this.restored = [];
    this.gaps = 0;
    this.rewraps = 0;
    this.discarded = 0;
  }

  private linkOverlay(): string {
    const buffer = this.term.buffer.active;
    const parts: string[] = [];
    for (let row = 0; row < this.term.rows; row++) {
      const line = buffer.getLine(buffer.baseY + row);
      if (!line) continue;
      let lastId = "";
      let lastStyle = "";
      for (let col = 0; col < this.term.cols; col++) {
        const cell = line.getCell(col);
        const id = cell ? this.adapter.link(cell) ?? "" : "";
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
    this.detachQueries?.();
    this.detachArchive?.();
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
