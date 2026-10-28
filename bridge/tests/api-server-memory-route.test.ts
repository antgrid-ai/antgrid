import { afterEach, expect, test } from "bun:test";
import { MemoryError } from "antgrid-memory";
import { startApiServer, type AgentContext, type MemoryCall } from "../src/api-server";
import type { AbConfig } from "../src/config";
import { resolveMemoryCaller } from "../src/memory";
import type { SessionEntry } from "../src/protocol";

const servers: { stop(): void }[] = [];
afterEach(() => { for (const server of servers.splice(0)) server.stop(); });

function serve(memory?: AgentContext["memory"]) {
  const server = startApiServer({
    manager: () => null, config: () => ({} as AbConfig), project: () => ({ id: "project", path: "." } as any),
    sendAb: () => {}, acceptsHookRun: () => { throw new Error("Memory must not mutate hook observation"); }, memory,
  });
  servers.push(server);
  return server.port;
}

function post(port: number, op: string, body: unknown, headers: Record<string, string> = {}, query = "?terminalId=session") {
  return fetch(`http://127.0.0.1:${port}/memory/${op}${query}`, {
    method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body),
  });
}

test("memory loopback separates caller credentials from model arguments and fixes the route operation", async () => {
  const calls: MemoryCall[] = [];
  const port = serve(async (call) => { calls.push(call); return { record: null }; });
  expect((await post(port, "get", { runId: "run", id: "record", op: "settings", owner_id: "spoof" })).status).toBe(200);
  expect(calls).toEqual([{ terminalId: "session", runId: "run", request: { op: "get", id: "record", owner_id: "spoof" } }]);
});

test("browser-rebound and non-JSON requests are refused before delegation", async () => {
  let called = false;
  const port = serve(async () => { called = true; return {}; });
  expect((await post(port, "search", { query: "finding" }, { host: `attacker.example:${port}` })).status).toBe(403);
  expect((await post(port, "search", {}, { "content-type": "text/plain" })).status).toBe(403);
  expect((await fetch(`http://127.0.0.1:${port}/memory/get`)).status).toBe(405);
  expect(called).toBe(false);
});

test("missing caller identity reaches the independent live-caller check", async () => {
  let call: MemoryCall | undefined;
  const port = serve(async (value) => { call = value; throw new MemoryError("NOT_A_SESSION", "No live caller"); });
  const response = await post(port, "status", { runId: 123 }, {}, "");
  expect(response.status).toBe(403);
  expect(await response.json()).toEqual({ error: { code: "NOT_A_SESSION", message: "No live caller" } });
  expect(call).toEqual({ terminalId: undefined, runId: undefined, request: { op: "status" } });
});

test("memory failures retain actionable codes without exposing storage errors", async () => {
  expect((await post(serve(), "search", {})).status).toBe(503);
  for (const code of ["CONFLICT", "IDEMPOTENCY_CONFLICT", "PAUSED", "UNKNOWN_OUTCOME", "CLEANUP_FAILED"]) {
    const response = await post(serve(async () => { throw new MemoryError(code, code); }), "save", {});
    expect(await response.json()).toEqual({ error: { code, message: code } });
  }
  const response = await post(serve(async () => { throw new Error("private database detail"); }), "save", {});
  expect(response.status).toBe(503);
  expect(JSON.stringify(await response.json())).not.toContain("private database detail");
});

test("bootstrap returns only validated settings through the existing memory caller boundary", async () => {
  const calls: MemoryCall[] = [];
  const flags = { available: true, enabled: true, paused: false, project_paused: false };
  const port = serve(async (call) => {
    calls.push(call);
    return { ...flags, owner_id: "private", results: [{ content: "saved finding" }], pending_operations: 4 };
  });
  for (const setting of ["enabled", "paused", "project_paused"] as const) {
    for (const value of [true, false]) {
      flags[setting] = value;
      const response = await post(port, "bootstrap", { runId: "run" });
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual(flags);
    }
  }
  expect(calls).toHaveLength(6);
  for (const call of calls) expect(call).toEqual({ terminalId: "session", runId: "run", request: { op: "status" } });
  for (const extra of [{ owner_id: "spoof" }, { op: "settings" }, { enabled: true }, { project_id: "foreign" }]) {
    expect((await post(port, "bootstrap", { runId: "run", ...extra })).status).toBe(400);
  }
  expect(calls).toHaveLength(6);
});

test("bootstrap never permits missing, stale, foreign or chat caller identity", async () => {
  let mode = "terminal";
  const port = serve(async (call) => {
    resolveMemoryCaller({
      session: (id) => id === "session" ? { id, mode, checkoutId: "checkout" } as SessionEntry : undefined,
      isLiveRun: (id, run) => id === "session" && run === "run",
      runAgent: () => "codex", checkoutExists: (id) => id === "checkout",
    }, call.terminalId, call.runId);
    return { available: true, enabled: true, paused: false, project_paused: false };
  });
  for (const [runId, query] of [[undefined, "?terminalId=session"], ["old", "?terminalId=session"], ["run", "?terminalId=foreign"], ["run", ""]]) {
    expect((await post(port, "bootstrap", { runId }, {}, query)).status).toBe(403);
  }
  mode = "chat";
  expect((await post(port, "bootstrap", { runId: "run" })).status).toBe(403);
  mode = "terminal";
  expect((await post(port, "bootstrap", { runId: "run" })).status).toBe(200);
});

test("bootstrap fails closed on unavailable or malformed service results and browser requests", async () => {
  for (const result of [
    { available: false, error: { message: "private storage path" } },
    { available: true, enabled: "yes", paused: false, project_paused: false },
    { available: true, enabled: true, paused: false },
  ]) {
    const response = await post(serve(async () => result), "bootstrap", { runId: "run" });
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: { code: "UNAVAILABLE", message: "Memory guidance is unavailable." } });
  }
  let called = false;
  const port = serve(async () => { called = true; return {}; });
  expect((await post(port, "bootstrap", { runId: "run" }, { host: `attacker.example:${port}` })).status).toBe(403);
  expect((await post(port, "bootstrap", { runId: "run" }, { "content-type": "text/plain" })).status).toBe(403);
  expect((await fetch(`http://127.0.0.1:${port}/memory/bootstrap?terminalId=session`)).status).toBe(405);
  expect(called).toBe(false);
});
