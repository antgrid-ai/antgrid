import { open, stat } from "node:fs/promises";

// Only the tail of a transcript is ever needed (recent turns, or the last
// assistant message), so never load a multi-MB file in full.
export const TAIL_BYTES = 256 * 1024;

// A notification body longer than this goes unread. Deliberately tighter than
// push-dispatcher's MAX_BODY_LEN, which is an FCM payload-size guard rather
// than a readability choice — the two answer different questions.
export const MAX_NOTIFICATION_BODY_LEN = 200;

/**
 * Trailing TAIL_BYTES of a file as UTF-8, with any partial leading line dropped
 * so every returned line is parseable. Returns "" on any error.
 */
export async function readTranscriptTail(path: string): Promise<string> {
  let fh: Awaited<ReturnType<typeof open>> | undefined;
  try {
    // isFile gates the open(): opening a FIFO blocks until a writer arrives,
    // and callers reach this from the /notify request handler with a path they
    // chose, so a non-regular file would hang the server rather than the caller.
    const info = await stat(path);
    if (!info.isFile()) return "";
    const start = info.size > TAIL_BYTES ? info.size - TAIL_BYTES : 0;
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
