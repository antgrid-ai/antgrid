import { Unicode11Addon } from "@xterm/addon-unicode11";
import { TerminalScreen } from "../terminal-screen";
import { TerminalModeTracker } from "../terminal-modes";
import { XtermFrameAdapter } from "./xterm-adapter";
import {
  TERMINAL_FRAME_MAX_ANSI_BYTES, TerminalScreenFrameSchema, encodedJsonBytes,
  type TerminalScreenFrame,
} from "./protocol";
import type { TerminalRunHistory } from "./history";
import { installTerminalQueries, type TerminalQueryColors } from "./queries";
export { TERMINAL_FRAME_INTERVAL_MS as FRAME_INTERVAL_MS } from "./protocol";
export const TerminalFrameSchema = TerminalScreenFrameSchema;
export type { TerminalScreenFrame };
/** @deprecated The screen PAYLOAD, not the `terminal:frame` wire message — that
 *  name belongs to bridge/src/protocol.ts. Retained only because the frozen
 *  prototype shim in ../experimental imports it; use TerminalScreenFrame. */
export type TerminalFrame = TerminalScreenFrame;

export const SYNC_OUTPUT_TIMEOUT_MS = 1000;
const MAX_PENDING_CHARS = 1_000_000;
const OSC_CLOSE = "\x1b]8;;\x1b\\";

/** Independent display frames; no raw tail is ever written to the viewer. */
export class TerminalFrameSource extends TerminalScreen {
  private readonly adapter: XtermFrameAdapter;
  private detachArchive?: () => void;
  private detachQueries?: () => void;
  private atBoundary = false;
  private readonly listeners = new Set<() => void>();
  private readonly modes = new TerminalModeTracker();
  private pending = 0;
  private failed: Error | undefined;
  private _revision = 0;
  private _oversize = false;
  private syncSince: number | undefined;
  private readonly keyboard = { normal: [0], alternate: [0] };

  constructor(cols: number, rows: number, private readonly history?: TerminalRunHistory) {
    super(cols, rows);
    this.term.loadAddon(new Unicode11Addon());
    this.term.unicode.activeVersion = "11";
    this.adapter = new XtermFrameAdapter(this.term);
    if (history) {
      this.detachArchive = this.adapter.onArchiveRow((row) => history.append(row));
      this.term.parser.registerCsiHandler({ final: "J" }, (params) => {
        if (params[0] === 3 && this.term.buffer.active.type === "normal") history.clear();
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
      this.history?.clear();
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

  override feed(data: string): void {
    if (this.isDisposed) throw new Error("Terminal frame source is disposed");
    if (this.failed) throw this.failed;
    if (this.pending + data.length > MAX_PENDING_CHARS) {
      this.failed = new Error("Terminal frame parser backlog exceeded; display unavailable");
      throw this.failed;
    }
    this.pending += data.length;
    try {
      this.term.write(data, () => {
        this.pending -= data.length;
        this.history?.flush();
        this._revision++;
        this.atBoundary = true;
        try { for (const listener of this.listeners) listener(); }
        finally { this.atBoundary = false; }
      });
    } catch (error) {
      this.pending -= data.length;
      this.failed = error instanceof Error ? error : new Error(String(error));
      throw this.failed;
    }
  }

  override resize(cols: number, rows: number): void {
    // A resize belongs BETWEEN writes, including writes not parsed yet.
    this.term.write("", () => {
      if (this.isDisposed) return;
      super.resize(cols, rows);
      this._revision++;
    });
  }

  override get hasPendingTail(): boolean { return this.pending !== 0; }
  get revision(): number { return this._revision; }
  /** True when the LAST capture was skipped for exceeding the display budget.
   *  Recoverable by construction — the sender reports it and keeps the
   *  attachment, and the next screen clears it. */
  get oversize(): boolean { return this._oversize; }

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

