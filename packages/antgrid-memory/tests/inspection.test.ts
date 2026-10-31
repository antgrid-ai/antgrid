import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { MemoryService, TASK_EXPIRY_MS, type MemoryContext, type MemoryRecord } from "../src";
import { searchResponse } from "../src/search";

const P1 = "project-one";
const P2 = "project-two";
let directory: string;
let service: MemoryService;
let now: number;
let app: MemoryContext;
let projectApp: MemoryContext;
let databases: Database[];

const agentFor = (project: string): MemoryContext => ({
  actor: "agent", owner_id: service.ownerId, project_id: project, session_id: "durable-session", checkout_id: "main", run_id: "live-run", agent_id: "claude-code",
});
const call = (ctx: MemoryContext, request: Record<string, unknown>) => service.execute(ctx, request);
const body = (content: string, overrides: Record<string, unknown> = {}) => ({ content, memory_type: "observation", scope: "project", ...overrides });
async function save(content: string, overrides: Record<string, unknown> = {}, ctx: MemoryContext = agentFor(P1)): Promise<string> {
  return (await call(ctx, { op: "save", operation_key: crypto.randomUUID(), save: body(content, overrides) }) as { id: string }).id;
}
async function correct(id: string, content: string, key: string = crypto.randomUUID(), ctx: MemoryContext = app): Promise<string> {
  return (await call(ctx, { op: "save", operation_key: key, save: body(content, { supersedes: id }) }) as { id: string }).id;
}
const list = async (ctx: MemoryContext, request: Record<string, unknown> = {}) =>
  await call(ctx, { op: "list", ...request }) as { results: MemoryRecord[]; has_more: boolean; total: number };
const ids = (records: MemoryRecord[]) => records.map(r => r.id);
const rejects = (promise: Promise<unknown>, code: string) => expect(promise).rejects.toMatchObject({ code });
function sql(): Database { const db = new Database(join(directory, "memory.sqlite")); databases.push(db); return db; }

beforeEach(async () => {
  directory = mkdtempSync(join(tmpdir(), "antgrid-memory-inspection-"));
  now = Date.UTC(2026, 9, 28);
  service = new MemoryService({ directory, now: () => now });
  app = { actor: "app", owner_id: service.ownerId };
  projectApp = { ...app, project_id: P1 };
  databases = [];
  await call(app, { op: "settings", enabled: true });
});
afterEach(() => {
  for (const db of databases) db.close();
  service.close();
  rmSync(directory, { recursive: true, force: true });
});

describe("project narrowing", () => {
  test("a machine caller may narrow, a project caller may not switch, an agent may not choose", async () => {
    await save("first project memory");
    await save("second project memory", {}, agentFor(P2));
    const narrowed = await list(app, { project_id: P1 });
    expect(ids(narrowed.results)).toEqual(ids((await list(projectApp)).results));
    expect(narrowed.results).toHaveLength(1);
    expect((await list(app)).results).toHaveLength(2);
    await rejects(call(projectApp, { op: "list", project_id: P2 }), "FORBIDDEN");
    expect(ids((await list(projectApp, { project_id: P1 })).results)).toEqual(ids(narrowed.results));
    await rejects(call(agentFor(P1), { op: "search", query: "memory", project_id: P1 }), "FORBIDDEN");
    await rejects(call(app, { op: "get", id: narrowed.results[0]!.id, project_id: P1 }), "INVALID_ARGUMENT");
  });
});

describe("versions, filters and paging", () => {
  test("current, earlier and all partition the records, and memory_type narrows", async () => {
    const original = await save("original wording");
    const replacement = await correct(original, "replacement wording");
    const stale = await save("old task progress", { memory_type: "task_state", scope: "task" });
    const preference = await save("always use tabs", { memory_type: "preference" });
    now += TASK_EXPIRY_MS + 1;
    const current = ids((await list(app)).results);
    const earlier = ids((await list(app, { versions: "earlier" })).results);
    const all = ids((await list(app, { versions: "all" })).results);
    expect(new Set(current)).toEqual(new Set([replacement, preference]));
    expect(new Set(earlier)).toEqual(new Set([original, stale]));
    expect(all.sort()).toEqual([...current, ...earlier].sort());
    expect(ids((await list(app, { versions: "all", memory_type: "preference" })).results)).toEqual([preference]);
    expect((await list(app, { versions: "earlier", memory_type: "task_state" })).total).toBe(1);
  });

  test("total is stable across pages and has_more is exact at 51 rows", async () => {
    for (let i = 0; i < 51; i++) await save(`distinct memory number ${i}`);
    const first = await list(app);
    const second = await list(app, { offset: 50 });
    expect(first.results).toHaveLength(50);
    expect([first.has_more, second.has_more]).toEqual([true, false]);
    expect([first.total, second.total]).toEqual([51, 51]);
    expect(second.results).toHaveLength(1);
  });

  test("offset paging repeats the boundary row when a record lands at the head", async () => {
    for (let i = 0; i < 51; i++) await save(`distinct memory number ${i}`);
    const first = await list(app);
    now += 1000;
    await save("a newer memory");
    const second = await list(app, { offset: 50 });
    expect(second.results[0]!.id).toBe(first.results[49]!.id);
  });
});

describe("app and agent search", () => {
  test("the app gets complete records with paging, while agent output keeps its shape", async () => {
    for (let i = 0; i < 3; i++) await save(`kiwi fruit note ${i}`, { evidence: ["src/a.ts"] });
    const result = await call(app, { op: "search", query: "kiwi", limit: 50, offset: 0 }) as { results: MemoryRecord[]; has_more: boolean; total: number };
    expect(result.total).toBe(3);
    expect(result.has_more).toBe(false);
    expect(result.results[0]).toMatchObject({ evidence: ["src/a.ts"], created_at: now });
    expect(result.results[0]).not.toHaveProperty("excerpted");
    const paged = await call(app, { op: "search", query: "kiwi", limit: 2, offset: 2 }) as { results: unknown[]; has_more: boolean; total: number };
    expect([paged.results.length, paged.has_more, paged.total]).toEqual([1, false, 3]);

    const agentResult = await call(agentFor(P1), { op: "search", query: "kiwi" });
    expect(Object.keys(agentResult)).toEqual(["results", "has_more"]);
    expect(JSON.stringify(agentResult)).toBe(JSON.stringify(searchResponse(result.results, 5)));
  });

  test("earlier versions are searchable only when asked for", async () => {
    const original = await save("original zebra note");
    await correct(original, "revised giraffe note");
    expect((await call(app, { op: "search", query: "zebra" })).results).toEqual([]);
    const found = await call(app, { op: "search", query: "zebra", versions: "earlier" }) as { results: MemoryRecord[] };
    expect(ids(found.results)).toEqual([original]);
  });

  test("a punctuation-only query is an empty app result but still an agent error", async () => {
    await save("anything at all");
    expect(await call(app, { op: "search", query: "!!" })).toEqual({ results: [], has_more: false, total: 0 });
    await rejects(call(agentFor(P1), { op: "search", query: "!!" }), "INVALID_ARGUMENT");
  });

  test("a broken index is an error even for a punctuation-only app query", async () => {
    (service as unknown as { store: { searchReady: boolean } }).store.searchReady = false;
    await rejects(call(app, { op: "search", query: "!!" }), "SEARCH_UNAVAILABLE");
  });
});

describe("projects", () => {
  test("counts current and earlier memories per project, including settings-only projects", async () => {
    const original = await save("first wording");
    await correct(original, "second wording");
    await save("other project memory", {}, agentFor(P2));
    await call(app, { op: "settings", project_id: P2, project_paused: true });
    await call(app, { op: "settings", project_id: "settings-only", project_paused: true });
    const result = await call(app, { op: "projects" }) as { projects: { project_id: string; memories: number; earlier_versions: number; paused: boolean }[]; memories: number; earlier_versions: number };
    expect(result.projects).toEqual([
      { project_id: P1, memories: 1, earlier_versions: 1, paused: false },
      { project_id: P2, memories: 1, earlier_versions: 0, paused: true },
      { project_id: "settings-only", memories: 0, earlier_versions: 0, paused: true },
    ]);
    expect([result.memories, result.earlier_versions]).toEqual([2, 1]);
    expect((await call(projectApp, { op: "projects" })).projects).toEqual([{ project_id: P1, memories: 1, earlier_versions: 1, paused: false }]);
  });

  test("a machine project pause is visible, and a machine profile pause is refused when narrowed", async () => {
    await save("some memory");
    await call(app, { op: "settings", project_id: P1, project_paused: true });
    expect((await call(app, { op: "projects" })).projects).toMatchObject([{ project_id: P1, paused: true }]);
    expect(await call(projectApp, { op: "status" })).toMatchObject({ project_paused: true });
    await rejects(call(app, { op: "settings", project_id: P1, paused: true }), "FORBIDDEN");
  });
});

describe("conflicts", () => {
  async function conflicted(key: string) {
    const stale = await save("stale wording");
    const current = await correct(stale, "current wording");
    await rejects(call(app, { op: "save", operation_key: key, save: body("late wording", { supersedes: stale }) }), "CONFLICT");
    return { stale, current };
  }

  test("a machine correction of a superseded memory is reported against its project and can be dismissed", async () => {
    const { stale, current } = await conflicted("late-key");
    const status = await call(app, { op: "status" });
    expect(status).toMatchObject({ failed_operations: 1, failures: [{ code: "CONFLICT", target_id: stale, latest_id: current, project_id: P1 }] });
    expect(await call(projectApp, { op: "status" })).toMatchObject({ failed_operations: 1 });
    expect(await call(agentFor(P1), { op: "status" })).not.toHaveProperty("failures");

    expect(await call(app, { op: "dismiss", target_id: stale })).toMatchObject({ failed_operations: 0, failures: [] });
    expect(await call(projectApp, { op: "status" })).toMatchObject({ failed_operations: 0 });
    await rejects(call(app, { op: "save", operation_key: "late-key", save: body("late wording", { supersedes: stale }) }), "CONFLICT");

    const db = sql();
    expect(db.query("SELECT failure_code, outcome FROM operations WHERE operation_key='late-key'").get()).toEqual({ failure_code: "CONFLICT", outcome: "dismissed" });
    expect(db.query("PRAGMA user_version").get()).toEqual({ user_version: 1 });
  });

  test("forgetting the latest version clears the failure and consumes the key", async () => {
    const { current } = await conflicted("forgotten-key");
    await call(app, { op: "forget", id: current });
    expect(await call(app, { op: "status" })).toMatchObject({ failed_operations: 0, failures: [] });
    await rejects(call(app, { op: "save", operation_key: "forgotten-key", save: body("late wording", { supersedes: current }) }), "FORGOTTEN");
  });
});

describe("earlier versions of a memory", () => {
  test("get lists the chain newest first, capped at 20", async () => {
    let id = await save("version 0");
    const chain = [id];
    for (let i = 1; i <= 22; i++) { id = await correct(id, `version ${i}`); chain.push(id); }
    const result = await call(app, { op: "get", id, history: true, earlier: true }) as { record: MemoryRecord; earlier: MemoryRecord[]; earlier_has_more: boolean };
    expect(result.record.id).toBe(id);
    expect(ids(result.earlier)).toEqual(chain.slice(-21, -1).reverse());
    expect(result.earlier_has_more).toBe(true);

    const short = await call(app, { op: "get", id: chain[2], history: true, earlier: true }) as { earlier: MemoryRecord[]; earlier_has_more: boolean };
    expect(ids(short.earlier)).toEqual([chain[1], chain[0]]);
    expect(short.earlier_has_more).toBe(false);
  });
});

describe("export narrowing", () => {
  test("a narrowed export equals the project export and its cursor stays bound to the project", async () => {
    for (let i = 0; i < 65; i++) await save(`exported memory ${i}`);
    await save("other project export", {}, agentFor(P2));
    const narrowed = await call(app, { op: "export", project_id: P1 }) as { records: MemoryRecord[]; next_cursor: string | null };
    const scoped = await call(projectApp, { op: "export" }) as { records: MemoryRecord[]; next_cursor: string | null };
    expect(ids(narrowed.records)).toEqual(ids(scoped.records));
    expect(narrowed.records).toHaveLength(64);
    expect(narrowed.next_cursor).not.toBeNull();
    await rejects(call(app, { op: "export", cursor: narrowed.next_cursor! }), "FORBIDDEN");
    const next = await call(app, { op: "export", project_id: P1, cursor: narrowed.next_cursor! }) as { records: MemoryRecord[] };
    expect(next.records).toHaveLength(1);
  });
});
