import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { MemoryService, TASK_EXPIRY_MS, MemoryResultSchema, bytes, type MemoryContext, type MemoryRecord } from "../src";

let directory: string;
let service: MemoryService;
let now: number;
let app: MemoryContext;
let agent: MemoryContext;
let otherConnections: Database[];
const finding = (overrides: Record<string, unknown> = {}) => ({ content: "Windows initialization fails with missing JDK; install the JDK before configuring CMake.", memory_type: "observation", scope: "project", applicability: "Observed on Windows; Linux is unverified.", ...overrides });
const call = (ctx: MemoryContext, request: Record<string, unknown>) => service.execute(ctx, request);
async function save(overrides: Record<string, unknown> = {}, key: string = crypto.randomUUID(), ctx = agent) {
  return await call(ctx, { op: "save", operation_key: key, save: finding(overrides) }) as { id: string; outcome: string; lifecycle: string };
}
async function record(id: string, ctx = agent, history = false): Promise<MemoryRecord> {
  return (await call(ctx, { op: "get", id, history })).record as MemoryRecord;
}
function sql(): Database { const db = new Database(join(directory, "memory.sqlite")); otherConnections.push(db); return db; }
async function rejects(promise: Promise<unknown>, code: string) { await expect(promise).rejects.toMatchObject({ code }); }

beforeEach(async () => {
  directory = mkdtempSync(join(tmpdir(), "antgrid-memory-test-"));
  now = Date.UTC(2026, 9, 28);
  service = new MemoryService({ directory, now: () => now });
  app = { actor: "app", owner_id: service.ownerId };
  agent = { actor: "agent", owner_id: service.ownerId, project_id: "non-git-project", session_id: "durable-session", checkout_id: "main", run_id: "live-run", agent_id: "claude-code" };
  otherConnections = [];
  await call(app, { op: "settings", enabled: true });
});
afterEach(() => {
  for (const db of otherConnections) db.close();
  service.close();
  rmSync(directory, { recursive: true, force: true });
});

describe("local ownership and controls", () => {
  test("new profile opts out and keeps its identity across restart", async () => {
    const secondDir = join(directory, "new-profile");
    let second = new MemoryService({ directory: secondDir });
    const owner = second.ownerId;
    expect(owner).not.toBe(service.ownerId);
    const ctx = { ...agent, owner_id: owner };
    expect(await second.execute(ctx, { op: "status" })).toMatchObject({ enabled: false });
    await rejects(second.execute(ctx, { op: "save", operation_key: "disabled", save: finding() }), "DISABLED");
    second.close();
    second = new MemoryService({ directory: secondDir });
    expect(second.ownerId).toBe(owner);
    await rejects(second.execute(agent, { op: "status" }), "FORBIDDEN");
    second.close();
  });
  test("profile and originating project pause include user saves; edits, reads and forget still work", async () => {
    const created = await save({ scope: "user" });
    const projectApp = { ...app, project_id: agent.project_id };
    await call(projectApp, { op: "settings", project_paused: true });
    await rejects(save({ scope: "user" }), "PAUSED");
    await save({ content: "other project", scope: "user" }, "other-project", { ...agent, project_id: "other" });
    expect((await record(created.id)).content).toContain("JDK");
    await call(app, { op: "settings", paused: true });
    await rejects(save({}, "paused-other", { ...agent, project_id: "other" }), "PAUSED");
    const correction = await save({ scope: "user", content: "Corrected finding", supersedes: created.id }, "app-correct", app);
    await call(agent, { op: "forget", id: correction.id });
    await rejects(record(created.id, app, true), "NOT_FOUND");
    await rejects(call(projectApp, { op: "settings", paused: false }), "FORBIDDEN");
  });
  test("agents cannot use app-only operations or provide source identities", async () => {
    for (const op of ["export", "list", "repair", "settings"]) await rejects(call(agent, { op }), "FORBIDDEN");
    await rejects(call(agent, { op: "save", operation_key: "spoof", save: finding({ project_id: "other" }) }), "INVALID_ARGUMENT");
    for (const key of ["session_id", "project_id", "checkout_id", "run_id"] as const) {
      await rejects(call({ ...agent, [key]: undefined }, { op: "search", query: "JDK" }), "FORBIDDEN");
    }
  });
});

describe("atomic persistence, duplicates and correction history", () => {
  test("concurrent independent duplicate saves preserve attribution, evidence and timestamps", async () => {
    const requests = await Promise.all(Array.from({ length: 8 }, (_, i) => save({ evidence: [`source-${i}`] }, `duplicate-${i}`)));
    expect(new Set(requests.map(r => r.id)).size).toBe(1);
    expect(requests.filter(r => r.outcome === "already_present")).toHaveLength(7);
    const first = await record(requests[0].id);
    now += 1000;
    await save({ evidence: ["different-source"] });
    expect(await record(first.id)).toEqual(first);
    expect(first.evidence).toEqual(["source-0"]);
  });
  test("lost response and restart replay commits once without retaining payload or run credentials", async () => {
    await call(agent, { op: "prepare", operation_key: "lost", save: finding() });
    const first = await save({}, "lost");
    service.close();
    service = new MemoryService({ directory, now: () => now });
    const replay = await save({}, "lost", { ...agent, run_id: "resumed-live-run", agent_id: "codex" });
    expect(replay.id).toBe(first.id);
    expect((await record(first.id)).source.agent_id).toBe("claude-code");
    const operations = sql().query("SELECT * FROM operations").all();
    expect(JSON.stringify(operations)).not.toContain("JDK");
    expect(JSON.stringify(operations)).not.toContain("live-run");
    await rejects(save({ content: "changed" }, "lost"), "IDEMPOTENCY_CONFLICT");
  });
  test("concurrent corrections conflict and replay still returns original revision identity", async () => {
    const first = await save({}, "original");
    const results = await Promise.allSettled([save({ supersedes: first.id, content: "New evidence A" }), save({ supersedes: first.id, content: "New evidence B" })]);
    expect(results.filter(r => r.status === "fulfilled")).toHaveLength(1);
    expect(results.find(r => r.status === "rejected")).toMatchObject({ reason: { code: "CONFLICT" } });
    await rejects(record(first.id), "NOT_FOUND");
    expect((await record(first.id, agent, true)).lifecycle).toBe("superseded");
    expect(await save({}, "original")).toMatchObject({ id: first.id, lifecycle: "superseded" });
    const search = await call(agent, { op: "search", query: "evidence" });
    expect(search.results).toHaveLength(1);
  });
  test("index write failure rolls back correction, record and receipt together", async () => {
    const first = await save();
    const db = sql();
    db.exec("DROP TRIGGER memory_insert; CREATE TRIGGER memory_insert AFTER INSERT ON records BEGIN INSERT INTO missing_index VALUES(new.id); END;");
    await rejects(save({ content: "new value", supersedes: first.id }, "rollback"), "UNAVAILABLE");
    expect((await record(first.id)).lifecycle).toBe("active");
    expect(db.query("SELECT * FROM operations WHERE operation_key='rollback'").get()).toBeNull();
    expect(db.query("SELECT count(*) AS n FROM records").get()).toEqual({ n: 1 });
    await call(app, { op: "repair" });
    expect((await save({ content: "new value", supersedes: first.id }, "rollback")).outcome).toBe("saved");
  });
  test("migration failure never resets a database and derived index loss is repaired", async () => {
    const first = await save();
    service.close();
    const db = sql();
    db.exec("DROP TABLE memory_fts");
    service = new MemoryService({ directory, now: () => now });
    expect((await call(agent, { op: "search", query: "JDK" })).results).toHaveLength(1);
    expect((await record(first.id)).id).toBe(first.id);
    const incompatible = join(directory, "newer");
    const newer = new MemoryService({ directory: incompatible });
    newer.close();
    const other = new Database(join(incompatible, "memory.sqlite"));
    other.exec("PRAGMA user_version=99");
    other.close();
    expect(() => new MemoryService({ directory: incompatible })).toThrow("newer version");
    const verify = new Database(join(incompatible, "memory.sqlite"));
    expect(verify.query("PRAGMA user_version").get()).toEqual({ user_version: 99 });
    verify.close();
  });
  test("failed first migration rolls back every new table without discarding existing data", () => {
    const path = join(directory, "memory.sqlite");
    service.close();
    const existing = new Database(path);
    existing.exec("PRAGMA user_version=0");
    existing.close();
    expect(() => new MemoryService({ directory })).toThrow();
    const verify = new Database(path);
    expect(verify.query("PRAGMA user_version").get()).toEqual({ user_version: 0 });
    expect(verify.query("SELECT owner_id FROM profile").get()).toEqual({ owner_id: app.owner_id });
    verify.exec("PRAGMA user_version=1");
    verify.close();
    service = new MemoryService({ directory, now: () => now });
  });
  test("independent service connections serialize duplicate saves through SQLite", async () => {
    const second = new MemoryService({ directory, now: () => now });
    try {
      const [a, b] = await Promise.all([
        save({}, "connection-a"),
        second.execute({ ...agent, session_id: "other-session", agent_id: "codex" }, { op: "save", operation_key: "connection-b", save: finding() }),
      ]);
      expect(a.id).toBe(b.id as string);
      expect((await call(app, { op: "list" })).results).toHaveLength(1);
    } finally { second.close(); }
  });
  test("an unreadable canonical database is preserved", () => {
    const bad = join(directory, "bad");
    const temp = new MemoryService({ directory: bad });
    temp.close();
    const path = join(bad, "memory.sqlite");
    writeFileSync(path, "not a SQLite database");
    expect(() => new MemoryService({ directory: bad })).toThrow();
    expect(readFileSync(path, "utf8")).toBe("not a SQLite database");
  });
});

describe("authorization and lifecycle", () => {
  test("search and get enforce the same project/session/checkout and owner restrictions", async () => {
    const task = await save({ scope: "task", restrict_to_checkout: true });
    const project = await save({ content: "project JDK" });
    const user = await save({ content: "user JDK", scope: "user" });
    for (const ctx of [{ ...agent, project_id: "elsewhere" }, { ...agent, session_id: "fork" }, { ...agent, checkout_id: "other-tree" }]) {
      await rejects(record(task.id, ctx, true), "NOT_FOUND");
      expect((await call(ctx, { op: "search", query: "initialization" })).results).toHaveLength(0);
    }
    await rejects(record(project.id, { ...agent, project_id: "elsewhere" }), "NOT_FOUND");
    expect((await record(user.id, { ...agent, project_id: "elsewhere" })).scope).toBe("user");
    await rejects(record(user.id, { ...app, project_id: agent.project_id }), "NOT_FOUND");
    expect((await call(app, { op: "list" })).results).toHaveLength(3);
    expect((await call({ ...app, project_id: agent.project_id }, { op: "list" })).results).toHaveLength(2);
  });
  test("exact 30-day boundary; duplicate/read cannot refresh; expired latest can be corrected", async () => {
    const state = { memory_type: "task_state", scope: "task", restrict_to_checkout: true };
    const first = await save(state);
    now += TASK_EXPIRY_MS - 1;
    expect((await record(first.id)).lifecycle).toBe("active");
    expect((await save(state)).id).toBe(first.id);
    now += 1;
    await rejects(record(first.id), "NOT_FOUND");
    expect((await call(agent, { op: "search", query: "JDK" })).results).toHaveLength(0);
    expect((await record(first.id, agent, true)).lifecycle).toBe("expired");
    const updated = await save({ ...state, supersedes: first.id, content: "Verified fresh state" });
    expect(updated.lifecycle).toBe("active");
    expect((await record(updated.id)).checkout_id).toBe(agent.checkout_id);
    await rejects(save({ supersedes: updated.id, scope: "project" }), "FORBIDDEN");
  });
  test("agent exit has no memory event; durable resume can read but a fork cannot", async () => {
    const first = await save({ scope: "task" });
    service.close();
    service = new MemoryService({ directory, now: () => now });
    expect((await record(first.id, { ...agent, run_id: "new-live-run" })).lifecycle).toBe("active");
    await rejects(record(first.id, { ...agent, session_id: "new-session" }), "NOT_FOUND");
    expect((await call(app, { op: "export" })).records).toHaveLength(1);
  });
});

describe("pending operation recovery and forgetting", () => {
  test("redacted pending saves survive restart and keep capture attribution", async () => {
    await call(agent, { op: "prepare", operation_key: "pending", save: finding({ content: "Use API_KEY=supersecretvalue to debug" }) });
    const pending = JSON.stringify(sql().query("SELECT * FROM operations").all());
    expect(pending).not.toContain("supersecretvalue");
    expect(pending).not.toContain("live-run");
    expect(await call({ ...app, project_id: agent.project_id }, { op: "status" })).toMatchObject({ pending_operations: 1 });
    service.close();
    service = new MemoryService({ directory, now: () => now });
    expect((await call({ ...agent, session_id: "fork" }, { op: "recover" })).recovered).toEqual([]);
    const recovered = await call({ ...agent, run_id: "resumed", agent_id: "codex" }, { op: "recover" });
    const id = (recovered.recovered as { id: string }[])[0].id;
    expect((await record(id)).content).toContain("[REDACTED]");
    expect((await record(id)).source.agent_id).toBe("claude-code");
    expect(await call(agent, { op: "status" })).toMatchObject({ pending_operations: 0, failed_operations: 0 });
    expect(JSON.stringify(sql().query("SELECT * FROM operations").all())).not.toContain("REDACTED");
  });
  test("JSON credential values and bearer tokens are redacted before any durable payload", async () => {
    const content = 'Configuration {"password": "private-password"} Authorization: Bearer abcdefghijklmnop';
    await call(agent, { op: "prepare", operation_key: "credentials", save: finding({ content }) });
    const pending = JSON.stringify(sql().query("SELECT payload FROM operations").all());
    expect(pending).not.toContain("private-password");
    expect(pending).not.toContain("abcdefghijklmnop");
    const result = await save({ content }, "credentials");
    expect((await record(result.id)).content).toContain('"password": "[REDACTED]"');
  });
  test("recovery respects pause and changed checkout, and clears terminal correction conflicts", async () => {
    const initial = await save({ scope: "task", restrict_to_checkout: true });
    const correction = finding({ scope: "task", restrict_to_checkout: true, content: "pending correction", supersedes: initial.id });
    await call(agent, { op: "prepare", operation_key: "pending", save: correction });
    await call(app, { op: "settings", paused: true });
    expect((await call(agent, { op: "recover" })).errors).toMatchObject([{ code: "PAUSED" }]);
    await call(app, { op: "settings", paused: false });
    expect((await call({ ...agent, checkout_id: "different" }, { op: "recover" })).errors).toMatchObject([{ code: "NOT_FOUND" }]);
    await save({ ...correction, content: "winner" });
    expect((await call(agent, { op: "recover" })).errors).toMatchObject([{ code: "CONFLICT" }]);
    expect(await call(agent, { op: "status" })).toMatchObject({ pending_operations: 0, failed_operations: 1 });
    expect(sql().query("SELECT payload FROM operations WHERE operation_key='pending'").get()).toEqual({ payload: null });
    await rejects(call(agent, { op: "save", operation_key: "pending", save: correction }), "CONFLICT");
  });
  test("forget removes entire history and suppresses duplicate receipts and pending corrections", async () => {
    const first = await save({}, "create");
    await save({}, "duplicate");
    await call(agent, { op: "prepare", operation_key: "queued-duplicate", save: finding() });
    const last = await save({ content: "updated", supersedes: first.id }, "correct");
    await call(agent, { op: "prepare", operation_key: "queued-correction", save: finding({ content: "queued", supersedes: last.id }) });
    expect(await call(app, { op: "forget", id: first.id })).toMatchObject({ forgotten: true });
    for (const id of [first.id, last.id]) await rejects(record(id, app, true), "NOT_FOUND");
    expect((await call(app, { op: "export" })).records).toEqual([]);
    for (const key of ["create", "duplicate", "queued-duplicate"]) await rejects(save({}, key), "FORGOTTEN");
    await rejects(save({ content: "queued", supersedes: last.id }, "queued-correction"), "FORGOTTEN");
    expect((await call(agent, { op: "recover" })).recovered).toEqual([]);
    const operations = sql().query("SELECT payload,payload_hash,match_hash,target_id,record_id,state FROM operations").all();
    for (const operation of operations) expect(operation).toEqual({ payload: null, payload_hash: null, match_hash: null, target_id: null, record_id: null, state: "suppressed" });
    expect(sql().query("SELECT count(*) AS n FROM memory_fts").get()).toEqual({ n: 0 });
  });
  test("bounded lock retry revalidates caller before another attempt", async () => {
    const db = sql();
    db.exec("BEGIN IMMEDIATE");
    let checks = 0;
    const started = performance.now();
    const pending = service.execute(() => {
      checks++;
      if (checks > 1) return { ...agent, owner_id: "changed-owner" };
      return agent;
    }, { op: "save", operation_key: "locked", save: finding() });
    await rejects(pending, "FORBIDDEN");
    expect(checks).toBe(2);
    expect(performance.now() - started).toBeLessThan(2000);
    db.exec("ROLLBACK");
    expect((await call(app, { op: "list" })).results).toHaveLength(0);
  });
  test("cleanup failure hides content and can be repaired without recreating it", async () => {
    const first = await save();
    const db = sql();
    db.exec("BEGIN");
    db.query("SELECT * FROM records").all();
    await rejects(call(agent, { op: "forget", id: first.id }), "CLEANUP_FAILED");
    await rejects(record(first.id, app, true), "NOT_FOUND");
    expect(await call(app, { op: "status" })).toMatchObject({ recovery_status: "cleanup_failed" });
    db.exec("ROLLBACK");
    expect(await call(app, { op: "repair" })).toMatchObject({ recovery_status: "ready" });
  });
});

describe("search, response limits and export", () => {
  test("terms are alternatives, phrases stay phrases, operators are literal, Unicode/path terms work", async () => {
    const a = await save({ content: "alpha beta src/lib/foo_bar.ts 東京 설정", applicability: "Linux 6" });
    const b = await save({ content: "alpha separated beta", applicability: "Windows" });
    expect((await call(agent, { op: "search", query: '"alpha beta"' })).results).toMatchObject([{ id: a.id }]);
    expect((await call(agent, { op: "search", query: 'alpha missing' })).results).toHaveLength(2);
    expect((await call(agent, { op: "search", query: 'alpha NOT beta' })).results).toHaveLength(2);
    for (const query of ["src/lib/foo_bar.ts", "東京", "설정", "Linux"]) expect((await call(agent, { op: "search", query })).results).toMatchObject([{ id: a.id }]);
    await rejects(call(agent, { op: "search", query: "!!! *** ()" }), "INVALID_ARGUMENT");
    await rejects(call(agent, { op: "search", query: "\u0301" }), "INVALID_ARGUMENT");
    expect(a.id).not.toBe(b.id);
  });
  test("eligibility filtering precedes limits and default BM25 ties use ID order", async () => {
    for (let i = 0; i < 12; i++) await save({ content: `rank rank rank private ${i}` }, `private-${i}`, { ...agent, project_id: "private" });
    const a = await save({ content: "rank common", applicability: "condition A" });
    const b = await save({ content: "rank common", applicability: "condition B" });
    const result = await call(agent, { op: "search", query: "rank", limit: 1 });
    expect((result.results as { id: string }[])[0].id).toBe([a.id, b.id].sort()[0]);
    expect(result.has_more).toBe(true);
  });
  test("default BM25 favors a focused repeated term and keeps incompatible conditions distinct", async () => {
    const focused = await save({ content: "cmake cmake cmake", applicability: "Windows" });
    await save({ content: "cmake " + "unrelated topics ".repeat(50), applicability: "Linux" });
    const result = await call(agent, { op: "search", query: "cmake" });
    expect((result.results as { id: string }[])[0].id).toBe(focused.id);
    const windows = await save({ content: "Same finding", applicability: "Windows" });
    const linux = await save({ content: "Same finding", applicability: "Linux" });
    expect(windows.id).not.toBe(linux.id);
  });
  test("UTF-8 fields and serialized record byte limits reject, never truncate", async () => {
    await rejects(save({ content: "🌱".repeat(1025) }), "INVALID_ARGUMENT");
    await rejects(save({ applicability: "é".repeat(513) }), "INVALID_ARGUMENT");
    await rejects(save({ evidence: Array(9).fill("source") }), "INVALID_ARGUMENT");
    await rejects(save({ evidence: ["\"".repeat(9000)] }), "INVALID_ARGUMENT");
    await rejects(call(agent, { op: "search", query: "é".repeat(513) }), "INVALID_ARGUMENT");
    const boundary = await save({ content: "🌱".repeat(1024) });
    expect(bytes((await record(boundary.id)).content)).toBe(4096);
  });
  test("response preserves conditions, marks excerpts and bounds JSON including MCP escapes", async () => {
    for (let i = 0; i < 10; i++) await save({ content: `quoted ${i} ` + '\"🌱'.repeat(500), applicability: `condition ${i} ` + "x".repeat(900) });
    const response = await call(agent, { op: "search", query: "quoted", limit: 10 });
    expect(bytes(response)).toBeLessThanOrEqual(8192);
    expect(bytes({ isError: false, content: [{ type: "text", text: JSON.stringify(response) }] }) + 256).toBeLessThanOrEqual(8192);
    expect(response.has_more).toBe(true);
    expect((response.results as { applicability: string; excerpted: boolean; content: string }[]).every(r => r.applicability.length > 900 && r.excerpted && bytes(r.content) <= 512)).toBe(true);
    expect(MemoryResultSchema.safeParse(response).success).toBe(true);
  });
  test("small findings return complete content and versioned export preserves history and provenance", async () => {
    const first = await save({ scope: "task", memory_type: "task_state", evidence: ["doc@v1"] });
    const second = await save({ scope: "task", memory_type: "task_state", supersedes: first.id, content: "checked alpha", evidence: ["doc@v2"] });
    const result = await call(agent, { op: "search", query: "alpha" });
    expect(result.results).toMatchObject([{ id: second.id, content: "checked alpha", excerpted: false }]);
    now += TASK_EXPIRY_MS;
    const exported = await call(app, { op: "export" });
    expect(exported).toMatchObject({ version: 1, owner_id: service.ownerId });
    expect((exported.records as MemoryRecord[]).map(r => r.lifecycle).sort()).toEqual(["expired", "superseded"]);
    expect(JSON.stringify(exported)).not.toContain("operation_key");
    expect(JSON.stringify(exported)).not.toContain("live-run");
    expect(MemoryResultSchema.safeParse(exported).success).toBe(true);
  });
});
