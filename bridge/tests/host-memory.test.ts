import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostServer } from "../src/host-server";
import { HostMemory } from "../src/memory";
import { computeProjectId } from "../src/project-id";
import { createMessage, type AbMessage } from "../src/protocol";
import { MessageBus } from "../src/message-bus";
import type { ProjectCore } from "../src/project-core";
import type { RemoteHostConnection } from "../src/remote-host-connection";
import { Database } from "bun:sqlite";

let root: string;
let previous: string | undefined;
let host: HostServer;
beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "antgrid-host-memory-"));
  previous = process.env.ANTGRID_DIR;
  process.env.ANTGRID_DIR = join(root, "profile");
  host = new HostServer({ desktopOwned: true, warmCap: 4 });
  spyOn(host, "buildToolsAdvertisement").mockResolvedValue([]);
});
afterEach(async () => {
  await host.shutdown();
  if (previous === undefined) delete process.env.ANTGRID_DIR; else process.env.ANTGRID_DIR = previous;
  rmSync(root, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
});

const memory = () => (host as unknown as { memory: HostMemory }).memory;
const app = () => ({ actor: "app" as const });

async function project(name: string) {
  const folder = join(root, name);
  mkdirSync(folder);
  writeFileSync(join(folder, "antgrid.yaml"), "");
  const id = computeProjectId(folder);
  await host.open(id, folder, "local");
  const core = (host as unknown as { cores: Map<string, { core: ProjectCore }> }).cores.get(id)!.core;
  return { id, core, bus: (core as unknown as { bus: MessageBus }).bus };
}

async function seed(projectId: string, scope: "project" | "task", content: string) {
  return await memory().execute(() => ({ actor: "agent", project_id: projectId, session_id: "session", checkout_id: "main", run_id: "run", agent_id: "codex" }), {
    op: "save", operation_key: crypto.randomUUID(), save: { content, memory_type: "note", scope },
  });
}

async function ask(bus: MessageBus, request: object): Promise<any> {
  const requestId = crypto.randomUUID();
  return await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => { unsubscribe(); reject(new Error("memory response timeout")); }, 5000);
    const unsubscribe = bus.subscribe({ deliver: (msg) => {
      if (msg.type === "memory:result" && msg.requestId === requestId) { clearTimeout(timeout); unsubscribe(); resolve(msg); }
    } });
    bus.dispatchInbound({ ...createMessage("memory:request", { requestId, request: { op: "status" } }), request } as AbMessage, "control", "loopback");
  });
}

test("machine memory requires the local owner token and persists opt-in across host restart", async () => {
  const control = await host.startControlPlane();
  const post = async (token: string, request: object) => await fetch(`http://127.0.0.1:${control.port}/control`, {
    method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ id: "memory", type: "memory:request", request }),
  });
  expect((await post("wrong", { op: "status" })).status).toBe(401);
  expect((await (await post(control.token, { op: "status" })).json()).result.enabled).toBe(false);
  expect((await (await post(control.token, { op: "settings", enabled: true })).json()).result.enabled).toBe(true);
  await host.shutdown();
  host = new HostServer({ desktopOwned: true });
  expect((await memory().execute(app, { op: "status" })).enabled).toBe(true);
});

test("project memory stays bound to its admitted core while machine inspection includes retained project records", async () => {
  const first = await project("first-non-git");
  const second = await project("second-non-git");
  expect((await ask(first.bus, { op: "settings", enabled: true })).ok).toBe(true);
  const own = await seed(first.id, "project", "first finding");
  await seed(first.id, "task", "task finding");
  const other = await seed(second.id, "project", "second finding");
  const rows = await ask(first.bus, { op: "list", versions: "all" });
  expect(rows.ok).toBe(true);
  expect(rows.result.results.map((r: any) => r.content).sort()).toEqual(["first finding", "task finding"]);
  expect((await ask(first.bus, { op: "get", id: other.id })).error.code).toBe("NOT_FOUND");
  expect((await ask(first.bus, { op: "get", id: own.id, project_id: second.id })).error.code).toBe("INVALID_ARGUMENT");
  expect((await ask(first.bus, { op: "settings", paused: true })).error.code).toBe("FORBIDDEN");
  expect((await ask(first.bus, { op: "settings", project_paused: true })).result.project_paused).toBe(true);
  (host as unknown as { seenProjects: Map<string, unknown> }).seenProjects.delete(second.id);
  const all = await memory().execute(app, { op: "list", versions: "all" }) as any;
  expect(all.results.map((r: any) => r.content)).toContain("second finding");
  expect((await ask(second.bus, { op: "status" })).error.code).toBe("FORBIDDEN");
});

test("native memory RPC gates account membership, current session and remote access and targets its asker", async () => {
  await host.startControlPlane();
  let authorized = true;
  let live = true;
  const sent: { frame: any; target: unknown }[] = [];
  (host as unknown as { controlPlaneRelay: RemoteHostConnection }).controlPlaneRelay = {
    peerSession: () => live ? {} : null,
    isPeerAuthorized: () => live,
    authorizeDevice: async () => authorized,
    sendOnChannel: (frame: unknown, _channel: unknown, target: unknown) => { sent.push({ frame, target }); },
    close: async () => {}, recheckAuthorization: () => {},
  } as unknown as RemoteHostConnection;
  const rpc = () => createMessage("request", { requestId: "read-memory", method: "memory.request", params: { op: "status" } });
  expect((await host.handleMemoryRpc(rpc(), "phone#machine") as any).error.code).toBe("FORBIDDEN");
  await host.handleRemoteAccessVerb({ id: "enable", type: "mobile-access:set", enabled: true });
  authorized = false;
  expect((await host.handleMemoryRpc(rpc(), "phone#machine") as any).error.code).toBe("FORBIDDEN");
  authorized = true;
  live = false;
  expect((await host.handleMemoryRpc(rpc(), "phone#machine") as any).error.code).toBe("FORBIDDEN");
  live = true;
  expect((await host.handleMemoryRpc(rpc()) as any).error.code).toBe("FORBIDDEN");
  const bus = new MessageBus();
  let broadcast = false;
  bus.subscribe({ deliver: () => { broadcast = true; } });
  host.dispatchControlPlaneInbound(rpc(), "control", bus, "phone#machine");
  for (let attempt = 0; sent.length === 0 && attempt < 50; attempt++) await Bun.sleep(10);
  expect(sent).toHaveLength(1);
  expect(sent[0]!.target).toEqual({ kind: "peer", peerId: "phone#machine" });
  expect(sent[0]!.frame.result.available).toBe(true);
  expect(broadcast).toBe(false);
});

test("a queued machine mutation rechecks its native lease before retry while the session still exists", async () => {
  await host.startControlPlane();
  await host.handleRemoteAccessVerb({ id: "enable", type: "mobile-access:set", enabled: true });
  await memory().execute(app, { op: "repair" });
  let authorized = true;
  (host as unknown as { controlPlaneRelay: RemoteHostConnection }).controlPlaneRelay = {
    peerSession: () => ({}), isPeerAuthorized: () => authorized,
    authorizeDevice: async () => true,
    close: async () => {}, recheckAuthorization: () => {},
  } as unknown as RemoteHostConnection;
  const blocker = new Database(join(root, "profile", "memory", "memory.sqlite"));
  blocker.exec("BEGIN IMMEDIATE");
  const timer = setTimeout(() => { authorized = false; blocker.exec("ROLLBACK"); }, 5);
  try {
    const request = createMessage("request", { requestId: "retry", method: "memory.request", params: { op: "settings", enabled: true } });
    const response = await host.handleMemoryRpc(request, "phone#machine") as any;
    expect(response.error.code).toBe("FORBIDDEN");
    expect((await memory().execute(app, { op: "status" })).enabled).toBe(false);
  } finally {
    clearTimeout(timer);
    if (blocker.inTransaction) blocker.exec("ROLLBACK");
    blocker.close();
  }
});

test("an unreadable memory location is reported without preventing a project from starting", async () => {
  mkdirSync(join(root, "profile"), { recursive: true });
  writeFileSync(join(root, "profile", "memory"), "preserve this file");
  const opened = await project("ordinary-work");
  const status = await ask(opened.bus, { op: "status" });
  expect(status.ok).toBe(true);
  expect(status.result.available).toBe(true);
  expect(status.result.enabled).toBe(false);
  const enable = await ask(opened.bus, { op: "settings", enabled: true });
  expect(enable.ok).toBe(false);
  expect(enable.error.code).toBe("UNAVAILABLE");
});

const agentCaller = () => ({ actor: "agent" as const, project_id: "p1", session_id: "s1", checkout_id: "c1", agent_id: "codex", run_id: "r1" });
const profileDirectory = () => join(root, "profile");
const save = { op: "save", operation_key: crypto.randomUUID(), save: { content: "x", memory_type: "note", scope: "project" } };

test("a profile that never enabled memory is answered without creating a store", async () => {
  const profile = new HostMemory(profileDirectory);
  try {
    expect(await profile.execute(app, { op: "status" })).toEqual({
      available: true, search_status: "ready", enabled: false, paused: false, failed_operations: 0,
      project_paused: false, pending_operations: 0, recovery_status: "ready", failures: [],
    });
    expect(await profile.execute(agentCaller, { op: "status" })).toEqual({
      available: true, search_status: "ready", enabled: false, paused: false, failed_operations: 0,
      project_paused: false, pending_operations: 0, recovery_status: "ready",
    });
    expect(await profile.execute(app, { op: "search", query: "anything" })).toEqual({ results: [], has_more: false, total: 0 });
    await expect(profile.execute(app, { op: "get", id: "m1" })).rejects.toMatchObject({ code: "NOT_FOUND" });
    await expect(profile.execute(app, { op: "export" })).rejects.toMatchObject({ code: "NOT_FOUND" });
    await expect(profile.execute(app, { op: "bogus" })).rejects.toMatchObject({ name: "ZodError" });
    const agentRequests = [
      { op: "recover" }, { op: "search", query: "anything" }, { op: "get", id: "m1" }, { op: "forget", id: "m1" },
      { ...save, op: "prepare" }, save,
    ];
    for (const request of agentRequests) {
      await expect(profile.execute(agentCaller, request)).rejects.toMatchObject({ code: "DISABLED" });
    }
    expect(await profile.execute(app, { op: "settings", enabled: false })).toMatchObject({ enabled: false });
    expect(profile.launchEnabled()).toBe(false);
    expect(existsSync(join(profileDirectory(), "memory"))).toBe(false);
  } finally { profile.close(); }
});

test("an absent store answers projects from the catalog without creating a store", async () => {
  const profile = new HostMemory(profileDirectory, () => [{ project_id: "alpha", label: "Alpha" }, { project_id: "beta" }]);
  try {
    expect(await profile.execute(app, { op: "projects" })).toEqual({
      projects: [
        { project_id: "alpha", memories: 0, earlier_versions: 0, paused: false, label: "Alpha", cataloged: true },
        { project_id: "beta", memories: 0, earlier_versions: 0, paused: false, cataloged: true },
      ],
      memories: 0, earlier_versions: 0,
    });
    expect(existsSync(join(profileDirectory(), "memory"))).toBe(false);
  } finally { profile.close(); }
});

test("removed projects keep their records in the project list but lose an empty settings row", async () => {
  let catalog = [{ project_id: "alpha", label: "Alpha" }, { project_id: "gone-with-records" }, { project_id: "gone-settings-only" }];
  const profile = new HostMemory(profileDirectory, () => catalog);
  const agent = (project_id: string) => () => ({ actor: "agent" as const, project_id, session_id: "s", checkout_id: "main", agent_id: "codex", run_id: "r" });
  try {
    await profile.execute(app, { op: "settings", enabled: true });
    for (const id of ["alpha", "gone-with-records"]) {
      await profile.execute(agent(id), { op: "save", operation_key: crypto.randomUUID(), save: { content: `memory for ${id}`, memory_type: "note", scope: "project" } });
    }
    await profile.execute(app, { op: "settings", project_id: "gone-settings-only", project_paused: true });
    await profile.execute(app, { op: "settings", project_id: "gone-settings-only", project_paused: false });
    catalog = [{ project_id: "alpha", label: "Alpha" }];
    const result = await profile.execute(app, { op: "projects" }) as any;
    expect(result.projects.map((row: any) => row.project_id)).toEqual(["alpha", "gone-with-records"]);
    expect(result.projects[0]).toMatchObject({ label: "Alpha", cataloged: true, memories: 1 });
    expect(result.projects[1]).toMatchObject({ cataloged: false, memories: 1 });
    expect(result.projects[1]).not.toHaveProperty("label");
    expect(result.memories).toBe(2);
  } finally { profile.close(); }
});

test("machine settings for an uncataloged project are refused before a store exists", async () => {
  const profile = new HostMemory(profileDirectory, () => [{ project_id: "alpha" }]);
  try {
    await expect(profile.execute(app, { op: "settings", project_id: "unknown", project_paused: true })).rejects.toMatchObject({ code: "NOT_FOUND" });
    expect(existsSync(join(profileDirectory(), "memory"))).toBe(false);
  } finally { profile.close(); }
});

test("the phone memory RPC accepts a project-narrowed list", async () => {
  await host.startControlPlane();
  (host as unknown as { controlPlaneRelay: RemoteHostConnection }).controlPlaneRelay = {
    peerSession: () => ({}), isPeerAuthorized: () => true, authorizeDevice: async () => true,
    close: async () => {}, recheckAuthorization: () => {},
  } as unknown as RemoteHostConnection;
  await host.handleRemoteAccessVerb({ id: "enable", type: "mobile-access:set", enabled: true });
  const request = createMessage("request", { requestId: "narrow", method: "memory.request", params: { op: "list", project_id: "some-project" } });
  const response = await host.handleMemoryRpc(request, "phone#machine") as any;
  expect(response.error).toBeUndefined();
  expect(response.result).toEqual({ results: [], has_more: false, total: 0 });
});

test("only an app request to enable or repair creates the store, and launches follow the setting", async () => {
  const profile = new HostMemory(profileDirectory);
  try {
    expect(profile.launchEnabled()).toBe(false);
    expect((await profile.execute(app, { op: "settings", enabled: true })).enabled).toBe(true);
    expect(existsSync(join(profileDirectory(), "memory", "memory.sqlite"))).toBe(true);
    expect(profile.launchEnabled()).toBe(true);
    await profile.execute(app, { op: "settings", enabled: false });
    expect(profile.launchEnabled()).toBe(false);
  } finally { profile.close(); }
  const reopened = new HostMemory(profileDirectory);
  try {
    expect(reopened.launchEnabled()).toBe(false);
    await reopened.execute(app, { op: "settings", enabled: true });
  } finally { reopened.close(); }
  const fresh = new HostMemory(profileDirectory);
  try { expect(fresh.launchEnabled()).toBe(true); } finally { fresh.close(); }
  const repaired = new HostMemory(() => join(root, "other"));
  try {
    await repaired.execute(app, { op: "repair" });
    expect(existsSync(join(root, "other", "memory", "memory.sqlite"))).toBe(true);
  } finally { repaired.close(); }
});

test("warm opens an existing store without a request and does nothing for an absent one", async () => {
  const absent = new HostMemory(profileDirectory);
  absent.warm(1);
  await Bun.sleep(30);
  absent.close();
  expect(existsSync(join(profileDirectory(), "memory"))).toBe(false);
  const seeded = new HostMemory(profileDirectory);
  await seeded.execute(app, { op: "settings", enabled: true });
  seeded.close();
  const warmed = new HostMemory(profileDirectory);
  try {
    warmed.warm(1);
    await Bun.sleep(100);
    expect((warmed as unknown as { service?: unknown }).service).toBeDefined();
  } finally { warmed.close(); }
});

const unlaunched = [{
  project_id: "p1", project_label: "One", session_id: "s1", name: "Session", agent_session_resumable: true,
}];

test("an unscoped app status lists sessions without Memory only while Memory is enabled", async () => {
  const rows = () => unlaunched;
  const absent = new HostMemory(profileDirectory, undefined, undefined, rows);
  try {
    expect(await absent.execute(app, { op: "status" })).not.toHaveProperty("sessions_without_memory");
    await absent.execute(app, { op: "settings", enabled: true });
    expect((await absent.execute(app, { op: "status" })).sessions_without_memory).toEqual(unlaunched);
    await absent.execute(app, { op: "settings", enabled: false });
    expect(await absent.execute(app, { op: "status" })).not.toHaveProperty("sessions_without_memory");
  } finally { absent.close(); }
});

test("sessions without Memory are withheld from agents and project-scoped app calls", async () => {
  const hostMemory = new HostMemory(profileDirectory, undefined, undefined, () => unlaunched);
  try {
    await hostMemory.execute(app, { op: "settings", enabled: true });
    const agent = await hostMemory.execute(() => ({
      actor: "agent", project_id: "p1", session_id: "s", checkout_id: "main", run_id: "r", agent_id: "codex",
    }), { op: "status" });
    expect(agent).not.toHaveProperty("sessions_without_memory");
    const scoped = await hostMemory.execute(() => ({ actor: "app", project_id: "p1" }), { op: "status" });
    expect(scoped).not.toHaveProperty("sessions_without_memory");
  } finally { hostMemory.close(); }
});

test("sessions without Memory are never listed for an absent store", async () => {
  const hostMemory = new HostMemory(profileDirectory, undefined, undefined, () => unlaunched);
  try {
    const answer = await hostMemory.execute(app, { op: "status" });
    expect(answer.enabled).toBe(false);
    expect(answer).not.toHaveProperty("sessions_without_memory");
  } finally { hostMemory.close(); }
});

test("the host lists only flagged sessions of cataloged warm projects", async () => {
  const flagged = await project("flagged-non-git");
  const hidden = await project("hidden-non-git");
  const idle = await project("idle-non-git");
  const row = (id: string, extra: object = {}) => ({
    id, name: `name-${id}`, agentSessionResumable: false, ...extra,
  }) as never;
  spyOn(flagged.core, "listSessions").mockReturnValue([
    row("a", { startedWithoutMemory: true, workStatus: "working", agentSessionResumable: true }),
    row("b"),
    row("c", { startedWithoutMemory: true }),
  ]);
  spyOn(hidden.core, "listSessions").mockReturnValue([row("d", { startedWithoutMemory: true })]);
  spyOn(idle.core, "listSessions").mockReturnValue([row("e")]);
  (host as unknown as { seenProjects: Map<string, unknown> }).seenProjects.delete(hidden.id);
  await memory().execute(app, { op: "settings", enabled: true });

  const listed = (await memory().execute(app, { op: "status" }) as any).sessions_without_memory;

  expect(listed).toEqual([
    {
      project_id: flagged.id, project_label: "flagged-non-git", session_id: "a", name: "name-a",
      work_status: "working", agent_session_resumable: true,
    },
    { project_id: flagged.id, project_label: "flagged-non-git", session_id: "c", name: "name-c", agent_session_resumable: false },
  ]);
});
