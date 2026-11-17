// The loopback grant verbs read and lower this machine's orchestrator grant on
// web. There is no raise verb: raising needs the owner's account session, from
// the app.
import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ControlRequestSchema } from "../src/control-protocol";
import type { HostRemoteConfig, HostServer, RemoteRuntime } from "../src/host-server";
import { __setRootForTest, setLogLevel } from "../src/logger";
import { createHostPolicyFixture } from "./host-policy-fixture";

setLogLevel("error");

let prevAbDir: string | undefined;
let abDir: string;
let host: HostServer | null = null;

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-bus-grants-"));
  process.env.ANTGRID_DIR = abDir;
});

afterEach(async () => {
  try { await host?.shutdown(); } catch { /* best effort */ }
  host = null;
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR;
  else process.env.ANTGRID_DIR = prevAbDir;
  try { rmSync(abDir, { recursive: true, force: true }); } catch { /* Windows handle */ }
});

const remote: HostRemoteConfig = {
  relayUrl: "ws://127.0.0.1:1",
  licenseApiUrl: "http://web.test",
  identity: { deviceId: "dev-1", deviceName: "dev-1", createdAt: "2026-01-01T00:00:00.000Z" },
  auth: { clientId: "cid", clientSecret: "secret", deviceUuid: "uuid-1" },
  onAuthRevoked: () => {},
};
const runtime = (): RemoteRuntime => ({ maint: { getToken: () => "maint-token", stop: () => {} } });

interface Call { url: string; method: string; auth: string | null; body: string | null }

function rig(web: (c: Call) => Response) {
  const calls: Call[] = [];
  const fetchFn = mock(async (url: string | URL | Request, init?: RequestInit) => {
    const headers = new Headers(init?.headers);
    const call: Call = {
      url: String(url), method: init?.method ?? "GET", auth: headers.get("authorization"),
      body: typeof init?.body === "string" ? init.body : null,
    };
    calls.push(call);
    return web(call);
  }) as unknown as typeof fetch;
  const kick = mock(() => {});
  const h = createHostPolicyFixture({ remote, remoteRuntimeFactory: () => Promise.resolve(runtime()), fetchFn });
  host = h;
  (h as any).machineDirectory = { kick, selfOrchestrator: () => false, current: () => null, onChange: () => () => {}, stop: () => {} };
  return { h, calls, kick };
}

const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { "content-type": "application/json" } });

test("bus-grants:lower posts the lowered grant with the maintenance bearer and kicks the directory once", async () => {
  const { h, calls, kick } = rig(() => json({ orchestrator: false }));
  const res = await h.handleBusGrantsVerb({ id: "1", type: "bus-grants:lower", orchestrator: false });
  expect(calls).toEqual([
    { url: "http://web.test/account/devices/me/session-bus", method: "POST", auth: "Bearer maint-token", body: JSON.stringify({ orchestrator: false }) },
  ]);
  expect(kick).toHaveBeenCalledTimes(1);
  expect(res).toMatchObject({ ok: true, type: "bus-grants:lower", grants: { orchestrator: false }, reachEnabled: true, level: "on" });
});

test("the level follows the local switch, not the account", async () => {
  const { h } = rig(() => json({ orchestrator: true }));
  expect(await h.handleBusGrantsVerb({ id: "1", type: "bus-grants:get" })).toMatchObject({ ok: true, grants: { orchestrator: true }, level: "on" });
  await h.handleAgentReachVerb({ id: "2", type: "agent-reach:set", enabled: false });
  expect(await h.handleBusGrantsVerb({ id: "3", type: "bus-grants:get" })).toMatchObject({ ok: true, level: "off" });
});

test("a web refusal fails the verb and does not kick", async () => {
  const { h, kick } = rig(() => json({ error: "OWNER_SESSION_REQUIRED" }, 403));
  const res = await h.handleBusGrantsVerb({ id: "1", type: "bus-grants:lower", orchestrator: false });
  expect(res).toMatchObject({ ok: false, error: { code: "WEB_403", message: "the account service refused the request (WEB_403)" } });
  expect(kick).not.toHaveBeenCalled();
});

test("an unreachable web fails the verb and does not kick", async () => {
  const { h, kick } = rig(() => { throw new Error("offline"); });
  const res = await h.handleBusGrantsVerb({ id: "1", type: "bus-grants:lower", orchestrator: false });
  expect(res).toMatchObject({ ok: false, error: { code: "WEB_UNREACHABLE", message: "could not reach the account service (WEB_UNREACHABLE)" } });
  expect(kick).not.toHaveBeenCalled();
});

test("bus-grants:get reads web, reports the local switch, and does not kick", async () => {
  const { h, calls, kick } = rig(() => json({ orchestrator: true }));
  await h.handleAgentReachVerb({ id: "s", type: "agent-reach:set", enabled: false });
  const res = await h.handleBusGrantsVerb({ id: "1", type: "bus-grants:get" });
  expect(calls).toEqual([
    { url: "http://web.test/account/devices/me/session-bus", method: "GET", auth: "Bearer maint-token", body: null },
  ]);
  // Local off wins over the orchestrator grant.
  expect(res).toMatchObject({ ok: true, grants: { orchestrator: true }, reachEnabled: false, level: "off" });
  expect(kick).not.toHaveBeenCalled();
});

test("a malformed web answer is a failed verb", async () => {
  const { h } = rig(() => json({ orchestrator: "yes" }));
  expect(await h.handleBusGrantsVerb({ id: "1", type: "bus-grants:get" })).toMatchObject({ ok: false });
});

test("agent-reach verbs report the level from the local switch", async () => {
  const { h } = rig(() => json({}));
  expect(await h.handleAgentReachVerb({ id: "g", type: "agent-reach:get" })).toMatchObject({ enabled: true, level: "on" });
  expect(await h.handleAgentReachVerb({ id: "s", type: "agent-reach:set", enabled: false })).toMatchObject({ enabled: false, level: "off" });
  expect(await h.handleAgentReachVerb({ id: "s", type: "agent-reach:set", enabled: true })).toMatchObject({ enabled: true, level: "on" });
});

test("there is no raise verb and the lower verb takes only false", () => {
  const types = ControlRequestSchema.options.map((o) => (o.shape.type as { value: string }).value);
  expect(types.filter((t) => t.startsWith("bus-grants:")).sort()).toEqual(["bus-grants:get", "bus-grants:lower"]);
  expect(types.some((t) => t.startsWith("orchestrator:"))).toBe(false);
  const lower = (b: object) => ControlRequestSchema.safeParse({ id: "1", type: "bus-grants:lower", ...b }).success;
  expect(lower({ orchestrator: false })).toBe(true);
  // Web refuses an empty patch, so the loopback refuses it before the round trip.
  expect(lower({})).toBe(false);
  expect(lower({ busControl: false })).toBe(false);
  expect(lower({ orchestrator: false, busControl: false })).toBe(false);
  expect(lower({ orchestrator: true })).toBe(false);
});

test("a directory refresh that raises the grant logs one warn", () => {
  const { h } = rig(() => json({}));
  let self = { orchestrator: false };
  (h as any).machineDirectory.current = () => ({ self });
  const lines: string[] = [];
  __setRootForTest({ write: (m: string) => { lines.push(m); } }, "warn");
  try {
    const note = () => (h as any).noteGrantTransitions();
    note();
    expect(lines).toEqual([]);
    self = { orchestrator: true };
    note();
    note();
    self = { orchestrator: false };
    note();
    expect(lines).toHaveLength(1);
    expect(lines[0]).toContain("orchestrator");
  } finally {
    __setRootForTest(process.stdout, "info");
    setLogLevel("error");
  }
});
