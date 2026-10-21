import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { opencodeFork } from "../src/agents/opencode/fork";
import { opencodeSnapshot } from "../src/agents/opencode/handoff-snapshot";
import { serializeOpencodeSession } from "../src/agents/handoff/opencode-serialize";
import { safeJoin } from "../src/agents/handoff";
import { addSession, createOpencodeDb, snapshotOpts } from "./fixtures/opencode-db";
import { withEnv } from "./fixtures/with-env";

let root: string;
beforeEach(() => { root = mkdtempSync(join(tmpdir(), "opencode-handoff-")); });
afterEach(() => rmSync(root, { recursive: true, force: true }));

test("serializes one session and its mixed-case children in export shape with indexed names", async () => {
  const dbPath = join(root, "opencode.db");
  const db = createOpencodeDb(dbPath);
  addSession(db, "ses_f82fcb337ffenUB26NghT6topR", null, "hello");
  addSession(db, "ses_Child1", "ses_f82fcb337ffenUB26NghT6topR", "child one");
  addSession(db, "ses_Grand1", "ses_Child1", "grandchild");
  addSession(db, "ses_other", null, "unrelated");
  db.run("INSERT INTO todo VALUES ('ses_f82fcb337ffenUB26NghT6topR', 'write tests', 'pending', 0)");
  const outDir = join(root, "out");
  mkdirSync(outDir);

  const snapshot = await opencodeSnapshot(snapshotOpts(outDir, { opencodeDbPath: dbPath, agentSessionId: "ses_f82fcb337ffenUB26NghT6topR" }));
  db.close();

  expect(snapshot?.method).toBe("db-serialize");
  expect(snapshot?.primary).toBe("opencode-session.json");
  expect(snapshot?.files.map((f) => f.name)).toEqual(["opencode-session.json", "opencode-child-01.json", "opencode-child-02.json", "opencode-todo.json"]);
  expect(snapshot?.files.filter((f) => f.originalName).map((f) => f.originalName)).toEqual(["ses_Child1", "ses_Grand1"]);
  for (const file of snapshot!.files) expect(() => safeJoin(outDir, file.name)).not.toThrow();
  expect(readdirSync(outDir).sort()).toEqual(snapshot!.files.map((f) => f.name).sort());

  const doc = JSON.parse(readFileSync(join(outDir, "opencode-session.json"), "utf8"));
  expect(doc.info.id).toBe("ses_f82fcb337ffenUB26NghT6topR");
  expect(doc.info.revert).toEqual({ messageID: "m" });
  expect(doc.messages.map((m: any) => m.info.role)).toEqual(["user", "assistant"]);
  expect(doc.messages[0].parts[0]).toMatchObject({ id: "prt_ses_f82fcb337ffenUB26NghT6topR_1", type: "text", text: "hello" });
  expect(readFileSync(join(outDir, "opencode-session.json"), "utf8")).toContain("\n  \"info\"");
});

test("returns undefined for a session the store does not hold, or an unsafe id", async () => {
  const dbPath = join(root, "opencode.db");
  const db = createOpencodeDb(dbPath);
  addSession(db, "ses_a", null, "x");
  db.close();
  const outDir = join(root, "out");
  mkdirSync(outDir);
  expect(await opencodeSnapshot(snapshotOpts(outDir, { opencodeDbPath: dbPath, agentSessionId: "ses_missing" }))).toBeUndefined();
  expect(await opencodeSnapshot(snapshotOpts(outDir, { opencodeDbPath: dbPath, agentSessionId: "../ses_a" }))).toBeUndefined();
  expect(await opencodeSnapshot(snapshotOpts(outDir, { opencodeDbPath: join(root, "none.db"), agentSessionId: "ses_a" }))).toBeUndefined();
  expect(readdirSync(outDir)).toEqual([]);
});

test("returns undefined for a session that was opened but never prompted", async () => {
  const dbPath = join(root, "opencode.db");
  const db = createOpencodeDb(dbPath);
  db.run("INSERT INTO session VALUES ('ses_empty', 'p1', NULL, '/work', 'New session', '1.0', NULL, NULL, 1, 1)");
  db.close();
  const outDir = join(root, "out");
  mkdirSync(outDir);
  expect(await opencodeSnapshot(snapshotOpts(outDir, { opencodeDbPath: dbPath, agentSessionId: "ses_empty" }))).toBeUndefined();
  expect(readdirSync(outDir)).toEqual([]);
});

test("refuses the real store under test when no seam is given", async () => {
  const dbPath = join(root, "opencode.db");
  const db = createOpencodeDb(dbPath);
  addSession(db, "ses_a", null, "x");
  db.close();
  const outDir = join(root, "out");
  mkdirSync(outDir);
  expect(await withEnv("OPENCODE_DB", dbPath, () => opencodeSnapshot(snapshotOpts(outDir, { agentSessionId: "ses_a" })))).toBeUndefined();
  expect(await opencodeSnapshot(snapshotOpts(outDir, { opencodeDbPath: dbPath, agentSessionId: "ses_a" }))).toBeDefined();
});

test("serializeOpencodeSession never selects credential tables and allowlists info.error", () => {
  const db = createOpencodeDb(":memory:");
  const outputPath = join(root, "tool_1");
  writeFileSync(outputPath, "full output");
  addSession(db, "ses_a", null, "hi", {
    error: {
      name: "APIError",
      data: { message: "rate limited", statusCode: 429, isRetryable: true, responseHeaders: { "set-cookie": "SECRET-COOKIE" }, responseBody: "SECRET-BODY", url: "https://x.example/SECRET-URL" },
    },
    part: { type: "tool", state: { status: "completed", metadata: { outputPath, openai: { reasoningEncryptedContent: "SECRET-REASONING" } } } },
  });
  const statements: string[] = [];
  const original = db.query.bind(db);
  (db as any).query = (sql: string) => { statements.push(sql); return original(sql); };

  const result = serializeOpencodeSession(db, "ses_a", { includeKiloBoard: false })!;
  const text = JSON.stringify(result);

  for (const secret of ["SECRET-ACCESS-TOKEN", "SECRET-COOKIE", "SECRET-BODY", "SECRET-URL", "SECRET-REASONING", "share.example"]) expect(text).not.toContain(secret);
  expect(result.doc.messages[1]!.info.error).toEqual({ name: "APIError", data: { message: "rate limited", statusCode: 429, isRetryable: true } });
  expect(result.redactions.join("\n")).toContain("message.info.error");
  expect(result.redactions.join("\n")).toContain("reasoningEncryptedContent");
  expect(result.redactions.join("\n")).toContain("share_url");
  expect(result.references).toEqual([{ path: outputPath, note: expect.any(String) }]);
  expect(statements.join("\n")).not.toMatch(/account|credential|session_share|control_account/i);
  db.close();
});

test("opencodeFork keeps the native fork contract and declares a snapshot", () => {
  expect(opencodeFork.kind).toBe("native-fork");
  expect(opencodeFork.nativeForkArgs("ses_x")).toEqual(["--session", "ses_x", "--fork"]);
  expect(opencodeFork.decodeLegacyArgs?.(["--session", "ses_x", "--fork"])).toBe("ses_x");
  expect(opencodeFork.snapshot).toBe(opencodeSnapshot);
});
