import type { IBufferCell, IBufferLine, Terminal } from "@xterm/headless";
import type { TerminalHistoryRow, TerminalHistorySpan } from "./protocol";

interface ExtendedCell extends IBufferCell {
  extended: { urlId: number };
  getUnderlineStyle(): number;
  getUnderlineColor(): number;
  isUnderlineColorRGB(): boolean;
  isUnderlineColorPalette(): boolean;
}
interface BufferService {
  buffer: { scrollTop: number };
  scroll(...args: unknown[]): void;
}
interface XtermInternals {
  _core: {
    _oscLinkService: { getLinkData(id: number): { uri: string } | undefined };
    _bufferService: BufferService;
  };
}

/** All xterm 6 private metadata access lives here. A dependency upgrade must
 * pass the scroll-boundary and native rendering fixtures before qualification. */
export class XtermFrameAdapter {
  private readonly core: XtermInternals["_core"];
  constructor(private readonly term: Terminal) {
    this.core = (term as unknown as XtermInternals)._core;
    if (typeof this.core?._oscLinkService?.getLinkData !== "function" ||
        typeof this.core?._bufferService?.scroll !== "function") {
      throw new Error("Unsupported xterm frame adapter API");
    }
    const cell = term.buffer.active.getNullCell() as ExtendedCell;
    if (typeof cell.getUnderlineStyle !== "function" || typeof cell.getUnderlineColor !== "function") {
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
    for (const [prefix, rgb, palette, color] of [
      [38, cell.isFgRGB(), cell.isFgPalette(), cell.getFgColor()],
      [48, cell.isBgRGB(), cell.isBgPalette(), cell.getBgColor()],
      [58, extended.isUnderlineColorRGB(), extended.isUnderlineColorPalette(), extended.getUnderlineColor()],
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

  onArchiveRow(consume: (row: Omit<TerminalHistoryRow, "rowId">) => void): () => void {
    const service = this.core._bufferService;
    const original = service.scroll;
    const term = this.term;
    const adapter = this;
    const replacement = function(this: BufferService, ...args: unknown[]): void {
      if (term.buffer.active.type === "normal" && this.buffer.scrollTop === 0) {
        const line = term.buffer.normal.getLine(term.buffer.normal.baseY);
        if (!line) throw new Error("Missing xterm row at scroll boundary");
        // Copy before recycle() mutates the ring, including every scroll in a
        // single write. onScroll fires after recycling and cannot do this job.
        consume(adapter.row(line, term.cols));
      }
      original.apply(this, args);
    };
    service.scroll = replacement;
    return () => { if (service.scroll === replacement) service.scroll = original; };
  }
}
