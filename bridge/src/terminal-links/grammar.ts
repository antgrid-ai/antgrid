// Plain-text path and URL detection for terminal output, with no filesystem
// access: everything here is a textual judgement, and the stat that confirms a
// guess lives elsewhere.
//
// Every scanner is a hand-written walk with no regular expressions: this runs
// over every line a program prints, and an explicit walk is linear by
// construction where each pattern would need auditing for backtracking.
//
// The `antgrid-path:` / `antgrid-url:` URI grammar is mirrored by hand in
// `app/lib/util/terminal_links.dart`, and `WRAP_EDGE_SLACK` / the URL rules
// copy `app/lib/util/wrapped_url.dart`. No suite spans those files, so change
// them together.

import {
  hasDriveLetterAt,
  hasLineTerminator,
  isAsciiAlnum,
  isAsciiDigit,
  isAsciiLetter,
  isAsciiLower,
  isAsciiUpper,
  isDriveAbsolute,
  isSeparator,
  isWhitespace,
  isWordChar,
  startsWithIgnoreCase,
} from "./chars";

export const PATH_LINK_SCHEME = "antgrid-path:";
export const URL_LINK_SCHEME = "antgrid-url:";
/** UTF-16 units. */
export const MAX_PRINTED_PATH_CHARS = 1024;
/** Ghostty captures an OSC 8 payload into a fixed 2048-byte buffer; staying
 *  under it with headroom keeps a minted link from being truncated into a
 *  different (and still clickable) target. */
export const MAX_LINK_URI_BYTES = 2000;
export const WRAP_EDGE_SLACK = 4;
export const MAX_JOINED_PATH_LINES = 3;
export const MAX_LINE_NUMBER = 10_000_000;
export const MAX_COLUMN_NUMBER = 100_000;

/** A token this long cannot be a path (the path cap is far below it), so it is
 *  dropped before any per-token work. */
const MAX_TOKEN_CHARS = 4096;
const MAX_OSC7_PATH_CHARS = 4096;
const MAX_QUOTED_CHARS = 1024;
/** How far back a trailing `(12,5)` position is looked for. */
const PAREN_POSITION_WINDOW = 64;
const PYTHON_LINE_PREFIX = ", line ";
/** The digits of a Python `, line N` suffix must start within this many
 *  characters of the closing quote. */
const PYTHON_LINE_REACH = 24;

export type PrintedPathBase = "a" | "l" | "s" | "r";
export type PrintedPathKind = "f" | "d" | "i";

export interface PathClaimText {
  variants: string[];
  line?: number;
  col?: number;
}

export interface ScannedPath {
  start: number;
  end: number;
  quoted: boolean;
  text: PathClaimText;
  followedByParen: boolean;
}

export interface ScannedUrl {
  start: number;
  end: number;
  url: string;
}

interface QuoteKind {
  open: number;
  close: number;
  /** An apostrophe inside a word ("don't", "it's") is not a quote; requiring a
   *  non-word neighbour on the outside of each mark is what tells them apart. */
  wordBounded: boolean;
}

const QUOTE_KINDS: readonly QuoteKind[] = [
  { open: 0x22, close: 0x22, wordBounded: false }, // "…"
  { open: 0x60, close: 0x60, wordBounded: false }, // `…`
  { open: 0x27, close: 0x27, wordBounded: true }, // '…'
  { open: 0x2018, close: 0x2019, wordBounded: false }, // ‘…’
  { open: 0x201c, close: 0x201d, wordBounded: false }, // “…”
];

/** Characters that end an unquoted token: white space, quotes, brackets and
 *  the shell's `|` / `*`. */
export function isTokenStop(code: number): boolean {
  if (isWhitespace(code)) return true;
  switch (code) {
    case 0x22: // "
    case 0x27: // '
    case 0x60: // `
    case 0x28: // (
    case 0x29: // )
    case 0x5b: // [
    case 0x5d: // ]
    case 0x7b: // {
    case 0x7d: // }
    case 0x3c: // <
    case 0x3e: // >
    case 0x7c: // |
    case 0x2a: // *
    case 0x2018:
    case 0x2019:
    case 0x201c:
    case 0x201d:
      return true;
    default:
      return false;
  }
}

/** Scans one logical line. Offsets are UTF-16 indices into `text`. */
export function scanLine(
  text: string,
  platform: NodeJS.Platform = process.platform,
): { paths: ScannedPath[]; urls: ScannedUrl[] } {
  const urls = scanUrls(text);
  const paths: ScannedPath[] = [];

  // A path may not overlap a URL, so URL cells are counted once and every
  // overlap question below is two array reads.
  const urlCover = new Int32Array(text.length + 1);
  if (urls.length > 0) {
    const mark = new Uint8Array(text.length);
    for (const u of urls) mark.fill(1, u.start, u.end);
    for (let i = 0; i < text.length; i++) urlCover[i + 1] = urlCover[i]! + mark[i]!;
  }
  const overlapsUrl = (start: number, end: number): boolean => urlCover[end]! - urlCover[start]! > 0;

  for (const kind of QUOTE_KINDS) {
    scanQuoted(text, kind, (start, end) => {
      if (overlapsUrl(start, end)) return;
      const claim = splitPathToken(text.slice(start, end), { platform });
      if (!claim) return;
      if (claim.line === undefined) {
        const line = pythonLineAfter(text, end + 1);
        if (line !== undefined) claim.line = line;
      }
      paths.push({ start, end, quoted: true, text: claim, followedByParen: false });
    });
  }

  const masked = urls.length > 0 ? maskRanges(text, urls) : text;
  scanTokens(masked, (tokenStart, tokenEnd) => {
    if (tokenEnd - tokenStart > MAX_TOKEN_CHARS) return;
    if (!hasPathMark(masked, tokenStart, tokenEnd)) return;
    const followedByParen = masked.charCodeAt(tokenEnd) === 0x28;

    let token = trimTrailingPunct(masked.slice(tokenStart, tokenEnd));
    if (token.length === 0) return;
    let start = tokenStart;
    const end = start + token.length;

    const valueAt = assignmentValueStart(token);
    if (valueAt !== -1) {
      start += valueAt;
      token = token.slice(valueAt);
    }

    if (isFileUrl(token)) {
      const decoded = decodeFileUrlPath(token, platform);
      if (decoded === undefined) return;
      token = decoded;
    }
    if (token.includes("://")) return;

    const claim = splitPathToken(token, { platform, followedByParen });
    if (claim) paths.push({ start, end, quoted: false, text: claim, followedByParen });
  });

  paths.sort((a, b) => a.start - b.start || b.end - a.end || Number(b.quoted) - Number(a.quoted));
  return { paths, urls };
}

/** Calls `found` with the inner range of each quoted run of one kind, leftmost
 *  first and never overlapping. A run is 1-1024 characters on one line. A
 *  failed opener resumes the search where its walk stopped: everything it
 *  passed is neither an opener nor a closer, so every character is visited a
 *  bounded number of times. */
function scanQuoted(text: string, kind: QuoteKind, found: (start: number, end: number) => void): void {
  const n = text.length;
  let i = 0;
  while (i < n) {
    if (
      text.charCodeAt(i) !== kind.open ||
      (kind.wordBounded && i > 0 && isAsciiAlnum(text.charCodeAt(i - 1)))
    ) {
      i++;
      continue;
    }
    let k = i + 1;
    let matched = false;
    for (; k < n; k++) {
      const code = text.charCodeAt(k);
      if (code === kind.close) {
        const length = k - i - 1;
        matched =
          length >= 1 &&
          length <= MAX_QUOTED_CHARS &&
          !(kind.wordBounded && isAsciiAlnum(text.charCodeAt(k + 1)));
        break;
      }
      if (code === kind.open || code === 0x0a || code === 0x0d || k - i - 1 >= MAX_QUOTED_CHARS) break;
    }
    if (matched) {
      found(i + 1, k);
      i = k + 1;
    } else {
      i = k;
    }
  }
}

/** Whether `text[start, end)` holds a separator or a dot. `plausiblePath`
 *  accepts a name only with one of them (a separator, or the dot of an
 *  extension), and a position suffix or an assignment prefix only shortens the
 *  token, so a token with none can never be a path. Almost every word of
 *  ordinary output is such a token, and one pass here spares it the several the
 *  full check makes. */
function hasPathMark(text: string, start: number, end: number): boolean {
  for (let i = start; i < end; i++) {
    const code = text.charCodeAt(i);
    if (code === 0x2e || code === 0x2f || code === 0x5c) return true;
  }
  return false;
}

/** Calls `found` with each unquoted token: a run of non-stop characters, plus
 *  a `(12)` / `(12,5)` position directly after it. */
function scanTokens(text: string, found: (start: number, end: number) => void): void {
  const n = text.length;
  let i = 0;
  while (i < n) {
    if (isTokenStop(text.charCodeAt(i))) {
      i++;
      continue;
    }
    const start = i;
    while (i < n && !isTokenStop(text.charCodeAt(i))) i++;
    if (text.charCodeAt(i) === 0x28) {
      const tail = parenPositionEnd(text, i);
      if (tail !== -1) i = tail;
    }
    found(start, i);
  }
}

/** The end of a `(12)` or `(12,5)` whose `(` is at `open`, or -1. */
function parenPositionEnd(text: string, open: number): number {
  let j = digitsEnd(text, open + 1);
  if (j === open + 1) return -1;
  if (text.charCodeAt(j) === 0x2c) {
    const colEnd = digitsEnd(text, j + 1);
    if (colEnd > j + 1) j = colEnd;
  }
  return text.charCodeAt(j) === 0x29 ? j + 1 : -1;
}

function digitsEnd(text: string, from: number): number {
  let j = from;
  while (isAsciiDigit(text.charCodeAt(j))) j++;
  return j;
}

/** Where the digits ending just before `end` begin (`end` when there are none),
 *  never reaching below `floor`. */
function digitsStart(text: string, end: number, floor: number): number {
  let j = end;
  while (j > floor && isAsciiDigit(text.charCodeAt(j - 1))) j--;
  return j;
}

/** The line number of a Python traceback's `"path", line N` whose closing quote
 *  sits just before `at`. */
function pythonLineAfter(text: string, at: number): number | undefined {
  if (!text.startsWith(PYTHON_LINE_PREFIX, at)) return undefined;
  const from = at + PYTHON_LINE_PREFIX.length;
  const limit = Math.min(text.length, at + PYTHON_LINE_REACH);
  let j = from;
  while (j < limit && isAsciiDigit(text.charCodeAt(j))) j++;
  return j > from ? inRange(text.slice(from, j), MAX_LINE_NUMBER) : undefined;
}

/** The offset of `VALUE` in a `NAME=VALUE`, `-NAME=VALUE` or `--NAME=VALUE`
 *  token, or -1. */
function assignmentValueStart(token: string): number {
  let i = 0;
  while (token.charCodeAt(i) === 0x2d) i++;
  if (i > 2 || !isAsciiLetter(token.charCodeAt(i))) return -1;
  i++;
  for (;;) {
    const code = token.charCodeAt(i);
    if (!isWordChar(code) && code !== 0x2d) break;
    i++;
  }
  return token.charCodeAt(i) === 0x3d && i + 1 < token.length ? i + 1 : -1;
}

function maskRanges(text: string, ranges: readonly { start: number; end: number }[]): string {
  const parts: string[] = [];
  let at = 0;
  for (const r of ranges) {
    parts.push(text.slice(at, r.start), " ".repeat(r.end - r.start));
    at = r.end;
  }
  parts.push(text.slice(at));
  return parts.join("");
}

export function isFileUrl(token: string): boolean {
  return startsWithIgnoreCase(token, "file:///");
}

export function decodeFileUrlPath(token: string, platform: NodeJS.Platform): string | undefined {
  let decoded: string;
  try {
    decoded = decodeURIComponent(token.slice("file://".length));
  } catch {
    return undefined;
  }
  if (platform === "win32" && decoded[0] === "/" && hasDriveLetterAt(decoded, 1)) decoded = decoded.slice(1);
  return decoded;
}

function isUrlStop(code: number): boolean {
  if (code <= 0x20 || code === 0x7f) return true;
  if (code > 0x7f) return isWhitespace(code);
  return code === 0x3c || code === 0x3e || code === 0x22 || code === 0x27 || code === 0x60;
}

/** The end of the `http://` / `https://` scheme starting at `i` (any letter
 *  case), or -1. The `h` must not continue a word. */
function urlSchemeEnd(text: string, i: number): number {
  if (i > 0 && isWordChar(text.charCodeAt(i - 1))) return -1;
  if (!startsWithIgnoreCase(text, "http", i)) return -1;
  let j = i + 4;
  if (text.charCodeAt(j) === 0x73 || text.charCodeAt(j) === 0x53) j++;
  return text.startsWith("://", j) ? j + 3 : -1;
}

/** A URL run is cut at an unbalanced `)` and scanning resumes right there, so
 *  a run of cuts is still one pass over the line. */
function scanUrls(text: string): ScannedUrl[] {
  const out: ScannedUrl[] = [];
  let i = 0;
  while (i < text.length) {
    const code = text.charCodeAt(i);
    const bodyStart = code === 0x68 || code === 0x48 ? urlSchemeEnd(text, i) : -1;
    if (bodyStart === -1) {
      i++;
      continue;
    }
    const start = i;
    i = bodyStart;
    let opens = 0;
    let closes = 0;
    while (i < text.length) {
      const ch = text.charCodeAt(i);
      if (isUrlStop(ch)) break;
      if (ch === 0x28) opens++;
      else if (ch === 0x29) {
        if (closes + 1 > opens) break;
        closes++;
      }
      i++;
    }
    const url = trimUrl(text.slice(start, i));
    if (!urlHasHost(url)) continue;
    out.push({ start, end: start + url.length, url });
  }
  return out;
}

function urlHasHost(url: string): boolean {
  const hostStart = url.indexOf("://") + 3;
  if (hostStart >= url.length) return false;
  const first = url[hostStart];
  return first !== "/" && first !== "?" && first !== "#";
}

/** Cuts at the first `)` with no opener before it, then drops the punctuation
 *  a sentence leaves after a URL. Mirrors `_trimSentencePunctuation` in
 *  `wrapped_url.dart`, whose trailing-`)` rule is vacuous here because the cut
 *  already guarantees no unbalanced closer survives. */
export function trimUrl(url: string): string {
  let opens = 0;
  let closes = 0;
  let end = url.length;
  for (let i = 0; i < url.length; i++) {
    const ch = url[i];
    if (ch === "(") opens++;
    else if (ch === ")") {
      if (closes + 1 > opens) {
        end = i;
        break;
      }
      closes++;
    }
  }
  while (end > 0 && ".,;:!?".includes(url[end - 1]!)) end--;
  return url.slice(0, end);
}

/** Drops the punctuation prose leaves after a path. A `)` goes only while it
 *  has no opener, so `Read(a.ts)`-style tokens and a `(12,5)` position tail
 *  keep theirs. Counts are taken once: re-counting per dropped character would
 *  make a run of `)` quadratic. */
export function trimTrailingPunct(token: string): string {
  let opens = 0;
  let closes = 0;
  for (let i = 0; i < token.length; i++) {
    const ch = token[i];
    if (ch === "(") opens++;
    else if (ch === ")") closes++;
  }
  let end = token.length;
  for (;;) {
    while (end > 0 && ".,;:!?".includes(token[end - 1]!)) end--;
    if (
      end > 0 &&
      token[end - 1] === ")" &&
      closes > opens &&
      !endsWithParenPosition(token, Math.max(0, end - PAREN_POSITION_WINDOW), end)
    ) {
      end--;
      closes--;
      continue;
    }
    break;
  }
  return token.slice(0, end);
}

/** Whether `text[floor, end)` ends with a `(12)` or `(12,5)` position. */
function endsWithParenPosition(text: string, floor: number, end: number): boolean {
  const close = end - 1;
  if (close < floor || text.charCodeAt(close) !== 0x29) return false;
  const last = digitsStart(text, close, floor);
  if (last === close) return false;
  const before = last - 1;
  if (before < floor) return false;
  if (text.charCodeAt(before) === 0x28) return true;
  if (text.charCodeAt(before) !== 0x2c) return false;
  const first = digitsStart(text, before, floor);
  return first < before && first - 1 >= floor && text.charCodeAt(first - 1) === 0x28;
}

function inRange(raw: string | undefined, max: number): number | undefined {
  if (raw === undefined) return undefined;
  const n = Number(raw);
  return Number.isSafeInteger(n) && n >= 1 && n <= max ? n : undefined;
}

interface PositionSuffix {
  path: string;
  line: string;
  col?: string;
}

/** `path(12)` / `path(12,5)`: the shape MSBuild and the TypeScript compiler
 *  print. */
function parenSuffix(token: string): PositionSuffix | undefined {
  const close = token.length - 1;
  if (token.charCodeAt(close) !== 0x29) return undefined;
  const last = digitsStart(token, close, 0);
  if (last === close) return undefined;
  const before = last - 1;
  if (token.charCodeAt(before) === 0x28) {
    return before >= 1 ? { path: token.slice(0, before), line: token.slice(last, close) } : undefined;
  }
  if (token.charCodeAt(before) !== 0x2c) return undefined;
  const first = digitsStart(token, before, 0);
  const open = first - 1;
  if (first === before || open < 1 || token.charCodeAt(open) !== 0x28) return undefined;
  return { path: token.slice(0, open), line: token.slice(first, before), col: token.slice(last, close) };
}

/** `path#L12`, `path#L12C5`, and a `-L20` / `-L20C3` range end, which is
 *  accepted and dropped. Only the LAST `#` can start one, because the suffix
 *  holds no other `#`. */
function hashSuffix(token: string): PositionSuffix | undefined {
  const hash = token.lastIndexOf("#");
  if (hash < 1 || token.charCodeAt(hash + 1) !== 0x4c) return undefined;
  const lineStart = hash + 2;
  let j = digitsEnd(token, lineStart);
  if (j === lineStart) return undefined;
  const line = token.slice(lineStart, j);
  let col: string | undefined;
  if (token.charCodeAt(j) === 0x43) {
    const colEnd = digitsEnd(token, j + 1);
    if (colEnd === j + 1) return undefined;
    col = token.slice(j + 1, colEnd);
    j = colEnd;
  }
  if (token.charCodeAt(j) === 0x2d) {
    j++;
    if (token.charCodeAt(j) === 0x4c) j++;
    const rangeEnd = digitsEnd(token, j);
    if (rangeEnd === j) return undefined;
    j = rangeEnd;
    if (token.charCodeAt(j) === 0x43) {
      const rangeColEnd = digitsEnd(token, j + 1);
      if (rangeColEnd === j + 1) return undefined;
      j = rangeColEnd;
    }
  }
  if (j !== token.length) return undefined;
  const suffix: PositionSuffix = { path: token.slice(0, hash), line };
  if (col !== undefined) suffix.col = col;
  return suffix;
}

/** `path:12`, `path:12:5`, and either followed by `:` and anything (a
 *  compiler's message). The first `:` that starts such a tail wins, so a drive
 *  letter's colon stays in the path. */
function colonSuffix(token: string): PositionSuffix | undefined {
  for (let colon = token.indexOf(":", 1); colon !== -1; colon = token.indexOf(":", colon + 1)) {
    const lineEnd = digitsEnd(token, colon + 1);
    if (lineEnd === colon + 1) continue;
    const line = token.slice(colon + 1, lineEnd);
    if (lineEnd === token.length) return { path: token.slice(0, colon), line };
    if (token.charCodeAt(lineEnd) !== 0x3a) continue;
    const colEnd = digitsEnd(token, lineEnd + 1);
    const suffix: PositionSuffix = { path: token.slice(0, colon), line };
    // A second number counts as the column only when it ends the token or is
    // itself followed by `:`; otherwise it is the start of the message.
    if (colEnd > lineEnd + 1 && (colEnd === token.length || token.charCodeAt(colEnd) === 0x3a)) {
      suffix.col = token.slice(lineEnd + 1, colEnd);
    }
    return suffix;
  }
  return undefined;
}

function positionSuffix(token: string): PositionSuffix | undefined {
  // A quoted run may hold U+2028/U+2029, and no position suffix spans a line.
  if (hasLineTerminator(token)) return undefined;
  return parenSuffix(token) ?? hashSuffix(token) ?? colonSuffix(token);
}

/** Splits an optional line/column suffix off `token` and decides whether what
 *  is left can plausibly be a path. The rules are textual heuristics: they
 *  decide what is worth a stat, never what is safe to open. */
export function splitPathToken(
  token: string,
  opts: { platform?: NodeJS.Platform; followedByParen?: boolean } = {},
): PathClaimText | undefined {
  const platform = opts.platform ?? process.platform;
  if (token.length === 0 || token.length > MAX_TOKEN_CHARS) return undefined;

  let path = token;
  let line: number | undefined;
  let col: number | undefined;
  const suffix = positionSuffix(token);
  if (suffix) {
    path = suffix.path;
    line = inRange(suffix.line, MAX_LINE_NUMBER);
    col = line === undefined ? undefined : inRange(suffix.col, MAX_COLUMN_NUMBER);
  }

  if (!plausiblePath(path, platform, opts.followedByParen === true)) return undefined;

  // `git diff` prints `a/src/x.ts` and `b/src/x.ts`; the stripped form is the
  // likelier file, the printed form still wins if it is the one that exists.
  const isDiffSide = (path[0] === "a" || path[0] === "b") && path[1] === "/" && path.length > 2 && !hasLineTerminator(path, 2);
  const claim: PathClaimText = { variants: isDiffSide ? [path.slice(2), path] : [path] };
  if (line !== undefined) claim.line = line;
  if (col !== undefined) claim.col = col;
  return claim;
}

function plausiblePath(path: string, platform: NodeJS.Platform, followedByParen: boolean): boolean {
  if (path.length === 0 || path.length > MAX_PRINTED_PATH_CHARS) return false;
  let hasLetter = false;
  for (let i = 0; i < path.length; i++) {
    const code = path.charCodeAt(i);
    if (code <= 0x1f || code === 0x7f) return false;
    switch (code) {
      case 0x2a: // *
      case 0x3f: // ?
      case 0x22: // "
      case 0x3c: // <
      case 0x3e: // >
      case 0x7c: // |
        return false;
    }
    if (isAsciiLetter(code)) hasLetter = true;
  }
  if (!hasLetter) return false;
  if (path[0] === "$" || path[0] === "%") return false;
  for (let at = path.indexOf("@"); at !== -1; at = path.indexOf("@", at + 1)) {
    if (at > 0 && path[at - 1] !== "/" && path[at - 1] !== "\\") return false;
  }
  if (isSeparator(path[0]) && isSeparator(path[1])) return false;
  // `package:foo`, `dart:io`, `git@host:org/repo`, `C:a.png` and `x::$DATA`
  // all carry a colon past the one a drive prefix may own.
  if (path.indexOf(":", isDriveAbsolute(path) ? 3 : 0) !== -1) return false;
  // A POSIX-absolute path on Windows resolves to the current drive and a
  // folder that practically never exists; it is almost always a URL path.
  if (platform === "win32" && path[0] === "/" && !isSeparator(path[1])) return false;
  const hasSeparator = path.includes("/") || path.includes("\\");
  if (!hasSeparator && (!hasExtension(path) || followedByParen)) return false;
  return true;
}

/** A bare name counts as a file only with an extension-shaped tail: 1-8
 *  lowercase letters and digits starting with a letter, or 1-4 capitals
 *  (`Makefile.PL`), after a dot that does not start the name. */
function hasExtension(path: string): boolean {
  const dot = path.lastIndexOf(".");
  if (dot < 1) return false;
  const before = path[dot - 1];
  if (before === "." || isSeparator(before)) return false;
  const length = path.length - dot - 1;
  const first = path.charCodeAt(dot + 1);
  if (isAsciiLower(first)) {
    if (length > 8) return false;
    for (let i = dot + 2; i < path.length; i++) {
      const code = path.charCodeAt(i);
      if (!isAsciiLower(code) && !isAsciiDigit(code)) return false;
    }
    return true;
  }
  if (isAsciiUpper(first)) {
    if (length > 4) return false;
    for (let i = dot + 2; i < path.length; i++) if (!isAsciiUpper(path.charCodeAt(i))) return false;
    return true;
  }
  return false;
}

/** The shared safety refusal, applied before any filesystem call. Unlike the
 *  heuristics above it is about what a path could DO: on Windows a UNC or
 *  device path makes the OS open a network session and offer the user's
 *  credentials to whichever host the path names. POSIX keeps `:` and `//`
 *  legal because they are ordinary filename characters there. */
export function isRefusedPathShape(path: string, platform: NodeJS.Platform = process.platform): boolean {
  for (let i = 0; i < path.length; i++) {
    const code = path.charCodeAt(i);
    if (code <= 0x1f || (code >= 0x7f && code <= 0x9f)) return true;
  }
  if (platform !== "win32") return false;
  if (isSeparator(path[0]) && isSeparator(path[1])) return true;
  return path.indexOf(":", isDriveAbsolute(path) ? 3 : 0) !== -1;
}

/** The directory an OSC 7 report names, when it is on this machine and
 *  absolute. Containment within the checkout is the caller's decision. */
export function parseOsc7(
  data: string,
  hostname: string,
  platform: NodeJS.Platform = process.platform,
): string | undefined {
  const scheme = "file://";
  if (!startsWithIgnoreCase(data, scheme)) return undefined;
  const slash = data.indexOf("/", scheme.length);
  if (slash === -1 || hasLineTerminator(data, slash)) return undefined;
  const host = data.slice(scheme.length, slash).toLowerCase();
  if (host !== "" && host !== "localhost" && host !== hostname.toLowerCase()) return undefined;
  let path: string;
  try {
    path = decodeURIComponent(data.slice(slash));
  } catch {
    return undefined;
  }
  if (
    platform === "win32" &&
    path[0] === "/" &&
    hasDriveLetterAt(path, 1) &&
    (path.length === 3 || isSeparator(path[3]))
  ) {
    path = path.slice(1);
  }
  if (path.length === 0 || path.length > MAX_OSC7_PATH_CHARS) return undefined;
  const absolute = platform === "win32" ? isDriveAbsolute(path) : path[0] === "/";
  if (!absolute) return undefined;
  // A leading double separator is a UNC root on Windows and a network root on
  // some POSIX layers; no shell reports its cwd that way.
  if (isSeparator(path[0]) && isSeparator(path[1])) return undefined;
  if (isRefusedPathShape(path, platform)) return undefined;
  return path;
}

export function encodePathLink(l: {
  path: string;
  base: PrintedPathBase;
  kind: PrintedPathKind;
  line?: number;
  col?: number;
}): string | undefined {
  if (l.path.length === 0 || l.path.length > MAX_PRINTED_PATH_CHARS) return undefined;
  let encoded: string;
  try {
    encoded = encodeURIComponent(l.path);
  } catch {
    return undefined;
  }
  let uri = `${PATH_LINK_SCHEME}?p=${encoded}&b=${l.base}&k=${l.kind}`;
  const line = l.line;
  if (line !== undefined && Number.isInteger(line) && line >= 1 && line <= MAX_LINE_NUMBER) {
    uri += `&n=${line}`;
    const col = l.col;
    if (col !== undefined && Number.isInteger(col) && col >= 1 && col <= MAX_COLUMN_NUMBER) {
      uri += `&c=${col}`;
    }
  }
  // Every character is ASCII by construction, so length is the byte count.
  return uri.length <= MAX_LINK_URI_BYTES ? uri : undefined;
}

/** Percent-encodes every character outside the printable ASCII range as UTF-8
 *  and keeps existing `%XX` escapes as written. */
export function encodeUrlLink(url: string): string | undefined {
  if (url.length === 0) return undefined;
  const encoder = new TextEncoder();
  let out = URL_LINK_SCHEME;
  for (const ch of url) {
    const code = ch.codePointAt(0)!;
    if (code >= 0x21 && code <= 0x7e) {
      out += ch;
      continue;
    }
    for (const b of encoder.encode(ch)) out += `%${b.toString(16).toUpperCase().padStart(2, "0")}`;
    if (out.length > MAX_LINK_URI_BYTES) return undefined;
  }
  return out.length <= MAX_LINK_URI_BYTES ? out : undefined;
}

export function isAntgridLinkUri(uri: string): boolean {
  return startsWithIgnoreCase(uri, "antgrid-");
}
