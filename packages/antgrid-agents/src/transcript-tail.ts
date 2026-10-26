import { open, stat, type FileHandle } from "node:fs/promises";

// Only the tail of a transcript is ever needed (recent turns, or the last
// assistant message), so never load a multi-MB file in full.
export const TAIL_BYTES = 256 * 1024;

// Widening windows for a reader that wants N MESSAGES rather than N bytes.
//
// A byte window is a poor proxy for a message count, because an agent
// transcript's tool output shares its lines with its prose: one 125KB tool
// result can fill half the window and yield nothing to read. Measured over 928
// local transcripts larger than TAIL_BYTES, that window returned FEWER than the
// twenty messages asked for in 98% of them, with a MEDIAN OF ONE — which is what
// a supervising judge was reasoning over.
//
// The ladder stops at 4MB because the yield does: on a 120-transcript sample,
// 1MB lifted the median to 5 and the share filling the 12k-char decide budget
// from 28/120 to 76/120, 4MB reached 77/120, and 16MB measured identical to 4MB.
// A ceiling is not optional — twenty enormous messages would otherwise be an
// unbounded read on the judge's hot path — so this is a wider bound, never no
// bound.
export const TAIL_WINDOW_BYTES: readonly number[] = [TAIL_BYTES, 1024 * 1024, 4 * 1024 * 1024];

// The windows count only lines a reader can use, or ten base64 image results
// would fill the widest one and push the conversation out of it. A line longer
// than this is a payload, skipped unread unless the reader claims it: in real
// transcripts the longest typed Claude prompt was 151KB, while Codex tool
// outputs reached 1.2MB.
export const OVERSIZED_LINE_BYTES = 256 * 1024;

// How far back a reader looks, skipped lines included. Skipping a line still
// means finding its start, so this bounds the read on the judge's hot path
// while the windows bound what is parsed.
export const TAIL_SCAN_BYTES = 64 * 1024 * 1024;

const SCAN_CHUNK_BYTES = 64 * 1024;

// Holds a Codex rollout line's top-level type, which follows its timestamp.
const LINE_HEAD_BYTES = 256;

export interface TailReadOptions {
  /** Keeps an oversized line whose first bytes show the parser needs it, such
   * as a marker that resets its state. */
  keepOversized?: (head: string) => boolean;
  /** Overrides TAIL_SCAN_BYTES. */
  scanBytes?: number;
}

// A notification body longer than this goes unread. Deliberately tighter than
// push-dispatcher's MAX_BODY_LEN, which is an FCM payload-size guard rather
// than a readability choice — the two answer different questions.
export const MAX_NOTIFICATION_BODY_LEN = 200;

/**
 * Trailing `maxBytes` of a file as UTF-8, with any partial leading line dropped
 * so every returned line is parseable. Returns "" on any error.
 */
export async function readTranscriptTail(path: string, maxBytes: number = TAIL_BYTES): Promise<string> {
  let fh: FileHandle | undefined;
  try {
    // isFile gates the open(): opening a FIFO blocks until a writer arrives,
    // and callers reach this from the /notify request handler with a path they
    // chose, so a non-regular file would hang the server rather than the caller.
    const info = await stat(path);
    if (!info.isFile()) return "";
    const start = info.size > maxBytes ? info.size - maxBytes : 0;
    fh = await open(path, "r");
    const buf = Buffer.alloc(info.size - start);
    // Decode only what was read. A transcript can shrink between the stat and
    // the read (rotation, a restarted session), and the unread remainder of the
    // zero-filled buffer would otherwise decode as trailing NULs, taking the
    // last line down with it at JSON.parse.
    const { bytesRead } = await fh.read(buf, 0, buf.length, start);
    let raw = buf.toString("utf8", 0, bytesRead);
    if (start > 0) {
      const nl = raw.indexOf("\n");
      raw = nl >= 0 ? raw.slice(nl + 1) : "";
    }
    return raw;
  } catch {
    return "";
  } finally {
    await fh?.close();
  }
}

/**
 * Items parsed out of the transcript's tail, widening the window until `parse`
 * yields `want` of them or the window reaches the file's start. A window is the
 * newest lines that fit in it, oversized ones left out (OVERSIZED_LINE_BYTES)
 * unless `keepOversized` claims them. Never throws.
 *
 * `parse` runs over a whole window rather than per line so a parser whose state
 * spans lines keeps it — codex's rollout resets its list at a `compacted`
 * marker, and a per-line contract would make that unspellable.
 *
 * The BEST result wins rather than the last, which makes widening a floor rather
 * than a gamble: a parser that discards history on a marker it finds is not
 * guaranteed to return more from more input, and nothing in this signature can
 * check that it does. Both of today's parsers happen to be monotonic; keeping
 * the best is what means a future one does not have to be.
 */
export async function readTailUntil<T>(
  path: string,
  want: number,
  parse: (raw: string) => T[],
  opts: TailReadOptions = {},
): Promise<T[]> {
  let best: T[] = [];
  let fh: FileHandle | undefined;
  try {
    // isFile gates the open, as in readTranscriptTail.
    const info = await stat(path);
    if (!info.isFile()) return [];
    const file = (fh = await open(path, "r"));
    const floor = Math.max(0, info.size - (opts.scanBytes ?? TAIL_SCAN_BYTES));
    const lines = linesFromEnd(file, info.size, floor);
    const kept: string[] = []; // newest first
    let keptBytes = 0;
    let parsed = 0;
    let next: LineSpan | undefined;
    let exhausted = false;
    for (const window of TAIL_WINDOW_BYTES) {
      while (!exhausted) {
        if (!next) {
          const step = await lines.next();
          if (step.done) {
            exhausted = true;
            break;
          }
          const span = step.value;
          if (span.end === span.start) continue;
          if (!span.bytes && !(await claims(file, span, opts.keepOversized))) continue;
          next = span;
        }
        // A line that does not fit waits for the next window. Skipping it would
        // hand the parser older lines without one it claimed, such as the
        // compaction marker that resets its state.
        const cost = next.end - next.start + 1;
        if (keptBytes + cost > window) break;
        const bytes = next.bytes ?? (await readSpan(file, next));
        kept.push(bytes.toString("utf8"));
        keptBytes += cost;
        next = undefined;
      }
      if (kept.length > parsed) {
        parsed = kept.length;
        const out = parse([...kept].reverse().join("\n"));
        if (out.length > best.length) best = out;
      }
      if (best.length >= want || exhausted) break;
    }
  } catch {
    // A read that fails partway keeps what it had parsed.
  } finally {
    await fh?.close();
  }
  return best;
}

type LineSpan = { start: number; end: number; bytes?: Buffer };

/**
 * The file's lines between `floor` and `size`, newest first, each with its
 * bytes unless it is oversized. A line that starts before `floor` is not
 * yielded, since only part of it was scanned.
 */
async function* linesFromEnd(fh: FileHandle, size: number, floor: number): AsyncGenerator<LineSpan> {
  let end = size;
  // The bytes after the current chunk of the line being assembled, dropped
  // once it is oversized.
  let pieces: Buffer[] = [];
  let cursor = size;
  while (cursor > floor) {
    const from = Math.max(floor, cursor - SCAN_CHUNK_BYTES);
    const chunk = Buffer.alloc(cursor - from);
    const { bytesRead } = await fh.read(chunk, 0, chunk.length, from);
    // The file shrank under the read, so the offsets no longer hold.
    if (bytesRead < chunk.length) return;
    let hi = chunk.length;
    // lastIndexOf takes a negative offset as counted from the end, so the
    // search stops at 0 by hand.
    for (let nl = chunk.lastIndexOf(0x0a, hi - 1); nl >= 0; nl = nl > 0 ? chunk.lastIndexOf(0x0a, nl - 1) : -1) {
      yield lineSpan(from + nl + 1, end, [chunk.subarray(nl + 1, hi), ...pieces]);
      end = from + nl;
      hi = nl;
      pieces = [];
    }
    pieces = end - from <= OVERSIZED_LINE_BYTES ? [chunk.subarray(0, hi), ...pieces] : [];
    cursor = from;
  }
  if (floor === 0) yield lineSpan(0, end, pieces);
}

function lineSpan(start: number, end: number, pieces: Buffer[]): LineSpan {
  return end - start <= OVERSIZED_LINE_BYTES ? { start, end, bytes: Buffer.concat(pieces) } : { start, end };
}

async function claims(fh: FileHandle, span: LineSpan, keep: TailReadOptions["keepOversized"]): Promise<boolean> {
  if (!keep) return false;
  const head = await readSpan(fh, { start: span.start, end: Math.min(span.end, span.start + LINE_HEAD_BYTES) });
  return keep(head.toString("utf8"));
}

async function readSpan(fh: FileHandle, span: LineSpan): Promise<Buffer> {
  const buf = Buffer.alloc(span.end - span.start);
  const { bytesRead } = await fh.read(buf, 0, buf.length, span.start);
  return buf.subarray(0, bytesRead);
}

// A closing sentence shorter than this is a stub that names no subject ("Done.",
// "Sound good?"), so the body reaches back one sentence for something to say.
const MIN_CLOSING_SENTENCE_LEN = 60;

// A boundary needs a terminator, whitespace, AND an opening character. The last
// condition is load-bearing: agent prose is dense with dotted identifiers, and a
// bare /[.!?]\s+/ reads `transcript-tail.ts and ...` as two sentences.
const SENTENCE_BOUNDARY = /(?<=[.!?])\s+(?=[A-Z"'(\[])/;

/**
 * The closing sentence of `text`, extended back one sentence when that closing
 * one is a stub, then capped to the FIRST maxChars — a sentence reads from its
 * start, so an over-long one loses its end rather than its beginning.
 */
export function closingSentences(text: string, maxChars: number): string {
  const parts = text.split(SENTENCE_BOUNDARY).filter((s) => s.trim());
  if (parts.length === 0) return "";
  const last = parts[parts.length - 1]!;
  const body =
    last.length < MIN_CLOSING_SENTENCE_LEN && parts.length > 1
      ? `${parts[parts.length - 2]} ${last}`
      : last;
  return body.slice(0, maxChars);
}
