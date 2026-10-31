// Mutating and reading bus requests as the responder serves them. Cores are
// stand-ins that record what the host asks of them; the seams themselves are
// pinned in bus-session-seams.test.ts against a real core.
import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { randomUUID } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { HostServer } from "../src/host-server";
import { setLogLevel } from "../src/logger";
import { computeProjectId } from "../src/project-id";
import { createMessage } from "../src/protocol";
import { BusRequests } from "../src/session-bus/bus-requests";
import type { BusSendInput, InboundVerdict, VerifiedInbound } from "../src/session-bus/relay-transport";
import type { InnerHeader } from "../src/session-bus/seal";
import { BUS_SESSION_ROW_KEYS } from "../src/session-bus/request-policy";
import { createHostPolicyFixture } from "./host-policy-fixture";

setLogLevel("error");

const PEER = randomUUID();
const SELF = randomUUID();

let prevAbDir: string | undefined;
let abDir: string;
let dir: string;
let host: HostServer | null = null;

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-bus-req-"));
  dir = mkdtempSync(join(tmpdir(), "antgrid-bus-req-proj-"));
  process.env.ANTGRID_DIR = abDir;
});

afterEach(async () => {
  try { await host?.shutdown(); } catch { /* best effort */ }
  host = null;
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR;
  else process.env.ANTGRID_DIR = prevAbDir;
  for (const p of [abDir, dir]) {
    try { rmSync(p, { recursive: true, force: true }); } catch { /* Windows handle */ }
  }
});

function fakeCore() {
  const calls: Array<[string, ...unknown[]]> = [];
  const sessions: any[] = [];
  return {
    calls,
    sessions,
    listSessions: () => sessions,
    createSessionForBus: mock(async (spec: unknown) => {
      calls.push(["create", spec]);
      const session = { id: "s1", name: "n", createdAt: 1, lastUsedAt: 1, archived: false, running: false, mode: "terminal", approvalPolicy: "default", agentTranscriptPath: "/secret" };
      return { ok: true as const, session };
    }),
    startSessionForBus: mock(async (id: string, prompt?: string): Promise<{ ok: true } | { ok: false; code: string }> => {
      calls.push(["start", id, prompt]);
      return { ok: true };
    }),
    stopSessionForBus: mock(async (id: string) => {
      calls.push(["stop", id]);
      return { ok: true as const };
    }),
    deleteSession: async () => true,
  };
}

interface Rig {
  h: HostServer;
  core: ReturnType<typeof fakeCore>;
  frames: BusSendInput[];
  projectId: string;
  inbound: (v: VerifiedInbound) => Promise<InboundVerdict>;
  setDirectory: (d: { orchestrators?: string[]; busControl?: boolean }) => void;
}

function rig(opts: { reach?: boolean; warm?: boolean } = {}): Rig {
  const h = createHostPolicyFixture({});
  host = h;
  const frames: BusSendInput[] = [];
  (h as any).busRequests = new BusRequests({
    transport: { send: (i) => { frames.push(i); return { sent: true }; } },
    selfRole: () => "agent",
  });
  (h as any).remoteAccessPolicy.setEnabled(true);
  (h as any).agentReachPolicy.setEnabled(opts.reach ?? true);
  const projectId = computeProjectId(dir);
  (h as any).seenProjects.set(projectId, { path: dir, label: "p", lastActiveAt: Date.now() });
  const core = fakeCore();
  if (opts.warm ?? true) (h as any).cores.set(projectId, { core, path: dir, mode: "local", lastFocusedMs: 0 });
  const setDirectory = (d: { orchestrators?: string[]; busControl?: boolean }) => {
    (h as any).machineDirectory = {
      machine: (id: string) => ({ deviceId: id, orchestrator: d.orchestrators?.includes(id) ?? false }),
      selfBusControl: () => d.busControl ?? false,
      selfOrchestrator: () => false,
      current: () => null,
      kick: () => {},
      onChange: () => () => {},
      stop: () => {},
    };
  };
  setDirectory({});
  return { h, core, frames, projectId, inbound: (v) => (h as any).handleBusInbound(v), setDirectory };
}

function request(method: string, params: unknown, claimedRole: "agent" | "orchestrator" = "agent", id = randomUUID()): VerifiedInbound {
  const header: InnerHeader = {
    v: 1, from: PEER, to: SELF, id, role: claimedRole, kind: "request",
    sentAt: Date.now(), expiresAt: Date.now() + 60_000,
  };
  return { from: PEER, id, header, role: claimedRole, body: createMessage("request", { requestId: id, method, params }) };
}

const answerOf = (v: InboundVerdict): { ok: boolean; result?: any; error?: { code: string } } =>
  JSON.parse((v as { response: string }).response);

test("methods outside the allowlist are refused METHOD_NOT_ALLOWED and nothing is sent", async () => {
  const { frames, core, inbound, setDirectory } = rig();
  setDirectory({ orchestrators: [PEER], busControl: true });
  for (const method of ["state.snapshot", "git.checkout", "sessions.delete", "scheduler.list", "scheduler.run", "session.delete"]) {
    expect(await inbound(request(method, {}, "orchestrator"))).toEqual({ outcome: "refused", code: "METHOD_NOT_ALLOWED" });
  }
  expect(frames).toEqual([]);
  expect(core.calls).toEqual([]);
});

test("remote access off is refused before anything else", async () => {
  const { h, frames, inbound, projectId } = rig();
  (h as any).remoteAccessPolicy.setEnabled(false);
  expect(await inbound(request("sessions.list", { projectId }))).toEqual({ outcome: "refused", code: "REMOTE_ACCESS_OFF" });
  expect(frames).toEqual([]);
});

test("at messages level a mutating request is NOT_ALLOWED_AGENT_REACH even from an orchestrator", async () => {
  const { core, inbound, projectId, setDirectory } = rig();
  setDirectory({ orchestrators: [PEER], busControl: false });
  const v = await inbound(request("session.create", { projectId }, "orchestrator"));
  expect(answerOf(v)).toMatchObject({ ok: false, error: { code: "NOT_ALLOWED_AGENT_REACH" } });
  expect(core.calls).toEqual([]);
});

test("a role the request claims is ignored: the directory says agent, so NOT_ORCHESTRATOR", async () => {
  const { core, inbound, projectId, setDirectory } = rig();
  setDirectory({ orchestrators: [], busControl: true });
  const v = await inbound(request("session.create", { projectId }, "orchestrator"));
  expect(answerOf(v)).toMatchObject({ ok: false, error: { code: "NOT_ORCHESTRATOR" } });
  expect(core.calls).toEqual([]);
});

test("with reach off a read is refused too, the capability card included", async () => {
  const { inbound, projectId, setDirectory } = rig({ reach: false });
  setDirectory({ orchestrators: [PEER], busControl: true });
  for (const [method, params] of [["sessions.list", { projectId }], ["machine.capability-card", {}]] as const) {
    expect(answerOf(await inbound(request(method, params, "orchestrator")))).toMatchObject({
      ok: false, error: { code: "NOT_ALLOWED_AGENT_REACH" },
    });
  }
});

test("a verified orchestrator at control level creates, starts with a prompt, and stops", async () => {
  const { core, inbound, frames, projectId, setDirectory } = rig();
  setDirectory({ orchestrators: [PEER], busControl: true });

  const created = answerOf(await inbound(request("session.create", { projectId, name: "n", tool: "claude-code", mode: "chat" })));
  expect(created.ok).toBe(true);
  expect(Object.keys(created.result.session).sort()).toEqual(["archived", "createdAt", "id", "lastUsedAt", "mode", "name", "running"]);
  expect(core.calls[0]).toEqual(["create", { name: "n", tool: "claude-code", mode: "chat" }]);

  const started = answerOf(await inbound(request("session.start", { projectId, sessionId: "s1", initialPrompt: "go" })));
  expect(started).toMatchObject({ ok: true, result: { sessionId: "s1" } });
  expect(core.calls[1]).toEqual(["start", "s1", "go"]);

  expect(answerOf(await inbound(request("session.stop", { projectId, sessionId: "s1" })))).toMatchObject({ ok: true });
  expect(core.calls[2]).toEqual(["stop", "s1"]);

  // Every answer went to the asker as a response and nowhere else.
  expect(frames).toHaveLength(3);
  expect(frames.every((f) => f.kind === "response" && f.to === PEER)).toBe(true);
});

test("the request schema rejects command, args and approvalPolicy on session.create", async () => {
  const { core, inbound, projectId, setDirectory } = rig();
  setDirectory({ orchestrators: [PEER], busControl: true });
  for (const extra of [{ command: "sh" }, { args: "-c x" }, { approvalPolicy: "bypass" }]) {
    expect(answerOf(await inbound(request("session.create", { projectId, ...extra })))).toMatchObject({
      ok: false, error: { code: "BAD_PARAMS" },
    });
  }
  expect(core.calls).toEqual([]);
});

test("a seam refusal reaches the asker as its own code", async () => {
  const { core, inbound, projectId, setDirectory } = rig();
  setDirectory({ orchestrators: [PEER], busControl: true });
  core.startSessionForBus.mockImplementationOnce(async () => ({ ok: false, code: "SESSION_NOT_BUS_ELIGIBLE" }));
  expect(answerOf(await inbound(request("session.start", { projectId, sessionId: "s1" })))).toMatchObject({
    ok: false, error: { code: "SESSION_NOT_BUS_ELIGIBLE" },
  });
});

test("sessions.list rows carry exactly the allowlist", async () => {
  const { core, inbound, projectId } = rig();
  core.sessions.push({
    id: "s1", name: "n", createdAt: 1, lastUsedAt: 2, archived: false, running: true, deleting: false,
    tool: "claude", agentKey: "claude", mode: "chat", approvalPolicy: "bypass", command: "sh", args: "-x",
    agentSessionId: "native", agentTranscriptPath: "/secret", workStatus: "working",
    checkoutKind: "main", checkoutBranch: "main", checkoutId: "main", setup: { state: "done" },
  });
  const a = answerOf(await inbound(request("sessions.list", { projectId })));
  expect(a.ok).toBe(true);
  expect(a.result.sessions).toHaveLength(1);
  expect(Object.keys(a.result.sessions[0]).sort()).toEqual([...BUS_SESSION_ROW_KEYS].sort());
});

test("a project outside the catalog, or with an unsafe id, is UNKNOWN_PROJECT", async () => {
  const { inbound, core, setDirectory } = rig();
  setDirectory({ orchestrators: [PEER], busControl: true });
  for (const projectId of ["not-a-project", "../x", ".hidden", "a/b"]) {
    expect(answerOf(await inbound(request("session.create", { projectId })))).toMatchObject({
      ok: false, error: { code: "UNKNOWN_PROJECT" },
    });
  }
  expect(core.calls).toEqual([]);
});

test("a cold project is warmed with open(projectId, path, local) before the seam runs", async () => {
  const { h, core, inbound, projectId, setDirectory } = rig({ warm: false });
  setDirectory({ orchestrators: [PEER], busControl: true });
  const open = spyOn(h, "open").mockImplementation(async () => {
    (h as any).cores.set(projectId, { core, path: dir, mode: "local", lastFocusedMs: 0 });
    return {} as any;
  });
  expect(answerOf(await inbound(request("project.start", { projectId }))).ok).toBe(true);
  expect(open).toHaveBeenCalledTimes(1);
  expect(open.mock.calls[0]![1]).toBe(dir);
  expect(open.mock.calls[0]![2]).toBe("local");
});

test("a project that will not open answers REQUEST_FAILED", async () => {
  const { h, inbound, projectId, setDirectory } = rig({ warm: false });
  setDirectory({ orchestrators: [PEER], busControl: true });
  spyOn(h, "open").mockRejectedValue(new Error("boom"));
  expect(answerOf(await inbound(request("session.stop", { projectId, sessionId: "s1" })))).toMatchObject({
    ok: false, error: { code: "REQUEST_FAILED" },
  });
});

test("the per-machine rate is charged before reach and role refusals", async () => {
  const { inbound, projectId } = rig();
  for (let i = 0; i < 60; i++) {
    expect(answerOf(await inbound(request("session.create", { projectId }))).error?.code).toBe("NOT_ALLOWED_AGENT_REACH");
  }
  expect(answerOf(await inbound(request("session.create", { projectId }))).error?.code).toBe("REQUEST_RATE");
}, 30_000);

test("an answer too large for one sealed message is replaced by RESPONSE_TOO_LARGE", async () => {
  const { core, inbound, projectId, frames } = rig();
  for (let i = 0; i < 400; i++) core.sessions.push({ id: `s${i}`, name: "x".repeat(2_000), createdAt: 1, lastUsedAt: 1, archived: false, running: false, mode: "terminal" });
  const v = await inbound(request("sessions.list", { projectId }));
  expect(answerOf(v)).toMatchObject({ ok: false, error: { code: "RESPONSE_TOO_LARGE" } });
  expect(frames[0]!.body).toMatchObject({ ok: false, error: { code: "RESPONSE_TOO_LARGE" } });
});
