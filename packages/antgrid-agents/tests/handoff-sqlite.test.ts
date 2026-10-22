import { afterEach, beforeEach, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HandoffSnapshotError, runDbSerializer, withReadSnapshot } from "../src/agents/handoff";

let root: string;
beforeEach(() => { root = mkdtempSync(join(tmpdir(), "handoff-sqlite-")); });
afterEach(() => rmSync(root, { recursive: true, force: true }));

test("withReadSnapshot sees WAL-only rows and leaves the db and -wal byte-identical", () => {
  const path = join(root, "agent.db");
  const writer = new Database(path);
  try {
    writer.run("PRAGMA journal_mode = WAL");
    writer.run("PRAGMA wal_autocheckpoint = 0");
    writer.run("CREATE TABLE message (id TEXT PRIMARY KEY, body TEXT)");
    writer.run("INSERT INTO message VALUES ('m1', 'only in the wal')");
    const before = { db: readFileSync(path), wal: readFileSync(`${path}-wal`) };
    expect(existsSync(`${path}-wal`)).toBe(true);

    const rows = withReadSnapshot(path, (db) => db.query("SELECT id, body FROM message").all());
    expect(rows).toEqual([{ id: "m1", body: "only in the wal" }]);

    expect(readFileSync(path).equals(before.db)).toBe(true);
    expect(readFileSync(`${path}-wal`).equals(before.wal)).toBe(true);
  } finally {
    writer.close();
  }
});

test("withReadSnapshot cannot write", () => {
  const path = join(root, "agent.db");
  const writer = new Database(path);
  writer.run("CREATE TABLE t (x)");
  writer.close();
  expect(() => withReadSnapshot(path, (db) => db.run("INSERT INTO t VALUES (1)"))).toThrow(HandoffSnapshotError);
});

test("withReadSnapshot reports a missing database as UNREADABLE", () => {
  try {
    withReadSnapshot(join(root, "none.db"), () => 1);
    throw new Error("expected a throw");
  } catch (error) {
    expect(error).toBeInstanceOf(HandoffSnapshotError);
    expect((error as HandoffSnapshotError).code).toBe("UNREADABLE");
  }
});

test("the serialize worker rejects an unregistered serializer instead of hanging", async () => {
  const controller = new AbortController();
  const error = await runDbSerializer({
    serializer: "does-not-exist", dbPath: join(root, "none.db"), outDir: root, signal: controller.signal,
  }).catch((e) => e);
  expect(error).toBeInstanceOf(HandoffSnapshotError);
  expect(error.code).toBe("UNREADABLE");
});

test("an already-aborted signal never starts the serialize worker", async () => {
  const controller = new AbortController();
  controller.abort();
  const error = await runDbSerializer({
    serializer: "x", dbPath: "x", outDir: root, signal: controller.signal,
  }).catch((e) => e);
  expect(error).toBeInstanceOf(HandoffSnapshotError);
  expect(error.code).toBe("UNREADABLE");
});
