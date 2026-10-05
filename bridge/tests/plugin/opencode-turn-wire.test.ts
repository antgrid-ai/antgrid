// The opencode plugin opens a terminal session's turn from inside opencode, and
// nothing on the bridge side knows to close it except the posts the same plugin
// sends at idle. A plugin that posts the right paths to an owner that files them
// under the wrong methods typechecks and passes the plugin's own suite, and the
// only symptom is a session wedged on "working". So this drives the real plugin
// into a real ProjectCore's api-server, records which owner methods each post
// reaches, and replays those calls through the real work-status reduction.
import { test, expect, beforeEach, afterEach, afterAll } from "bun:test";
import { mkdtempSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { AntgridSessionNamer } from "../../../packages/antgrid-agents/assets/opencode/plugin";
import { ProjectCore } from "../../src/project-core";
import { hookTurnEnd, initialWorkStatus, reduceWorkStatus, turnStart, userReply, type WorkStatusState } from "../../src/work-status";
import type { AbMessage } from "../../src/protocol";

const ENV_KEYS = ["ANTGRID_DIR", "ANTGRID_API_PORT", "ANTGRID_TERMINAL_ID", "ANTGRID_RUN_ID"] as const;
let savedEnv: Record<string, string | undefined> = {};
let stateDir: string;
beforeEach(() => {
  savedEnv = Object.fromEntries(ENV_KEYS.map((k) => [k, process.env[k]]));
  for (const k of ENV_KEYS) delete process.env[k];
  // The api-server's port file is one shared path every started core overwrites;
  // pinning ANTGRID_DIR makes it this suite's own.
  stateDir = mkdtempSync(join(tmpdir(), "antgrid-opencode-wire-state-"));
  process.env.ANTGRID_DIR = stateDir;
});

// A late EPERM/ENOENT from the raw fs.watch when a temp folder goes away lands
// asynchronously, sometimes in the next test.
function ignoreWatcherEperm(err: unknown): void {
  const code = (err as { code?: string } | null)?.code;
  if (code === "EPERM" || code === "ENOENT") return;
  throw err;
}
process.on("uncaughtException", ignoreWatcherEperm);
afterAll(() => { process.off("uncaughtException", ignoreWatcherEperm); });

const cleanup: Array<() => void | Promise<unknown>> = [];
afterEach(async () => { for (const fn of cleanup.splice(0).reverse()) try { await fn(); } catch {} });
afterEach(() => {
  for (const k of ENV_KEYS) {
    if (savedEnv[k] === undefined) delete process.env[k];
    else process.env[k] = savedEnv[k];
  }
  rmSync(stateDir, { recursive: true, force: true });
});

type Call =
  | { kind: "turnStart"; id?: string }
  | { kind: "hookTurnEnd"; id: string }
  | { kind: "userReply"; id: string; opts: { submitted: boolean; typed: boolean } }
  | { kind: "notification"; msg: AbMessage };

/** A started local core whose turn-relevant owner methods are recorded in call
 *  order. Patched on the instance: the owner re-emits its own (empty) session
 *  list, which prunes any fixture session, so its live reduction cannot show
 *  whether a close happened. */
async function startCore(): Promise<{ calls: Call[] }> {
  const folder = mkdtempSync(join(tmpdir(), "antgrid-opencode-wire-proj-"));
  const core = new ProjectCore({
    folder,
    mode: "local",
    identity: { deviceId: randomUUID(), deviceName: "local", createdAt: new Date().toISOString() },
  });
  cleanup.push(() => rmSync(folder, { recursive: true, force: true }));
  cleanup.push(() => core.shutdown());
  const calls: Call[] = [];
  const c = core as any;
  const wrap = (name: string, record: (...args: any[]) => Call | undefined) => {
    const real = c[name].bind(core);
    c[name] = (...args: any[]) => { const call = record(...args); if (call) calls.push(call); return real(...args); };
  };
  wrap("noteTurnStart", (id) => ({ kind: "turnStart", id }));
  wrap("noteHookTurnEnd", (id) => ({ kind: "hookTurnEnd", id }));
  wrap("noteUserReply", (id, opts) => ({ kind: "userReply", id, opts }));
  wrap("observeWorkStatus", (msg: AbMessage) => msg.type === "notification:push" ? { kind: "notification", msg } : undefined);
  await core.start();
  const port = Number(readFileSync(join(stateDir, "api.port"), "utf8"));
  expect(port).toBeGreaterThan(0);
  process.env.ANTGRID_API_PORT = String(port);
  process.env.ANTGRID_TERMINAL_ID = "term-1";
  return { calls };
}

/** term-1 listed running, then [calls] applied the way ProjectCore applies them. */
function replay(calls: Call[]): WorkStatusState {
  const listed = reduceWorkStatus(initialWorkStatus, {
    id: "m", timestamp: 0, type: "session:updated",
    sessions: [{ id: "term-1", name: "term-1", createdAt: 0, lastUsedAt: 0, archived: false, running: true }],
  } as unknown as AbMessage);
  return calls.reduce((state, call) => {
    switch (call.kind) {
      case "turnStart": return turnStart(state, call.id, undefined, 1);
      case "hookTurnEnd": return hookTurnEnd(state, call.id);
      case "userReply": return userReply(state, call.id, call.opts, 1);
      case "notification": return reduceWorkStatus(state, call.msg);
    }
  }, listed);
}

const status = (type: "busy" | "retry" | "idle") =>
  ({ type: "session.status", properties: { sessionID: "ses_root", status: { type } } });

async function plugin() {
  const p = await AntgridSessionNamer({} as any) as any;
  return async (...events: any[]) => { for (const event of events) await p.event({ event }); };
}

const summary = (calls: Call[]) => calls.map((c) =>
  c.kind === "notification" ? `notify:${(c.msg as any).notificationType}:${(c.msg as any).sessionId}` : `${c.kind}:${c.id}`);

test("busy opens term-1's turn and idle closes it, on both closers", async () => {
  const { calls } = await startCore();
  const fire = await plugin();

  await fire(status("busy"), status("retry"), status("busy"));
  expect(summary(calls)).toEqual(["turnStart:term-1"]);
  expect(replay(calls).sessionStatuses.get("term-1")).toBe("working");

  await fire(status("idle"));
  expect(summary(calls)).toEqual(["turnStart:term-1", "notify:idle:term-1", "hookTurnEnd:term-1"]);
  expect(replay(calls).sessionStatuses.get("term-1")).toBe("done");
  // Each closer alone ends the turn: /notify can be deduplicated away, and
  // turn_end can be refused for a chat slot.
  expect(replay(calls.filter((c) => c.kind !== "hookTurnEnd")).activeTurns.has("term-1")).toBe(false);
  expect(replay(calls.filter((c) => c.kind !== "notification")).activeTurns.has("term-1")).toBe(false);
});

test("a second quick run still closes when its identical idle /notify is deduplicated", async () => {
  const { calls } = await startCore();
  const fire = await plugin();
  await fire(status("busy"), status("idle"), status("busy"), status("idle"));
  expect(summary(calls)).toEqual([
    "turnStart:term-1", "notify:idle:term-1", "hookTurnEnd:term-1",
    // The bridge collapses an identical /notify inside its dedup window.
    "turnStart:term-1", "hookTurnEnd:term-1",
  ]);
  expect(replay(calls).activeTurns.has("term-1")).toBe(false);
});

test("a permission raises needs-you mid-turn and its reply lowers it without opening a turn", async () => {
  const { calls } = await startCore();
  const fire = await plugin();
  await fire(status("busy"),
    { type: "permission.asked", properties: { id: "per_1", sessionID: "ses_root", permission: "bash", patterns: ["git push"] } });
  expect(replay(calls).sessionStatuses.get("term-1")).toBe("attention");

  await fire({ type: "permission.replied", properties: { sessionID: "ses_root", requestID: "per_1", reply: "once" } });
  expect(summary(calls).at(-1)).toBe("userReply:term-1");
  expect(replay(calls).sessionStatuses.get("term-1")).toBe("working");

  await fire(status("idle"));
  expect(replay(calls).sessionStatuses.get("term-1")).toBe("done");
});

test("a rejected question after the run already stopped leaves the session done", async () => {
  // The resolution must never be what opens a turn: nothing would close it.
  const { calls } = await startCore();
  const fire = await plugin();
  await fire(status("busy"),
    { type: "question.asked", properties: { id: "que_1", sessionID: "ses_root", questions: [{ question: "Which branch?", header: "Branch", options: [] }] } },
    status("idle"),
    { type: "question.rejected", properties: { sessionID: "ses_root", requestID: "que_1" } });
  expect(replay(calls).activeTurns.has("term-1")).toBe(false);
  expect(replay(calls).sessionStatuses.get("term-1")).toBe("done");
});
