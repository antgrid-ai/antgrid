// The suppression is threaded owner → core → api-server, and a missed hop is
// SILENT: everything typechecks, the api-server suite still passes (it injects
// the predicate directly), and the only symptom is the Handler quietly still
// paying a context assemble plus a judge spawn for every post-completion nudge.
// So this drives a real ProjectCore and reaches its api-server the way an
// injected hook does, which is the only thing that proves all three legs are
// connected.
import { test, expect, afterEach, afterAll } from "bun:test";
import { mkdtempSync, rmSync, readFileSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { ProjectCore } from "../../src/project-core";
import { initialWorkStatus, reduceWorkStatus } from "../../src/work-status";
import type { AbMessage } from "../../src/protocol";

// The port a hook posts to is discovered from the api-server's own port file —
// the fallback path in `hook-runner.ts`, and the only handle a test has on a
// core's loopback port. Resolved the way api-server resolves it, and read only
// straight after this suite's own start, since it is a single shared path that
// every started core overwrites.
const portFile = () => join(process.env.ANTGRID_DIR ?? join(homedir(), ".antgrid"), "api.port");

// A late EPERM/ENOENT from the raw fs.watch when a temp folder goes away lands
// asynchronously, sometimes in the next test — the same teardown artifact the
// other core-driving suites swallow.
function ignoreWatcherEperm(err: unknown): void {
  const code = (err as { code?: string } | null)?.code;
  if (code === "EPERM" || code === "ENOENT") return;
  throw err;
}
process.on("uncaughtException", ignoreWatcherEperm);
afterAll(() => { process.off("uncaughtException", ignoreWatcherEperm); });

const cleanup: Array<() => void | Promise<unknown>> = [];
// LIFO + awaited: the core stops watching before its folder is removed.
afterEach(async () => { for (const fn of cleanup.splice(0).reverse()) try { await fn(); } catch {} });

/** A started local core plus the loopback api-server port its hooks post to. */
async function startCore(): Promise<{ core: ProjectCore; port: number }> {
  const folder = mkdtempSync(join(tmpdir(), "antgrid-stale-nudge-proj-"));
  const core = new ProjectCore({
    folder,
    mode: "local",
    identity: { deviceId: randomUUID(), deviceName: "local", createdAt: new Date().toISOString() },
  });
  cleanup.push(() => rmSync(folder, { recursive: true, force: true }));
  cleanup.push(() => core.shutdown());
  await core.start();
  const port = Number(readFileSync(portFile(), "utf8"));
  expect(port).toBeGreaterThan(0);
  return { core, port };
}

/** Put the owner's reduction in the state a finished turn on [sessionId] leaves
 *  it in — built with the real reducer, then installed, because replaying the
 *  frames through the core's own subscriber cannot survive: a per-session move
 *  makes it re-emit its (empty) REAL session list, which prunes a session no
 *  PTY ever backed. The session list is part of the fixture on purpose — a
 *  notification for an id that was never listed running falls back to the
 *  project-wide key, and that attribution must never suppress anything. */
function endTurn(core: ProjectCore, sessionId: string): void {
  const frames = [
    {
      id: "m", timestamp: 0, type: "session:updated",
      sessions: [{ id: sessionId, name: sessionId, createdAt: 0, lastUsedAt: 0, archived: false, running: true }],
    },
    { id: "m", timestamp: 0, type: "notification:push", notificationType: "task_complete", sessionId },
  ] as unknown as AbMessage[];
  const work = frames.reduce(reduceWorkStatus, initialWorkStatus);
  expect(work.notifications.get(sessionId)).toBe("task_complete");
  (core as any)._work = work;
}

function postHandlerEvent(port: number, body: unknown): Promise<Response> {
  return fetch(`http://127.0.0.1:${port}/handler-event`, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
  });
}

// `idleNudge` is the hook's own reading of the message it saw, and the drop needs
// it as well as the turn state — so every post below states it the way the real
// claude hook would for the case it describes.
test("a nudge arriving after the slot's own turn ended is dropped end to end", async () => {
  const { core, port } = await startCore();
  endTurn(core, "term-1");
  const res = await postHandlerEvent(port, { terminalId: "term-1", event: "awaiting_input", idleNudge: true });
  expect(res.status).toBe(200);
  expect(await res.json()).toEqual({ ok: true, stale: true });
});

test("a nudge for a slot whose turn never ended still reaches the core", async () => {
  const { port } = await startCore();
  const res = await postHandlerEvent(port, { terminalId: "term-1", event: "awaiting_input", idleNudge: true });
  expect(res.status).toBe(200);
  expect(await res.json()).toEqual({ ok: true });
});

test("a sibling's turn-end cannot suppress this slot's nudge", async () => {
  const { core, port } = await startCore();
  endTurn(core, "term-1");
  const res = await postHandlerEvent(port, { terminalId: "term-2", event: "awaiting_input", idleNudge: true });
  expect(res.status).toBe(200);
  expect(await res.json()).toEqual({ ok: true });
});

test("a genuine block reaches the core even from a latched turn-end", async () => {
  // The reduction the drop reads is exactly one hook invocation behind: this
  // event's own /notify — `permission_request`, because the hook did not read the
  // message as the nudge — has not folded yet, so turn state alone would drop the
  // block and then light the session up as needing the user anyway.
  const { core, port } = await startCore();
  endTurn(core, "term-1");
  const res = await postHandlerEvent(port, { terminalId: "term-1", event: "awaiting_input", idleNudge: false });
  expect(res.status).toBe(200);
  expect(await res.json()).toEqual({ ok: true });
});

test("turn_end is forwarded from the same latched state", async () => {
  const { core, port } = await startCore();
  endTurn(core, "term-1");
  const res = await postHandlerEvent(port, { terminalId: "term-1", event: "turn_end" });
  expect(res.status).toBe(200);
  expect(await res.json()).toEqual({ ok: true });
});
