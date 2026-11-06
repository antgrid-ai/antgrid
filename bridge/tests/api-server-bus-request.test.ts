// POST /session-bus/request: the loopback door an agent's MCP tool uses to ask
// another machine for something. What the other machine allows is decided
// there; this route only names a caller, bounds the body, and renders the answer.
import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { startApiServer, type AgentContext } from "../src/api-server";
import type { AbConfig } from "../src/config";
import { createSessionBusApi } from "../src/session-bus/api";
import { BUS_REQUEST_MAX_TIMEOUT_MS } from "../src/session-bus/constants";
import type { BusRequestResult } from "../src/session-bus/bus-requests";
import { SessionBusCoordinator } from "../src/session-bus/coordinator";

const dirs: string[] = [];
const stops: Array<() => void> = [];

afterEach(() => {
  for (const s of stops.splice(0)) s();
  for (const d of dirs.splice(0)) {
    try { rmSync(d, { recursive: true, force: true }); } catch { /* Windows handle */ }
  }
});

const TARGET = randomUUID();

function rig(opts: { answer?: BusRequestResult; remote?: boolean; withRequest?: boolean } = {}) {
  const abDir = realpathSync(mkdtempSync(join(tmpdir(), "antgrid-bus-request-api-")));
  dirs.push(abDir);
  const asked: Array<{ to: string; method: string; params?: unknown; timeoutMs: number }> = [];
  const coordinator = new SessionBusCoordinator({
    abDir,
    projectIdFor: () => "p",
    self: () => null,
    addressable: () => true,
    deliverLocal: () => true,
    send: () => ({ sent: false, reason: "no-transport" }),
  });
  stops.push(() => coordinator.stop());
  const api = createSessionBusApi({
    coordinator,
    abDir,
    projectId: "p",
    machineId: () => "m1",
    membership: (id) => (id === "lead-1" ? { sessionId: "lead-1" } : null),
    remoteAccessEnabled: () => opts.remote !== false,
    ...(opts.withRequest === false ? {} : {
      request: async (i) => {
        asked.push(i);
        return opts.answer ?? { ok: true, result: { fine: true } };
      },
    }),
  });
  const ctx: AgentContext = {
    manager: () => null,
    config: () => ({} as AbConfig),
    project: () => ({ id: "p", path: abDir } as any),
    sendAb: () => {},
    sessionBus: api,
  };
  const server = startApiServer(ctx);
  stops.push(() => server.stop());
  const post = async (body: unknown, terminalId: string | null = "lead-1") => {
    const q = terminalId ? `?terminalId=${terminalId}` : "";
    const res = await fetch(`http://127.0.0.1:${server.port}/session-bus/request${q}`, {
      method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body),
    });
    return { status: res.status, body: (await res.json()) as any };
  };
  return { post, asked };
}

test("a request is forwarded with the default timeout and answered with its result", async () => {
  const { post, asked } = rig();
  const r = await post({ to: TARGET, method: "sessions.list", params: { projectId: "x" } });
  expect(r).toEqual({ status: 200, body: { ok: true, result: { fine: true } } });
  expect(asked).toEqual([{ to: TARGET, method: "sessions.list", params: { projectId: "x" }, timeoutMs: 30_000 }]);
});

test("a body that is not a request is 400 and nothing is sent", async () => {
  const { post, asked } = rig();
  for (const body of [{}, { to: "nope", method: "sessions.list" }, { to: TARGET }, { to: TARGET, method: "m", timeoutMs: "5s" }, { to: TARGET, method: "m", extra: 1 }]) {
    expect((await post(body)).status).toBe(400);
  }
  expect(asked).toEqual([]);
});

test("a timeout out of range or fractional is clamped, not refused", async () => {
  const { post, asked } = rig();
  for (const timeoutMs of [10_000_000, 0, 1500.6]) {
    expect((await post({ to: TARGET, method: "sessions.list", timeoutMs })).status).toBe(200);
  }
  expect(asked.map((a) => a.timeoutMs)).toEqual([BUS_REQUEST_MAX_TIMEOUT_MS, 1, 1501]);
});

test("a caller that names no session is refused", async () => {
  const { post, asked } = rig();
  expect((await post({ to: TARGET, method: "sessions.list" }, null)).status).toBe(403);
  expect((await post({ to: TARGET, method: "sessions.list" }, "some-service-pty")).status).toBe(403);
  expect(asked).toEqual([]);
});

test("with remote access off nothing leaves", async () => {
  const { post, asked } = rig({ remote: false });
  const r = await post({ to: TARGET, method: "sessions.list" });
  expect(r.status).toBe(403);
  expect(r.body.code).toBe("REMOTE_ACCESS_OFF");
  expect(asked).toEqual([]);
});

test("a refusal from the other machine keeps its status and code", async () => {
  const { post } = rig({ answer: { ok: false, code: "NOT_ORCHESTRATOR" } });
  const r = await post({ to: TARGET, method: "session.create", params: { projectId: "x" } });
  expect(r.status).toBe(403);
  expect(r.body.code).toBe("NOT_ORCHESTRATOR");
});

test("a code this bridge has no entry for is REQUEST_FAILED with the remote code alongside, never in the text", async () => {
  const { post } = rig({ answer: { ok: false, code: "FUTURE_CODE" } });
  const r = await post({ to: TARGET, method: "sessions.list" });
  expect(r.status).toBe(502);
  expect(r.body).toMatchObject({ code: "REQUEST_FAILED", remoteCode: "FUTURE_CODE" });
  expect(r.body.error).not.toContain("FUTURE_CODE");
});

test("a held request that timed out reports why", async () => {
  const { post } = rig({ answer: { ok: false, code: "REQUEST_TIMEOUT", held: "central-offline" } });
  const r = await post({ to: TARGET, method: "sessions.list" });
  expect(r.status).toBe(504);
  expect(r.body).toMatchObject({ code: "REQUEST_TIMEOUT", held: "central-offline" });
});

test("a bridge with no request sender answers AGENT_NOT_READY", async () => {
  const { post } = rig({ withRequest: false });
  const r = await post({ to: TARGET, method: "sessions.list" });
  expect(r.status).toBe(503);
  expect(r.body.code).toBe("AGENT_NOT_READY");
});
