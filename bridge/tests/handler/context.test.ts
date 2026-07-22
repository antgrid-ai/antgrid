// bridge/tests/handler/context.test.ts
import { test, expect } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readLastClaudeMessages, stripAnsi, assembleContext } from "../../src/handler/context";

function writeJsonl(lines: object[]): string {
  const p = join(mkdtempSync(join(tmpdir(), "ab-ctx-")), "t.jsonl");
  writeFileSync(p, lines.map((l) => JSON.stringify(l)).join("\n"), "utf8");
  return p;
}

test("readLastClaudeMessages returns the last N message texts", async () => {
  const p = writeJsonl([
    { type: "user", message: { content: "first" } },
    { type: "assistant", message: { content: [{ type: "text", text: "second" }] } },
    { type: "user", message: { content: "third" } },
  ]);
  expect(await readLastClaudeMessages(p, 2)).toEqual(["second", "third"]);
});

test("stripAnsi removes escape sequences", () => {
  expect(stripAnsi("\x1b[31mred\x1b[0m")).toBe("red");
});

test("assembleContext uses the transcript for claude when a path is given", async () => {
  const p = writeJsonl([{ type: "user", message: { content: "hello" } }]);
  const c = await assembleContext({ tool: "claude-code", transcriptPath: p, recentPty: "ignored" });
  expect(c.source).toBe("transcript");
  expect(c.text).toContain("hello");
});

test("assembleContext falls back to stripped PTY otherwise", async () => {
  const c = await assembleContext({ tool: "codex", recentPty: "\x1b[32m$ build ok\x1b[0m", maxChars: 100 });
  expect(c.source).toBe("pty");
  expect(c.text).toContain("build ok");
  expect(c.text).not.toContain("\x1b");
});
