// Plain-text path and URL detection for terminal output, with no filesystem
// access: everything here is a textual judgement, and the stat that confirms a
// guess lives elsewhere.
//
// The `antgrid-path:` / `antgrid-url:` URI grammar is mirrored by hand in
// `app/lib/util/terminal_links.dart`, and `WRAP_EDGE_SLACK` / the URL rules
// copy `app/lib/util/wrapped_url.dart`. No suite spans those files, so change
// them together.

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

/** A token this long cannot be a path (the path cap is far below it) and
 *  skipping it before any regex runs keeps a pathological line linear. */
const MAX_TOKEN_CHARS = 4096;
const MAX_OSC7_PATH_CHARS = 4096;

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

const QUOTE_PATTERNS: readonly RegExp[] = [
  /"([^"\r\n]{1,1024})"/g,
  /`([^`\r\n]{1,1024})`/g,
  // An apostrophe inside a word ("don't", "it's") is not a quote; requiring a
  // non-word neighbour on the outside of each mark is what tells them apart.
  /(?<![A-Za-z0-9])'([^'\r\n]{1,1024})'(?![A-Za-z0-9])/g,
  /‘([^‘’\r\n]{1,1024})’/g,
  /“([^“”\r\n]{1,1024})”/g,
];

const UNQUOTED_TOKEN = /[^\s"'`()\[\]{}<>|*‘’“”]+(?:\(\d+(?:,\d+)?\))?/g;
const ASSIGNMENT = /^-{0,2}[A-Za-z][\w-]*=(.+)$/;
const PYTHON_LINE_SUFFIX = /^, line (\d+)/;
const URL_START = /\bhttps?:\/\//gi;
const NUMERIC_TAIL = /\(\d+(?:,\d+)?\)$/;

const SUFFIX_PAREN = /^(.+?)\((\d+)(?:,(\d+))?\)$/;
const SUFFIX_HASH = /^(.+?)#L(\d+)(?:C(\d+))?(?:-L?\d+(?:C\d+)?)?$/;
const SUFFIX_COLON = /^(.+?):(\d+)(?::(\d+))?(?::.*)?$/;

const EXTENSION = /[^./\\]\.(?:[a-z][a-z0-9]{0,7}|[A-Z]{1,4})$/;
const WS = /\s/;

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

  for (const pattern of QUOTE_PATTERNS) {
    for (const m of text.matchAll(pattern)) {
      const inner = m[1]!;
      const start = m.index! + 1;
      const end = start + inner.length;
      if (overlapsUrl(start, end)) continue;
      const claim = splitPathToken(inner, { platform });
      if (!claim) continue;
      if (claim.line === undefined) {
        const py = PYTHON_LINE_SUFFIX.exec(text.slice(end + 1, end + 25));
        const line = py ? Number(py[1]) : undefined;
        if (line !== undefined && line >= 1 && line <= MAX_LINE_NUMBER) claim.line = line;
      }
      paths.push({ start, end, quoted: true, text: claim, followedByParen: false });
    }
  }

  const masked = urls.length > 0 ? maskRanges(text, urls) : text;
  for (const m of masked.matchAll(UNQUOTED_TOKEN)) {
    const raw = m[0];
    if (raw.length > MAX_TOKEN_CHARS) continue;
    const followedByParen = masked[m.index! + raw.length] === "(";

    let token = trimTrailingPunct(raw);
    if (token.length === 0) continue;
    let start = m.index!;
    const end = start + token.length;

    const assignment = ASSIGNMENT.exec(token);
    if (assignment) {
      start += token.length - assignment[1]!.length;
      token = assignment[1]!;
    }

    if (/^file:\/\/\//i.test(token)) {
      const decoded = decodeFileUrlPath(token, platform);
      if (decoded === undefined) continue;
      token = decoded;
    }
    if (token.includes("://")) continue;

    const claim = splitPathToken(token, { platform, followedByParen });
    if (claim) paths.push({ start, end, quoted: false, text: claim, followedByParen });
  }

  paths.sort((a, b) => a.start - b.start || b.end - a.end || Number(b.quoted) - Number(a.quoted));
  return { paths, urls };
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

export function decodeFileUrlPath(token: string, platform: NodeJS.Platform): string | undefined {
  let decoded: string;
  try {
    decoded = decodeURIComponent(token.slice("file://".length));
  } catch {
    return undefined;
  }
  if (platform === "win32" && /^\/[A-Za-z]:/.test(decoded)) decoded = decoded.slice(1);
  return decoded;
}

function isUrlStop(ch: string): boolean {
  const code = ch.charCodeAt(0);
  if (code <= 0x20 || code === 0x7f) return true;
  if (code > 0x7f) return WS.test(ch);
  return ch === "<" || ch === ">" || ch === '"' || ch === "'" || ch === "`";
}

/** Walked by hand rather than matched: a URL run is cut at an unbalanced `)`
 *  and scanning resumes right there, and a regex that re-finds the tail of a
 *  long run for every cut would be quadratic on a line made of them. */
function scanUrls(text: string): ScannedUrl[] {
  const out: ScannedUrl[] = [];
  const finder = new RegExp(URL_START);
  let m: RegExpExecArray | null;
  while ((m = finder.exec(text)) !== null) {
    const start = m.index;
    const bodyStart = start + m[0].length;
    let i = bodyStart;
    let opens = 0;
    let closes = 0;
    while (i < text.length) {
      const ch = text[i]!;
      if (isUrlStop(ch)) break;
      if (ch === "(") opens++;
      else if (ch === ")") {
        if (closes + 1 > opens) break;
        closes++;
      }
      i++;
    }
    finder.lastIndex = i;
    const url = trimUrl(text.slice(start, i));
    if (!urlHasHost(url)) continue;
    out.push({ start, end: start + url.length, url });
  }
  return out;
}

function urlHasHost(url: string): boolean {
  const rest = url.slice(url.indexOf("://") + 3);
  const hostEnd = rest.search(/[/?#]/);
  return (hostEnd === -1 ? rest : rest.slice(0, hostEnd)).length > 0;
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
      !NUMERIC_TAIL.test(token.slice(Math.max(0, end - 64), end))
    ) {
      end--;
      closes--;
      continue;
    }
    break;
  }
  return token.slice(0, end);
}

function inRange(raw: string | undefined, max: number): number | undefined {
  if (raw === undefined) return undefined;
  const n = Number(raw);
  return Number.isSafeInteger(n) && n >= 1 && n <= max ? n : undefined;
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
  const m = SUFFIX_PAREN.exec(token) ?? SUFFIX_HASH.exec(token) ?? SUFFIX_COLON.exec(token);
  if (m) {
    path = m[1]!;
    line = inRange(m[2], MAX_LINE_NUMBER);
    col = line === undefined ? undefined : inRange(m[3], MAX_COLUMN_NUMBER);
  }

  if (!plausiblePath(path, platform, opts.followedByParen === true)) return undefined;

  const diff = /^[ab]\/(.+)$/.exec(path);
  const claim: PathClaimText = { variants: diff ? [diff[1]!, path] : [path] };
  if (line !== undefined) claim.line = line;
  if (col !== undefined) claim.col = col;
  return claim;
}

function plausiblePath(path: string, platform: NodeJS.Platform, followedByParen: boolean): boolean {
  if (path.length === 0 || path.length > MAX_PRINTED_PATH_CHARS) return false;
  if (!/[A-Za-z]/.test(path)) return false;
  if (/[\x00-\x1f\x7f*?"<>|]/.test(path)) return false;
  if (path[0] === "$" || path[0] === "%") return false;
  for (let at = path.indexOf("@"); at !== -1; at = path.indexOf("@", at + 1)) {
    if (at > 0 && path[at - 1] !== "/" && path[at - 1] !== "\\") return false;
  }
  if (isSeparator(path[0]) && isSeparator(path[1])) return false;
  // `package:foo`, `dart:io`, `git@host:org/repo`, `C:a.png` and `x::$DATA`
  // all carry a colon past the one a drive prefix may own.
  if (path.replace(/^[A-Za-z]:[\\/]/, "").includes(":")) return false;
  // A POSIX-absolute path on Windows resolves to the current drive and a
  // folder that practically never exists; it is almost always a URL path.
  if (platform === "win32" && path[0] === "/" && !isSeparator(path[1])) return false;
  const hasSeparator = path.includes("/") || path.includes("\\");
  if (!hasSeparator && (!EXTENSION.test(path) || followedByParen)) return false;
  return true;
}

function isSeparator(ch: string | undefined): boolean {
  return ch === "/" || ch === "\\";
}

/** The shared safety refusal, applied before any filesystem call. Unlike the
 *  heuristics above it is about what a path could DO: on Windows a UNC or
 *  device path makes the OS open a network session and offer the user's
 *  credentials to whichever host the path names. POSIX keeps `:` and `//`
 *  legal because they are ordinary filename characters there. */
export function isRefusedPathShape(path: string, platform: NodeJS.Platform = process.platform): boolean {
  if (/[\x00-\x1f\x7f-\x9f]/.test(path)) return true;
  if (platform !== "win32") return false;
  if (isSeparator(path[0]) && isSeparator(path[1])) return true;
  return path.replace(/^[A-Za-z]:[\\/]/, "").includes(":");
}

/** The directory an OSC 7 report names, when it is on this machine and
 *  absolute. Containment within the checkout is the caller's decision. */
export function parseOsc7(
  data: string,
  hostname: string,
  platform: NodeJS.Platform = process.platform,
): string | undefined {
  const m = /^file:\/\/([^/]*)(\/.*)$/i.exec(data);
  if (!m) return undefined;
  const host = m[1]!.toLowerCase();
  if (host !== "" && host !== "localhost" && host !== hostname.toLowerCase()) return undefined;
  let path: string;
  try {
    path = decodeURIComponent(m[2]!);
  } catch {
    return undefined;
  }
  if (platform === "win32" && /^\/[A-Za-z]:(?:[\\/]|$)/.test(path)) path = path.slice(1);
  if (path.length === 0 || path.length > MAX_OSC7_PATH_CHARS) return undefined;
  const absolute = platform === "win32" ? /^[A-Za-z]:[\\/]/.test(path) : path[0] === "/";
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
  return /^antgrid-/i.test(uri);
}
