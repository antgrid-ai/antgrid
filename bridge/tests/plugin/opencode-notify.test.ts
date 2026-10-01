import { test, expect, beforeEach, afterEach, setSystemTime } from "bun:test";
import { AntgridSessionNamer } from "../../../packages/antgrid-agents/assets/opencode/plugin";

// Event shapes are opencode's own (packages/schema in the opencode repo): the
// plugin receives `{ type, properties }`, where properties is the event's data.

type Hit = { path: string; body: any };

/** Port 0 lets the OS pick: a fixed port collides with whatever else the suite
 *  is listening on, and the loser fails to bind rather than failing an assert.
 *  A hit is recorded when its response is sent, after any per-path delay, which
 *  is the order a bridge would have folded them in. */
function collector(delays: Record<string, number> = {}): { hits: Hit[]; server: ReturnType<typeof Bun.serve> } {
  const hits: Hit[] = [];
  const server = Bun.serve({ port: 0, async fetch(req) {
    const path = new URL(req.url).pathname;
    const body = JSON.parse(await req.text());
    if (delays[path]) await Bun.sleep(delays[path]);
    hits.push({ path, body });
    return new Response("{}");
  }});
  return { hits, server };
}

// The suite runs inside whatever shell launched it, and a developer working in
// an Antgrid terminal has every one of these set for real.
const ENV_KEYS = ["ANTGRID_API_PORT", "ANTGRID_TERMINAL_ID", "ANTGRID_RUN_ID"] as const;
let savedEnv: Record<string, string | undefined> = {};
const servers: Array<ReturnType<typeof Bun.serve>> = [];
beforeEach(() => {
  savedEnv = Object.fromEntries(ENV_KEYS.map((k) => [k, process.env[k]]));
  for (const k of ENV_KEYS) delete process.env[k];
});
afterEach(() => {
  setSystemTime();
  for (const s of servers.splice(0)) s.stop(true);
  for (const k of ENV_KEYS) {
    if (savedEnv[k] === undefined) delete process.env[k];
    else process.env[k] = savedEnv[k];
  }
});

async function start(opts: { terminalId?: string; delays?: Record<string, number> } = {}) {
  const { hits, server } = collector(opts.delays);
  servers.push(server);
  process.env.ANTGRID_API_PORT = String(server.port);
  if (opts.terminalId !== undefined) process.env.ANTGRID_TERMINAL_ID = opts.terminalId;
  const plugin = await AntgridSessionNamer({} as any) as any;
  const fire = async (...events: any[]) => { for (const event of events) await plugin.event({ event }); };
  return { hits, plugin, fire };
}

const status = (sessionID: string, type: "busy" | "retry" | "idle") =>
  ({ type: "session.status", properties: { sessionID, status: type === "retry" ? { type, attempt: 1, message: "overloaded", next: 0 } : { type } } });
const idle = (sessionID: string) => ({ type: "session.idle", properties: { sessionID } });
const created = (id: string, parentID?: string) =>
  ({ type: "session.created", properties: { sessionID: id, info: { id, ...(parentID ? { parentID } : {}) } } });
const updated = (id: string, title?: string, parentID?: string) =>
  ({ type: "session.updated", properties: { sessionID: id, info: { id, title, ...(parentID ? { parentID } : {}) } } });
const permissionAsked = (id: string, sessionID: string) =>
  ({ type: "permission.asked", properties: { id, sessionID, permission: "bash", patterns: ["git push"], metadata: {}, always: [] } });
const questionAsked = (id: string, sessionID: string) =>
  ({ type: "question.asked", properties: { id, sessionID, questions: [{ question: "Which branch?", header: "Branch", options: [] }] } });

const paths = (hits: Hit[]) => hits.map((h) => h.path);

test("a root run posts one turn start and closes it with both closers on idle", async () => {
  const { hits, fire } = await start({ terminalId: "t1" });
  // opencode republishes busy on every model step and flips through retry while
  // backing off; one run is still one turn. Its idle is published twice (status
  // and the deprecated session.idle), and is still one close.
  await fire(updated("ses_root", "Fix it"), status("ses_root", "busy"), status("ses_root", "busy"),
    status("ses_root", "retry"), status("ses_root", "busy"), status("ses_root", "idle"), idle("ses_root"));

  expect(hits.filter((h) => h.path !== "/session-title")).toEqual([
    { path: "/turn-start", body: { terminalId: "t1" } },
    { path: "/notify", body: { type: "idle", terminalId: "t1" } },
    { path: "/handler-event", body: { terminalId: "t1", agent: "opencode", event: "turn_end" } },
  ]);
});

test("the next run after an idle opens a new turn", async () => {
  const { hits, fire } = await start({ terminalId: "t1" });
  await fire(status("ses_root", "busy"), status("ses_root", "idle"), status("ses_root", "busy"), status("ses_root", "idle"));
  expect(paths(hits)).toEqual([
    "/turn-start", "/notify", "/handler-event",
    "/turn-start", "/notify", "/handler-event",
  ]);
});

test("an interrupt ends the turn as idle, not as an error", async () => {
  // opencode's cancel interrupts the run, reports the abort as a session error,
  // and then sets the session idle.
  const { hits, fire } = await start({ terminalId: "t1" });
  await fire(status("ses_root", "busy"),
    { type: "session.error", properties: { sessionID: "ses_root", error: { name: "MessageAbortedError", data: { message: "Aborted" } } } },
    status("ses_root", "idle"));
  expect(hits.map((h) => [h.path, h.body.type ?? h.body.event])).toEqual([
    ["/turn-start", undefined], ["/notify", "idle"], ["/handler-event", "turn_end"],
  ]);
});

test("a run's own error is reported when the run stops, as its turn end", async () => {
  const { hits, fire } = await start({ terminalId: "t1" });
  await fire(status("ses_root", "busy"),
    { type: "session.error", properties: { sessionID: "ses_root", error: { name: "APIError", data: { message: "invalid api key" } } } });
  expect(paths(hits)).toEqual(["/turn-start"]);
  await fire(status("ses_root", "idle"));
  expect(hits.slice(1)).toEqual([
    { path: "/notify", body: { type: "error", terminalId: "t1", message: "invalid api key" } },
    { path: "/handler-event", body: { terminalId: "t1", agent: "opencode", event: "turn_end" } },
  ]);
});

test("an error the run recovers from is not how the run ends", async () => {
  // A context overflow is published as an error, then compacted away while the
  // run keeps stepping.
  const { hits, fire } = await start({ terminalId: "t1" });
  await fire(status("ses_root", "busy"),
    { type: "session.error", properties: { sessionID: "ses_root", error: { name: "ContextOverflowError", data: { message: "too long" } } } },
    status("ses_root", "busy"), status("ses_root", "idle"));
  expect(hits.find((h) => h.path === "/notify")!.body.type).toBe("idle");
});

test("an error outside any run is still notified at once", async () => {
  const { hits, fire } = await start({ terminalId: "t1" });
  await fire({ type: "session.error", properties: {} });
  expect(hits).toEqual([{ path: "/notify", body: { type: "error", terminalId: "t1" } }]);
});

test("sends reach the bridge in event order even when opencode does not await the handler", async () => {
  // A /turn-start the bridge folds after the same run's idle is a turn nothing
  // closes. opencode dispatches each event with `void hook.event(...)`, so the
  // plugin's own sends are what has to stay ordered.
  const { hits, plugin } = await start({ terminalId: "t1", delays: { "/turn-start": 100 } });
  void plugin.event({ event: status("ses_root", "busy") });
  await plugin.event({ event: status("ses_root", "idle") });
  expect(paths(hits)).toEqual(["/turn-start", "/notify", "/handler-event"]);
});

test("a subagent's status never moves the terminal's turn", async () => {
  const { hits, fire } = await start({ terminalId: "t1" });
  await fire(status("ses_root", "busy"));
  // opencode creates the child session, touches it (session.updated) before
  // prompting it, and runs it to idle while the parent waits on the task tool.
  await fire(created("ses_child", "ses_root"), updated("ses_child", "Explore (@explore subagent)", "ses_root"),
    status("ses_child", "busy"), status("ses_child", "idle"), idle("ses_child"),
    { type: "session.error", properties: { sessionID: "ses_child", error: { name: "APIError", data: {} } } });
  expect(paths(hits)).toEqual(["/turn-start"]);
  await fire(status("ses_root", "idle"));
  expect(paths(hits)).toEqual(["/turn-start", "/notify", "/handler-event"]);
});

test("a resumed subagent is classified by the session.updated that precedes its run", async () => {
  // A task resumed by id gets no session.created in this process.
  const { hits, fire } = await start({ terminalId: "t1" });
  await fire(status("ses_root", "busy"), updated("ses_old_child", "Earlier task", "ses_root"),
    status("ses_old_child", "busy"), status("ses_old_child", "idle"));
  expect(paths(hits)).toEqual(["/turn-start"]);
});

test("permission.asked raises permission_request and wakes the Handler with the request id", async () => {
  const { hits, fire } = await start({ terminalId: "t1" });
  await fire(permissionAsked("per_1", "ses_root"));
  expect(hits).toEqual([
    { path: "/notify", body: { type: "permission_request", terminalId: "t1", message: "opencode needs your permission for bash: git push" } },
    { path: "/handler-event", body: { terminalId: "t1", agent: "opencode", event: "awaiting_input", promptId: "per_1" } },
  ]);
});

test("the pre-2026-03 permission.updated name still raises permission_request", async () => {
  const { hits, fire } = await start({ terminalId: "t1" });
  await fire({ type: "permission.updated", properties: { id: "per_1", sessionID: "ses_root", title: "Run git push" } });
  expect(hits[0]).toEqual({ path: "/notify", body: { type: "permission_request", terminalId: "t1", message: "opencode needs your permission for Run git push" } });
});

test("a subagent's permission is the user's to answer too", async () => {
  // opencode's TUI draws a child's permission in the parent's view.
  const { hits, fire } = await start({ terminalId: "t1" });
  await fire(created("ses_child", "ses_root"), permissionAsked("per_c", "ses_child"));
  expect(paths(hits)).toEqual(["/notify", "/handler-event"]);
});

test("question.asked puts the question on record, then announces it", async () => {
  const { hits, fire } = await start({ terminalId: "t1" });
  await fire(questionAsked("que_1", "ses_root"));
  expect(hits).toEqual([
    { path: "/handler-event", body: { terminalId: "t1", agent: "opencode", event: "question", promptId: "que_1", detail: "Which branch?" } },
    { path: "/notify", body: { type: "question", terminalId: "t1", message: "Which branch?" } },
  ]);
});

test("each resolution retires its own prompt, and never opens a turn", async () => {
  const { hits, fire } = await start({ terminalId: "t1" });
  await fire(permissionAsked("per_1", "ses_root"), questionAsked("que_1", "ses_root"), questionAsked("que_2", "ses_root"));
  hits.length = 0;
  await fire(
    { type: "permission.replied", properties: { sessionID: "ses_root", requestID: "per_1", reply: "once" } },
    { type: "question.replied", properties: { sessionID: "ses_root", requestID: "que_1", answers: [["main"]] } },
    { type: "question.rejected", properties: { sessionID: "ses_root", requestID: "que_2" } },
    // Settled twice, or never announced: nothing left to retire.
    { type: "question.rejected", properties: { sessionID: "ses_root", requestID: "que_2" } },
    { type: "permission.replied", properties: { sessionID: "ses_root", requestID: "per_unknown", reply: "reject" } },
  );
  expect(hits).toEqual(["per_1", "que_1", "que_2"].map((promptId) => (
    { path: "/handler-event", body: { terminalId: "t1", agent: "opencode", event: "prompt_answered", promptId } }
  )));
});

test("a prompt dropped by an interrupt is retired before the turn closes", async () => {
  // opencode cancels a pending permission with no reply event; the session going
  // idle is the only word that it is gone.
  const { hits, fire } = await start({ terminalId: "t1" });
  await fire(status("ses_root", "busy"), permissionAsked("per_1", "ses_root"));
  hits.length = 0;
  await fire(status("ses_root", "idle"));
  expect(hits.map((h) => [h.path, h.body.type ?? h.body.event])).toEqual([
    ["/handler-event", "prompt_answered"], ["/notify", "idle"], ["/handler-event", "turn_end"],
  ]);
});

test("a long run re-asserts its turn at most once a minute", async () => {
  const { hits, fire } = await start({ terminalId: "t1" });
  setSystemTime(new Date("2026-10-01T00:00:00Z"));
  await fire(status("ses_root", "busy"));
  setSystemTime(new Date("2026-10-01T00:00:30Z"));
  await fire(status("ses_root", "busy"));
  setSystemTime(new Date("2026-10-01T00:01:01Z"));
  await fire(status("ses_root", "busy"), status("ses_root", "busy"));
  expect(hits).toEqual([
    { path: "/turn-start", body: { terminalId: "t1" } },
    { path: "/turn-activity", body: { terminalId: "t1" } },
  ]);
});

test("without a terminal id no turn is opened, and idle still notifies", async () => {
  const { hits, fire } = await start();
  await fire(status("ses_root", "busy"), status("ses_root", "idle"));
  expect(hits).toEqual([{ path: "/notify", body: { type: "idle" } }]);
});

test("disposing mid-run closes the turn it opened", async () => {
  const { hits, plugin, fire } = await start({ terminalId: "t1" });
  await fire(status("ses_root", "busy"), questionAsked("que_1", "ses_root"));
  hits.length = 0;
  await plugin.dispose();
  expect(hits.map((h) => [h.path, h.body.type ?? h.body.event])).toEqual([
    ["/handler-event", "prompt_answered"], ["/notify", "idle"], ["/handler-event", "turn_end"],
  ]);
  hits.length = 0;
  await plugin.dispose();
  expect(hits).toEqual([]);
});

test("an opencode with no session.status still reports session.idle", async () => {
  const { hits, fire } = await start({ terminalId: "t1" });
  await fire({ type: "session.idle", properties: {} });
  expect(hits).toEqual([
    { path: "/notify", body: { type: "idle", terminalId: "t1" } },
    { path: "/handler-event", body: { terminalId: "t1", agent: "opencode", event: "turn_end" } },
  ]);
});

test("the root session's id and title go to /session-title; a subagent's do not", async () => {
  const { hits, fire } = await start({ terminalId: "t1" });
  await fire(updated("ses_root", "Fix the build"), updated("ses_child", "Explore", "ses_root"));
  expect(hits).toEqual([
    { path: "/session-title", body: { terminalId: "t1", sessionId: "ses_root", title: "Fix the build", agent: "opencode" } },
  ]);
});

test("native runtime posts carry the launching run ID", async () => {
  const { hits, fire } = await start({ terminalId: "t1" });
  process.env.ANTGRID_RUN_ID = "run-2";
  await fire(status("ses_root", "busy"), permissionAsked("per_1", "ses_root"), status("ses_root", "idle"));
  expect(hits.length).toBeGreaterThan(0);
  for (const hit of hits) expect(hit.body.runId).toBe("run-2");
});
