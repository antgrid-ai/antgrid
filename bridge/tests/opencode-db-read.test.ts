// bridge/tests/opencode-db-read.test.ts
import { test, expect, afterEach } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, sep } from "node:path";
import { readLastOpencodeMessages, resolveOpencodeDbPath } from "../../packages/antgrid-agents/src/agents/opencode/db-read";

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
function addMessage(path: string, role: "user" | "assistant", parts: object[], t?: number, info: object = {}): string {
  const db = new Database(path);
  const id = `msg_${String(seq++).padStart(4, "0")}`;
  db.query("INSERT INTO message VALUES (?, ?, ?, ?, ?)").run(id, SES, t ?? seq, seq, JSON.stringify({ role, time: { created: t ?? seq }, ...info }));
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

// opencode's compaction shape (session/compaction.ts): a user message carrying
// the compaction part, then the summary assistant parented to it, then a
// synthetic continue prompt.
function addCompaction(db: string, part: object, summary: { finish: string; error?: object; text?: string }): void {
  const compaction = addMessage(db, "user", [{ type: "compaction", auto: true, ...part }]);
  addMessage(db, "assistant", summary.text ? [{ type: "text", text: summary.text }] : [], undefined, {
    parentID: compaction, mode: "compaction", agent: "compaction", summary: true,
    finish: summary.finish, ...(summary.error ? { error: summary.error } : {}),
  });
  addMessage(db, "user", [{ type: "text", text: "Continue if you have next steps", synthetic: true, metadata: { compaction_continue: true } }]);
}

test("a completed compaction without a retained tail drops everything older", () => {
  const db = makeDb();
  addMessage(db, "user", [{ type: "text", text: "ancient" }]);
  addCompaction(db, {}, { finish: "stop", text: "the summary" });
  addMessage(db, "user", [{ type: "text", text: "fresh" }]);
  expect(readLastOpencodeMessages(SES, 10, db)).toEqual(["the summary", "fresh"]);
});

test("a compaction with tail_start_id keeps the retained tail turns", () => {
  const db = makeDb();
  addMessage(db, "user", [{ type: "text", text: "head question" }]);
  addMessage(db, "assistant", [{ type: "text", text: "head answer" }], undefined, { finish: "stop" });
  const tail = addMessage(db, "user", [{ type: "text", text: "tail question" }]);
  addMessage(db, "assistant", [{ type: "text", text: "tail answer" }], undefined, { finish: "stop" });
  addCompaction(db, { tail_start_id: tail }, { finish: "stop", text: "the summary" });
  addMessage(db, "assistant", [{ type: "text", text: "after" }], undefined, { finish: "stop" });
  expect(readLastOpencodeMessages(SES, 10, db)).toEqual(["tail question", "tail answer", "the summary", "after"]);
});

test("a failed compaction is not a boundary", () => {
  const db = makeDb();
  addMessage(db, "user", [{ type: "text", text: "earlier" }]);
  addCompaction(db, {}, { finish: "error", error: { name: "ContextOverflowError", data: { message: "too long" } } });
  addMessage(db, "user", [{ type: "text", text: "later" }]);
  expect(readLastOpencodeMessages(SES, 10, db)).toEqual(["earlier", "later"]);
});

test("the newest completed compaction wins over a newer failed one", () => {
  const db = makeDb();
  addMessage(db, "user", [{ type: "text", text: "ancient" }]);
  addCompaction(db, {}, { finish: "stop", text: "the summary" });
  addMessage(db, "user", [{ type: "text", text: "middle" }]);
  addCompaction(db, {}, { finish: "error", error: { name: "UnknownError", data: { message: "boom" } } });
  addMessage(db, "user", [{ type: "text", text: "fresh" }]);
  expect(readLastOpencodeMessages(SES, 10, db)).toEqual(["the summary", "middle", "fresh"]);
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
