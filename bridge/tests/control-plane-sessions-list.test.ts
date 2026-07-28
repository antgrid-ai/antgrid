import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostServer, type HostRemoteConfig, type RemoteRuntime } from "../src/host-server";

function fakeRemoteConfig(): HostRemoteConfig {
  return {
    relayUrl: "ws://127.0.0.1:1",
    licenseApiUrl: "http://127.0.0.1:1",
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
function req(projectId: unknown) {
  return { id: "x", timestamp: 0, type: "request", requestId: "rq1", method: "sessions.list", params: { projectId } } as any;
}

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-cp-sessions-"));
  process.env.ANTGRID_DIR = abDir;
  host = new HostServer({ remote: fakeRemoteConfig(), remoteRuntimeFactory: () => Promise.resolve(fakeRuntime()) });
});
afterEach(async () => {
  await host?.shutdown();
  host = null;
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR; else process.env.ANTGRID_DIR = prevAbDir;
  if (abDir) rmSync(abDir, { recursive: true, force: true });
});

test("allowed phone gets the persisted list WITHOUT starting a core", async () => {
  const h = host!;
  seedSessions("projA", [{ id: "a", name: "A", createdAt: 1, lastUsedAt: 10, archived: false }]);
  h.pairedPhones.upsert({ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "x", lastSeenAt: "x", allowedProjects: ["projA"] });

  const res = (await h.handleSessionsListRpc(req("projA"), "pk1")) as any;
  expect(res.ok).toBe(true);
  expect(res.requestId).toBe("rq1");
  expect(res.result.sessions.map((s: any) => s.id)).toEqual(["a"]);
  expect(res.result.sessions[0].running).toBe(false);
  // SECURITY/PERF: a peek never warms a core.
  expect(h.get("projA")).toBeNull();
});

test("a WARM core is delegated to so the peek reports LIVE per-session running", async () => {
  // The whole point of the peek fix: a warm core owns live PTY/chat state, so the
  // handler must route to entry.core.listSessions (true `running`) instead of the
  // disk peek, which always reports running:false. Inject a fake warm core into
  // the private cores map — matching control-plane-sessions-delete's pattern — so
  // we don't spawn a real one. Seed disk with running:false to prove the live core
  // (not the disk file) is the source.
  const h = host!;
  seedSessions("projWarm", [{ id: "live", name: "Live", createdAt: 1, lastUsedAt: 10, archived: false, running: false }]);
  h.pairedPhones.upsert({ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "x", lastSeenAt: "x", allowedProjects: ["projWarm"] });
  const captured: { includeArchived: boolean | null } = { includeArchived: null };
  (h as any).cores.set("projWarm", {
    core: {
      listSessions: (includeArchived: boolean) => {
        captured.includeArchived = includeArchived;
        return [{ id: "live", name: "Live", createdAt: 1, lastUsedAt: 10, archived: false, running: true }];
      },
      shutdown: async () => {},
    },
    path: "/p", mode: "local", lastFocusedMs: 0,
  });

  const res = (await h.handleSessionsListRpc(req("projWarm"), "pk1")) as any;
  expect(res.ok).toBe(true);
  expect(res.result.sessions.map((s: any) => s.id)).toEqual(["live"]);
  expect(res.result.sessions[0].running).toBe(true); // LIVE state, not the disk's false
  expect(captured.includeArchived).toBe(false); // routed to the live core
});

test("buildProjectsAdvertisement carries a warm core's work status", () => {
  const h = host!;
  h.pairedPhones.upsert({ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "x", lastSeenAt: "x", allowedProjects: ["projWarm"] });
  // Inject a fake warm core exposing the reduced work status the advert folds in
  // (mirrors the warm-core injection pattern above; no real core spawned).
  (h as any).cores.set("projWarm", {
    core: { workStatus: "attention", isRelayRegistered: () => true, shutdown: async () => {} },
    path: "/p", mode: "local", lastFocusedMs: 0,
  });

  const entry = h.buildProjectsAdvertisement("pk1").find((p) => p.projectId === "projWarm");
  expect(entry?.status).toBe("attention"); // folded from the core
  expect(entry?.running).toBe(true); // dialable (isRelayRegistered)
});

test("non-allowed phone is rejected NOT_ALLOWED (no disk read leaked)", async () => {
  const h = host!;
  seedSessions("projA", [{ id: "a", name: "A", createdAt: 1, lastUsedAt: 10, archived: false }]);
  // pk1 paired but projA NOT in its allowlist.
  h.pairedPhones.upsert({ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "x", lastSeenAt: "x", allowedProjects: [] });

  const res = (await h.handleSessionsListRpc(req("projA"), "pk1")) as any;
  expect(res.ok).toBe(false);
  expect(res.error.code).toBe("NOT_ALLOWED");
});

test("a stopped project's list is served from disk (no core ever opened)", async () => {
  const h = host!;
  seedSessions("stopped", [{ id: "s", name: "S", createdAt: 1, lastUsedAt: 5, archived: false }]);
  h.pairedPhones.upsert({ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "x", lastSeenAt: "x", allowedProjects: ["stopped"] });

  const res = (await h.handleSessionsListRpc(req("stopped"), "pk1")) as any;
  expect(res.ok).toBe(true);
  expect(res.result.sessions).toHaveLength(1);
  expect(h.get("stopped")).toBeNull();
});

test("a projectId with path separators is rejected E_BAD_PARAMS", async () => {
  const h = host!;
  h.pairedPhones.upsert({ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "x", lastSeenAt: "x", allowedProjects: ["../etc"] });
  const res = (await h.handleSessionsListRpc(req("../etc"), "pk1")) as any;
  expect(res.ok).toBe(false);
  expect(res.error.code).toBe("E_BAD_PARAMS");
});

test("a non-string projectId is rejected E_BAD_PARAMS", async () => {
  const h = host!;
  const res = (await h.handleSessionsListRpc(req(123), "pk1")) as any;
  expect(res.ok).toBe(false);
  expect(res.error.code).toBe("E_BAD_PARAMS");
});

test("a projectId containing '..' (e.g. foo..bar) is rejected E_BAD_PARAMS by the path guard, not the allowlist", async () => {
  const h = host!;
  // Phone explicitly allows "foo..bar" — so if the allowlist gate fired first,
  // this would return NOT_ALLOWED (wrong). E_BAD_PARAMS proves the path guard runs first.
  h.pairedPhones.upsert({ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "x", lastSeenAt: "x", allowedProjects: ["foo..bar"] });
  const res = (await h.handleSessionsListRpc(req("foo..bar"), "pk1")) as any;
  expect(res.ok).toBe(false);
  expect(res.error.code).toBe("E_BAD_PARAMS");
});

test("a leading-dot projectId (e.g. .ssh) is rejected E_BAD_PARAMS by the path guard, not the allowlist", async () => {
  const h = host!;
  // Hidden-dir name: the old regex /^[A-Za-z0-9._-]+$/ accepted it. Phone
  // explicitly allows ".ssh" so a passing path guard, not the allowlist, must
  // be what rejects it.
  h.pairedPhones.upsert({ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "x", lastSeenAt: "x", allowedProjects: [".ssh"] });
  const res = (await h.handleSessionsListRpc(req(".ssh"), "pk1")) as any;
  expect(res.ok).toBe(false);
  expect(res.error.code).toBe("E_BAD_PARAMS");
});
