// The whole agent path with nothing stubbed between the loopback route and the
// scheduler service: a live session's MCP-shaped POST reaches the core's API
// server, the core resolves the caller from its run id, ProjectCore forwards the
// host's closure, and HostServer.schedulerRequestForAgent answers with the
// catalog projectId bound. Each half is tested alone elsewhere; only this file
// fails if `startCore` stops passing `schedulerForAgent` or binds the wrong id.
import { afterAll, afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostServer } from "../src/host-server";
import { computeProjectId } from "../src/project-id";
import type { ProjectCore } from "../src/project-core";
import type { MessageBus } from "../src/message-bus";
import { createMessage, type AbMessage } from "../src/protocol";
import { StructuredAgentManager } from "../src/structured/structured-manager";
import type { SchedulerService } from "../src/scheduler";

let root: string;
let previous: string | undefined;
let host: HostServer;

// The chokidar watcher can emit a late EPERM/ENOENT once its temp dir goes away.
function ignoreWatcherEperm(err: unknown): void {
  const code = (err as { code?: string } | null)?.code;
  if (code === "EPERM" || code === "ENOENT") return;
  throw err;
}
process.on("uncaughtException", ignoreWatcherEperm);
afterAll(() => { process.off("uncaughtException", ignoreWatcherEperm); });

beforeEach(async () => {
  root = mkdtempSync(join(tmpdir(), "host-sched-route-"));
  previous = process.env.ANTGRID_DIR;
  process.env.ANTGRID_DIR = join(root, "state");
  host = new HostServer({ desktopOwned: true, warmCap: 4 });
  spyOn(host, "buildToolsAdvertisement").mockResolvedValue([
    { tool: "claude-code", path: "fixture", label: "Claude", chatCapable: true },
  ]);
  await host.startControlPlane();
});
afterEach(async () => {
  await host.shutdown();
  if (previous === undefined) delete process.env.ANTGRID_DIR; else process.env.ANTGRID_DIR = previous;
  rmSync(root, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
});

const scheduler = () => (host as unknown as { scheduler: SchedulerService }).scheduler;
const coreOf = (projectId: string) =>
  (host as unknown as { cores: Map<string, { core: ProjectCore }> }).cores.get(projectId)!.core;

async function waitFor(pred: () => boolean, timeoutMs = 5000): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (pred()) return true;
    await new Promise((r) => setTimeout(r, 15));
  }
  return pred();
}

async function openPlain(name: string): Promise<string> {
  const folder = join(root, name);
  mkdirSync(folder);
  writeFileSync(join(folder, "antgrid.yaml"), `name: ${name}\n`);
  const projectId = computeProjectId(folder);
  await host.open(projectId, folder, "local");
  return projectId;
}

/** Creates and starts a chat session in the project's warm core and returns
 *  the slot and the run id its MCP server would carry. */
async function liveSession(projectId: string, name: string): Promise<{ sessionId: string; runId: string }> {
  const bus = (coreOf(projectId) as unknown as { bus: MessageBus }).bus;
  const sent: AbMessage[] = [];
  const unsubscribe = bus.subscribe({ deliver: (m) => sent.push(m) });
  try {
    bus.dispatchInbound(createMessage("session:create", { requestId: name, name, tool: "claude-code", mode: "chat" }), "control", "loopback");
    expect(await waitFor(() => sent.some((m) => m.type === "session:result" && (m as any).requestId === name))).toBe(true);
    const created = sent.find((m) => m.type === "session:result" && (m as any).requestId === name) as any;
    expect(created.ok).toBe(true);
    const sessionId = created.session.id as string;
    let runId: string | undefined;
    const start = spyOn(StructuredAgentManager.prototype, "startChat").mockImplementation(async (options) => {
      runId = options.runId;
      return "ready";
    });
    try {
      bus.dispatchInbound(createMessage("session:start", { requestId: `start-${name}`, sessionId }), "control", "loopback");
      expect(await waitFor(() => !!runId)).toBe(true);
    } finally {
      start.mockRestore();
    }
    return { sessionId, runId: runId! };
  } finally {
    unsubscribe();
  }
}

function post(port: number, route: string, terminalId: string, body: Record<string, unknown>): Promise<Response> {
  return fetch(`http://127.0.0.1:${port}/scheduler/${route}?terminalId=${encodeURIComponent(terminalId)}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

test("a live session reaches the host scheduler through its core, scoped to the catalog project", async () => {
  const projectId = await openPlain("caller");
  // Every core writes the same api.port; read it before a second core overwrites it.
  const port = Number(readFileSync(join(process.env.ANTGRID_DIR!, "api.port"), "utf8").trim());
  const { sessionId, runId } = await liveSession(projectId, "Planner");

  const created = await post(port, "create", sessionId, { runId, name: "Nightly review", prompt: "Review the diff", cron: "0 9 * * *" });
  expect(created.status).toBe(200);
  const made = await created.json() as any;
  expect(made.saved).toBe(true);
  expect(made.schedule).toMatchObject({
    projectId, agentId: "claude-code", mode: "chat", approvalPolicy: "default", workspace: "shared",
    authorSessionId: sessionId, authorSessionName: "Planner",
  });
  expect(scheduler().schedules().map((s) => s.id)).toEqual([made.schedule.id]);

  // D1: a gated caller's bypass create is refused before any write.
  const ceiling = await post(port, "create", sessionId, { runId, name: "Unattended", prompt: "Go", cron: "0 9 * * *", approvalPolicy: "bypass" });
  expect(ceiling.status).toBe(403);
  expect((await ceiling.json() as any).code).toBe("APPROVAL_CEILING");

  // D2: another project's schedule is invisible and untouchable from here.
  const otherId = await openPlain("other");
  const other = await host.schedulerRequestForAgent({
    projectId: otherId, sessionId: "other-session", sessionName: "Other", agentId: "claude-code", mode: "chat", approvalLevel: "gated", scheduled: false,
  }, "create", { name: "Elsewhere", prompt: "Other work", cron: "0 10 * * *" }) as any;
  for (const [route, body] of [
    ["update", { id: other.schedule.id, prompt: "Hijacked" }],
    ["delete", { id: other.schedule.id }],
    ["run-now", { id: other.schedule.id }],
  ] as const) {
    const res = await post(port, route, sessionId, { runId, ...body });
    expect(res.status).toBe(404);
    expect((await res.json() as any).code).toBe("SCHEDULE_NOT_FOUND");
  }
  expect(scheduler().schedules().find((s) => s.id === other.schedule.id)).toMatchObject({ projectId: otherId, prompt: "Other work" });

  const listed = await post(port, "list", sessionId, { runId });
  expect(listed.status).toBe(200);
  const page = await listed.json() as any;
  expect(page.header).toMatchObject({ timezone: scheduler().timezone });
  expect(page.schedules.map((s: { id: string }) => s.id)).toEqual([made.schedule.id]);
  expect(page.projects).toBeUndefined();
});

test("the same route refuses a guessed run id before the host is consulted", async () => {
  const projectId = await openPlain("guess");
  const port = Number(readFileSync(join(process.env.ANTGRID_DIR!, "api.port"), "utf8").trim());
  const { sessionId } = await liveSession(projectId, "Guesser");
  const res = await post(port, "create", sessionId, { runId: "guessed", name: "Sneaky", prompt: "Go", cron: "0 9 * * *" });
  expect(res.status).toBe(403);
  expect((await res.json() as any).code).toBe("NOT_A_SESSION");
  expect(scheduler().schedules()).toHaveLength(0);
});
