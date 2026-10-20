import { createReadStream } from "node:fs";
import { open } from "node:fs/promises";
import { join } from "node:path";
import type { HandoffSnapshot } from "./types";

export type HandoffEvent =
  | { kind: "user"; text: string; genuine: boolean; at: string }
  | { kind: "assistant"; text: string; at: string }
  | { kind: "tool_call"; name: string; input: string; at: string }
  | { kind: "tool_result"; name?: string; output: string; isError?: boolean; at: string }
  | { kind: "compaction"; summary?: string; note?: string; at: string };

/** Push-style so the whole parse runs inside the adapter's async call, and
 * therefore inside `withAgentHost`'s AsyncLocalStorage context: an
 * AsyncIterable's body would run on `.next()`, outside it, and `agentHost()`
 * would throw. Memory stays bounded because the sink consumes each event. `at`
 * is a locator the reader can open in the raw snapshot (`file:line` or a native
 * message id). */
export type HandoffEventsFn = (
  dir: string,
  manifest: HandoffSnapshot,
  sink: (event: HandoffEvent) => void,
  signal: AbortSignal,
) => Promise<void>;

/** Parsers truncate every text field to this before emitting, so the sink never
 * holds more than a bounded number of bytes per event. */
export const EVENT_TEXT_CAP = 8 * 1024;

/** Keeps the end of an over-long field: for output and conversation text the
 * newest part is the part a continuing agent needs. */
export function capEventText(text: string, cap = EVENT_TEXT_CAP): string {
  if (text.length <= cap) return text;
  return `${text.slice(0, Math.floor(cap / 2))}\n[… ${text.length - cap} chars omitted …]\n${text.slice(text.length - Math.floor(cap / 2))}`;
}

/** Streams a JSONL file line by line, so a multi-megabyte single line parses
 * without ever holding the whole file. Unparseable lines (a torn final write)
 * are skipped; line numbers start at 1 and count them. */
export async function forEachJsonlLine(
  path: string,
  each: (lineNo: number, value: unknown) => void,
  signal: AbortSignal,
): Promise<void> {
  const decoder = new TextDecoder();
  let pending = "";
  let lineNo = 0;
  const emit = (raw: string) => {
    lineNo++;
    const line = raw.endsWith("\r") ? raw.slice(0, -1) : raw;
    if (!line.trim()) return;
    let value: unknown;
    try {
      value = JSON.parse(line);
    } catch {
      return;
    }
    each(lineNo, value);
  };
  const stream = createReadStream(path, { highWaterMark: 256 * 1024 });
  try {
    for await (const chunk of stream) {
      if (signal.aborted) throw new Error("The handoff parse ran past its deadline.");
      const text = decoder.decode(chunk as Uint8Array, { stream: true });
      let start = 0;
      let newline = text.indexOf("\n", start);
      while (newline !== -1) {
        emit(pending + text.slice(start, newline));
        pending = "";
        start = newline + 1;
        newline = text.indexOf("\n", start);
      }
      pending += text.slice(start);
    }
  } finally {
    stream.destroy();
  }
  pending += decoder.decode();
  if (pending) emit(pending);
}

const HANDOFF_PROMPT_MARKER = /^\s*Continue a task handed off from .{1,80}?\. Antgrid saved its context in two files/s;
const HANDOFF_PATH = /\.antgrid[\\/]+handoff[\\/]/;

/** True for a user text that is Antgrid's own handoff prompt, so a source that
 * was itself a handoff target keeps its real original task. Matching the path
 * as well as the template keeps a prompt that an agent echoed back reworded. */
export function isAntgridHandoffPrompt(text: string): boolean {
  return HANDOFF_PROMPT_MARKER.test(text) || HANDOFF_PATH.test(text);
}

/** The newest part of a terminal's scrollback is the part that matters. */
const SCROLLBACK_READ_BYTES = EVENT_TEXT_CAP * 4;

/** For an agent with no readable store: the scrollback file stands in as one
 * assistant event, so the excerpt still carries what the terminal last showed. */
export const scrollbackEvents: HandoffEventsFn = async (dir, manifest, sink, signal) => {
  const handle = await open(join(dir, manifest.primary), "r");
  try {
    const { size } = await handle.stat();
    const length = Math.min(size, SCROLLBACK_READ_BYTES);
    const buffer = Buffer.alloc(length);
    await handle.read(buffer, 0, length, size - length);
    if (signal.aborted) throw new Error("The handoff parse ran past its deadline.");
    const text = buffer.toString("utf8").trim();
    if (text) sink({ kind: "assistant", text: capEventText(text), at: manifest.primary });
  } finally {
    await handle.close();
  }
};
