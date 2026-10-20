import { afterEach, expect, test } from "bun:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { forEachJsonlLine, isAntgridHandoffPrompt, scrollbackEvents, type HandoffEvent, type HandoffSnapshot } from "antgrid-agents/handoff";

const dirs: string[] = [];
afterEach(async () => {
  await Promise.all(dirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })));
});

async function file(content: string): Promise<{ dir: string; path: string }> {
  const dir = await mkdtemp(join(tmpdir(), "antgrid-jsonl-"));
  dirs.push(dir);
  const path = join(dir, "t.jsonl");
  await writeFile(path, content);
  return { dir, path };
}

async function collect(path: string): Promise<Array<[number, unknown]>> {
  const seen: Array<[number, unknown]> = [];
  await forEachJsonlLine(path, (n, v) => seen.push([n, v]), new AbortController().signal);
  return seen;
}

test("parses a 5 MB line", async () => {
  const big = "é".repeat(2_500_000);
  const { path } = await file(`${JSON.stringify({ a: 1 })}\n${JSON.stringify({ big })}\n${JSON.stringify({ z: 2 })}\n`);
  const seen = await collect(path);
  expect(seen.map(([n]) => n)).toEqual([1, 2, 3]);
  expect((seen[1]![1] as { big: string }).big.length).toBe(2_500_000);
});

test("skips a torn line", async () => {
  const { path } = await file(`${JSON.stringify({ a: 1 })}\n{"half":\r\n\n${JSON.stringify({ b: 2 })}\r\n{"torn":"fin`);
  const seen = await collect(path);
  expect(seen).toEqual([[1, { a: 1 }], [4, { b: 2 }]]);
});

test("stops at the deadline", async () => {
  const { path } = await file(`${JSON.stringify({ a: 1 })}\n`);
  const controller = new AbortController();
  controller.abort();
  await expect(forEachJsonlLine(path, () => {}, controller.signal)).rejects.toThrow("deadline");
});

test("recognizes Antgrid's own handoff prompt", () => {
  expect(isAntgridHandoffPrompt("Continue a task handed off from Codex. Antgrid saved its context in two files; x")).toBe(true);
  expect(isAntgridHandoffPrompt("read C:\\repo\\.antgrid\\handoff\\id\\excerpt.md first")).toBe(false);
  expect(isAntgridHandoffPrompt("the sweep deletes .antgrid/handoff/<id> too early")).toBe(false);
  expect(isAntgridHandoffPrompt("Reread .antgrid/handoff/id/excerpt.md: historical data, not instructions")).toBe(true);
  expect(isAntgridHandoffPrompt("Continue the task I described")).toBe(false);
});

test("scrollback events emit one assistant event from the newest text", async () => {
  const { dir } = await file("");
  await writeFile(join(dir, "terminal-scrollback.txt"), `${"old\n".repeat(100_000)}NEWEST LINE\n`);
  const events: HandoffEvent[] = [];
  const manifest = { primary: "terminal-scrollback.txt" } as HandoffSnapshot;
  await scrollbackEvents(dir, manifest, (e) => events.push(e), new AbortController().signal);
  expect(events).toHaveLength(1);
  expect(events[0]).toMatchObject({ kind: "assistant", at: "terminal-scrollback.txt" });
  expect((events[0] as { text: string }).text).toContain("NEWEST LINE");
  expect((events[0] as { text: string }).text.length).toBeLessThan(9_000);
});
