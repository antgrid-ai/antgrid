import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostServer } from "../src/host-server";
import { ProjectCore } from "../src/project-core";
import { computeProjectId } from "../src/project-id";
import { createMessage } from "../src/protocol";
import { MessageBus } from "../src/message-bus";
import type { RemoteHostConnection } from "../src/remote-host-connection";
import { armBodyCapture, captureBody, BODY_REDACTED_MARKER } from "../src/netwatch";

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
  prompt: "Review changes", approvalPolicy: "default", workspace: "shared", cron: "0 9 * * 1-5", timezone: "UTC", enabled: true });

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
  expect(capability.result.projects[0]).toMatchObject({ projectId, isGitRepository: false });
  expect((await request("scheduler.preview", { cron: "0 9 * * 1-5", timezone: "UTC" })).result.occurrences).toHaveLength(5);
  expect((await request("scheduler.preview", { cron: "@daily", timezone: "UTC" })).ok).toBe(false);
  expect((await request("scheduler.create", { schedule: settings("../escape") })).ok).toBe(false);
  expect((await request("scheduler.create", { schedule: { ...settings(projectId), workspace: "worktree" } })).ok).toBe(false);
  const created = (await request("scheduler.create", { schedule: settings(projectId) })).result.schedule;
  expect(created.authorDeviceId).toBeNull();
  expect((await request("scheduler.update", { id: created.id, patch: { enabled: false } })).result.schedule.enabled).toBe(false);
  expect((await request("scheduler.list")).result.schedules).toHaveLength(1);
  await request("scheduler.delete", { id: created.id });
  expect((await request("scheduler.list")).result.schedules).toHaveLength(0);
  expect((await request("scheduler.runs")).result.runs).toEqual([]);
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
