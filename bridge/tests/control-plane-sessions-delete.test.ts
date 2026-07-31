// bridge/tests/control-plane-sessions-delete.test.ts
import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostServer, type HostRemoteConfig, type RemoteRuntime } from "../src/host-server";
import { SessionManager } from "../src/session-manager";

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
  await h.handleMobileAccessVerb({ id: "t", type: "mobile-access:set", enabled });
}
function delReq(projectId: unknown, sessionId: unknown) {
  return { id: "x", timestamp: 0, type: "request", requestId: "rq1", method: "sessions.delete", params: { projectId, sessionId } } as any;
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
