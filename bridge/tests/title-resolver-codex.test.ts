import { afterEach, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { codexThreadExistsSync } from "../src/title-resolver";

const dirs: string[] = [];
function tmp() { const d = mkdtempSync(join(tmpdir(), "ab-codex-exist-")); dirs.push(d); return d; }
afterEach(() => { for (const d of dirs.splice(0)) try { rmSync(d, { recursive: true, force: true }); } catch {} });

/** Write a state_<N>.sqlite with a threads table and one row. */
function writeStateDb(home: string, version: number, id: string) {
  const db = new Database(join(home, `state_${version}.sqlite`));
  db.run("CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, first_user_message TEXT)");
  db.query("INSERT INTO threads (id, title, first_user_message) VALUES (?, ?, ?)").run(id, "A title", "first msg");
  db.close();
}

test("codexThreadExistsSync returns true for an existing thread id", () => {
  const home = tmp();
  writeStateDb(home, 0, "real-thread-id");
  expect(codexThreadExistsSync("real-thread-id", home)).toBe(true);
});

test("codexThreadExistsSync returns false for a missing thread id", () => {
  const home = tmp();
  writeStateDb(home, 0, "real-thread-id");
  expect(codexThreadExistsSync("missing-id", home)).toBe(false);
});

test("codexThreadExistsSync returns null when the codexHome dir is missing", () => {
  expect(codexThreadExistsSync("any-id", join(tmp(), "no-such-dir"))).toBeNull();
});

test("codexThreadExistsSync picks the newest state_<N>.sqlite", () => {
  const home = tmp();
  // state_0 has the thread; state_3 (newer) does not — newest wins, returns false.
  writeStateDb(home, 0, "old-schema-thread");
  writeStateDb(home, 3, "new-schema-thread");
  expect(codexThreadExistsSync("old-schema-thread", home)).toBe(false);
  expect(codexThreadExistsSync("new-schema-thread", home)).toBe(true);
});
