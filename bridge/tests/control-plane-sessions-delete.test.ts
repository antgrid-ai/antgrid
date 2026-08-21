// bridge/tests/control-plane-sessions-delete.test.ts
import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostServer, type HostRemoteConfig, type RemoteRuntime } from "../src/host-server";
import { SessionManager } from "../src/session-manager";
import { WorktreeError } from "../src/worktrees/worktree-manager";

function fakeRemoteConfig(): HostRemoteConfig {
  return {
    relayUrl: "ws://127.0.0.1:1", licenseApiUrl: "http://127.0.0.1:1",
    identity: { deviceId: "dev-1", deviceName: "dev-1", createdAt: "2026-01-01T00:00:00.000Z" },
    auth: { clientId: "cid", clientSecret: "secret", deviceUuid: "uuid-1" },
    onAuthRevoked: () => {},
  };
}
function fakeRuntime(): RemoteRuntime {
  return { maint: { getToken: () => "tok", stop: () => {} } };
}

let host: HostServer | null = null;
let prevAbDir: string | undefined;
let abDir: string | undefined;

function seedSessions(projectId: string, sessions: unknown[]): void {
  const dir = join(abDir!, "agents", projectId);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "sessions.json"), JSON.stringify({ version: 1, sessions }));
}
/** Put a project in the host's seen catalog without spawning a real core — the
 *  catalog is the only per-project bound left on a phone-named projectId. */
function seedCatalog(h: HostServer, projectId: string): void {
  (h as any).seenProjects.set(projectId, { path: "/p", label: projectId });
}
/** Flip the machine switch through its only mutation path, the loopback verb. */
async function setMobileAccess(h: HostServer, enabled: boolean): Promise<void> {
  await h.handleRemoteAccessVerb({ id: "t", type: "mobile-access:set", enabled });
}
function delReq(projectId: unknown, sessionId: unknown) {
  return delReqWith(projectId, sessionId, {});
}
/** Same request with the confirm ladder's second-rung params attached. */
function delReqWith(projectId: unknown, sessionId: unknown, extra: Record<string, unknown>) {
  return { id: "x", timestamp: 0, type: "request", requestId: "rq1", method: "sessions.delete", params: { projectId, sessionId, ...extra } } as any;
}

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-cp-del-"));
  process.env.ANTGRID_DIR = abDir;
  host = new HostServer({ remote: fakeRemoteConfig(), remoteRuntimeFactory: () => Promise.resolve(fakeRuntime()) });
});
afterEach(async () => {
  await host?.shutdown();
  host = null;
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR; else process.env.ANTGRID_DIR = prevAbDir;
  if (abDir) rmSync(abDir, { recursive: true, force: true });
});

test("a mobile-enabled machine deletes a stopped project's session from disk (no core warmed)", async () => {
  const h = host!;
  seedSessions("projA", [
    { id: "a", name: "A", createdAt: 1, lastUsedAt: 10, archived: false },
    { id: "b", name: "B", createdAt: 2, lastUsedAt: 20, archived: false },
  ]);
  seedCatalog(h, "projA");
  await setMobileAccess(h, true);

  const res = (await h.handleSessionsDeleteRpc(delReq("projA", "a"))) as any;
  expect(res.ok).toBe(true);
  expect(res.result.deleted).toBe(true);
  expect(h.get("projA")).toBeNull(); // never warmed a core
  const left = await SessionManager.readPersisted(abDir!, "projA", true);
  expect(left.map((s: any) => s.id)).toEqual(["b"]);
});

test("deleting a missing session returns ok with deleted:false", async () => {
  const h = host!;
  seedSessions("projA", [{ id: "a", name: "A", createdAt: 1, lastUsedAt: 10, archived: false }]);
  seedCatalog(h, "projA");
  await setMobileAccess(h, true);
  const res = (await h.handleSessionsDeleteRpc(delReq("projA", "ghost"))) as any;
  expect(res.ok).toBe(true);
  expect(res.result.deleted).toBe(false);
});

test("a WARM core is delegated to and the disk file is NOT mutated", async () => {
  // The dangerous branch: when a core owns sessions.json the handler MUST route to
  // the live SessionManager (via entry.core.deleteSession) and must NOT also run the
  // static disk delete, or in-memory state and disk desync. Inject a fake warm core
  // into the private cores map so we don't spawn a real one; seed disk to prove it
  // is left untouched.
  const h = host!;
  seedSessions("projWarm", [{ id: "a", name: "A", createdAt: 1, lastUsedAt: 10, archived: false }]);
  seedCatalog(h, "projWarm");
  await setMobileAccess(h, true);
  const captured: { id: string | null } = { id: null };
  (h as any).cores.set("projWarm", {
    core: { deleteSession: (id: string) => { captured.id = id; return true; }, shutdown: async () => {} },
    path: "/p", mode: "local", lastFocusedMs: 0,
  });

  const res = (await h.handleSessionsDeleteRpc(delReq("projWarm", "a"))) as any;
  expect(res.ok).toBe(true);
  expect(res.result.deleted).toBe(true);
  expect(captured.id).toBe("a"); // routed to the live core, not the disk path
  // Disk is the warm core's responsibility now — the handler must leave it alone.
  const left = await SessionManager.readPersisted(abDir!, "projWarm", true);
  expect(left.map((s: any) => s.id)).toEqual(["a"]);
});

test("a WARM core's WorktreeError is answered as ok:false, not left unanswered", async () => {
  // The phone's delete confirm ladder is driven ENTIRELY by this refusal: it
  // asks its force/delete-branch question only after seeing the code. The warm
  // branch used to sit outside the handler's try, so the rejection escaped to a
  // caller that only logs — the RPC published no frame at all and the phone hung
  // until its own timeout, with nothing to tell the user what to confirm.
  const h = host!;
  seedSessions("projWarm", [{ id: "a", name: "A", createdAt: 1, lastUsedAt: 10, archived: false }]);
  seedCatalog(h, "projWarm");
  await setMobileAccess(h, true);
  (h as any).cores.set("projWarm", {
    core: {
      deleteSession: () => { throw new WorktreeError("WORKTREE_DIRTY", "The isolated worktree has uncommitted changes."); },
      shutdown: async () => {},
    },
    path: "/p", mode: "local", lastFocusedMs: 0,
  });

  const res = (await h.handleSessionsDeleteRpc(delReq("projWarm", "a"))) as any;
  expect(res.ok).toBe(false);
  expect(res.error.code).toBe("WORKTREE_DIRTY");
});

test("force and deleteBranch reach a warm core's deleteSession", async () => {
  // The ladder's second rung is only honest if both flags survive the hop — and
  // they must stay SEPARATE: force discards uncommitted work, deleteBranch
  // destroys commits, and folding one into the other deletes what the user was
  // never asked about.
  const h = host!;
  seedSessions("projWarm", [{ id: "a", name: "A", createdAt: 1, lastUsedAt: 10, archived: false }]);
  seedCatalog(h, "projWarm");
  await setMobileAccess(h, true);
  const captured: { opts: any } = { opts: null };
  (h as any).cores.set("projWarm", {
    core: { deleteSession: (_id: string, opts: any) => { captured.opts = opts; return true; }, shutdown: async () => {} },
    path: "/p", mode: "local", lastFocusedMs: 0,
  });

  const res = (await h.handleSessionsDeleteRpc(
    delReqWith("projWarm", "a", { force: true, deleteBranch: true }),
  )) as any;
  expect(res.ok).toBe(true);
  expect(captured.opts.force).toBe(true);
  expect(captured.opts.deleteBranch).toBe(true);
});

test("with mobile access off the delete is rejected NOT_ALLOWED (no disk mutation)", async () => {
  const h = host!;
  seedSessions("projA", [{ id: "a", name: "A", createdAt: 1, lastUsedAt: 10, archived: false }]);
  seedCatalog(h, "projA");
  // Machine switch left at its default (off).
  const res = (await h.handleSessionsDeleteRpc(delReq("projA", "a"))) as any;
  expect(res.ok).toBe(false);
  expect(res.error.code).toBe("NOT_ALLOWED");
  const left = await SessionManager.readPersisted(abDir!, "projA", true);
  expect(left.map((s: any) => s.id)).toEqual(["a"]); // untouched
});

test("an id absent from the machine's catalog is rejected UNKNOWN_PROJECT (no disk mutation)", async () => {
  // This verb DELETES, so the catalog bound matters more here than on the read
  // path: the machine switch says whether any project is reachable, only the
  // catalog says which ids exist.
  const h = host!;
  seedSessions("ghost", [{ id: "a", name: "A", createdAt: 1, lastUsedAt: 10, archived: false }]);
  await setMobileAccess(h, true);

  const res = (await h.handleSessionsDeleteRpc(delReq("ghost", "a"))) as any;
  expect(res.ok).toBe(false);
  expect(res.error.code).toBe("UNKNOWN_PROJECT");
  const left = await SessionManager.readPersisted(abDir!, "ghost", true);
  expect(left.map((s: any) => s.id)).toEqual(["a"]); // untouched
});

test("a projectId with path separators is rejected E_BAD_PARAMS", async () => {
  const h = host!;
  await setMobileAccess(h, true);
  const res = (await h.handleSessionsDeleteRpc(delReq("../etc", "a"))) as any;
  expect(res.ok).toBe(false);
  expect(res.error.code).toBe("E_BAD_PARAMS");
});

test("a non-string sessionId is rejected E_BAD_PARAMS", async () => {
  const h = host!;
  seedCatalog(h, "projA");
  await setMobileAccess(h, true);
  const res = (await h.handleSessionsDeleteRpc(delReq("projA", 123))) as any;
  expect(res.ok).toBe(false);
  expect(res.error.code).toBe("E_BAD_PARAMS");
});

// --- cold-path serialization -------------------------------------------------
// The warm path holds `SessionManager.deleting` for the whole removal; the cold
// path has no core to hold anything, so the host holds it instead. Everything
// below is about that window: sessions.json still lists the session (the row is
// persisted LAST, on purpose) while its checkout is being torn down.

test("a second cold delete of the same session is refused while the first runs", async () => {
  const h = host!;
  seedSessions("projA", [{ id: "a", name: "A", createdAt: 1, lastUsedAt: 10, archived: false }]);
  seedCatalog(h, "projA");
  await setMobileAccess(h, true);

  // Gate the cold path at its first await so both requests are genuinely in
  // flight — a real removal takes seconds, and there is no faster way to hold
  // one open without spawning a worktree.
  const original = SessionManager.readPersisted;
  let release: () => void = () => {};
  const gate = new Promise<void>((resolve) => { release = resolve; });
  let calls = 0;
  (SessionManager as any).readPersisted = async (...args: unknown[]) => {
    if (++calls === 1) await gate;
    return (original as any).apply(SessionManager, args);
  };
  try {
    const first = h.handleSessionsDeleteRpc(delReq("projA", "a")) as Promise<any>;
    const second = (await h.handleSessionsDeleteRpc(delReq("projA", "a"))) as any;
    expect(second.ok).toBe(false);
    expect(second.error.code).toBe("WORKTREE_DELETE_IN_PROGRESS");

    release();
    const res = await first;
    expect(res.ok).toBe(true);
    expect(res.result.deleted).toBe(true);
  } finally {
    (SessionManager as any).readPersisted = original;
  }

  // And the guard's life is exactly one operation: a retry afterwards runs.
  const again = (await h.handleSessionsDeleteRpc(delReq("projA", "a"))) as any;
  expect(again.ok).toBe(true);
  expect(again.result.deleted).toBe(false); // already gone
});

test("a delete arriving during an in-flight open is handed to the core that open builds", async () => {
  // The one ordering `awaitColdDeletes` cannot cover: the delete picks its
  // branch off `cores`, which an open in flight has not filled yet. Deleting
  // from disk here would tear the row out from under a core that is about to
  // `start()` that very session.
  const h = host!;
  seedSessions("projA", [{ id: "a", name: "A", createdAt: 1, lastUsedAt: 10, archived: false }]);
  seedCatalog(h, "projA");
  await setMobileAccess(h, true);

  const captured: { id: string | null } = { id: null };
  let finishOpen: () => void = () => {};
  const opening = new Promise<void>((resolve) => { finishOpen = resolve; }).then(() => {
    (h as any).cores.set("projA", {
      core: { deleteSession: (id: string) => { captured.id = id; return true; }, shutdown: async () => {} },
      path: "/p", mode: "local", lastFocusedMs: 0,
    });
  });
  (h as any).opening.set("projA", opening);

  const pending = h.handleSessionsDeleteRpc(delReq("projA", "a")) as Promise<any>;
  finishOpen();
  const res = await pending;

  expect(res.ok).toBe(true);
  expect(captured.id).toBe("a"); // the core owns it now
  const left = await SessionManager.readPersisted(abDir!, "projA", true);
  expect(left.map((s: any) => s.id)).toEqual(["a"]); // disk untouched by the host
});

test("awaitColdDeletes drains this project's deletes and only this project's", async () => {
  // `open()` calls this above its warm-core check, so a core is never built off
  // a row whose checkout Git is still removing.
  const h = host!;
  let mineSettled = false;
  let otherSettled = false;
  const map = (h as any).coldDeletes as Map<string, Promise<unknown>>;
  map.set("projA/a", new Promise<void>((r) => setTimeout(() => { mineSettled = true; r(); }, 20)));
  map.set("projB/a", new Promise<void>((r) => setTimeout(() => { otherSettled = true; r(); }, 200)));

  await (h as any).awaitColdDeletes("projA");
  expect(mineSettled).toBe(true);
  expect(otherSettled).toBe(false);
  map.clear();
});
