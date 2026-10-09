// The scheduler routes are the only thing an agent's MCP process can reach the
// scheduler through, so what a refusal looks like on the wire, and which
// requests never get as far as the scheduler, is pinned here.
import { afterEach, describe, expect, test } from "bun:test";
import { z } from "zod";
import { startApiServer, type AgentContext, type SchedulerCall } from "../src/api-server";
import { SCHEDULER_AGENT_ERRORS, SchedulerRefusal } from "../src/scheduler/agent";
import type { AbConfig } from "../src/config";

const servers: { stop(): void }[] = [];
afterEach(() => { for (const s of servers.splice(0)) s.stop(); });

/** Every `acceptsHookRun` the route made. In agent-core that check's wrapper
 *  treats an absent run id as a lost hook channel and fails a scheduled
 *  session's run, so a run-id-less list call must never reach it. */
let hookChecks: [string | undefined, string | undefined][] = [];

function serve(scheduler?: AgentContext["scheduler"]) {
  const ctx: AgentContext = {
    acceptsHookRun: (terminalId, runId) => { hookChecks.push([terminalId, runId]); return false; },
    manager: () => null,
    config: () => ({} as AbConfig),
    project: () => ({ id: "p", path: "." } as any),
    sendAb: () => {},
    ...(scheduler ? { scheduler } : {}),
  };
  const server = startApiServer(ctx);
  servers.push(server);
  return server.port;
}

function post(port: number, route: string, body: unknown, init: { headers?: Record<string, string>; query?: string } = {}) {
  return fetch(`http://127.0.0.1:${port}/scheduler/${route}${init.query ?? "?terminalId=term-1"}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...init.headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

describe("POST /scheduler/*", () => {
  test("never consults the hook-run check, whatever the request and however it is answered", async () => {
    hookChecks = [];
    const ok = serve(async () => ({}));
    const refusing = serve(async () => { throw new SchedulerRefusal("NOT_A_SESSION", "no"); });
    for (const route of ["list", "runs", "create", "update", "delete", "run-now"]) {
      for (const port of [ok, refusing]) {
        await post(port, route, {});
        await post(port, route, { runId: "r" });
        await post(port, route, { runId: "r" }, { query: "" });
        await post(port, route, { runId: "r" }, { headers: { "content-type": "text/plain" } });
        await post(port, route, { runId: "r" }, { headers: { host: `evil.example:${port}` } });
      }
    }
    await post(serve(), "list", {});
    expect(hookChecks).toEqual([]);
  });

  test("maps each route to its method and splits the run id from the arguments", async () => {
    const calls: SchedulerCall[] = [];
    const port = serve(async (call) => { calls.push(call); return { ok: true }; });
    const routes = {
      list: "list", runs: "runs", create: "create", update: "update", delete: "delete", "run-now": "runNow",
    } as const;
    for (const [route, method] of Object.entries(routes)) {
      const res = await post(port, route, { runId: "run-1", scheduleId: "s", extra: 1 });
      expect(res.status).toBe(200);
      expect(await res.json()).toEqual({ ok: true });
      expect(calls.at(-1)).toEqual({
        terminalId: "term-1", runId: "run-1", method, params: { scheduleId: "s", extra: 1 },
      });
    }
  });

  test("passes a missing run id and slot through as absent for the caller check to refuse", async () => {
    const calls: SchedulerCall[] = [];
    const port = serve(async (call) => { calls.push(call); return {}; });
    await post(port, "list", { runId: 7 }, { query: "" });
    await post(port, "list", "not json");
    await post(port, "list", [1, 2]);
    expect(calls.map((c) => [c.terminalId, c.runId])).toEqual([
      [undefined, undefined], ["term-1", undefined], ["term-1", undefined],
    ]);
    expect(calls[2]!.params).toEqual({});
  });

  test("answers an unknown route, an inherited property name and a GET as not found", async () => {
    const port = serve(async () => ({}));
    for (const route of ["nope", "constructor", "__proto__", "toString"]) {
      expect((await post(port, route, { runId: "r" })).status).toBe(404);
    }
    const get = await fetch(`http://127.0.0.1:${port}/scheduler/list?terminalId=term-1`);
    expect(get.status).toBe(404);
  });

  test("refuses a request that is not JSON, before the scheduler hears of it", async () => {
    let called = false;
    const port = serve(async () => { called = true; return {}; });
    const res = await post(port, "list", "runId=1", { headers: { "content-type": "text/plain" } });
    expect(res.status).toBe(SCHEDULER_AGENT_ERRORS.NOT_A_SESSION);
    expect((await res.json()).code).toBe("NOT_A_SESSION");
    expect(called).toBe(false);
  });

  test("refuses a request whose Host is not the loopback listener, as a browser rebind would send", async () => {
    let called = false;
    const port = serve(async () => { called = true; return {}; });
    const res = await post(port, "list", { runId: "r" }, { headers: { host: `evil.example:${port}` } });
    expect(res.status).toBe(SCHEDULER_AGENT_ERRORS.NOT_A_SESSION);
    expect(called).toBe(false);
  });

  test("answers 503 when no scheduler is wired", async () => {
    const res = await post(serve(), "list", { runId: "r" });
    expect(res.status).toBe(503);
    expect((await res.json()).code).toBe("SCHEDULER_UNAVAILABLE");
  });

  test("carries a refusal's code and the status that code owns", async () => {
    for (const code of ["APPROVAL_CEILING", "SCHEDULE_NOT_FOUND", "SCHEDULE_EXISTS", "AGENT_NOT_SCHEDULABLE"] as const) {
      const port = serve(async () => { throw new SchedulerRefusal(code, `because ${code}`); });
      const res = await post(port, "create", { runId: "r" });
      expect(res.status).toBe(SCHEDULER_AGENT_ERRORS[code]);
      expect(await res.json()).toEqual({ error: `because ${code}`, code });
    }
  });

  test("answers an argument that failed validation as INVALID_ARGUMENT, naming the field", async () => {
    const port = serve(async () => { z.object({ name: z.string() }).parse({}); return {}; });
    const res = await post(port, "create", { runId: "r" });
    expect(res.status).toBe(400);
    const body = await res.json();
    expect(body.code).toBe("INVALID_ARGUMENT");
    expect(body.error).toContain("name");
  });

  test("answers anything else as SCHEDULER_ERROR rather than dropping the connection", async () => {
    const port = serve(async () => { throw new Error("disk on fire"); });
    const res = await post(port, "list", { runId: "r" });
    expect(res.status).toBe(500);
    expect(await res.json()).toEqual({ error: "disk on fire", code: "SCHEDULER_ERROR" });
  });
});
