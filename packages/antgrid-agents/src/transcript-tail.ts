import { open, stat } from "node:fs/promises";

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

// A notification body longer than this goes unread. Deliberately tighter than
// push-dispatcher's MAX_BODY_LEN, which is an FCM payload-size guard rather
// than a readability choice — the two answer different questions.
export const MAX_NOTIFICATION_BODY_LEN = 200;

/**
 * Trailing `maxBytes` of a file as UTF-8, with any partial leading line dropped
 * so every returned line is parseable, plus whether the window reached the
 * file's start — which is the only thing that tells an escalating reader there
 * is nothing further back to find. Returns "" on any error, reported as
 * `fromStart` so a caller stops rather than re-reading a file it cannot open.
 */
export async function readTranscriptTailWindow(
  path: string,
  maxBytes: number = TAIL_BYTES,
): Promise<{ raw: string; fromStart: boolean }> {
  let fh: Awaited<ReturnType<typeof open>> | undefined;
  try {
    // isFile gates the open(): opening a FIFO blocks until a writer arrives,
    // and callers reach this from the /notify request handler with a path they
    // chose, so a non-regular file would hang the server rather than the caller.
    const info = await stat(path);
    if (!info.isFile()) return { raw: "", fromStart: true };
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
    return { raw, fromStart: start === 0 };
  } catch {
    return { raw: "", fromStart: true };
  } finally {
    await fh?.close();
  }
}

/**
 * Trailing TAIL_BYTES of a file as UTF-8, with any partial leading line dropped
 * so every returned line is parseable. Returns "" on any error.
 */
export async function readTranscriptTail(path: string, maxBytes?: number): Promise<string> {
  return (await readTranscriptTailWindow(path, maxBytes)).raw;
}

/**
 * Items parsed out of the transcript's tail, widening the window until `parse`
 * yields `want` of them or the window reaches the file's start.
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
): Promise<T[]> {
  let best: T[] = [];
  for (const bytes of TAIL_WINDOW_BYTES) {
    const { raw, fromStart } = await readTranscriptTailWindow(path, bytes);
    if (!raw) {
      // Empty means one of two opposite things, and only `fromStart` separates
      // them. A file that could not be read reports itself as `fromStart`, so
      // there is nothing further back to find and the ladder stops. A window
      // that did NOT reach the start is empty only because it landed inside a
      // single line longer than itself — one oversized tool result — which is
      // precisely the case this ladder exists to widen past, so it continues.
      if (fromStart) break;
      continue;
    }
    const out = parse(raw);
    if (out.length > best.length) best = out;
    if (best.length >= want || fromStart) break;
  }
  return best;
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
