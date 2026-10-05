import {
  MAX_SPANS_PER_ROW,
  TERMINAL_HISTORY_PAGE_BYTES,
  encodedJsonBytes,
  type TerminalHistoryRow,
  type TerminalHistorySpan,
} from "../terminal-frames/protocol";
import { NO_EXPLICIT_LINKS, cutDetectRow, detectLinks, type DetectedSpan, type DetectRow } from "./detector";
import { isAntgridLinkUri, scanLine } from "./grammar";
import { normalizeBases, type LinkBases } from "./resolver";
import { sharedPathStatCache, type PathStatCache } from "./stat-cache";

const HISTORY_BUDGET = { lookups: 4096, newStats: 512 };
const MAX_PASSES = 4;
const DEFAULT_BUDGET_MS = 150;
/** Room kept under the page cap for the page envelope the rows travel in. */
const PAGE_HEADROOM_BYTES = 1024;

type ContextRow = Omit<TerminalHistoryRow, "rowId">;

/** The output on either side of a page. Detection reads it so a mention that
 *  crosses the page's edge is judged whole, but never paints it. */
export interface HistoryContext {
  /** Oldest first, ending where the page begins. */
  before: readonly ContextRow[];
  /** Oldest first, starting where the page ends. */
  after: readonly ContextRow[];
  /** `after` runs to the end of the output, so nothing continues past its last
   *  row. Without it a mention that reaches the right edge of that row is
   *  unlinked: its continuation is unknown. */
  afterComplete: boolean;
}

export interface HistoryLinkOptions {
  context?: HistoryContext;
  cache?: PathStatCache;
  budgetMs?: number;
  now?: () => number;
  /** Tests only: the platform whose path rules apply. */
  platform?: NodeJS.Platform;
}

/**
 * Links the printed paths and URLs in one served history page.
 *
 * The page is the only moment every archived row is in hand together with its
 * neighbours (a path joined across a hard wrap needs both rows) and there is
 * time to wait on a stat. Archived rows never carry detected links themselves:
 * they would go stale, and a restored copy would replay them as program-authored.
 *
 * A page is cut at an arbitrary row, so a line that wraps across the cut would
 * otherwise be linked as two unrelated fragments, each aimed at the wrong
 * target. `opts.context` supplies the rows around it. A row the page begins
 * with that continues the one before it, and a mention running to the right
 * edge of the last row, are left unlinked when the context does not settle them.
 *
 * Never rejects. Whatever fails, the caller still gets the page, with at
 * least the program-authored `antgrid-*` links removed.
 */
export async function linkHistoryRows(
  rows: TerminalHistoryRow[],
  bases: LinkBases,
  opts: HistoryLinkOptions = {},
): Promise<TerminalHistoryRow[]> {
  let stripped = rows;
  try {
    stripped = stripProgramLinks(rows);
    return await link(stripped, bases, opts);
  } catch {
    return stripped;
  }
}

/** Only the bridge's own detector may mint these; a stored one was written by
 *  a program (or by an older bridge) and must not borrow the detected route. */
function stripProgramLinks<R extends ContextRow>(rows: R[]): R[] {
  return rows.map((row) => {
    if (!row.spans.some((s) => s.uri !== undefined && isAntgridLinkUri(s.uri))) return row;
    return {
      ...row,
      spans: row.spans.map((s) => (s.uri !== undefined && isAntgridLinkUri(s.uri) ? piece(s, s.text, s.cells) : s)),
    };
  });
}

async function link(
  rows: TerminalHistoryRow[],
  bases: LinkBases,
  opts: HistoryLinkOptions,
): Promise<TerminalHistoryRow[]> {
  const cache = opts.cache ?? sharedPathStatCache();
  const now = opts.now ?? Date.now;
  const budgetMs = opts.budgetMs ?? DEFAULT_BUDGET_MS;
  const started = now();
  const platform = opts.platform ?? process.platform;
  const normalized = normalizeBases(bases, platform);
  if (normalized.checkoutRoot === undefined) return rows;
  // A page can be served before any live terminal has registered this volume.
  cache.trustVolume(normalized.checkoutRoot);

  const context = opts.context;
  const before = context ? stripProgramLinks(context.before as TerminalHistoryRow[]) : [];
  const after = context ? stripProgramLinks(context.after as TerminalHistoryRow[]) : [];
  const all = [...before, ...rows, ...after];
  const detectRows = all.map((row, i) => toDetectRow(row, all[i + 1]?.wrapped !== true));
  const painted = before.length;
  const pageEnd = painted + rows.length;
  const edges = { tailOpen: context?.afterComplete !== true, paintedEnd: pageEnd };
  // The same rows are read on every pass, and a pass differs only in what the
  // stat cache has answered since.
  const scanned = new Map<string, ReturnType<typeof scanLine>>();
  const scan = (text: string): ReturnType<typeof scanLine> => {
    let hit = scanned.get(text);
    if (!hit) scanned.set(text, (hit = scanLine(text, platform)));
    return hit;
  };
  let spans: DetectedSpan[] = [];
  for (let pass = 0; pass < MAX_PASSES; pass++) {
    const result = detectLinks(detectRows, painted, normalized, cache, HISTORY_BUDGET, scan, platform, edges);
    spans = result.spans.map((s) => ({ ...s, row: s.row - painted }));
    // The root's own answer can still change a link found, as a stat a claim
    // waits on can.
    const awaited = [...result.pending, ...result.refining];
    if (awaited.length === 0) break;
    const remaining = budgetMs - (now() - started);
    // A prefetch after the last pass would delay the reply for answers nothing
    // reads.
    if (remaining <= 0 || pass === MAX_PASSES - 1) break;
    await cache.prefetch(awaited, remaining);
  }
  return spans.length === 0 ? rows : applySpans(rows, spans);
}

function piece(span: TerminalHistorySpan, text: string, cells: number, uri?: string): TerminalHistorySpan {
  return { text, cells, sgr: span.sgr, ...(uri !== undefined ? { uri } : {}) };
}

/**
 * A span whose code points equal its cells maps one code point to one column.
 * Any other span holds a wide or combining character, whose column cannot be
 * recovered from the text alone, so nothing inside it may be linked.
 */
function toDetectRow(row: ContextRow, lastOfLine: boolean): DetectRow {
  const cols = row.cols;
  const widthAt = new Uint8Array(cols).fill(1);
  let explicit: (string | undefined)[] | undefined;
  let total = 0;
  for (const span of row.spans) total += span.text.length;
  const colAt = new Int32Array(total);
  let used = 0;
  let text = "";
  let col = 0;
  let endCol = 0;
  let keep = 0;

  for (const span of row.spans) {
    const startCol = col;
    const cps = Array.from(span.text);
    if (cps.length === span.cells) {
      for (const cp of cps) {
        for (let u = 0; u < cp.length; u++) colAt[used++] = col;
        text += cp;
        if (cp !== " ") {
          endCol = col + 1;
          keep = text.length;
        }
        col++;
      }
    } else {
      for (let u = 0; u < span.text.length; u++) colAt[used++] = -1;
      text += span.text;
      let trailing = 0;
      while (trailing < span.text.length && span.text[span.text.length - 1 - trailing] === " ") trailing++;
      if (trailing < span.text.length) {
        endCol = startCol + span.cells - trailing;
        keep = text.length - trailing;
      }
      col += span.cells;
    }
    if (span.uri !== undefined) {
      explicit ??= new Array<string | undefined>(cols).fill(undefined);
      for (let c = startCol; c < col && c < cols; c++) explicit[c] = span.uri;
    }
  }

  return cutDetectRow({
    text, colAt, keep, continued: !lastOfLine, widthAt, cols, wrapped: row.wrapped, endCol,
    explicit: explicit ?? NO_EXPLICIT_LINKS,
  });
}

function applySpans(rows: TerminalHistoryRow[], spans: DetectedSpan[]): TerminalHistoryRow[] {
  const byRow = new Map<number, DetectedSpan[]>();
  for (const s of spans) {
    const list = byRow.get(s.row);
    if (list) list.push(s);
    else byRow.set(s.row, [s]);
  }
  const cap = TERMINAL_HISTORY_PAGE_BYTES - PAGE_HEADROOM_BYTES;
  let total = encodedJsonBytes(rows);
  const out = rows.slice();

  for (const index of [...byRow.keys()].sort((a, b) => a - b)) {
    let row = out[index];
    if (!row) continue;
    let rowBytes = encodedJsonBytes(row);
    let full = false;
    for (const l of byRow.get(index)!.sort((a, b) => a.startCol - b.startCol)) {
      const next = splitRow(row, l);
      if (!next) continue;
      const nextBytes = encodedJsonBytes(next);
      if (total - rowBytes + nextBytes > cap) {
        full = true;
        break;
      }
      total += nextBytes - rowBytes;
      row = next;
      rowBytes = nextBytes;
    }
    out[index] = row;
    if (full) break;
  }
  return out;
}

/** Splits spans at the link's boundaries into new objects; the input row is
 *  shared with the archive and is never touched. */
function splitRow(row: TerminalHistoryRow, l: DetectedSpan): TerminalHistoryRow | undefined {
  const spans: TerminalHistorySpan[] = [];
  let col = 0;
  for (const span of row.spans) {
    const start = col;
    const end = col + span.cells;
    col = end;
    if (end <= l.startCol || start >= l.endCol) {
      spans.push(span);
      continue;
    }
    const cps = Array.from(span.text);
    if (cps.length !== span.cells || span.uri !== undefined) return undefined;
    const from = Math.max(l.startCol, start) - start;
    const to = Math.min(l.endCol, end) - start;
    if (from > 0) spans.push(piece(span, cps.slice(0, from).join(""), from));
    spans.push(piece(span, cps.slice(from, to).join(""), to - from, l.uri));
    if (to < cps.length) spans.push(piece(span, cps.slice(to).join(""), cps.length - to));
  }
  return spans.length > MAX_SPANS_PER_ROW ? undefined : { ...row, spans };
}
