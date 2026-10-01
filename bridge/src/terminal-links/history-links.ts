import {
  TERMINAL_HISTORY_PAGE_BYTES,
  encodedJsonBytes,
  type TerminalHistoryRow,
  type TerminalHistorySpan,
} from "../terminal-frames/protocol";
import { detectLinks, type DetectedSpan, type DetectRow } from "./detector";
import { isAntgridLinkUri } from "./grammar";
import { normalizeBases, type LinkBases } from "./resolver";
import { sharedPathStatCache, type PathStatCache } from "./stat-cache";

const HISTORY_BUDGET = { lookups: 4096, newStats: 512 };
const MAX_PASSES = 4;
const DEFAULT_BUDGET_MS = 150;
/** Mirrors `TerminalHistoryRowSchema`'s span bound. */
const MAX_SPANS_PER_ROW = 1000;
/** Room kept under the page cap for the page envelope the rows travel in. */
const PAGE_HEADROOM_BYTES = 1024;

export interface HistoryLinkOptions {
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
function stripProgramLinks(rows: TerminalHistoryRow[]): TerminalHistoryRow[] {
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

  const detectRows = rows.map((row, i) => toDetectRow(row, rows[i + 1]?.wrapped !== true));
  let spans: DetectedSpan[] = [];
  for (let pass = 0; pass < MAX_PASSES; pass++) {
    const result = detectLinks(detectRows, 0, normalized, cache, { ...HISTORY_BUDGET }, undefined, platform);
    spans = result.spans;
    if (result.pending.size === 0) break;
    const remaining = budgetMs - (now() - started);
    // A prefetch after the last pass would delay the reply for answers nothing
    // reads.
    if (remaining <= 0 || pass === MAX_PASSES - 1) break;
    await cache.prefetch([...result.pending], remaining);
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
function toDetectRow(row: TerminalHistoryRow, lastOfLine: boolean): DetectRow {
  const cols = row.cols;
  const widthAt = new Uint8Array(cols).fill(1);
  const explicit: (string | undefined)[] = new Array<string | undefined>(cols).fill(undefined);
  const colAt: number[] = [];
  let text = "";
  let col = 0;
  let endCol = 0;
  let keep = 0;

  for (const span of row.spans) {
    const startCol = col;
    const cps = Array.from(span.text);
    if (cps.length === span.cells) {
      for (const cp of cps) {
        for (let u = 0; u < cp.length; u++) colAt.push(col);
        text += cp;
        if (cp !== " ") {
          endCol = col + 1;
          keep = text.length;
        }
        col++;
      }
    } else {
      for (let u = 0; u < span.text.length; u++) colAt.push(-1);
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
      for (let c = startCol; c < col && c < cols; c++) explicit[c] = span.uri;
    }
  }

  // The last row of a logical line is cut at its last visible character, so
  // that "does this row run to the edge" is a question about content.
  const cut = lastOfLine ? keep : text.length;
  return {
    text: text.slice(0, cut),
    colAt: Int32Array.from(colAt.slice(0, cut)),
    widthAt,
    cols,
    wrapped: row.wrapped,
    endCol,
    explicit,
  };
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
