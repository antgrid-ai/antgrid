import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { kiloFork } from "../src/agents/kilo/fork";
import { resolveKiloDbPath } from "../src/agents/kilo/db-path";
import { kiloSnapshot } from "../src/agents/kilo/handoff-snapshot";
import { addSession, createOpencodeDb, snapshotOpts } from "./fixtures/opencode-db";

let root: string;
beforeEach(() => { root = mkdtempSync(join(tmpdir(), "kilo-handoff-")); });
afterEach(() => rmSync(root, { recursive: true, force: true }));

test("Kilo serializes under kilo names and includes a non-empty board", async () => {
  const dbPath = join(root, "kilo.db");
  const db = createOpencodeDb(dbPath);
  db.run("CREATE TABLE kilo_board (id TEXT PRIMARY KEY, session_id TEXT, title TEXT)");
  db.run("CREATE TABLE kilo_board_message (id TEXT PRIMARY KEY, board_id TEXT, body TEXT)");
  addSession(db, "ses_k", null, "hello kilo");
  addSession(db, "ses_kc", "ses_k", "child");
  db.run("INSERT INTO kilo_board VALUES ('b1', 'ses_k', 'plan')");
  const outDir = join(root, "out");
  mkdirSync(outDir);

  const snapshot = await kiloSnapshot(snapshotOpts(outDir, { kiloDbPath: dbPath, agentSessionId: "ses_k" }));
  db.close();

  expect(snapshot?.agent).toBe("kilo");
  expect(snapshot?.primary).toBe("kilo-session.json");
  expect(snapshot?.files.map((f) => f.name)).toEqual(["kilo-session.json", "kilo-child-01.json"]);
  const doc = JSON.parse(readFileSync(join(outDir, "kilo-session.json"), "utf8"));
  expect(doc.board).toEqual({ kilo_board: [{ id: "b1", session_id: "ses_k", title: "plan" }] });
  expect(doc.messages).toHaveLength(2);
  expect(JSON.parse(readFileSync(join(outDir, "kilo-child-01.json"), "utf8")).board).toBeUndefined();
  expect(JSON.stringify(doc)).not.toContain("SECRET-ACCESS-TOKEN");
  expect(snapshot?.warnings.join("\n")).toContain("kilo_board_message");
});

test("an empty board adds nothing and a missing board table is fine", async () => {
  const dbPath = join(root, "kilo.db");
  const db = createOpencodeDb(dbPath);
  addSession(db, "ses_k", null, "hello");
  db.close();
  const outDir = join(root, "out");
  mkdirSync(outDir);
  const snapshot = await kiloSnapshot(snapshotOpts(outDir, { kiloDbPath: dbPath, agentSessionId: "ses_k" }));
  expect(snapshot?.files.map((f) => f.name)).toEqual(["kilo-session.json"]);
  expect(JSON.parse(readFileSync(join(outDir, "kilo-session.json"), "utf8")).board).toBeUndefined();
});

test("Kilo honours KILO_DB and XDG_DATA_HOME", () => {
  const abs = join(root, "custom.db");
  expect(resolveKiloDbPath({ KILO_DB: abs })).toBe(abs);
  expect(resolveKiloDbPath({ KILO_DB: "named.db", XDG_DATA_HOME: root })).toBe(join(root, "kilo", "named.db"));
  expect(resolveKiloDbPath({ XDG_DATA_HOME: root })).toBe(join(root, "kilo", "kilo.db"));
});

test("KILO_DB=:memory: is not found", () => {
  expect(resolveKiloDbPath({ KILO_DB: ":memory:" })).toBeUndefined();
});

test("kiloFork keeps its native fork contract and declares a snapshot", () => {
  expect(kiloFork.kind).toBe("native-fork");
  expect(kiloFork.snapshot).toBe(kiloSnapshot);
});

test("refuses the real store under test when no seam is given", async () => {
  expect(await kiloSnapshot(snapshotOpts(root, { agentSessionId: "ses_a" }))).toBeUndefined();
});
