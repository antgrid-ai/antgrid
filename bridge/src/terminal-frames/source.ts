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
      this.term.parser.registerCsiHandler({ final: "J" }, (params) => {
        if (params[0] === 3 && this.term.buffer.active.type === "normal") this.clearHistory();
        return false;
      });
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
        this.history?.flush();
        this._revision++;
        this.atBoundary = true;
        try { for (const listener of this.listeners) listener(); }
        finally { this.atBoundary = false; }
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
      const before = {
        baseY: this.term.buffer.normal.baseY,
        cols: this.term.cols,
        rows: this.term.rows,
        capped: this.term.buffer.normal.baseY >= (this.term.options.scrollback ?? 0),
      };
      super.resize(cols, rows);
      if (this.history) this.reconcileResize(before);
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
      () => this.keyboard[this.term.buffer.active.type].at(-1)!, colors);
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

  /**
   * xterm moves rows into and out of scrollback inside `Buffer.resize` without
   * ever calling `BufferService.scroll`; `onResize` fires only after the
   * mutation and `onScroll`/`onLineFeed` never fire at all. This call site is
   * the sole interception point, and the SIGNED `baseY` delta is the exact
   * number of rows that moved.
   */
  private reconcileResize(before: { baseY: number; cols: number; rows: number; capped: boolean }): void {
    const buffer = this.term.buffer.normal;
    const delta = buffer.baseY - before.baseY;
    const rewrapped = this.term.cols !== before.cols;
    if (rewrapped) this.rewraps++;
    if (delta > 0) {
      // Read AFTER the resize: a column reflow changes the shape of the rows it
      // pushes out, so a pre-resize snapshot would archive the wrong geometry.
      for (let index = before.baseY; index < buffer.baseY; index++) {
        const row = this.adapter.normalRow(index);
        if (row) this.archive(row);
        else this.gaps++;
      }
    } else if (delta < 0 && !rewrapped) {
      this.restored = Array.from({ length: -delta }, (_, index) =>
        JSON.stringify(this.adapter.normalRow(buffer.baseY + index) ?? null));
    } else if (delta < 0) {
      // A column grow REJOINS rows already published under separate ids into one
      // wider live row. Nothing an append-only history can say puts that back.
      this.gaps += -delta;
    } else if (before.capped && this.term.rows < before.rows) {
      // baseY was already pinned at the ring's ceiling, so the trim and the
      // eviction cancel out and its delta can no longer count what left.
      this.gaps++;
    }
  }

  /** A cleared history starts a fresh epoch, which is the app's discontinuity
   *  signal — so the gaps and rewraps describing the old one go with it. */
  private clearHistory(): void {
    this.history?.clear();
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
        const uri = id;
        if (!uri || /[\x00-\x1f\x7f-\x9f]/.test(uri)) {
          if (lastId) parts.push(OSC_CLOSE);
          lastId = "";
          lastStyle = "";
          continue;
        }
        if (lastId !== id) parts.push(`\x1b[${row + 1};${col + 1}H\x1b]8;;${uri}\x1b\\`);
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
    this.history?.flush();
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
