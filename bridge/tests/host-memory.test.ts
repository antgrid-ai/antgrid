import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
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

async function seed(projectId: string, scope: "user" | "project" | "task", content: string) {
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
  await seed(first.id, "user", "user finding");
  const own = await seed(first.id, "project", "first finding");
  await seed(first.id, "task", "task finding");
  const other = await seed(second.id, "project", "second finding");
  const rows = await ask(first.bus, { op: "list", history: true });
  expect(rows.ok).toBe(true);
  expect(rows.result.results.map((r: any) => r.content).sort()).toEqual(["first finding", "task finding"]);
  expect((await ask(first.bus, { op: "get", id: other.id })).error.code).toBe("NOT_FOUND");
  expect((await ask(first.bus, { op: "get", id: own.id, project_id: second.id })).error.code).toBe("INVALID_ARGUMENT");
  expect((await ask(first.bus, { op: "settings", paused: true })).error.code).toBe("FORBIDDEN");
  expect((await ask(first.bus, { op: "settings", project_paused: true })).result.project_paused).toBe(true);
  (host as unknown as { seenProjects: Map<string, unknown> }).seenProjects.delete(second.id);
  const all = await memory().execute(app, { op: "list", history: true }) as any;
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
  await memory().execute(app, { op: "status" });
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
  expect(status.result.available).toBe(false);
  expect(status.result.error.code).toBe("UNAVAILABLE");
});
