import {
  MAX_JOINED_PATH_LINES,
  WRAP_EDGE_SLACK,
  decodeFileUrlPath,
  encodePathLink,
  encodeUrlLink,
  isFileUrl,
  isTokenStop,
  scanLine,
  splitPathToken,
  trimTrailingPunct,
  trimUrl,
  type PathClaimText,
  type ScannedPath,
} from "./grammar";
import { isSeparator, isWhitespace } from "./chars";
import { candidatesFor, classifyPath, type LinkBases } from "./resolver";
import type { PathStatCache } from "./stat-cache";

export interface DetectRow {
  /** Every non-width-0 cell's chars (blank becomes " "). Full width for every
   *  row of a logical line except its last, which is cut at `endCol`. */
  text: string;
  /** Per UTF-16 index of `text`: its column, or -1 when unmappable. */
  colAt: Int32Array;
  /** Per column: the cell width (0 for a wide character's tail). */
  widthAt: Uint8Array;
  cols: number;
  /** The row continues the previous one (terminal soft wrap). */
  wrapped: boolean;
  /** Exclusive: 1 + the last non-blank column, 0 for a blank row. */
  endCol: number;
  /** Per column: the program's own OSC 8 uri. */
  explicit: (string | undefined)[];
}

export interface DetectedSpan {
  row: number;
  startCol: number;
  /** Exclusive. */
  endCol: number;
  uri: string;
}

export interface DetectBudget {
  lookups: number;
  newStats: number;
}

export interface DetectResult {
  spans: DetectedSpan[];
  /** Keys a claim is still waiting on. */
  pending: Set<string>;
  /** Keys answered "missing" or "refused" that a claim walked past. */
  negatives: Set<string>;
  /** Keys behind every emitted path link. */
  linked: Set<string>;
  /** A request was dropped or the new-stat budget ran out. */
  starved: boolean;
}

type ScanFn = (text: string) => ReturnType<typeof scanLine>;

/** The end of the run starting at `from` whose characters `stop` lets through. */
function runEnd(text: string, from: number, stop: (code: number) => boolean): number {
  let i = from;
  while (i < text.length && !stop(text.charCodeAt(i))) i++;
  return i;
}

/** What ends a URL continuation: `_urlContinuation` in
 *  `app/lib/util/wrapped_url.dart`. */
function isUrlPieceStop(code: number): boolean {
  return isWhitespace(code) || code === 0x3c || code === 0x3e || code === 0x22 || code === 0x27;
}

/** Box rules and gutter glyphs an agent TUI repeats at the start of a wrapped
 *  row: `_rowGutter` in `wrapped_url.dart`. */
function gutterEnd(text: string): number {
  return runEnd(text, 0, (code) => !(isWhitespace(code) || code === 0x2502 || code === 0x2503 || code === 0x7c));
}

interface Line {
  first: number;
  last: number;
  text: string;
  /** Length of `text` without trailing blanks. */
  trimmedLength: number;
  rowAt: Int32Array;
  colAt: Int32Array;
  occupied: Uint8Array;
}

interface Segment {
  line: Line;
  start: number;
  end: number;
}

interface Claim {
  kind: "path" | "url";
  segs: Segment[];
  text?: PathClaimText;
  uri?: string;
  /** The text as printed, before any suffix removal. */
  printed: string;
  quoted: boolean;
  /** Part of a URL's continuation, or covering a link the program wrote itself. */
  dead: boolean;
  guard?: Guard;
}

interface Option {
  claims: Claim[];
  /** How many continuation pieces this option's claim consumed; 0 for a plain option. */
  pieces: number;
}

/** A group member whose cells a join might own: it may only link when that
 *  join did not win. */
interface Guard {
  group: Group;
  piece: number;
}

interface Group {
  options: Option[];
  guard?: Guard;
  evaluated: boolean;
  resolved?: Resolution;
}

interface Resolution {
  emit: Claim[];
  /** A join option is still waiting on a stat, so the next-line claims it might own may not link yet. */
  blocked: boolean;
  /** Pieces owned by the winning join option; 0 when none won. */
  ownedPieces: number;
}

type ClaimEval = { state: "linked"; uri: string; key?: string } | { state: "pending" } | { state: "none" };

interface Piece {
  line: Line;
  lineIndex: number;
  start: number;
  /** After trimming. */
  end: number;
}

export function detectLinks(
  rows: readonly DetectRow[],
  firstPainted: number,
  bases: LinkBases,
  cache: PathStatCache,
  budget: DetectBudget,
  scan?: ScanFn,
  platform: NodeJS.Platform = process.platform,
): DetectResult {
  const result: DetectResult = {
    spans: [],
    pending: new Set(),
    negatives: new Set(),
    linked: new Set(),
    starved: false,
  };
  try {
    run(rows, firstPainted, bases, cache, { ...budget }, scan ?? ((t) => scanLine(t, platform)), platform, result);
    return result;
  } catch {
    // Detection is decoration: a throw here must never reach the frame
    // pipeline, which would latch the whole terminal as failed.
    return { spans: [], pending: new Set(), negatives: new Set(), linked: new Set(), starved: false };
  }
}

function run(
  rows: readonly DetectRow[],
  firstPainted: number,
  bases: LinkBases,
  cache: PathStatCache,
  budget: DetectBudget,
  scan: ScanFn,
  platform: NodeJS.Platform,
  result: DetectResult,
): void {
  const lines = buildLines(rows);
  const scanned = lines.map((l) => (l.trimmedLength === 0 ? { paths: [], urls: [] } : scan(l.text)));
  const pathClaims: Array<Array<{ scanned: ScannedPath; claim: Claim }>> = lines.map((l, li) =>
    scanned[li]!.paths.map((p) => ({ scanned: p, claim: pathClaim(l, p) })),
  );

  const reachesEdge = (line: Line): boolean => {
    const row = rows[line.last]!;
    return row.endCol > 0 && row.endCol >= row.cols - WRAP_EDGE_SLACK;
  };

  const coversExplicit = (c: Claim): boolean => {
    for (const seg of c.segs) {
      for (let i = seg.start; i < seg.end; i++) {
        const col = seg.line.colAt[i]!;
        if (col < 0) continue;
        const row = rows[seg.line.rowAt[i]!]!;
        const width = Math.max(1, row.widthAt[col] ?? 1);
        for (let t = 0; t < width; t++) if (row.explicit[col + t] !== undefined) return true;
      }
    }
    return false;
  };
  const track = (c: Claim): Claim => {
    if (coversExplicit(c)) c.dead = true;
    return c;
  };
  for (const entries of pathClaims) for (const e of entries) track(e.claim);

  const groupsByLine: Group[][] = lines.map(() => []);

  for (let li = 0; li < lines.length; li++) {
    const line = lines[li]!;

    for (const u of scanned[li]!.urls) {
      const claim = urlClaim(li, u.start, u.end, u.url);
      if (claim) groupsByLine[li]!.push(plainGroup(claim));
    }

    const entries = pathClaims[li]!;
    const inQuote = new Set<(typeof entries)[number]>();
    for (const q of entries) {
      if (!q.scanned.quoted) continue;
      // Entries are ordered by start, so the tokens inside a quote are one
      // contiguous run; filtering the whole line per quote would be quadratic
      // on a line of nothing but quoted names.
      const inner: typeof entries = [];
      for (let i = firstStartingAt(entries, q.scanned.start); i < entries.length; i++) {
        const e = entries[i]!;
        if (e.scanned.start >= q.scanned.end) break;
        if (!e.scanned.quoted && e.scanned.end <= q.scanned.end) inner.push(e);
      }
      for (const e of inner) inQuote.add(e);
      const options: Option[] = [
        { claims: live([q.claim]), pieces: 0 },
        { claims: live(inner.map((e) => e.claim)), pieces: 0 },
      ].filter((o) => o.claims.length > 0);
      if (options.length > 0) groupsByLine[li]!.push(makeGroup(options, q.claim.guard));
    }

    for (const e of entries) {
      if (e.scanned.quoted || inQuote.has(e)) continue;
      if (e.claim.dead) continue;
      const joined = joinGroup(li, e);
      groupsByLine[li]!.push(joined ?? plainGroup(e.claim));
    }
  }

  function live(claims: Claim[]): Claim[] {
    return claims.filter((c) => !c.dead);
  }

  function makeGroup(options: Option[], guard?: Guard): Group {
    return { options, guard, evaluated: false };
  }

  function plainGroup(claim: Claim): Group {
    return makeGroup([{ claims: [claim], pieces: 0 }], claim.guard);
  }

  function pathClaim(line: Line, p: ScannedPath): Claim {
    return {
      kind: "path",
      segs: [{ line, start: p.start, end: p.end }],
      text: p.text,
      printed: line.text.slice(p.start, p.end),
      quoted: p.quoted,
      dead: false,
    };
  }

  /** The text on `li` after the claim at `end` is only blanks. */
  function endsLine(li: number, end: number): boolean {
    return end >= lines[li]!.trimmedLength;
  }

  function urlClaim(li: number, start: number, end: number, url: string): Claim | undefined {
    const line = lines[li]!;
    const head: Segment = { line, start, end };
    const next = lines[li + 1];
    let joined = url;
    const segs: Segment[] = [head];
    let tooLong = encodeUrlLink(url) === undefined;

    if (!tooLong && next && endsLine(li, end) && reachesEdge(line)) {
      let cur = li;
      for (;;) {
        const nl = lines[cur + 1];
        if (!nl) break;
        const gutter = gutterEnd(nl.text);
        const pieceEnd = runEnd(nl.text, gutter, isUrlPieceStop);
        if (pieceEnd === gutter) break;
        const piece = nl.text.slice(gutter, pieceEnd);
        // A continuation that opens its own scheme is a second URL.
        if (piece.includes("://")) break;
        joined += piece;
        segs.push({ line: nl, start: gutter, end: gutter + piece.length });
        // Past the cap the whole mention is dropped rather than truncated: a
        // shortened URL would open a different page than the one printed.
        if (encodeUrlLink(joined) === undefined) {
          tooLong = true;
          break;
        }
        if (gutter + piece.length < nl.trimmedLength || !reachesEdge(nl)) break;
        cur++;
      }
    }

    if (segs.length > 1) {
      // The continuation text belongs to this URL even when it ends up
      // unlinked, so a path-looking tail of it must not link on its own.
      for (const seg of segs.slice(1)) {
        for (const e of pathClaims[lines.indexOf(seg.line)]!) {
          if (e.claim.segs[0]!.start < seg.end && e.claim.segs[0]!.end > seg.start) e.claim.dead = true;
        }
      }
    }
    if (tooLong) return undefined;

    const trimmed = segs.length > 1 ? trimUrl(joined) : url;
    if (segs.length > 1) truncateSegments(segs, trimmed.length);
    const uri = encodeUrlLink(trimmed);
    if (!uri) return undefined;
    const claim: Claim = { kind: "url", segs, uri, printed: trimmed, quoted: false, dead: false };
    return track(claim).dead ? undefined : claim;
  }

  /** Keeps the first `length` characters of a claim's cells. */
  function truncateSegments(segs: Segment[], length: number): void {
    let left = length;
    for (let i = 0; i < segs.length; i++) {
      const seg = segs[i]!;
      const size = seg.end - seg.start;
      if (left >= size) {
        left -= size;
        continue;
      }
      seg.end = seg.start + left;
      segs.length = left > 0 ? i + 1 : i;
      return;
    }
  }

  function pathPieces(li: number): Piece[] {
    const out: Piece[] = [];
    let cur = li;
    while (out.length < MAX_JOINED_PATH_LINES - 1) {
      const nl = lines[cur + 1];
      if (!nl) break;
      const gutter = gutterEnd(nl.text);
      // The unquoted-token class of `scanLine`, without the paren tail.
      const pieceEnd = runEnd(nl.text, gutter, isTokenStop);
      if (pieceEnd === gutter) break;
      const raw = nl.text.slice(gutter, pieceEnd);
      const trimmed = trimTrailingPunct(raw);
      if (trimmed.length === 0) break;
      out.push({ line: nl, lineIndex: cur + 1, start: gutter, end: gutter + trimmed.length });
      if (gutter + raw.length < nl.trimmedLength || !reachesEdge(nl)) break;
      cur++;
    }
    return out;
  }

  /** A path that stops at the right edge of a full row may continue on the
   *  next one. The continuation is a guess, so every join is an alternative
   *  that must be verified on disk before it links, and the head-only reading
   *  stays available behind them. */
  function joinGroup(li: number, head: { scanned: ScannedPath; claim: Claim }): Group | undefined {
    const line = lines[li]!;
    const p = head.scanned;
    if (!endsLine(li, p.end) || !reachesEdge(line) || !lines[li + 1]) return undefined;
    const pieces = pathPieces(li);
    if (pieces.length === 0) return undefined;

    const options: Option[] = [];
    for (let k = pieces.length; k >= 1; k--) {
      const used = pieces.slice(0, k);
      const last = used[k - 1]!;
      const text = head.claim.printed + used.map((u) => u.line.text.slice(u.start, u.end)).join("");
      // The scheme and percent escapes belong to the whole printed token, so
      // they are decoded after the pieces are joined: a cut can fall inside one.
      const joinedPath = isFileUrl(text) ? decodeFileUrlPath(text, platform) : text;
      const claim = joinedPath && splitPathToken(joinedPath, { platform, followedByParen: last.line.text[last.end] === "(" });
      if (!claim) continue;
      const joined = track({
        kind: "path",
        segs: [head.claim.segs[0]!, ...used.map((u) => ({ line: u.line, start: u.start, end: u.end }))],
        text: claim,
        printed: text,
        quoted: false,
        dead: false,
      });
      if (!joined.dead) options.push({ claims: [joined], pieces: k });
    }

    const printedHead = head.claim.printed;
    const truncatedDirectory =
      isSeparator(printedHead[printedHead.length - 1]) && !lines[pieces[0]!.lineIndex]!.text.startsWith("…", pieces[0]!.start);
    // A head that visibly stops at a directory separator is a directory the
    // output cut short; opening it would present the parent as the target.
    const fallback = truncatedDirectory || head.claim.dead ? [] : [head.claim];
    if (fallback.length > 0) options.push({ claims: fallback, pieces: 0 });
    if (options.length === 0) return undefined;

    const maxPieces = options.reduce((m, o) => Math.max(m, o.pieces), 0);
    const group = makeGroup(options, head.claim.guard);
    if (maxPieces > 0) {
      pieces.forEach((piece, j) => {
        if (j >= maxPieces) return;
        for (const e of pathClaims[piece.lineIndex]!) {
          const seg = e.claim.segs[0]!;
          if (seg.start < piece.end && seg.end > piece.start) e.claim.guard ??= { group, piece: j };
        }
      });
    }
    return group;
  }

  const memo = new Map<Claim, ClaimEval>();

  function evalClaim(c: Claim): ClaimEval {
    const hit = memo.get(c);
    if (hit) return hit;
    const r = c.kind === "url" ? (c.uri ? { state: "linked" as const, uri: c.uri } : { state: "none" as const }) : evalPath(c);
    memo.set(c, r);
    return r;
  }

  function evalPath(c: Claim): ClaimEval {
    const cands = candidatesFor(c.text!.variants, bases, platform);
    budget.lookups -= cands.length;
    // Every candidate is requested before any is read: a screen that never
    // changes again must not stall behind the first unanswered one, and the
    // requests are also what keep an answer's TTL from lapsing under a link.
    for (const cand of cands) {
      // Only a key nothing has answered yet spends the budget. Re-stating a
      // stale one is upkeep that usually changes nothing, and charging for it
      // would let a screenful of old negatives starve the unknown candidates
      // behind them with nothing left to wake the screen.
      const known = cache.peek(cand.abs) !== undefined;
      if (!known && budget.newStats <= 0) {
        result.starved = true;
        continue;
      }
      const outcome = cache.request(cand.abs);
      if (outcome === "queued" && !known) budget.newStats--;
      else if (outcome === "dropped") result.starved = true;
    }
    for (const cand of cands) {
      const status = cache.peek(cand.abs);
      if (status === undefined) {
        result.pending.add(cand.abs);
        return { state: "pending" };
      }
      if (status === "missing" || status === "refused") {
        result.negatives.add(cand.abs);
        continue;
      }
      const kind = classifyPath(cand.abs, status, bases.checkoutRoot, platform);
      if (!kind) return { state: "none" };
      const uri = encodePathLink({
        path: cand.text,
        base: cand.base,
        kind,
        line: c.text!.line,
        col: c.text!.col,
      });
      return uri ? { state: "linked", uri, key: cand.abs } : { state: "none" };
    }
    return { state: "none" };
  }

  function evaluateGroup(g: Group): void {
    for (const o of g.options) for (const c of o.claims) evalClaim(c);
    g.evaluated = true;
  }

  function resolve(g: Group): Resolution {
    if (g.resolved) return g.resolved;
    let r: Resolution = { emit: [], blocked: false, ownedPieces: 0 };
    for (const o of g.options) {
      const evals = o.claims.map((c) => ({ c, e: evalClaim(c) }));
      const linked = evals.filter((x) => x.e.state === "linked").map((x) => x.c);
      if (linked.length > 0) {
        r = { emit: linked, blocked: false, ownedPieces: o.pieces };
        break;
      }
      // An earlier alternative still waiting on a stat decides what the later
      // ones may become, so none of them links until it settles. The head-only
      // fallback decides nothing for the next line's own paths: no join can
      // claim their cells once it is the one still waiting.
      if (evals.some((x) => x.e.state === "pending")) {
        r = { emit: [], blocked: o.pieces > 0, ownedPieces: 0 };
        break;
      }
    }
    g.resolved = r;
    return r;
  }

  function emittable(g: Group): boolean {
    if (!g.evaluated) return false;
    const guard = g.guard;
    if (!guard) return true;
    const res = guard.group.evaluated ? resolve(guard.group) : undefined;
    if (!res || res.blocked || res.ownedPieces > guard.piece) return false;
    return emittable(guard.group);
  }

  // Newest output first, so a screen with more candidates than budget spends
  // it on what the reader is looking at.
  for (let li = lines.length - 1; li >= 0; li--) {
    for (const g of groupsByLine[li]!) {
      if (budget.lookups <= 0) {
        result.starved = true;
        break;
      }
      evaluateGroup(g);
    }
  }

  const emitted = new Set<Claim>();
  for (let li = 0; li < lines.length; li++) {
    for (const g of groupsByLine[li]!) {
      if (!emittable(g)) continue;
      for (const claim of resolve(g).emit) {
        if (emitted.has(claim)) continue;
        emitted.add(claim);
        emit(claim);
      }
    }
  }

  function emit(claim: Claim): void {
    const ev = evalClaim(claim);
    if (ev.state !== "linked") return;
    for (const seg of claim.segs) {
      for (let i = seg.start; i < seg.end; i++) if (seg.line.occupied[i]) return;
    }
    const spans = spansOf(claim, ev.uri);
    if (!spans) return;
    for (const seg of claim.segs) seg.line.occupied.fill(1, seg.start, seg.end);
    let painted = false;
    for (const s of spans) {
      if (s.row < firstPainted) continue;
      result.spans.push(s);
      painted = true;
    }
    if (painted && ev.key !== undefined) result.linked.add(ev.key);
  }

  function spansOf(claim: Claim, uri: string): DetectedSpan[] | undefined {
    const out: DetectedSpan[] = [];
    let cur: DetectedSpan | undefined;
    for (const seg of claim.segs) {
      for (let i = seg.start; i < seg.end; i++) {
        const col = seg.line.colAt[i]!;
        if (col < 0) return undefined;
        const row = seg.line.rowAt[i]!;
        const r = rows[row]!;
        const end = Math.min(r.cols, col + Math.max(1, r.widthAt[col] ?? 1));
        if (cur && cur.row === row && col >= cur.startCol) {
          cur.endCol = Math.max(cur.endCol, end);
        } else {
          cur = { row, startCol: col, endCol: end, uri };
          out.push(cur);
        }
      }
    }
    return out.length > 0 ? out : undefined;
  }
}

function firstStartingAt(entries: ReadonlyArray<{ scanned: { start: number } }>, at: number): number {
  let lo = 0;
  let hi = entries.length;
  while (lo < hi) {
    const mid = (lo + hi) >>> 1;
    if (entries[mid]!.scanned.start < at) lo = mid + 1;
    else hi = mid;
  }
  return lo;
}

/** Rows joined by terminal soft wrap form one logical line; a hard wrap (the
 *  program writing its own newline) starts the next. */
function buildLines(rows: readonly DetectRow[]): Line[] {
  const out: Line[] = [];
  let i = 0;
  while (i < rows.length) {
    let j = i;
    while (j + 1 < rows.length && rows[j + 1]!.wrapped) j++;
    let total = 0;
    for (let r = i; r <= j; r++) total += rows[r]!.text.length;
    const rowAt = new Int32Array(total);
    const colAt = new Int32Array(total).fill(-1);
    const parts: string[] = [];
    let at = 0;
    for (let r = i; r <= j; r++) {
      const row = rows[r]!;
      parts.push(row.text);
      for (let k = 0; k < row.text.length; k++) {
        rowAt[at + k] = r;
        const col = row.colAt[k];
        if (col !== undefined) colAt[at + k] = col;
      }
      at += row.text.length;
    }
    const text = parts.join("");
    out.push({
      first: i,
      last: j,
      text,
      trimmedLength: text.trimEnd().length,
      rowAt,
      colAt,
      occupied: new Uint8Array(total),
    });
    i = j + 1;
  }
  return out;
}
