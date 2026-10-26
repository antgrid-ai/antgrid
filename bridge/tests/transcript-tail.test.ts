import { afterAll, test, expect } from "bun:test";
import { appendFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { OVERSIZED_LINE_BYTES, readTailUntil, readTranscriptTail, TAIL_BYTES, TAIL_WINDOW_BYTES } from "../src/transcript-tail";
import {
  lastAssistantText,
  readLastClaudeMessages,
} from "../../packages/antgrid-agents/src/agents/claude-code/transcript";

const tempDirs: string[] = [];

afterAll(() => {
  for (const dir of tempDirs) rmSync(dir, { recursive: true, force: true });
});

function tempDir(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  tempDirs.push(dir);
  return dir;
}

function fixture(lines: string[]): string {
  const path = join(tempDir("tt-"), "transcript.jsonl");
  writeFileSync(path, lines.join("\n"), "utf8");
  return path;
}

function assistant(text: string): string {
  return JSON.stringify({ type: "assistant", message: { role: "assistant", content: [{ type: "text", text }] } });
}

test("returns the LAST assistant message text", async () => {
  const path = fixture([
    assistant("first turn"),
    JSON.stringify({ type: "user", message: { content: "do more" } }),
    assistant("second turn"),
  ]);
  expect(await lastAssistantText(path)).toBe("second turn");
});

test("ignores user messages", async () => {
  const path = fixture([
    assistant("the answer"),
    JSON.stringify({ type: "user", message: { content: "a later user message" } }),
  ]);
  expect(await lastAssistantText(path)).toBe("the answer");
});

test("skips a tool-only final turn with no text", async () => {
  const path = fixture([
    assistant("real summary"),
    JSON.stringify({ type: "assistant", message: { content: [{ type: "tool_use", id: "t1", name: "Bash", input: {} }] } }),
  ]);
  expect(await lastAssistantText(path)).toBe("real summary");
});

test("collapses whitespace and newlines", async () => {
  const path = fixture([assistant("line one\n\n  line two\ttabbed  ")]);
  expect(await lastAssistantText(path)).toBe("line one line two tabbed");
});

// The body answers "does this need me?", so it is built from the end of the
// turn. These pin the selection rule; the GUI showed the opening sentence is
// usually a restatement of the request, not the ask.
test("takes the closing sentence, not the opening summary", async () => {
  const closing =
    "Do you want me to add the same isFile guard to the handler path as well, or leave that for later?";
  const path = fixture([
    assistant(
      "I refactored the transcript reader and moved the bounded read into a shared module. " +
        closing,
    ),
  ]);
  expect(await lastAssistantText(path)).toBe(closing);
});

test("reaches back one sentence when the closing sentence is a stub", async () => {
  const path = fixture([
    assistant("I gated the open on isFile so a FIFO can no longer hang the handler. Sound good?"),
  ]);
  expect(await lastAssistantText(path)).toBe(
    "I gated the open on isFile so a FIFO can no longer hang the handler. Sound good?",
  );
});

// Over the 60-char stub threshold, so it carries a subject on its own.
test("a closing sentence long enough to stand alone does not reach back", async () => {
  const long = "B".repeat(70) + ".";
  const path = fixture([assistant(`First sentence here. ${long}`)]);
  expect(await lastAssistantText(path)).toBe(long);
});

// Agent prose is full of these; a naive /[.!?]\s+/ split would cut after ".ts"
// and hand the notification a fragment.
test("does not treat a dotted identifier as a sentence boundary", async () => {
  const path = fixture([
    assistant("Check transcript-tail.ts and the bridge on 127.0.0.1 for the change."),
  ]);
  expect(await lastAssistantText(path)).toBe(
    "Check transcript-tail.ts and the bridge on 127.0.0.1 for the change.",
  );
});

test("truncates the selection to maxChars, taking its FIRST chars", async () => {
  const path = fixture([assistant("A".repeat(50) + "B".repeat(50))]);
  expect(await lastAssistantText(path, 10)).toBe("A".repeat(10));
});

test("defaults to a 200-char cap", async () => {
  const path = fixture([assistant("x".repeat(500))]);
  expect((await lastAssistantText(path))!.length).toBe(200);
});

test("skips malformed lines instead of throwing", async () => {
  const path = fixture(["{not json", assistant("survived"), "}also not json"]);
  expect(await lastAssistantText(path)).toBe("survived");
});

test("missing file returns null", async () => {
  expect(await lastAssistantText(join(tmpdir(), "does-not-exist-9f3a.jsonl"))).toBeNull();
});

// The caller picks this path over HTTP, so a non-regular file must be rejected
// off the stat rather than opened — a FIFO would block the request handler.
test("a path that is not a regular file returns empty without opening it", async () => {
  const dir = join(tempDir("tt-"), "a-directory.jsonl");
  mkdirSync(dir);
  expect(await readTranscriptTail(dir)).toBe("");
});

test("no assistant message returns null", async () => {
  const path = fixture([JSON.stringify({ type: "user", message: { content: "hi" } })]);
  expect(await lastAssistantText(path)).toBeNull();
});

test("reads only the tail of an oversized file and drops the partial leading line", async () => {
  const filler = JSON.stringify({ type: "user", message: { content: "z".repeat(1000) } });
  const lines: string[] = [];
  let bytes = 0;
  while (bytes < TAIL_BYTES + 50_000) { lines.push(filler); bytes += filler.length + 1; }
  lines.push(assistant("tail message"));
  const path = fixture(lines);
  const raw = await readTranscriptTail(path);
  expect(raw.length).toBeLessThanOrEqual(TAIL_BYTES);
  // Every retained line must be complete JSON — the partial first line is dropped.
  for (const line of raw.split("\n")) {
    if (line.trim()) expect(() => JSON.parse(line)).not.toThrow();
  }
  expect(await lastAssistantText(path)).toBe("tail message");
});

test("string content (not a parts array) is read", async () => {
  const path = fixture([JSON.stringify({ type: "assistant", message: { content: "plain string body" } })]);
  expect(await lastAssistantText(path)).toBe("plain string body");
});

// A reader that wants N MESSAGES widens its window until it has them. The fixed
// TAIL_BYTES window was the handler judge's whole corpus, and a transcript's
// tool traffic shares its lines with its prose, so the window it filled held
// almost none of what the reader keeps.
function toolResult(bytes: number): string {
  return JSON.stringify({
    type: "user",
    message: { content: [{ type: "tool_result", tool_use_id: "t", content: "z".repeat(bytes) }] },
  });
}

test("widens past the first window when it yields fewer messages than asked for", async () => {
  const lines: string[] = [];
  for (let i = 0; i < 30; i++) {
    lines.push(toolResult(40_000));
    lines.push(assistant(`msg-${i}`));
  }
  const path = fixture(lines);

  // The regression this closes: one TAIL_BYTES window is nowhere near twenty.
  const inFirstWindow = (await readTranscriptTail(path))
    .split("\n")
    .filter((l) => l.includes('"text"')).length;
  expect(inFirstWindow).toBeLessThan(20);

  const msgs = await readLastClaudeMessages(path, 20);
  expect(msgs.length).toBe(20);
  expect(msgs[msgs.length - 1]).toBe("msg-29");
  expect(msgs[0]).toBe("msg-10");
});

// The worst case the ladder exists for, and the one a "stop on an empty window"
// rule silently failed: a single tool result larger than the narrowest window
// leaves it holding no line boundary at all, so the window yields "" and the
// reader must widen rather than conclude the transcript is empty.
test("widens past a window that landed inside one oversized line", async () => {
  const lines: string[] = [];
  for (let i = 0; i < 5; i++) lines.push(assistant(`msg-${i}`));
  lines.push(toolResult(TAIL_BYTES + 50_000));
  const path = fixture(lines);

  expect(await readTranscriptTail(path)).toBe("");
  expect(await readLastClaudeMessages(path, 20))
    .toEqual(["msg-0", "msg-1", "msg-2", "msg-3", "msg-4"]);
});

// Widening has to terminate on a short file as well as on a satisfied count, or
// every read of a small transcript pays for the whole ladder.
test("stops at the file's start and returns what is there", async () => {
  const path = fixture([assistant("one"), assistant("two"), assistant("three")]);
  expect(await readLastClaudeMessages(path, 20)).toEqual(["one", "two", "three"]);
});

// Claude Code 2.1.300+ records every API request in the session transcript: an
// `api-request` and `api-request-shape` per call, plus one `api-request-blob`
// per distinct system prompt, tool list or replayed turn. Blobs carry a
// `message` with text parts, so a reader that ignores `type` returns harness
// text as conversation.
function apiRequestRecords(sessionId: string, n: number): string[] {
  const hash = (i: number) => i.toString(16).padStart(64, "0");
  return [
    JSON.stringify({ type: "api-request-blob", sessionId, hash: hash(n * 10 + 1),
      message: { role: "system", content: [{ type: "text", text: `harness system prompt ${n}` }] } }),
    JSON.stringify({ type: "api-request-blob", sessionId, hash: hash(n * 10 + 2),
      message: { role: "user", content: [{ type: "text", text: `replayed reminder ${n}` }] } }),
    JSON.stringify({ type: "api-request-blob", sessionId, hash: hash(n * 10 + 3),
      message: { role: "assistant", content: [{ type: "text", text: `replayed reply ${n}` }] } }),
    JSON.stringify({ type: "api-request-shape", sessionId, shapeHash: hash(n * 10 + 4),
      timestamp: "2026-10-01T00:00:00.000Z", version: "2.1.300", shape: {} }),
    JSON.stringify({ type: "api-request", sessionId, id: `req_${n}`, timestamp: "2026-10-01T00:00:00.000Z",
      version: "2.1.300", querySource: "repl_main_thread", shapeHash: hash(n * 10 + 4), params: {},
      keep: 0, tail: [hash(n * 10 + 1), hash(n * 10 + 2)], cacheControl: {}, requestDigest: hash(n) }),
  ];
}

test("API request records are not conversation messages", async () => {
  const sessionId = "0b7c5a2e-4f1d-4c8e-9a6b-3d2f1e0c9b8a";
  const path = fixture([
    JSON.stringify({ type: "user", message: { role: "user", content: "fix the parser" } }),
    ...apiRequestRecords(sessionId, 1),
    assistant("parser fixed"),
    JSON.stringify({ type: "user", message: { role: "user", content: "now add a test" } }),
    ...apiRequestRecords(sessionId, 2),
    assistant("test added"),
  ]);
  expect(await readLastClaudeMessages(path, 20))
    .toEqual(["fix the parser", "parser fixed", "now add a test", "test added"]);
  expect(await lastAssistantText(path)).toBe("test added");
});

test("a window that already holds enough is the only one read", async () => {
  const path = fixture([assistant("a"), assistant("b"), assistant("c")]);
  expect(await readLastClaudeMessages(path, 2)).toEqual(["b", "c"]);
});

// The ceiling is the point of the ladder: a wider bound, never no bound. Without
// it, twenty enormous messages would be an unbounded read on the judge's hot path.
test("never reads past the widest window", async () => {
  const path = join(tempDir("tt-"), "huge.jsonl");
  const line = `${toolResult(64 * 1024)}\n`;
  const chunk = Buffer.from(line.repeat(16), "utf8"); // ~1MB
  writeFileSync(path, "");
  for (let i = 0; i < 6; i++) appendFileSync(path, chunk);

  const seen: number[] = [];
  const out = await readTailUntil(path, 20, (raw) => { seen.push(raw.length); return []; });
  expect(out).toEqual([]);
  expect(seen.length).toBe(TAIL_WINDOW_BYTES.length);
  expect(Math.max(...seen)).toBeLessThanOrEqual(TAIL_WINDOW_BYTES[TAIL_WINDOW_BYTES.length - 1]!);
});

// An image read or a large file dump is one tool_result line. Counted against
// the windows, ten of them fill the widest and leave the judge a handful of
// the twenty messages it asked for.
test("tool results larger than OVERSIZED_LINE_BYTES do not count against the windows", async () => {
  const lines: string[] = [];
  for (let i = 0; i < 20; i++) {
    lines.push(assistant(`msg-${i}`));
    if (i >= 10) lines.push(toolResult(OVERSIZED_LINE_BYTES + 300_000));
  }
  const path = fixture(lines);
  const msgs = await readLastClaudeMessages(path, 20);
  expect(msgs).toHaveLength(20);
  expect(msgs[0]).toBe("msg-0");
});

// Skipping a line still means scanning it for its start, so the scan has a
// ceiling of its own.
test("does not look further back than the scan ceiling", async () => {
  const lines = [assistant("before"), ...Array.from({ length: 3 }, () => toolResult(OVERSIZED_LINE_BYTES + 100_000)), assistant("after")];
  const path = fixture(lines);
  const texts = (raw: string) => raw.split("\n").filter((l) => l.includes('"text"'));
  expect(await readTailUntil(path, 20, texts)).toHaveLength(2);
  expect(await readTailUntil(path, 20, texts, { scanBytes: 1024 * 1024 })).toEqual([assistant("after")]);
});

// A claimed line no window can hold is never passed over, since older lines
// without it would give the parser the wrong state.
test("a claimed line too large for every window ends the read", async () => {
  const marker = JSON.stringify({ type: "marker", pad: "z".repeat(TAIL_WINDOW_BYTES[TAIL_WINDOW_BYTES.length - 1]!) });
  const path = fixture([assistant("before"), marker, assistant("after")]);
  const texts = (raw: string) => raw.split("\n").filter((l) => l.includes('"text"'));
  expect(await readTailUntil(path, 20, texts, { keepOversized: (head) => head.includes('"marker"') }))
    .toEqual([assistant("after")]);
  expect(await readTailUntil(path, 20, texts)).toHaveLength(2);
});

// Typed text is kept at any size; only tool results are skipped as payloads.
test("an oversized typed prompt is still read", async () => {
  const big = "y".repeat(OVERSIZED_LINE_BYTES + 100_000);
  const path = fixture([
    assistant("before"),
    JSON.stringify({ type: "user", message: { role: "user", content: big } }),
    toolResult(OVERSIZED_LINE_BYTES + 100_000),
    assistant("after"),
  ]);
  expect(await readLastClaudeMessages(path, 20)).toEqual(["before", big, "after"]);
});
