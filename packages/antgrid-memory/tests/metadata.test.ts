import { afterEach, beforeEach, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { createHash } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { bytes, LIMITS, MemoryResultSchema, MemoryService, TASK_EXPIRY_MS, type MemoryContext, type MemoryRecord } from "../src";

let directory: string;
let service: MemoryService;
let agent: MemoryContext;
let app: MemoryContext;
const finding = (extra: Record<string, unknown> = {}) => ({ content: "A reproducible finding", memory_type: "note", scope: "project", ...extra });
const save = (extra: Record<string, unknown> = {}, key: string = crypto.randomUUID()) => service.execute(agent, { op: "save", operation_key: key, save: finding(extra) });
const get = async (id: unknown, history = false) => (await service.execute(agent, { op: "get", id, history })).record as MemoryRecord;
const hash = (v: unknown) => createHash("sha256").update(JSON.stringify(v)).digest("hex");

beforeEach(async () => {
  directory = mkdtempSync(join(tmpdir(), "antgrid-metadata-"));
  service = new MemoryService({ directory });
  agent = { actor: "agent", owner_id: service.ownerId, project_id: "p", session_id: "s", checkout_id: "main", run_id: "r" };
  app = { actor: "app", owner_id: service.ownerId };
  await service.execute(app, { op: "settings", enabled: true });
});
afterEach(() => { service.close(); rmSync(directory, { recursive: true, force: true }); });

test("metadata UTF-8 boundaries, redaction and blank normalization", async () => {
  const result = await save({ title: "🌱".repeat(64), description: "é".repeat(256), content: "🌱".repeat(4096) });
  expect(await get(result.id)).toMatchObject({ title: "🌱".repeat(64), description: "é".repeat(256) });
  expect(bytes((await get(result.id)).content)).toBe(LIMITS.content);
  for (const extra of [{ title: "🌱".repeat(65) }, { description: "é".repeat(257) }, { content: "🌱".repeat(4097) }, { evidence: ["e".repeat(16385)] }, { content: "\u0001".repeat(16384) }]) {
    await expect(save(extra)).rejects.toMatchObject({ code: "INVALID_ARGUMENT" });
  }
  await service.execute(agent, { op: "prepare", operation_key: "secret", save: finding({ title: "password=secret123", description: "Bearer abcdef12345678" }) });
  const db = new Database(join(directory, "memory.sqlite"));
  const queued = db.query("SELECT payload FROM operations WHERE operation_key='secret'").get() as { payload: string };
  expect(queued.payload).not.toContain("secret123");
  expect(queued.payload).not.toContain("abcdef12345678");
  db.close();
  await service.execute(agent, { op: "recover" });
  const blank = await save({ content: "empty labels", title: "  ", description: "\n " });
  expect(await get(blank.id)).not.toHaveProperty("title");
  expect(await get(blank.id)).not.toHaveProperty("description");
});

test("labels cannot bypass dedup and revisions atomically replace or clear metadata", async () => {
  const first = await save({ title: "Old label", description: "Original description" }, "first");
  const duplicate = await save({ title: "Reworded label", description: "Same body" }, "duplicate");
  expect(duplicate).toMatchObject({ id: first.id, outcome: "already_present" });
  expect((await get(first.id)).title).toBe("Old label");
  await expect(save({ title: "Different payload" }, "first")).rejects.toMatchObject({ code: "IDEMPOTENCY_CONFLICT" });
  const changed = await save({ supersedes: first.id, title: "Updated label", description: "Updated description" });
  expect((await get(changed.id)).title).toBe("Updated label");
  const cleared = await save({ supersedes: changed.id });
  expect(await get(cleared.id)).not.toHaveProperty("description");
  expect((await get(changed.id, true)).description).toBe("Updated description");
  expect((await service.execute(app, { op: "export" })).records).toEqual(expect.arrayContaining([expect.objectContaining({ id: first.id, title: "Old label" })]));
  await service.execute(agent, { op: "forget", id: cleared.id });
  await expect(save({ title: "Old label", description: "Original description" }, "first")).rejects.toMatchObject({ code: "FORGOTTEN" });
});

test("exact serialized record cap reserves no silent space for correction history", async () => {
  const evidence = [...Array(4).fill("e".repeat(10000)), "e"];
  const seed = await save({ content: "x".repeat(16384), evidence });
  const remaining = LIMITS.record - bytes(await get(seed.id));
  evidence[4] = "e".repeat(remaining + 1);
  const boundary = await save({ content: "y".repeat(16384), evidence });
  expect(bytes(await get(boundary.id))).toBe(LIMITS.record);
  await expect(save({ supersedes: boundary.id, content: "updated", evidence: [] }, "history-overflow")).rejects.toMatchObject({ code: "INVALID_ARGUMENT" });
  expect((await get(boundary.id)).lifecycle).toBe("active");
  expect((await service.execute(app, { op: "list" })).results).toHaveLength(2);
});

test("task expiry preserves a maximum-sized saved record in project and machine exports", async () => {
  let now = 1_700_000_000_000;
  service.close();
  service = new MemoryService({ directory, now: () => now });
  const evidence = ['"'.repeat(6000), ...Array(3).fill("e".repeat(10000)), "e"];
  const fields = {
    memory_type: "task_state", scope: "task", title: '"'.repeat(LIMITS.title),
    description: "é".repeat(LIMITS.description / 2), applicability: 'C:\\src\\task\n"staging" 🌱', evidence,
  };
  const seed = await save({ ...fields, content: "🌱".repeat(LIMITS.content / 4) });
  evidence[4] = "e".repeat(LIMITS.record - bytes(await get(seed.id)) + 1);
  const boundary = await save({ ...fields, content: "🌿".repeat(LIMITS.content / 4) });
  const active = await get(boundary.id);
  expect(bytes(active)).toBe(65536);
  expect(bytes(active.content)).toBe(LIMITS.content);
  expect(bytes(active.title)).toBe(LIMITS.title);
  expect(bytes(active.description)).toBe(LIMITS.description);
  expect(bytes(JSON.stringify(active.evidence[0]))).toBe(12002);
  for (const reference of active.evidence) expect(bytes(reference)).toBeLessThanOrEqual(LIMITS.evidence);

  for (const elapsed of [TASK_EXPIRY_MS - 1, TASK_EXPIRY_MS]) {
    now = active.updated_at + elapsed;
    const lifecycle = elapsed < TASK_EXPIRY_MS ? "active" : "expired";
    for (const context of [app, { ...app, project_id: agent.project_id }]) {
      const page = await service.execute(context, { op: "export" });
      expect(MemoryResultSchema.safeParse(page).success).toBe(true);
      expect(page.next_cursor).toBeNull();
      expect(page.exported_at).toBe(now);
      expect(bytes(page)).toBeLessThanOrEqual(LIMITS.exportPage);
      const exported = (page.records as MemoryRecord[]).find(record => record.id === boundary.id)!;
      expect(exported).toEqual({ ...active, lifecycle });
      expect(bytes(exported)).toBe(lifecycle === "active" ? 65536 : 65537);
      expect(bytes({ ...exported, lifecycle: "active" })).toBe(LIMITS.record);
    }
  }
  await expect(get(boundary.id)).rejects.toMatchObject({ code: "NOT_FOUND" });
  expect(await get(boundary.id, true)).toEqual({ ...active, lifecycle: "expired" });
});

test("search finds metadata and deep body text while keeping full reads and bounded previews", async () => {
  const body = "opening ".repeat(1200) + "needlequartz diagnostic fix " + "closing ".repeat(700);
  const entry = await save({ content: body, title: "Headingzircon", description: "Summarytopaz", applicability: "Conditiongarnet" });
  for (const query of ["Headingzircon", "Summarytopaz", "Conditiongarnet", "needlequartz"]) {
    const result = await service.execute(agent, { op: "search", query });
    expect(result.results).toMatchObject([{ id: entry.id, title: "Headingzircon", description: "Summarytopaz", excerpted: true }]);
    const hit = (result.results as MemoryRecord[])[0]!;
    expect(bytes(hit.content)).toBeLessThanOrEqual(256);
    if (query === "needlequartz") expect(hit.content).toContain(query);
  }
  expect((await get(entry.id)).content).toBe(body);
  const other = { ...agent, project_id: "other" };
  expect((await service.execute(other, { op: "search", query: "Summarytopaz" })).results).toEqual([]);
  for (let i = 0; i < 10; i++) await save({ title: `quoted ${i} ` + '"'.repeat(240), description: '"'.repeat(512), content: `body ${i} ` + "x".repeat(15000), applicability: '"'.repeat(1024) });
  const response = await service.execute(agent, { op: "search", query: "quoted", limit: 10 });
  expect(bytes({ isError: false, content: [{ type: "text", text: JSON.stringify(response) }] }) + 256).toBeLessThanOrEqual(8192);
  expect(response.has_more).toBe(true);
});

test("large labeled records retain metadata through bounded export pages and index repair", async () => {
  const ids = new Set<string>();
  for (let i = 0; i < 12; i++) {
    const result = await save({ content: `${i}:` + "x".repeat(16000), title: `large ${i}`, description: "retained export labels", evidence: Array(4).fill("e".repeat(10000)) });
    ids.add(result.id as string);
    expect(bytes(await get(result.id))).toBeGreaterThan(55000);
  }
  let cursor: unknown;
  let pages = 0;
  do {
    const result = await service.execute(app, { op: "export", ...(cursor ? { cursor } : {}) });
    expect(bytes(result)).toBeLessThanOrEqual(LIMITS.exportPage);
    for (const row of result.records as MemoryRecord[]) {
      expect(row.description).toBe("retained export labels");
      expect(ids.delete(row.id)).toBe(true);
    }
    cursor = result.next_cursor; pages++;
  } while (cursor);
  expect(pages).toBeGreaterThan(1);
  expect(ids.size).toBe(0);
  service.close();
  const db = new Database(join(directory, "memory.sqlite"));
  db.exec("UPDATE memory_fts SET title='damagedlabel'"); db.close();
  service = new MemoryService({ directory });
  expect((await service.execute(agent, { op: "search", query: "damagedlabel" })).results).toEqual([]);
  expect((await service.execute(agent, { op: "search", query: '"retained export labels"' })).results).not.toEqual([]);
});

test("byte-limited excerpts keep the match even after long Unicode tokens", async () => {
  await save({ content: ("界".repeat(90) + " ").repeat(20) + "rarequeryneedle " + "tail ".repeat(30), description: "Long tokens before the match" });
  const result = await service.execute(agent, { op: "search", query: "rarequeryneedle" });
  expect((result.results as MemoryRecord[])[0]!.content).toContain("rarequeryneedle");
});

// Reproduce the v1 column/index layout, leaving old records and receipts intact.
function restoreV1(db: Database) {
  db.exec(`DROP TRIGGER memory_insert; DROP TRIGGER memory_update; DROP TRIGGER memory_delete; DROP TABLE memory_fts;
    ALTER TABLE records DROP COLUMN title; ALTER TABLE records DROP COLUMN description;
    CREATE VIRTUAL TABLE memory_fts USING fts5(id UNINDEXED,content,applicability,tokenize='unicode61');
    INSERT INTO memory_fts(rowid,id,content,applicability) SELECT seq,id,content,applicability FROM records;
    PRAGMA user_version=1;`);
}

test("v1 migration preserves receipts, pending recovery, suppression, identity and timestamps", async () => {
  const resolved = await save({}, "resolved");
  const before = await get(resolved.id);
  await service.execute(agent, { op: "prepare", operation_key: "pending", save: finding({ content: "queued legacy" }) });
  const forgotten = await save({ content: "forgotten legacy" }, "forgotten");
  await service.execute(agent, { op: "forget", id: forgotten.id });
  service.close();
  const db = new Database(join(directory, "memory.sqlite"));
  const legacySave = { ...finding(), evidence: [], restrict_to_checkout: false };
  expect((db.query("SELECT payload_hash FROM operations WHERE operation_key='resolved'").get() as { payload_hash: string }).payload_hash)
    .toBe(hash([agent.owner_id, { scope: "project", project_id: "p", task_id: null, checkout_id: null }, legacySave]));
  restoreV1(db);
  db.close();
  service = new MemoryService({ directory });
  expect(service.ownerId).toBe(agent.owner_id!);
  expect(await get(resolved.id)).toEqual(before);
  expect(await save({}, "resolved")).toMatchObject({ id: resolved.id });
  expect((await service.execute(agent, { op: "recover" })).recovered).toHaveLength(1);
  await expect(save({ content: "forgotten legacy" }, "forgotten")).rejects.toMatchObject({ code: "FORGOTTEN" });
  const labeled = await save({ content: "after migration", title: "migrationlabel" });
  service.close(); service = new MemoryService({ directory });
  await service.execute(app, { op: "repair" });
  expect((await service.execute(agent, { op: "search", query: "migrationlabel" })).results).toMatchObject([{ id: labeled.id }]);
});

test("a failed migration rolls back columns and version without discarding records", async () => {
  const first = await save();
  service.close();
  const path = join(directory, "memory.sqlite");
  const db = new Database(path);
  restoreV1(db);
  db.exec("ALTER TABLE records ADD COLUMN description TEXT");
  db.close();
  expect(() => new MemoryService({ directory })).toThrow();
  const verify = new Database(path);
  expect(verify.query("PRAGMA user_version").get()).toEqual({ user_version: 1 });
  expect(verify.query("PRAGMA table_info(records)").all()).not.toEqual(expect.arrayContaining([expect.objectContaining({ name: "title" })]));
  expect(verify.query("SELECT id FROM records").get()).toEqual({ id: first.id });
  verify.exec("ALTER TABLE records DROP COLUMN description"); verify.close();
  service = new MemoryService({ directory });
  expect((await get(first.id)).content).toBe(finding().content);
});
