// bridge/tests/opencode-db-read.test.ts
import { test, expect, afterEach } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, sep } from "node:path";
import { readLastOpencodeMessages, resolveOpencodeDbPath } from "../src/opencode/opencode-db-read";

const SES = "ses_test";

// Real schema subset (opencode session.sql.ts): data columns hold the JSON that
// opencode's drizzle rows carry, minus id/sessionID (those live in columns).
function makeDb(): string {
  const path = join(mkdtempSync(join(tmpdir(), "ab-oc-")), "opencode.db");
  const db = new Database(path);
  db.exec(`
    CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
    CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
  `);
  db.close();
  return path;
}

let seq = 0;
function addMessage(path: string, role: "user" | "assistant", parts: object[], t?: number): string {
  const db = new Database(path);
  const id = `msg_${String(seq++).padStart(4, "0")}`;
  db.query("INSERT INTO message VALUES (?, ?, ?, ?, ?)").run(id, SES, t ?? seq, seq, JSON.stringify({ role, time: { created: t ?? seq } }));
  parts.forEach((p, i) =>
    db.query("INSERT INTO part VALUES (?, ?, ?, ?, ?, ?)").run(`prt_${id}_${i}`, id, SES, seq, seq, JSON.stringify(p)));
  db.close();
  return id;
}

const ENV_KEYS = ["OPENCODE_DB", "XDG_DATA_HOME"] as const;
const saved = ENV_KEYS.map((k) => [k, process.env[k]] as const);
afterEach(() => { for (const [k, v] of saved) { if (v === undefined) delete process.env[k]; else process.env[k] = v; } });

test("extracts user+assistant text parts in order, last n", () => {
  const db = makeDb();
  addMessage(db, "user", [{ type: "text", text: "one" }]);
  addMessage(db, "assistant", [{ type: "step-start", snapshot: "x" }, { type: "text", text: "two" }]);
  addMessage(db, "user", [{ type: "text", text: "three" }]);
  expect(readLastOpencodeMessages(SES, 2, db)).toEqual(["two", "three"]);
});

test("filters synthetic and ignored text parts and tool-only messages", () => {
  const db = makeDb();
  addMessage(db, "user", [{ type: "text", text: "real" }, { type: "text", text: "machinery", synthetic: true }]);
  addMessage(db, "assistant", [{ type: "tool", tool: "bash", state: { status: "completed", output: "noise" } }]);
  addMessage(db, "assistant", [{ type: "text", text: "hidden", ignored: true }]);
  addMessage(db, "assistant", [{ type: "text", text: "answer" }]);
  expect(readLastOpencodeMessages(SES, 10, db)).toEqual(["real", "answer"]);
});

test("a compaction part on a user message drops everything older", () => {
  const db = makeDb();
  addMessage(db, "user", [{ type: "text", text: "ancient" }]);
  addMessage(db, "user", [{ type: "compaction", auto: true }]);
  addMessage(db, "assistant", [{ type: "text", text: "the summary" }]); // summary child, inside kept range
  addMessage(db, "user", [{ type: "text", text: "fresh" }]);
  expect(readLastOpencodeMessages(SES, 10, db)).toEqual(["the summary", "fresh"]);
});

test("returns [] for a missing db, an unknown session, and malformed row data", () => {
  expect(readLastOpencodeMessages(SES, 5, join(tmpdir(), "ab-none", "opencode.db"))).toEqual([]);
  const db = makeDb();
  expect(readLastOpencodeMessages("ses_other", 5, db)).toEqual([]);
  const raw = new Database(db);
  raw.query("INSERT INTO message VALUES (?, ?, ?, ?, ?)").run("msg_bad", SES, 1, 1, "{not json");
  raw.close();
  expect(readLastOpencodeMessages(SES, 5, db)).toEqual([]);
});

test("resolveOpencodeDbPath honors OPENCODE_DB and XDG_DATA_HOME", () => {
  process.env.XDG_DATA_HOME = `${sep}xdg`;
  delete process.env.OPENCODE_DB;
  expect(resolveOpencodeDbPath()).toBe(join(`${sep}xdg`, "opencode", "opencode.db"));
  process.env.OPENCODE_DB = "custom.db";
  expect(resolveOpencodeDbPath()).toBe(join(`${sep}xdg`, "opencode", "custom.db"));
  process.env.OPENCODE_DB = join(`${sep}abs`, "x.db");
  expect(resolveOpencodeDbPath()).toBe(join(`${sep}abs`, "x.db"));
});
