import { afterEach, expect, test } from "bun:test";

import { Database } from "bun:sqlite";
import { appendFileSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AntigravityTitleWatcher } from "../src/agents/antigravity/title-watcher";

const dirs: string[] = [];
const watchers: AntigravityTitleWatcher[] = [];
function tmp() { const d = mkdtempSync(join(tmpdir(), "ab-agy-title-")); dirs.push(d); return d; }
afterEach(() => {
  for (const w of watchers.splice(0)) w.stop();
  for (const d of dirs.splice(0)) try { rmSync(d, { recursive: true, force: true }); } catch {}
});

function makeWatcher(home: string, calls: Array<[string, string]>): AntigravityTitleWatcher {
  const w = new AntigravityTitleWatcher(home, (cid, title) => calls.push([cid, title]), 20);
  watchers.push(w);
  return w;
}

const line = (cid: string, display: string) =>
  `${JSON.stringify({ display, conversationId: cid, type: "slash_command" })}\n`;

function writeSummariesDb(home: string, rows: Array<{ id: string; title?: string; preview?: string }>) {
  const db = new Database(join(home, "conversation_summaries.db"));
  db.run("CREATE TABLE IF NOT EXISTS conversation_summaries (conversation_id TEXT PRIMARY KEY, title TEXT, preview TEXT)");
  const stmt = db.query(
    "INSERT INTO conversation_summaries (conversation_id, title, preview) VALUES (?, ?, ?) " +
    "ON CONFLICT(conversation_id) DO UPDATE SET title=excluded.title, preview=excluded.preview",
  );
  for (const r of rows) stmt.run(r.id, r.title ?? "", r.preview ?? "");
  db.close();
}

test("emits (conversationId, name) once when a /rename is appended after start", async () => {
  const home = tmp();
  const calls: Array<[string, string]> = [];
  makeWatcher(home, calls).start();
  appendFileSync(join(home, "history.jsonl"), line("c1", "/rename my chat"));
  await Bun.sleep(300);
  expect(calls).toEqual([["c1", "my chat"]]);
});

// agy writes its own conversation preview into that DB, and we deliberately do
// not read it: Antgrid names the session itself, so the only title this watcher
// carries is one the user typed (see ResolvedTitle in agents/types.ts).
test("ignores agy's generated preview, and still emits a later /rename", async () => {
  const home = tmp();
  const calls: Array<[string, string]> = [];
  makeWatcher(home, calls).start();
  writeSummariesDb(home, [{ id: "c1", preview: "Casual Greeting And Introduction" }]);
  await Bun.sleep(300);
  expect(calls).toEqual([]);
  appendFileSync(join(home, "history.jsonl"), line("c1", "/rename mine"));
  await Bun.sleep(300);
  expect(calls).toEqual([["c1", "mine"]]);
});

test("does not re-emit a title that has not changed", async () => {
  const home = tmp();
  const calls: Array<[string, string]> = [];
  makeWatcher(home, calls).start();
  appendFileSync(join(home, "history.jsonl"), line("c1", "/rename stable"));
  await Bun.sleep(300);
  appendFileSync(join(home, "history.jsonl"), line("c1", "/logout"));
  await Bun.sleep(300);
  expect(calls).toEqual([["c1", "stable"]]);
});

test("seeds pre-existing titles at start without emitting them", async () => {
  const home = tmp();
  writeFileSync(join(home, "history.jsonl"), line("c1", "/rename before start"));
  const calls: Array<[string, string]> = [];
  makeWatcher(home, calls).start();
  await Bun.sleep(300);
  expect(calls).toEqual([]);
});

test("bare /rename does not emit", async () => {
  const home = tmp();
  const calls: Array<[string, string]> = [];
  makeWatcher(home, calls).start();
  appendFileSync(join(home, "history.jsonl"), line("c1", "/rename"));
  await Bun.sleep(300);
  expect(calls).toEqual([]);
});

test("start() no-ops (no throw, no emit) when the agy home dir is absent", async () => {
  const home = join(tmp(), "does-not-exist");
  const calls: Array<[string, string]> = [];
  expect(() => makeWatcher(home, calls).start()).not.toThrow();
  await Bun.sleep(100);
  expect(calls).toEqual([]);
});
