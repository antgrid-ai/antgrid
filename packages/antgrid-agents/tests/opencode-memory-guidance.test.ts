import { afterEach, beforeEach, expect, test } from "bun:test";
import { AntgridSessionNamer } from "../assets/opencode/plugin";
import { MEMORY_AGENT_GUIDANCE } from "../assets/memory-guidance";

const keys = ["ANTGRID_API_PORT", "ANTGRID_TERMINAL_ID", "ANTGRID_RUN_ID"] as const;
let saved: Record<string, string | undefined>;
const servers: Array<ReturnType<typeof Bun.serve>> = [];
beforeEach(() => {
  saved = Object.fromEntries(keys.map(key => [key, process.env[key]]));
  for (const key of keys) delete process.env[key];
});
afterEach(() => {
  for (const server of servers.splice(0)) server.stop(true);
  for (const key of keys) {
    if (saved[key] === undefined) delete process.env[key];
    else process.env[key] = saved[key];
  }
});

const enabled = { available: true, enabled: true, paused: false, project_paused: false };
async function fixture(respond: () => Response | Promise<Response> = () => Response.json(enabled)) {
  const requests: Array<{ url: URL; body: unknown }> = [];
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
    requests.push({ url: new URL(request.url), body: await request.json() });
    return respond();
  } });
  servers.push(server);
  process.env.ANTGRID_API_PORT = String(server.port);
  process.env.ANTGRID_TERMINAL_ID = "durable-antgrid-session";
  process.env.ANTGRID_RUN_ID = "verified-live-run";
  const plugin = await AntgridSessionNamer();
  const transform = plugin["experimental.chat.system.transform"];
  expect(typeof transform).toBe("function");
  return {
    requests,
    plugin,
    transform: async (system = ["Existing system guidance"], sessionID: string | undefined = "untrusted-native-session") => {
      await transform!({ sessionID, model: {} }, { system });
      return system;
    },
  };
}

test("enabled terminal memory adds static guidance through the system transform", async () => {
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

test("each model request rechecks pause and opt-out without accumulating guidance", async () => {
  let state = enabled;
  const { requests, transform } = await fixture(() => Response.json(state));
  const system = await transform();
  expect(await transform(system)).toHaveLength(2);
  state = { ...enabled, paused: true };
  expect(await transform(system)).toEqual(["Existing system guidance"]);
  state = { ...enabled, enabled: false };
  expect(await transform()).toEqual(["Existing system guidance"]);
  expect(requests).toHaveLength(4);
});

test("subagents and model calls without a native session receive no memory guidance", async () => {
  const { plugin, requests, transform } = await fixture();
  await plugin.event!({ event: { type: "session.created", properties: { info: { id: "child", parentID: "root" } } } });
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
