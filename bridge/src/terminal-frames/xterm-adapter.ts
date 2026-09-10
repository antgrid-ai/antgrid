import type { IBufferCell, IBufferLine, Terminal } from "@xterm/headless";
import type { TerminalHistoryRow, TerminalHistorySpan } from "./protocol";

interface ExtendedCell extends IBufferCell {
  extended: { urlId: number };
  hasExtendedAttrs(): number;
  getUnderlineStyle(): number;
  getUnderlineColor(): number;
  isUnderlineColorRGB(): boolean;
  isUnderlineColorPalette(): boolean;
}
interface BufferService {
  buffer: { scrollTop: number; scrollBottom: number };
  scroll(...args: unknown[]): void;
}
interface XtermInternals {
  _core: {
    _oscLinkService: { getLinkData(id: number): { uri: string } | undefined };
    _bufferService: BufferService;
  };
}

/**
 * Where rows leaving the normal viewport are reported. Every method is called
 * from inside xterm's own parse loop, so an implementation must not throw.
 */
export interface TerminalArchiveSink {
  /** One row leaving the viewport upward, in eviction order. */
  row(row: Omit<TerminalHistoryRow, "rowId">): void;
  /**
   * Rows that reached xterm's scrollback but could not be recorded. History is
   * now short of what the buffer holds — a divergence the source must surface,
   * because a history that is internally consistent and wrong is worse than one
   * that admits a hole.
   */
  gap(count: number): void;
  /**
   * Rows destroyed with no scrollback destination: a bottom-edge scroll
   * (`CSI L`, `CSI T`, `ESC M`), a splice below the top margin, or an alignment
   * fill. No terminal records these, so they are counted, never archived.
   */
  discarded(count: number): void;
}

/** All xterm 6 private metadata access lives here. A dependency upgrade must
 * pass the scroll-boundary and native rendering fixtures before qualification. */
export class XtermFrameAdapter {
  private readonly core: XtermInternals["_core"];
  constructor(private readonly term: Terminal) {
    this.core = (term as unknown as XtermInternals)._core;
    const buffer = this.core?._bufferService?.buffer;
    if (typeof this.core?._oscLinkService?.getLinkData !== "function" ||
        typeof this.core?._bufferService?.scroll !== "function" ||
        typeof buffer?.scrollTop !== "number" || typeof buffer?.scrollBottom !== "number") {
      throw new Error("Unsupported xterm frame adapter API");
    }
    const cell = term.buffer.active.getNullCell() as ExtendedCell;
    if (typeof cell.getUnderlineStyle !== "function" || typeof cell.getUnderlineColor !== "function" ||
        typeof cell.hasExtendedAttrs !== "function") {
      throw new Error("Unsupported xterm extended cell API");
    }
  }

  link(cell: IBufferCell): string | undefined {
    const id = (cell as ExtendedCell).extended?.urlId;
    const uri = id ? this.core._oscLinkService.getLinkData(id)?.uri : undefined;
    return uri && uri.length <= 8192 && !/[\x00-\x1f\x7f-\x9f]/.test(uri) ? uri : undefined;
  }

  style(cell: IBufferCell): string {
    const extended = cell as ExtendedCell;
    const sgr = ["0"];
    for (const [enabled, code] of [
      [cell.isBold(), "1"], [cell.isDim(), "2"], [cell.isItalic(), "3"],
      [cell.isBlink(), "5"], [cell.isInverse(), "7"], [cell.isInvisible(), "8"],
      [cell.isStrikethrough(), "9"], [cell.isOverline(), "53"],
    ] as const) if (enabled) sgr.push(code);
    if (cell.isUnderline()) sgr.push(`4:${extended.getUnderlineStyle() || 1}`);
    // xterm's underline-colour accessors fall back to the FOREGROUND when the
    // guest set no SGR 58, so asking them unconditionally writes an explicit
    // underline colour into every span of every coloured cell. Gate on the same
    // extended-attrs flag xterm's own accessors gate on.
    const tinted = extended.hasExtendedAttrs() !== 0;
    for (const [prefix, rgb, palette, color] of [
      [38, cell.isFgRGB(), cell.isFgPalette(), cell.getFgColor()],
      [48, cell.isBgRGB(), cell.isBgPalette(), cell.getBgColor()],
      [58, tinted && extended.isUnderlineColorRGB(), tinted && extended.isUnderlineColorPalette(),
        extended.getUnderlineColor()],
    ] as const) {
      if (rgb) sgr.push(`${prefix};2;${color >> 16 & 255};${color >> 8 & 255};${color & 255}`);
      else if (palette) sgr.push(`${prefix};5;${color}`);
    }
    return `\x1b[${sgr.join(";")}m`;
  }

  row(line: IBufferLine, cols: number): Omit<TerminalHistoryRow, "rowId"> {
    const spans: TerminalHistorySpan[] = [];
    for (let col = 0; col < cols; col++) {
      const cell = line.getCell(col);
      if (!cell || !cell.getWidth()) continue;
      const sgr = this.style(cell);
      const uri = this.link(cell);
      const text = cell.getChars() || " ";
      const last = spans.at(-1);
      if (last && last.sgr === sgr && last.uri === uri) {
        last.text += text;
        last.cells += cell.getWidth();
      } else spans.push({ text, cells: cell.getWidth(), sgr, ...(uri ? { uri } : {}) });
    }
    return { cols, wrapped: line.isWrapped, spans };
  }

  /** One normal-buffer row by absolute index, for the source's resize
   * reconciliation — the one eviction family no hook can reach. */
  normalRow(index: number): Omit<TerminalHistoryRow, "rowId"> | undefined {
    const line = this.term.buffer.normal.getLine(index);
    return line ? this.row(line, this.term.cols) : undefined;
  }

  /** The live DECSTBM margins, 0-based and inclusive. Not on the public buffer
   * API, and every splice handler needs them to tell an eviction from a discard. */
  margins(): { top: number; bottom: number } {
    const buffer = this.core._bufferService.buffer;
    return { top: buffer.scrollTop, bottom: buffer.scrollBottom };
  }

  /**
   * Installs every hook by which a row can leave the normal viewport.
   *
   * Two layers, because no single one covers the buffer. `BufferService.scroll`
   * is the only place a row is visible before `recycle()` reuses the ring, and
   * it is what LF/IND and the scrollback-cap trim go through — but `CSI S`,
   * `CSI M`, `CSI L`, `CSI T`, `ESC M`, `ED(2)` and `DECALN` all splice the
   * buffer directly and never call it, so each gets a parser handler that reads
   * the doomed rows BEFORE xterm's default handler mutates anything and then
   * returns false so the default still runs.
   *
   * The third family, resize, is reconciled at the source's own `term.resize()`
   * call site: `onResize` fires after the mutation and `onScroll`/`onLineFeed`
   * never fire at all, so no hook installed here could reach it.
   */
  onArchiveRow(sink: TerminalArchiveSink): () => void {
    const detach = [
      this.patchScroll(sink),
      // Rows leave the region's top. Only a region anchored at row 0 is
      // scrollback-bound; VT semantics drop the rest on the floor.
      this.onCsi("S", sink, (params) => {
        const { top, bottom } = this.margins();
        const count = this.clamp(params, 1, bottom - top + 1);
        if (top === 0) this.archiveRows(sink, 0, count);
        else sink.discarded(count);
      }),
      // deleteLines. Only rows spliced out AT the top of a top-anchored region
      // reach scrollback; a mid-screen delete is a discard in any terminal.
      this.onCsi("M", sink, (params) => {
        const { top, bottom } = this.margins();
        const cursor = this.term.buffer.active.cursorY;
        if (cursor < top || cursor > bottom) return;
        const count = this.clamp(params, 1, bottom - cursor + 1);
        if (top === 0 && cursor === 0) this.archiveRows(sink, 0, count);
        else sink.discarded(count);
      }),
      // ED. Only the whole-screen erase evicts; ED(3) is the source's own
      // history-clear rule and ED(0)/ED(1) erase in place.
      this.onCsi("J", sink, (params) => {
        if (this.clamp(params, 0, 3) !== 2) return;
        this.archiveRows(sink, 0, this.usedRows());
      }),
      // insertLines and scrollDown push rows off the BOTTOM edge, where no
      // terminal's scrollback model can follow them.
      this.onCsi("L", sink, (params) => this.dropBottom(sink, params)),
      this.onCsi("T", sink, (params) => this.dropBottom(sink, params)),
      this.onEsc({ final: "M" }, sink, () => this.dropBottom(sink, [1])),
      // DECALN overpaints the whole screen in place.
      this.onEsc({ intermediates: "#", final: "8" }, sink, () => sink.discarded(this.usedRows())),
    ];
    return () => { for (const dispose of detach.reverse()) dispose(); };
  }

  private patchScroll(sink: TerminalArchiveSink): () => void {
    const service = this.core._bufferService;
    const original = service.scroll;
    const term = this.term;
    const adapter = this;
    const replacement = function(this: BufferService, ...args: unknown[]): void {
      // The alternate buffer has no scrollback, and a region whose top is not
      // row 0 discards by VT semantics. Both are measured, both are correct.
      if (term.buffer.active.type === "normal" && this.buffer.scrollTop === 0) {
        adapter.guard(sink, () => {
          const line = term.buffer.normal.getLine(term.buffer.normal.baseY);
          if (!line) return sink.gap(1);
          // Copy before recycle() mutates the ring, including every scroll in a
          // single write. onScroll fires after recycling and cannot do this job.
          sink.row(adapter.row(line, term.cols));
        });
      }
      original.apply(this, args);
    };
    service.scroll = replacement;
    return () => { if (service.scroll === replacement) service.scroll = original; };
  }

  private onCsi(final: string, sink: TerminalArchiveSink,
    apply: (params: (number | number[])[]) => void): () => void {
    const handler = this.term.parser.registerCsiHandler({ final }, (params) => {
      if (this.term.buffer.active.type === "normal") this.guard(sink, () => apply(params));
      return false;
    });
    return () => handler.dispose();
  }

  private onEsc(id: { intermediates?: string; final: string }, sink: TerminalArchiveSink,
    apply: () => void): () => void {
    const handler = this.term.parser.registerEscHandler(id, () => {
      if (this.term.buffer.active.type === "normal") this.guard(sink, apply);
      return false;
    });
    return () => handler.dispose();
  }

  /**
   * Handlers and the scroll patch run inside xterm's asynchronous parse loop,
   * outside every caller's try/catch — a throw there is an uncaughtException
   * that takes down every PTY on the machine. Losing a row is the small failure;
   * report it as a gap and let the parse continue.
   */
  private guard(sink: TerminalArchiveSink, work: () => void): void {
    try { work(); } catch { sink.gap(1); }
  }

  private dropBottom(sink: TerminalArchiveSink, params: (number | number[])[]): void {
    const { top, bottom } = this.margins();
    const cursor = this.term.buffer.active.cursorY;
    if (cursor < top || cursor > bottom) return;
    sink.discarded(this.clamp(params, 1, bottom - cursor + 1));
  }

  private archiveRows(sink: TerminalArchiveSink, first: number, count: number): void {
    const buffer = this.term.buffer.normal;
    for (let index = 0; index < count; index++) {
      const line = buffer.getLine(buffer.baseY + first + index);
      if (line) sink.row(this.row(line, this.term.cols));
      else sink.gap(1);
    }
  }

  /** Viewport rows up to and including the last one holding anything. `ED(2)`
   * over a mostly blank screen must not archive a screenful of nothing. */
  private usedRows(): number {
    const buffer = this.term.buffer.active;
    for (let row = this.term.rows - 1; row >= 0; row--) {
      if (buffer.getLine(buffer.baseY + row)?.translateToString(true)) return row + 1;
    }
    return 0;
  }

  /** A handler sees RAW params — `CSI 99 S` on a four-row terminal delivers 99
   * while xterm's own default clamps to the region — so each one clamps itself. */
  private clamp(params: (number | number[])[], fallback: number, ceiling: number): number {
    const raw = params[0];
    const value = (typeof raw === "number" ? raw : 0) || fallback;
    return Math.max(0, Math.min(value, ceiling));
  }
}
