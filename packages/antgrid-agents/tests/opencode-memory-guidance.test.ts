import { afterEach, beforeEach, expect, test } from "bun:test";
import plugin from "../assets/opencode/plugin";
import { MEMORY_AGENT_GUIDANCE } from "../assets/memory-guidance";

const keys = ["ANTGRID_API_PORT", "ANTGRID_TERMINAL_ID", "ANTGRID_RUN_ID", "ANTGRID_MEMORY_MCP"] as const;
let saved: Record<string, string | undefined>;
const servers: Array<ReturnType<typeof Bun.serve>> = [];
const disposers: Array<() => Promise<void>> = [];
beforeEach(() => {
  saved = Object.fromEntries(keys.map(key => [key, process.env[key]]));
  for (const key of keys) delete process.env[key];
});
afterEach(async () => {
  for (const dispose of disposers.splice(0)) await dispose();
  for (const server of servers.splice(0)) server.stop(true);
  for (const key of keys) {
    if (saved[key] === undefined) delete process.env[key];
    else process.env[key] = saved[key];
  }
});

const enabled = { available: true, enabled: true, paused: false, project_paused: false };
type Context = { sessionID: string; system: Array<{ type: "text"; text: string }> };
async function fixture(
  respond: () => Response | Promise<Response> = () => Response.json(enabled),
  parents: Record<string, string> = {},
) {
  const requests: Array<{ url: URL; body: unknown }> = [];
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
    const url = new URL(request.url);
    // The plugin reports session identity to the same port; only bootstrap is under test.
    if (url.pathname !== "/memory/bootstrap") return new Response(null, { status: 204 });
    requests.push({ url, body: await request.json() });
    return respond();
  } });
  servers.push(server);
  process.env.ANTGRID_API_PORT = String(server.port);
  process.env.ANTGRID_TERMINAL_ID = "durable-antgrid-session";
  process.env.ANTGRID_RUN_ID = "verified-live-run";
  process.env.ANTGRID_MEMORY_MCP = "1";
  let context: ((input: Context) => Promise<void>) | undefined;
  disposers.push(await plugin.setup({
    event: { subscribe: async function* () {} },
    session: {
      get: async ({ sessionID }: { sessionID: string }) => ({ id: sessionID, parentID: parents[sessionID] }),
      hook: async (name: string, callback: (input: Context) => Promise<void>) => {
        expect(name).toBe("context");
        context = callback;
        return { dispose: async () => {} };
      },
    },
  } as unknown as Parameters<typeof plugin.setup>[0]));
  expect(typeof context).toBe("function");
  return {
    requests,
    transform: async (system = ["Existing system guidance"], sessionID = "untrusted-native-session") => {
      const input: Context = { sessionID, system: system.map((text) => ({ type: "text", text })) };
      await context!(input);
      return input.system.map((part) => part.text);
    },
  };
}

test("enabled terminal memory adds static guidance through the context hook", async () => {
  const { requests, transform } = await fixture();
  const system = await transform();
  expect(system).toHaveLength(2);
  expect(system[0]).toBe("Existing system guidance");
  expect(system[1]).toBe(MEMORY_AGENT_GUIDANCE);
  expect(requests).toHaveLength(1);
  expect(requests[0].url.pathname).toBe("/memory/bootstrap");
  expect(requests[0].url.searchParams.get("terminalId")).toBe("durable-antgrid-session");
  expect(requests[0].body).toEqual({ runId: "verified-live-run" });
  expect(system.join(" ")).not.toContain("verified-live-run");
  expect(system.join(" ")).not.toContain("untrusted-native-session");
});

test.each([
  { ...enabled, enabled: false },
  { ...enabled, paused: true },
  { ...enabled, project_paused: true },
  { available: false },
  { ...enabled, enabled: "true" },
  { ...enabled, content: "saved memory must never enter this hook" },
  [enabled],
  null,
].map(reply => ({ reply })))("disabled, paused, unavailable or widened replies add no instructions: %j", async ({ reply }) => {
  const { transform } = await fixture(() => Response.json(reply));
  expect(await transform()).toEqual(["Existing system guidance"]);
});

test.each([
  ["ANTGRID_API_PORT", undefined],
  ["ANTGRID_API_PORT", "65536"],
  ["ANTGRID_API_PORT", "1234/redirect"],
  ["ANTGRID_TERMINAL_ID", undefined],
  ["ANTGRID_TERMINAL_ID", "${ANTGRID_TERMINAL_ID}"],
  ["ANTGRID_RUN_ID", undefined],
  ["ANTGRID_RUN_ID", "${ANTGRID_RUN_ID}"],
] as const)("missing or invalid injected identity makes no request: %s %s", async (key, value) => {
  const { requests, transform } = await fixture();
  if (value === undefined) delete process.env[key]; else process.env[key] = value;
  expect(await transform()).toEqual(["Existing system guidance"]);
  expect(requests).toHaveLength(0);
});

// A refresh runs behind a request, at most every 30s, and lands on the next
// one, so a change in the user's setting is seen late and never blocks a request.
const settle = () => Bun.sleep(50);
let clock = 0;
let realNow: () => number;
beforeEach(() => { clock = 0; realNow = Date.now; Date.now = () => realNow() + clock; });
afterEach(() => { Date.now = realNow; });
const later = () => { clock += 31_000; };

test("a refresh runs at most every 30s and never accumulates guidance", async () => {
  let state = enabled;
  const { requests, transform } = await fixture(() => Response.json(state));
  const system = await transform();
  expect(await transform(system)).toHaveLength(2);
  await settle();
  expect(requests).toHaveLength(1);
  state = { ...enabled, paused: true };
  expect(await transform(system)).toHaveLength(2);
  await settle();
  expect(requests).toHaveLength(1);
  later();
  expect(await transform(system)).toHaveLength(2);
  await settle();
  expect(requests).toHaveLength(2);
  expect(await transform(system)).toEqual(["Existing system guidance"]);
  expect(requests).toHaveLength(2);
});

test("a paused reply removes guidance on the request after the refresh", async () => {
  let state = enabled;
  const { transform } = await fixture(() => Response.json(state));
  expect(await transform()).toHaveLength(2);
  state = { ...enabled, paused: true };
  later();
  expect(await transform()).toHaveLength(2);
  await settle();
  expect(await transform()).toEqual(["Existing system guidance"]);
});

test("a hung or failing bridge keeps the last known guidance without delaying later requests", async () => {
  const script = ["ok", "hang", "503"];
  const { transform } = await fixture(() => {
    const next = script.shift();
    if (next === "hang") return new Promise<Response>(() => {});
    if (next === "503") return new Response("down", { status: 503 });
    return Response.json(enabled);
  });
  for (let call = 1; call <= 3; call++) {
    const started = performance.now();
    expect(await transform()).toHaveLength(2);
    if (call > 1) expect(performance.now() - started).toBeLessThan(100);
    await settle();
    later();
  }
});

test("the first answer is shared by every session", async () => {
  let state = enabled;
  const { requests, transform } = await fixture(() => Response.json(state));
  expect(await transform(undefined, "one")).toHaveLength(2);
  state = { ...enabled, enabled: false };
  expect(await transform(undefined, "two")).toHaveLength(2);
  await settle();
  expect(requests).toHaveLength(1);
});

test("without the registered-server flag no request is made and no guidance is added", async () => {
  const { requests, transform } = await fixture();
  delete process.env.ANTGRID_MEMORY_MCP;
  expect(await transform()).toEqual(["Existing system guidance"]);
  expect(requests).toHaveLength(0);
});

test("subagents and model calls without a native session receive no memory guidance", async () => {
  const { requests, transform } = await fixture(undefined, { child: "root" });
  expect(await transform(undefined, "child")).toEqual(["Existing system guidance"]);
  expect(await transform(undefined, "")).toEqual(["Existing system guidance"]);
  expect(requests).toHaveLength(0);
});

test("bootstrap redirects never forward the live identity", async () => {
  let destinationHits = 0;
  const destination = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch() {
    destinationHits++;
    return Response.json(enabled);
  } });
  servers.push(destination);
  const { transform } = await fixture(() => Response.redirect(`http://127.0.0.1:${destination.port}/other`, 307));
  expect(await transform()).toEqual(["Existing system guidance"]);
  expect(destinationHits).toBe(0);
});

test("refusal, malformed JSON and oversized bodies fail open for the agent turn", async () => {
  for (const response of [
    () => Response.json(enabled, { status: 403 }),
    () => new Response("invalid JSON"),
    () => new Response(" ".repeat(2048) + JSON.stringify(enabled)),
  ]) {
    const { transform } = await fixture(response);
    expect(await transform()).toEqual(["Existing system guidance"]);
  }
});

test("a stalled bootstrap response cannot block the model request indefinitely", async () => {
  const { transform } = await fixture(() => new Promise<Response>(() => {}));
  const started = Date.now();
  expect(await transform()).toEqual(["Existing system guidance"]);
  expect(Date.now() - started).toBeLessThan(3000);
});
