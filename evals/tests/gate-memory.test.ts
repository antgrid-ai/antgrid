import { expect, test } from "bun:test";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { MemoryService } from "../../packages/antgrid-memory/src/index";
import { createMessage } from "../../bridge/src/protocol";
import { setupTestEnv, type TestEnv } from "../helpers/harness";
import { TestApp } from "../helpers/test-app";

async function projectRequest(env: TestEnv, streamId: string, request: Record<string, unknown>): Promise<any> {
  const requestId = crypto.randomUUID();
  const response = env.app.waitFor((message: any) => message._streamId === streamId
    && message.type === "memory:result" && message.requestId === requestId, 8000);
  env.app.sendOnStream(streamId, createMessage("memory:request", { requestId, request }));
  return await response;
}

async function machineRequest(env: TestEnv, request: Record<string, unknown>): Promise<any> {
  const requestId = crypto.randomUUID();
  const response = env.app.waitFor((message: any) => message.type === "response" && message.requestId === requestId, 8000);
  env.app.sendEncrypted(createMessage("request", { requestId, method: "memory.request", params: request }));
  return await response;
}

test("native memory inspection, correction, forgetting and restart preserve profile and project boundaries", async () => {
  const env = await setupTestEnv({ fixtureName: "basic", prepareProject: (directory) => {
    const path = join(directory, "antgrid.yaml");
    writeFileSync(path, `${readFileSync(path, "utf8").split("services:")[0]}services: []\n`);
  } });
  try {
    let streamId = env.streamId;
    expect((await projectRequest(env, streamId, { op: "status" })).result.enabled).toBe(false);
    expect((await projectRequest(env, streamId, { op: "settings", enabled: true })).result.enabled).toBe(true);

    // Stored findings are fixtures: this gate qualifies native payload routing,
    // not a provider's willingness to save automatically during a real task.
    const fixture = new MemoryService({ directory: join(env.abDir, "memory") });
    const caller = { owner_id: fixture.ownerId, actor: "agent" as const, project_id: env.projectId,
      session_id: "fixture-session", checkout_id: "main", agent_id: "codex", run_id: "fixture-run" };
    const original = { content: "Quartz build requires tool version 3", memory_type: "observation", scope: "project", applicability: "Windows only; macOS unverified" };
    let own: Record<string, unknown>;
    let foreign: Record<string, unknown>;
    try {
      own = await fixture.execute(caller, { op: "save", operation_key: "original", save: original });
      foreign = await fixture.execute({ ...caller, project_id: "unrelated-project" }, { op: "save", operation_key: "foreign", save: { ...original, content: "Quartz unrelated project finding" } });
      await fixture.execute(caller, { op: "save", operation_key: "task", save: { ...original, scope: "task", memory_type: "task_state", restrict_to_checkout: true, content: "Quartz temporary progress" } });
      await fixture.execute(caller, { op: "prepare", operation_key: "pending-duplicate", save: original });
    } finally { fixture.close(); }

    const matches = await projectRequest(env, streamId, { op: "search", query: "Quartz" });
    expect(matches.ok).toBe(true);
    expect(matches.result.results).toHaveLength(2);
    expect((await projectRequest(env, streamId, { op: "get", id: foreign.id })).error.code).toBe("NOT_FOUND");
    expect((await projectRequest(env, streamId, { op: "get", id: foreign.id, project_id: "unrelated-project" })).error.code).toBe("INVALID_ARGUMENT");
    const exported = await machineRequest(env, { op: "export" });
    expect(exported.result.records).toHaveLength(3);
    expect(JSON.stringify(exported.result)).not.toContain("fixture-run");
    expect(exported.result).not.toHaveProperty("operations");

    expect((await projectRequest(env, streamId, { op: "settings", project_paused: true })).result.project_paused).toBe(true);
    const correction = await projectRequest(env, streamId, { op: "save", operation_key: "app-correction", save: {
      ...original, content: "Quartz build requires tool version 4", supersedes: own.id,
    } });
    expect(correction.ok).toBe(true);
    expect((await projectRequest(env, streamId, { op: "get", id: own.id })).error.code).toBe("NOT_FOUND");
    expect((await projectRequest(env, streamId, { op: "get", id: own.id, history: true })).result.record.lifecycle).toBe("superseded");

    const streamList = await projectRequest(env, streamId, { op: "list", versions: "all" });
    const machineList = await machineRequest(env, { op: "list", project_id: env.projectId, versions: "all" });
    expect(machineList.result.results.map((r: any) => r.id).sort()).toEqual(streamList.result.results.map((r: any) => r.id).sort());
    const projects = await machineRequest(env, { op: "projects" });
    expect(projects.result.projects).toContainEqual(expect.objectContaining({ project_id: env.projectId, cataloged: true }));

    env.app.dropSocket();
    expect(await env.app.waitForClose(2000)).toBe(true);
    const detail = await projectRequest(env, streamId, { op: "get", id: correction.result.id });
    expect(detail.result.record.content).toBe("Quartz build requires tool version 4");
    expect(detail.result.record.applicability).toBe(original.applicability);
    expect((await projectRequest(env, streamId, { op: "forget", id: correction.result.id })).result.cleanup).toBe("complete");

    await env.agent.restart();
    const app = await TestApp.connect(env);
    await app.recoverStateSnapshot({ timeoutMs: 20_000 });
    streamId = await env.app.openProjectStream(env.projectId, 10_000);
    expect((await projectRequest(env, streamId, { op: "status" })).result.project_paused).toBe(true);
    expect((await projectRequest(env, streamId, { op: "get", id: own.id, history: true })).error.code).toBe("NOT_FOUND");
    expect((await projectRequest(env, streamId, { op: "settings", project_paused: false })).ok).toBe(true);
    const restarted = new MemoryService({ directory: join(env.abDir, "memory") });
    try {
      for (const operation_key of ["original", "pending-duplicate"]) {
        await expect(restarted.execute(caller, { op: "save", operation_key, save: original })).rejects.toMatchObject({ code: "FORGOTTEN" });
      }
    } finally { restarted.close(); }
  } finally { await env.teardown(); }
}, 60_000);

test("memory export pages traverse machine and project native responses without losing records", async () => {
  const env = await setupTestEnv({ fixtureName: "basic", prepareProject: (directory) => {
    const path = join(directory, "antgrid.yaml");
    writeFileSync(path, `${readFileSync(path, "utf8").split("services:")[0]}services: []\n`);
  } });
  try {
    const fixture = new MemoryService({ directory: join(env.abDir, "memory") });
    const caller = { owner_id: fixture.ownerId, actor: "agent" as const, project_id: env.projectId,
      session_id: "export-session", checkout_id: "main", agent_id: "codex", run_id: "export-run" };
    const projectIds: string[] = [];
    let foreignId: string;
    try {
      await fixture.execute({ owner_id: fixture.ownerId, actor: "app" }, { op: "settings", enabled: true });
      for (let index = 0; index < 160; index++) {
        const saved = await fixture.execute(caller, { op: "save", operation_key: `export-${index}`, save: {
          content: `Export fixture ${index}: ${'行"\\\n'.repeat(500)}`, memory_type: "observation", scope: "project",
        } });
        projectIds.push(saved.id as string);
      }
      const foreign = await fixture.execute({ ...caller, project_id: "removed-project" }, {
        op: "save", operation_key: "retained-export", save: {
          content: "Retained history from a removed project", memory_type: "note", scope: "project",
        },
      });
      foreignId = foreign.id as string;
    } finally { fixture.close(); }

    const collect = async (request: (body: Record<string, unknown>) => Promise<any>, expectedIds: string[]) => {
      const records: any[] = [];
      const cursors = new Set<string>();
      let cursor: string | undefined;
      let exportedAt: number | undefined;
      let ownerId: string | undefined;
      let pages = 0;
      do {
        const response = await request({ op: "export", ...(cursor ? { cursor } : {}) });
        expect(response.ok).toBe(true);
        expect(Buffer.byteLength(JSON.stringify(response), "utf8")).toBeLessThan(256 * 1024 + 4096);
        const page = response.result;
        expect(page.version).toBe(1);
        expect(page.owner_id).toBe(ownerId ??= page.owner_id);
        expect(page.exported_at).toBe(exportedAt ??= page.exported_at);
        records.push(...page.records);
        pages++;
        expect(page).toHaveProperty("next_cursor");
        if (page.next_cursor === null) break;
        expect(typeof page.next_cursor).toBe("string");
        expect(cursors.has(page.next_cursor)).toBe(false);
        cursors.add(page.next_cursor);
        cursor = page.next_cursor;
        expect(pages).toBeLessThan(160);
      } while (true);
      expect(pages).toBeGreaterThan(1);
      expect(records.map((record) => record.id).sort()).toEqual([...expectedIds].sort());
      return records;
    };

    const machine = await collect((request) => machineRequest(env, request), [...projectIds, foreignId]);
    const project = await collect((request) => projectRequest(env, env.streamId, request), projectIds);
    expect(project).toEqual(machine.filter((record) => record.project_id === env.projectId));

    const interrupted = await machineRequest(env, { op: "export" });
    const cursor = interrupted.result.next_cursor;
    expect(typeof cursor).toBe("string");
    expect((await projectRequest(env, env.streamId, { op: "export", cursor })).error.code).toBe("FORBIDDEN");
    expect((await projectRequest(env, env.streamId, { op: "forget", id: projectIds[0] })).ok).toBe(true);
    expect((await machineRequest(env, { op: "export", cursor })).error.code).toBe("EXPORT_CHANGED");
  } finally { await env.teardown(); }
}, 90_000);
