import { afterEach, beforeEach, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { MemoryService, MemoryResultSchema, TASK_EXPIRY_MS, bytes, type MemoryContext, type MemoryRecord } from "../src";

let directory: string;
let service: MemoryService | undefined;
let now: number;
let app: MemoryContext;
let agent: MemoryContext;
const page = (cursor?: string, context = app) => service!.execute(context, { op: "export", ...(cursor ? { cursor } : {}) });
const save = (content: string, extra: Record<string, unknown> = {}) => service!.execute(agent, { op: "save", operation_key: crypto.randomUUID(), save: { content, memory_type: "observation", scope: "project", ...extra } });
function database(): Database { return new Database(join(directory, "memory.sqlite")); }
function clone(seed: string, count: number, project = "project", owner = app.owner_id, prefix = "row"): void {
  const db = database();
  const insert = db.prepare(`INSERT INTO records(id,owner_id,scope,project_id,task_id,checkout_id,memory_type,content,applicability,evidence,source,supersedes,superseded_by,created_at,updated_at,match_hash)
    SELECT ?,?,scope,?,task_id,checkout_id,memory_type,content,applicability,evidence,source,supersedes,superseded_by,created_at,updated_at,? FROM records WHERE id=?`);
  try { db.transaction(() => {
    for (let i = 0; i < count; i++) {
      const id = `${prefix}-${String(i).padStart(5, "0")}`;
      insert.run(id, owner, project, id, seed);
    }
  }).immediate(); } finally { insert.finalize(); db.close(true); }
}

beforeEach(async () => {
  directory = mkdtempSync(join(tmpdir(), "antgrid-memory-export-"));
  now = Date.UTC(2026, 9, 28);
  service = new MemoryService({ directory, now: () => now });
  app = { actor: "app", owner_id: service.ownerId };
  agent = { actor: "agent", owner_id: service.ownerId, project_id: "project", session_id: "session", checkout_id: "main", run_id: "run" };
  await service.execute(app, { op: "settings", enabled: true });
});
afterEach(() => { service?.close(); rmSync(directory, { recursive: true, force: true }); });

test("more than 32 MiB of retained data reconstructs through bounded UTF-8 JSON pages", async () => {
  const content = '🌱"\\'.repeat(500);
  const evidence = ['🌱"'.repeat(1500)];
  const seed = await save(content, { evidence, applicability: "版本条件" });
  clone(seed.id as string, 2800);
  const ids = new Set<string>();
  let cursor: string | undefined;
  let exportedAt: unknown;
  let totalBytes = 0;
  let pages = 0;
  do {
    const result = await page(cursor);
    expect(bytes(result)).toBeLessThanOrEqual(256 * 1024);
    expect(MemoryResultSchema.safeParse(result).success).toBe(true);
    const records = result.records as MemoryRecord[];
    expect(records.length).toBeGreaterThan(0);
    expect(records.length).toBeLessThanOrEqual(64);
    expect(result.owner_id).toBe(app.owner_id);
    exportedAt ??= result.exported_at;
    expect(result.exported_at).toBe(exportedAt);
    for (const record of records) {
      expect(record.content).toBe(content);
      expect(record.evidence).toEqual(evidence);
      expect(ids.has(record.id)).toBe(false);
      ids.add(record.id);
      totalBytes += bytes(record);
    }
    expect(typeof result.next_cursor === "string" || result.next_cursor === null).toBe(true);
    cursor = result.next_cursor as string | undefined;
    pages++;
  } while (cursor);
  expect(ids.size).toBe(2801);
  expect(totalBytes).toBeGreaterThan(32 * 1024 * 1024);
  expect(pages).toBeGreaterThan(100);
  expect([...ids]).toEqual([...ids].sort());
}, 30_000);

test("authorization filters before the page limit and cursors bind the admitted context", async () => {
  const seed = await save("eligible record");
  clone(seed.id as string, 90, "other", app.owner_id, "a-private");
  clone(seed.id as string, 90, "project", "other-owner", "b-foreign");
  clone(seed.id as string, 70, "project", app.owner_id, "z-visible");
  const project = { ...app, project_id: "project" };
  const first = await page(undefined, project);
  expect(first.records).toHaveLength(64);
  expect((first.records as MemoryRecord[]).every(record => record.project_id === "project" && record.owner_id === app.owner_id)).toBe(true);
  expect(typeof first.next_cursor).toBe("string");
  await expect(page(first.next_cursor as string, app)).rejects.toMatchObject({ code: "FORBIDDEN" });
  await expect(page(first.next_cursor as string, { ...project, project_id: "other" })).rejects.toMatchObject({ code: "FORBIDDEN" });
  const second = await page(first.next_cursor as string, project);
  expect(second.records).toHaveLength(7);
  expect(second.next_cursor).toBeNull();
});

test("malformed, oversized, tampered and foreign-profile cursors fail closed", async () => {
  const seed = await save("cursor seed");
  clone(seed.id as string, 70);
  const first = await page();
  const cursor = first.next_cursor as string;
  expect(typeof cursor).toBe("string");
  const db = database();
  try {
    const secret = (db.query("SELECT cursor_key FROM export_state").get() as { cursor_key: string }).cursor_key;
    expect(JSON.stringify(first)).not.toContain(secret);
    expect(Buffer.from(cursor.split(".")[0]!, "base64url").toString("utf8")).not.toContain(secret);
  } finally { db.close(true); }
  for (const bad of ["?", "e30.signature", "x".repeat(2049), cursor.slice(0, -4) + "AAAA"]) {
    await expect(page(bad)).rejects.toMatchObject({ code: "INVALID_ARGUMENT" });
  }
  await expect(service!.execute(app, { op: "export", cursor: "" })).rejects.toMatchObject({ code: "INVALID_ARGUMENT" });
  const other = new MemoryService({ directory: join(directory, "other-profile") });
  try {
    await expect(other.execute({ actor: "app", owner_id: other.ownerId }, { op: "export", cursor })).rejects.toMatchObject({ code: "INVALID_ARGUMENT" });
  } finally { other.close(); }
});

test("keyset queries avoid sorting the matching store for every page", () => {
  const db = database();
  try {
    for (const project of [false, true]) {
      const query = db.prepare(`EXPLAIN QUERY PLAN SELECT r.* FROM records r WHERE r.owner_id=? ${project ? "AND r.scope!='user' AND r.project_id=?" : ""} AND r.id>? ORDER BY r.id ASC LIMIT ?`);
      try {
        const plan = query.all(...(project ? [app.owner_id, "project", "", 65] : [app.owner_id, "", 65])) as { detail: string }[];
        expect(plan.some(row => row.detail.includes("TEMP B-TREE"))).toBe(false);
        expect(plan.some(row => row.detail.includes("id>?"))).toBe(true);
      } finally { query.finalize(); }
    }
  } finally { db.close(true); }
});

test.each(["insert", "correction", "forget"])("%s invalidates an in-progress export", async mutation => {
  const seed = await save("revision seed");
  clone(seed.id as string, 70);
  const first = await page();
  if (mutation === "insert") await save("new record");
  else if (mutation === "correction") await save("corrected record", { supersedes: seed.id });
  else await service!.execute(app, { op: "forget", id: seed.id });
  await expect(page(first.next_cursor as string)).rejects.toMatchObject({ code: "EXPORT_CHANGED" });
});

test("restart, index repair, duplicate receipts and settings preserve a stable export", async () => {
  const seed = await save("stable record");
  clone(seed.id as string, 70);
  const first = await page();
  await save("stable record");
  await service!.execute(app, { op: "settings", paused: true });
  await service!.execute(app, { op: "repair" });
  service!.close();
  service = new MemoryService({ directory, now: () => now });
  expect((await page(first.next_cursor as string)).next_cursor).toBeNull();
  const second = await page();
  const db = database();
  try { db.exec("UPDATE records SET content='changed externally' WHERE id='row-00069'"); } finally { db.close(true); }
  await expect(page(second.next_cursor as string)).rejects.toMatchObject({ code: "EXPORT_CHANGED" });
});

test("a rolled-back mutation preserves the current export revision", async () => {
  const seed = await save("rollback sentinel");
  clone(seed.id as string, 70);
  const first = await page();
  const db = database();
  try {
    expect(() => db.transaction(() => {
      db.exec("UPDATE records SET content='rolled back' WHERE id='row-00069'");
      throw new Error("abort mutation");
    }).immediate()).toThrow("abort mutation");
  } finally { db.close(true); }
  const second = await page(first.next_cursor as string);
  expect((second.records as MemoryRecord[]).every(record => record.content === "rollback sentinel")).toBe(true);
  expect(second.next_cursor).toBeNull();
});

test("task lifecycle is fixed at the first page timestamp", async () => {
  const seed = await save("unfinished task", { scope: "task", memory_type: "task_state" });
  clone(seed.id as string, 70);
  now += TASK_EXPIRY_MS - 1;
  const first = await page();
  now += 2;
  const second = await page(first.next_cursor as string);
  expect(second.exported_at).toBe(first.exported_at);
  expect((second.records as MemoryRecord[]).every(record => record.lifecycle === "active")).toBe(true);
  expect(((await page()).records as MemoryRecord[]).every(record => record.lifecycle === "expired")).toBe(true);
});

function downgradeToV1(): void {
  service!.close(); service = undefined;
  const db = database();
  try { db.exec("DROP TRIGGER IF EXISTS export_record_insert; DROP TRIGGER IF EXISTS export_record_update; DROP TRIGGER IF EXISTS export_record_delete; DROP TABLE IF EXISTS export_state; DROP INDEX IF EXISTS records_export; DROP INDEX IF EXISTS records_project_export; PRAGMA user_version=1;"); }
  finally { db.close(true); }
}

test("v1 migration preserves records, owner, receipts and settings", async () => {
  const seed = await save("migration sentinel");
  await service!.execute(app, { op: "settings", paused: true });
  downgradeToV1();
  service = new MemoryService({ directory, now: () => now });
  expect(service.ownerId).toBe(app.owner_id);
  expect((await page()).records).toMatchObject([{ id: seed.id, content: "migration sentinel" }]);
  expect(await service.execute(app, { op: "status" })).toMatchObject({ enabled: true, paused: true });
  const db = database();
  try {
    expect(db.query("PRAGMA user_version").get()).toEqual({ user_version: 2 });
    expect(db.query("SELECT count(*) AS count FROM operations").get()).toEqual({ count: 1 });
  } finally { db.close(true); }
});

test("failed v2 migration rolls back and preserves the v1 database", async () => {
  await save("preserve on migration failure");
  downgradeToV1();
  const db = database();
  try { db.exec("CREATE TABLE export_state (keep TEXT); INSERT INTO export_state VALUES('preserved');"); } finally { db.close(true); }
  expect(() => { service = new MemoryService({ directory }); }).toThrow();
  const verify = database();
  try {
    expect(verify.query("PRAGMA user_version").get()).toEqual({ user_version: 1 });
    expect(verify.query("SELECT keep FROM export_state").get()).toEqual({ keep: "preserved" });
    expect(verify.query("SELECT content FROM records").get()).toEqual({ content: "preserve on migration failure" });
    expect(verify.query("SELECT count(*) AS count FROM sqlite_master WHERE type='trigger' AND name LIKE 'export_record_%'").get()).toEqual({ count: 0 });
  } finally { verify.close(true); }
});
