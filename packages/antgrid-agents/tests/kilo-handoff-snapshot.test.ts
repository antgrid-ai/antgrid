import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { kiloFork } from "../src/agents/kilo/fork";
import { resolveKiloDbPath } from "../src/agents/kilo/db-path";
import { kiloSnapshot } from "../src/agents/kilo/handoff-snapshot";
import { addSession, createOpencodeDb, snapshotOpts } from "./fixtures/opencode-db";
import { withEnv } from "./fixtures/with-env";

let root: string;
beforeEach(() => { root = mkdtempSync(join(tmpdir(), "kilo-handoff-")); });
afterEach(() => rmSync(root, { recursive: true, force: true }));

// Kilo 7.8.x board schema: keyed by the root session, messages ordered by seq
// and hidden at or below the board's cleared_seq.
const BOARD_DDL = [
  "CREATE TABLE kilo_board (root_session_id TEXT PRIMARY KEY, objective TEXT NOT NULL, objective_message_id TEXT, next_seq INTEGER DEFAULT 1 NOT NULL, cleared_seq INTEGER DEFAULT 0 NOT NULL, message_count INTEGER DEFAULT 0 NOT NULL, message_bytes INTEGER DEFAULT 0 NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL)",
  "CREATE TABLE kilo_board_message (id TEXT PRIMARY KEY, board_root_session_id TEXT NOT NULL, seq INTEGER NOT NULL, time_created INTEGER NOT NULL, sender_session_id TEXT NOT NULL, recipient TEXT NOT NULL, type TEXT NOT NULL, body TEXT NOT NULL, reply_to TEXT, source_message_id TEXT NOT NULL, source_call_id TEXT NOT NULL)",
];

test("Kilo serializes under kilo names and includes the root session's board", async () => {
  const dbPath = join(root, "kilo.db");
  const db = createOpencodeDb(dbPath);
  for (const ddl of BOARD_DDL) db.run(ddl);
  addSession(db, "ses_k", null, "hello kilo");
  addSession(db, "ses_kc", "ses_k", "child");
  addSession(db, "ses_other", null, "unrelated");
  db.run("INSERT INTO kilo_board VALUES ('ses_k', 'ship the plan', NULL, 5, 1, 2, 20, 1, 2)");
  db.run("INSERT INTO kilo_board VALUES ('ses_other', 'other objective', NULL, 2, 0, 1, 10, 1, 2)");
  const message = db.prepare("INSERT INTO kilo_board_message VALUES (?, ?, ?, 1, ?, 'all', 'note', ?, NULL, 'msg_src', 'call_src')");
  message.run("kbm_3", "ses_k", 3, "ses_kc", "third");
  message.run("kbm_1", "ses_k", 1, "ses_k", "cleared");
  message.run("kbm_2", "ses_k", 2, "ses_kc", "second");
  message.run("kbm_o", "ses_other", 1, "ses_other", "other board");
  const outDir = join(root, "out");
  mkdirSync(outDir);

  const snapshot = await kiloSnapshot(snapshotOpts(outDir, { kiloDbPath: dbPath, agentSessionId: "ses_k" }));
  db.close();

  expect(snapshot?.agent).toBe("kilo");
  expect(snapshot?.primary).toBe("kilo-session.json");
  expect(snapshot?.files.map((f) => f.name)).toEqual(["kilo-session.json", "kilo-child-01.json"]);
  const doc = JSON.parse(readFileSync(join(outDir, "kilo-session.json"), "utf8"));
  expect(doc.board.kilo_board.map((row: { objective: string }) => row.objective)).toEqual(["ship the plan"]);
  expect(doc.board.kilo_board_message.map((row: { body: string }) => row.body)).toEqual(["second", "third"]);
  expect(doc.messages).toHaveLength(2);
  expect(JSON.parse(readFileSync(join(outDir, "kilo-child-01.json"), "utf8")).board).toBeUndefined();
  expect(JSON.stringify(doc)).not.toContain("SECRET-ACCESS-TOKEN");
  expect(snapshot?.warnings.join("\n")).not.toContain("kilo_board");
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
  const dbPath = join(root, "kilo.db");
  const db = createOpencodeDb(dbPath);
  addSession(db, "ses_a", null, "x");
  db.close();
  const outDir = join(root, "out");
  mkdirSync(outDir);
  expect(await withEnv("KILO_DB", dbPath, () => kiloSnapshot(snapshotOpts(outDir, { agentSessionId: "ses_a" })))).toBeUndefined();
  expect(await kiloSnapshot(snapshotOpts(outDir, { kiloDbPath: dbPath, agentSessionId: "ses_a" }))).toBeDefined();
});
