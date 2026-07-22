import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { resolveStructuredTitle } from "../src/title-resolver";

const dirs: string[] = [];
function newDir() { const d = mkdtempSync(join(tmpdir(), "ab-gemtitle-")); dirs.push(d); return d; }
afterEach(() => { for (const d of dirs.splice(0)) try { rmSync(d, { recursive: true, force: true }); } catch {} });

test("gemini transcript title comes from the first user message", async () => {
  const d = newDir();
  const p = join(d, "session.jsonl");
  // Gemini session jsonl: a metadata line then message records {type, content}.
  writeFileSync(p, [
    JSON.stringify({ sessionId: "s1", projectHash: "h" }),
    JSON.stringify({ type: "user", content: "Refactor the auth module" }),
    JSON.stringify({ type: "gemini", content: "Sure, …" }),
  ].join("\n"));
  const title = await resolveStructuredTitle("gemini", { sessionId: "s1", transcriptPath: p });
  expect(title).toBe("Refactor the auth module");
});

test("gemini transcript title comes from array Part[] content (no type field)", async () => {
  const d = newDir();
  const p = join(d, "session-array.jsonl");
  // Gemini/Qwen persist Part[] as {text} objects with no `type` field.
  writeFileSync(p, [
    JSON.stringify({ sessionId: "s2", projectHash: "h" }),
    JSON.stringify({ type: "user", content: [{ text: "Refactor the auth module" }] }),
    JSON.stringify({ type: "gemini", content: "Sure, …" }),
  ].join("\n"));
  const title = await resolveStructuredTitle("gemini", { sessionId: "s2", transcriptPath: p });
  expect(title).toBe("Refactor the auth module");
});

test("missing transcript path yields null", async () => {
  expect(await resolveStructuredTitle("qwen", { sessionId: "s1" })).toBeNull();
});
