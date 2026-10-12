import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostServer } from "../src/host-server";
import { SchedulerService } from "../src/scheduler";
import { ProjectCore } from "../src/project-core";
import { computeProjectId } from "../src/project-id";
import { createMessage } from "../src/protocol";
import { MessageBus } from "../src/message-bus";
import type { RemoteHostConnection } from "../src/remote-host-connection";
import { armBodyCapture, captureBody, BODY_REDACTED_MARKER } from "../src/netwatch";
import { Database } from "bun:sqlite";
import { SessionManager } from "../src/session-manager";
import { agentRuntime } from "../src/agent-runtime";

let root: string;
let previous: string | undefined;
let host: HostServer;
beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "scheduler-host-"));
  previous = process.env.ANTGRID_DIR;
  process.env.ANTGRID_DIR = join(root, "state");
  host = new HostServer({ desktopOwned: true, warmCap: 1 });
  spyOn(host, "buildToolsAdvertisement").mockResolvedValue([{ tool: "claude-code", path: "fixture", label: "Claude", chatCapable: true }]);
});
afterEach(async () => {
  armBodyCapture(false, 0);
  await host.shutdown();
  spyOn(host, "buildToolsAdvertisement").mockRestore();
  if (previous === undefined) delete process.env.ANTGRID_DIR; else process.env.ANTGRID_DIR = previous;
  rmSync(root, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
});
const settings = (projectId: string) => ({ name: "Daily review", projectId, agentId: "claude-code", mode: "chat",
  prompt: "Review changes", approvalPolicy: "default", workspace: "shared", cron: "0 9 * * 1-5", timezone: "UTC", enabled: true, catchUp: "latest" });

test("project-free loopback scheduler uses host validation for CRUD and preview", async () => {
  const control = await host.startControlPlane();
  const project = join(root, "project"); mkdirSync(project);
  const projectId = computeProjectId(project);
  await host.open(projectId, project, "local");
  const request = async (method: string, params: object = {}) => {
    const response = await fetch(`http://127.0.0.1:${control.port}/control`, { method: "POST",
      headers: { authorization: `Bearer ${control.token}`, "content-type": "application/json" },
      body: JSON.stringify({ id: "test", type: "scheduler:request", method, params }) });
    return await response.json() as any;
  };
  const capability = await request("scheduler.capabilities");
  expect(capability.result.supported).toBe(true);
  expect(capability.result.supportsBaseBranchClear).toBe(true);
  expect(capability.result.supportsCatchUp).toBe(true);
  expect(capability.result.projects[0]).toMatchObject({ projectId, isGitRepository: false });
  expect((await request("scheduler.preview", { cron: "0 9 * * 1-5", timezone: "UTC" })).result.occurrences).toHaveLength(5);
  for (const params of [{ cron: "@daily", timezone: "UTC" }, { cron: "", timezone: "UTC" },
    { cron: "0 9 * * *", timezone: "Moon/Base" }, { cron: "60 * * * *", timezone: "UTC" }]) {
    expect((await request("scheduler.preview", params)).error.code).toBe("SCHEDULER_INVALID_CRON");
  }
  expect((await request("scheduler.create", { schedule: settings("../escape") })).ok).toBe(false);
  expect((await request("scheduler.create", { schedule: { ...settings(projectId), workspace: "worktree" } })).ok).toBe(false);
  const created = (await request("scheduler.create", { schedule: settings(projectId) })).result.schedule;
  expect(created.authorDeviceId).toBeNull();
  await request("scheduler.update", { id: created.id, patch: { baseBranch: "main" } });
  expect((await request("scheduler.update", { id: created.id, patch: { name: "Renamed" } })).result.schedule.baseBranch).toBe("main");
  expect((await request("scheduler.update", { id: created.id, patch: { baseBranch: null } })).result.schedule.baseBranch).toBeUndefined();
  const scheduler = (host as unknown as { scheduler: SchedulerService }).scheduler;
  const saved = scheduler.schedules().find((s) => s.id === created.id)!;
  scheduler.store.saveSchedule({ ...saved, baseBranch: "main", workspaceCreated: true });
  expect((await request("scheduler.update", { id: created.id, patch: { baseBranch: null } })).error.code).toBe("WORKSPACE_LOCKED");
  expect((await request("scheduler.update", { id: created.id, patch: { name: "Locked" } })).result.schedule.baseBranch).toBe("main");
  expect((await request("scheduler.update", { id: "missing", patch: { name: "Unknown" } })).error.code).toBe("SCHEDULE_NOT_FOUND");
  expect((await request("scheduler.update", { id: created.id, patch: { enabled: false } })).result.schedule.enabled).toBe(false);
  expect((await request("scheduler.list")).result.schedules).toHaveLength(1);
  await request("scheduler.delete", { id: created.id });
  expect((await request("scheduler.list")).result.schedules).toHaveLength(0);
  expect((await request("scheduler.runs")).result.runs).toEqual([]);
});

test("scheduler.list carries each enabled cron schedule's runs in the next day, capped", async () => {
  const control = await host.startControlPlane();
  const project = join(root, "upcoming"); mkdirSync(project);
  const projectId = computeProjectId(project);
  await host.open(projectId, project, "local");
  const request = async (method: string, params: object = {}) => {
    const response = await fetch(`http://127.0.0.1:${control.port}/control`, { method: "POST",
      headers: { authorization: `Bearer ${control.token}`, "content-type": "application/json" },
      body: JSON.stringify({ id: "test", type: "scheduler:request", method, params }) });
    return await response.json() as any;
  };
  const hourly = (await request("scheduler.create", { schedule: { ...settings(projectId), name: "Hourly", cron: "30 * * * *" } })).result.schedule;
  const minutely = (await request("scheduler.create", { schedule: { ...settings(projectId), name: "Minutely", cron: "* * * * *" } })).result.schedule;
  const paused = (await request("scheduler.create", { schedule: { ...settings(projectId), name: "Paused", cron: "0 * * * *", enabled: false } })).result.schedule;
  const before = Date.now();
  const rows = (await request("scheduler.list")).result.schedules as { id: string; upcoming: number[] }[];
  const upcoming = (id: string) => rows.find((row) => row.id === id)!.upcoming;
  expect(upcoming(hourly.id)).toHaveLength(24);
  expect(upcoming(hourly.id).every((at) => at > before - 1000 && at < before + 86_400_000 + 1000)).toBe(true);
  expect(upcoming(minutely.id)).toHaveLength(48);
  expect(upcoming(paused.id)).toEqual([]);
});

test("remote scheduler gates account, switch, safe IDs and targets the requester", async () => {
  await host.startControlPlane();
  let authorized = true;
  const sent: { frame: any; peer: any }[] = [];
  const relay = { peerSession: () => ({}), authorizeDevice: async () => authorized,
    sendOnChannel: (frame: unknown, _channel: unknown, peer: unknown) => { sent.push({ frame, peer }); },
    close: async () => {}, recheckAuthorization: () => {} } as unknown as RemoteHostConnection;
  (host as unknown as { controlPlaneRelay: RemoteHostConnection }).controlPlaneRelay = relay;
  const rpc = (method: string, params: object = {}) => createMessage("request", { requestId: "r", method, params });
  expect((await host.handleSchedulerRpc(rpc("scheduler.list"), "phone#machine") as any).ok).toBe(false);
  await host.handleRemoteAccessVerb({ id: "enable", type: "mobile-access:set", enabled: true });
  authorized = false;
  expect((await host.handleSchedulerRpc(rpc("scheduler.list"), "phone#machine") as any).ok).toBe(false);
  authorized = true;
  for (const params of [{ cron: "@daily", timezone: "UTC" }, { cron: "0 9 * * *", timezone: "Moon/Base" }]) {
    expect((await host.handleSchedulerRpc(rpc("scheduler.preview", params), "phone#machine") as any).error.code).toBe("SCHEDULER_INVALID_CRON");
  }
  const project = join(root, "native-project"); mkdirSync(project);
  const projectId = computeProjectId(project);
  await host.open(projectId, project, "local");
  const created = (await host.handleSchedulerRpc(rpc("scheduler.create", { schedule: { ...settings(projectId), baseBranch: "main" } }), "phone#machine") as any).result.schedule;
  expect((await host.handleSchedulerRpc(rpc("scheduler.update", { id: created.id, patch: { name: "Changed" } }), "phone#machine") as any).result.schedule.baseBranch).toBe("main");
  expect((await host.handleSchedulerRpc(rpc("scheduler.update", { id: created.id, patch: { baseBranch: null } }), "phone#machine") as any).result.schedule.baseBranch).toBeUndefined();
  const scheduler = (host as unknown as { scheduler: SchedulerService }).scheduler;
  const saved = scheduler.schedules().find((s) => s.id === created.id)!;
  scheduler.store.saveSchedule({ ...saved, baseBranch: "main", workspaceCreated: true });
  expect((await host.handleSchedulerRpc(rpc("scheduler.update", { id: created.id, patch: { baseBranch: null } }), "phone#machine") as any).error.code).toBe("WORKSPACE_LOCKED");
  expect((await host.handleSchedulerRpc(rpc("scheduler.create", { schedule: settings("unknown") }), "phone#machine") as any).ok).toBe(false);
  const bus = new MessageBus();
  host.dispatchControlPlaneInbound(rpc("scheduler.list"), "control", bus, "phone#machine");
  for (let attempt = 0; attempt < 20 && sent.length === 0; attempt++) await Bun.sleep(10);
  expect(sent).toHaveLength(1);
  expect(sent[0]!.peer).toEqual({ kind: "peer", peerId: "phone#machine" });
  expect(sent[0]!.frame.ok).toBe(true);
});

test("scheduler diagnostics redact saved prompts in generic requests and replies", () => {
  armBodyCapture(true, 1000);
  for (const value of [
    { type: "request", method: "scheduler.create", params: { schedule: { prompt: "secret" } } },
    { type: "response", result: { schedules: [{ prompt: "secret" }] } },
    { type: "scheduler:request", method: "scheduler.list" },
  ]) expect(captureBody(JSON.stringify(value), value.type)).toBe(BODY_REDACTED_MARKER);
});

test("active scheduled projects survive LRU eviction and explicit project stop releases the run", async () => {
  const launch = spyOn(ProjectCore.prototype, "prepareScheduledSession").mockImplementation(async (_spec, bind) => {
    const identity = { sessionId: "scheduled", checkoutId: "main", runtimeGeneration: "generation" };
    await bind(identity);
    return { ...identity, deliverPrompt: async () => {} };
  });
  try {
    await host.startControlPlane();
    const folder = join(root, "one"); mkdirSync(folder);
    const projectId = computeProjectId(folder);
    await host.open(projectId, folder, "local");
    const created = await host.schedulerRequest("scheduler.create", { schedule: settings(projectId) }) as any;
    const started = await host.schedulerRequest("scheduler.runNow", { id: created.schedule.id }) as any;
    for (let attempt = 0; attempt < 30; attempt++) {
      const history = await host.schedulerRequest("scheduler.runs") as any;
      if (history.runs[0].status === "running") break;
      await Bun.sleep(10);
    }
    const another = join(root, "two"); mkdirSync(another);
    await host.open(computeProjectId(another), another, "local");
    expect(host.get(projectId)?.running).toBe(true);
    await host.stop(projectId);
    const history = await host.schedulerRequest("scheduler.runs") as any;
    expect(history.runs.find((r: any) => r.id === started.run.id).status).toBe("interrupted");
  } finally { launch.mockRestore(); }
});

test("dispatch refuses a stored schedule whose project left the catalog", async () => {
  await host.startControlPlane();
  const folder = join(root, "gone"); mkdirSync(folder);
  const projectId = computeProjectId(folder);
  await host.open(projectId, folder, "local");
  const created = await host.schedulerRequest("scheduler.create", { schedule: settings(projectId) }) as any;
  (host as unknown as { seenProjects: Map<string, unknown> }).seenProjects.delete(projectId);
  const started = await host.schedulerRequest("scheduler.runNow", { id: created.schedule.id }) as any;
  let run: any;
  for (let attempt = 0; attempt < 50; attempt++) {
    run = ((await host.schedulerRequest("scheduler.runs")) as any).runs.find((r: any) => r.id === started.run.id);
    if (run.status === "failed") break;
    await Bun.sleep(10);
  }
  expect(run.status).toBe("failed");
  expect(run.reason).toBe("Project is unavailable. Open it from the desktop before running this schedule.");
});

test("the host launches a scheduled chat run in the schedule's own permission mode", async () => {
  const specs: { chatMode?: string }[] = [];
  const launch = spyOn(ProjectCore.prototype, "prepareScheduledSession").mockImplementation(async (spec, bind) => {
    specs.push(spec);
    const identity = { sessionId: "scheduled", checkoutId: "main", runtimeGeneration: "generation" };
    await bind(identity);
    return { ...identity, deliverPrompt: async () => {} };
  });
  try {
    await host.startControlPlane();
    const folder = join(root, "pinned"); mkdirSync(folder);
    const projectId = computeProjectId(folder);
    await host.open(projectId, folder, "local");
    const created = await host.schedulerRequest("scheduler.create", { schedule: { ...settings(projectId), chatMode: "plan" } }) as any;
    await host.schedulerRequest("scheduler.runNow", { id: created.schedule.id });
    for (let attempt = 0; attempt < 50 && specs.length === 0; attempt++) await Bun.sleep(10);
    expect(specs).toHaveLength(1);
    expect(specs[0]!.chatMode).toBe("plan");
  } finally { launch.mockRestore(); }
});

test("at start the host carries a pre-mode chat schedule over from the project's last-used chat mode", async () => {
  const state = join(root, "state");
  const folder = join(root, "carried"); mkdirSync(folder);
  const projectId = computeProjectId(folder);
  // A store as the previous release left it: the schedules exist, then the version is rewound so the open migrates.
  const seeding = new SchedulerService({ abDir: state, desktopOwned: true, timezone: "UTC",
    supportedAgents: () => [{ agentId: "claude-code", modes: ["terminal", "chat"] }],
    prepare: async () => { throw new Error("not dispatched"); }, stop: async () => {} });
  const carried = await seeding.create({ ...settings(projectId), mode: "chat" } as any);
  const empty = await seeding.create({ ...settings(computeProjectId(join(root, "no-sessions"))), name: "No sessions" } as any);
  seeding.close();
  const db = new Database(join(state, "scheduler", "scheduler.db"));
  try { db.exec("PRAGMA user_version = 2"); } finally { db.close(); }
  const sessions = new SessionManager({ projectId, projectPath: folder, storeDir: state, terminalManager: {} as any,
    agentSpec: { command: "claude", name: "claude-code" }, agentRuntime, sendMessage: () => {} });
  const chat = sessions.create("Mine", { tool: "claude-code", mode: "chat" });
  sessions.setSessionConfig(chat.id, "mode", "auto");
  sessions.flushNow();

  await host.startControlPlane();
  const scheduler = (host as unknown as { scheduler: SchedulerService }).scheduler;
  const settled = () => scheduler.schedules().every((s) => s.chatModeCarryOver === undefined);
  for (let attempt = 0; attempt < 100 && !settled(); attempt++) await Bun.sleep(10);
  const byId = new Map(scheduler.schedules().map((s) => [s.id, s]));
  expect(byId.get(carried.id)).toMatchObject({ chatMode: "auto" });
  expect(byId.get(carried.id)!.chatModeCarryOver).toBeUndefined();
  expect(byId.get(empty.id)!.chatMode).toBeUndefined();
  expect(byId.get(empty.id)!.chatModeCarryOver).toBeUndefined();
});
