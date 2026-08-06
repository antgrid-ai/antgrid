import { afterAll, test, expect } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readTranscriptTail, TAIL_BYTES } from "../src/transcript-tail";
import { lastAssistantText } from "../src/agents/claude-code/transcript";

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
