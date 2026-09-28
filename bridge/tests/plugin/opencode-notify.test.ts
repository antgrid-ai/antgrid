import { test, expect, beforeEach, afterEach } from "bun:test";
import { AntgridSessionNamer } from "../../../packages/antgrid-agents/assets/opencode/plugin";

// This suite's own host process may be an Antgrid-managed terminal (dogfooding),
// which would otherwise leak a real ANTGRID_RUN_ID into these in-process plugin
// calls and stamp it onto the posted body the tests assert against.
let hostRunId: string | undefined;
beforeEach(() => {
  hostRunId = process.env.ANTGRID_RUN_ID;
  delete process.env.ANTGRID_RUN_ID;
});
afterEach(() => {
  if (hostRunId === undefined) delete process.env.ANTGRID_RUN_ID;
  else process.env.ANTGRID_RUN_ID = hostRunId;
});

/** Port 0 lets the OS pick: a fixed port collides with whatever else the suite
 *  is listening on, and the loser fails to bind rather than failing an assert. */
function collector(): { hits: Array<{ path: string; body: string }>; server: ReturnType<typeof Bun.serve> } {
  const hits: Array<{ path: string; body: string }> = [];
  const server = Bun.serve({ port: 0, async fetch(req) {
    hits.push({ path: new URL(req.url).pathname, body: await req.text() }); return new Response("{}");
  }});
  return { hits, server };
}

test("permission.updated posts permission_request to /notify", async () => {
  const { hits, server } = collector();
  process.env.ANTGRID_API_PORT = String(server.port);
  process.env.ANTGRID_TERMINAL_ID = "t1";

  const plugin = await AntgridSessionNamer({} as any);
  await plugin.event!({ event: { type: "permission.updated", properties: {} } } as any);
  await Bun.sleep(100);
  server.stop(true);

  expect(hits.some((h) => h.path === "/notify" && h.body.includes("permission_request"))).toBe(true);
});

test("session.idle posts idle (not task_complete) to /notify", async () => {
  const { hits, server } = collector();
  process.env.ANTGRID_API_PORT = String(server.port);
  process.env.ANTGRID_TERMINAL_ID = "t1";

  const plugin = await AntgridSessionNamer({} as any);
  await plugin.event!({ event: { type: "session.idle", properties: {} } } as any);
  await Bun.sleep(100);
  server.stop(true);

  expect(hits.some((h) => h.path === "/notify" && h.body.includes('"idle"'))).toBe(true);
  expect(hits.some((h) => h.body.includes("task_complete"))).toBe(false);
});

test("session.idle notify carries terminalId so the bridge can name the session", async () => {
  const { hits, server } = collector();
  process.env.ANTGRID_API_PORT = String(server.port);
  process.env.ANTGRID_TERMINAL_ID = "t1";

  const plugin = await AntgridSessionNamer({} as any);
  await plugin.event!({ event: { type: "session.idle", properties: {} } } as any);
  await Bun.sleep(100);
  server.stop(true);

  const notify = hits.find((h) => h.path === "/notify");
  expect(JSON.parse(notify!.body)).toEqual({ type: "idle", terminalId: "t1" });
});

test("a missing terminal id still notifies, without the field", async () => {
  const { hits, server } = collector();
  process.env.ANTGRID_API_PORT = String(server.port);
  delete process.env.ANTGRID_TERMINAL_ID;

  const plugin = await AntgridSessionNamer({} as any);
  await plugin.event!({ event: { type: "session.error", properties: {} } } as any);
  await Bun.sleep(100);
  server.stop(true);

  const notify = hits.find((h) => h.path === "/notify");
  expect(notify).toBeDefined();
  expect(JSON.parse(notify!.body)).toEqual({ type: "error" });
});

test("native runtime posts carry the launching run ID", async () => {
  const { hits, server } = collector();
  process.env.ANTGRID_API_PORT = String(server.port);
  process.env.ANTGRID_TERMINAL_ID = "t1";
  process.env.ANTGRID_RUN_ID = "run-2";
  try {
    const plugin = await AntgridSessionNamer({} as any);
    await plugin.event!({ event: { type: "session.idle", properties: {} } } as any);
    expect(hits).toHaveLength(2);
    for (const hit of hits) expect(JSON.parse(hit.body).runId).toBe("run-2");
  } finally {
    server.stop(true);
  }
});
