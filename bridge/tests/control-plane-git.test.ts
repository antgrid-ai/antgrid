import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostServer, type HostRemoteConfig, type RemoteRuntime } from "../src/host-server";

async function run(cwd: string, args: string[]) {
  const proc = Bun.spawn(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  await proc.exited;
}

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
let gitDir: string;

function seedCatalog(h: HostServer, projectId: string, path: string): void {
  (h as any).seenProjects.set(projectId, { path, label: projectId });
}

async function setMobileAccess(h: HostServer, enabled: boolean): Promise<void> {
  await h.handleRemoteAccessVerb({ id: "t", type: "mobile-access:set", enabled });
}

beforeEach(async () => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-cp-git-"));
  process.env.ANTGRID_DIR = abDir;

  gitDir = mkdtempSync(join(tmpdir(), "antgrid-git-repo-"));
  await run(gitDir, ["init"]);
  await run(gitDir, ["config", "user.email", "test@antgrid.local"]);
  await run(gitDir, ["config", "user.name", "Test"]);
  writeFileSync(join(gitDir, "init.txt"), "v1\n");
  await run(gitDir, ["add", "."]);
  await run(gitDir, ["commit", "-m", "initial"]);
  await run(gitDir, ["branch", "dev"]);

  host = new HostServer({ remote: fakeRemoteConfig(), remoteRuntimeFactory: () => Promise.resolve(fakeRuntime()) });
});

afterEach(async () => {
  await host?.shutdown();
  host = null;
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR; else process.env.ANTGRID_DIR = prevAbDir;
  if (abDir) rmSync(abDir, { recursive: true, force: true });
  if (gitDir) rmSync(gitDir, { recursive: true, force: true });
});

test("loopback git:branches and git:checkout work without creating a core", async () => {
  const h = host!;
  const resBranches = (await (h as any).handleControl({
    id: "req1",
    type: "git:branches",
    projectId: "p1",
    projectPath: gitDir,
  })) as any;

  expect(resBranches.ok).toBe(true);
  expect(resBranches.isRepository).toBe(true);
  expect(resBranches.branches).toContain("dev");
  expect(h.get("p1")).toBeNull();

  const resCheckout = (await (h as any).handleControl({
    id: "req2",
    type: "git:checkout",
    projectId: "p1",
    projectPath: gitDir,
    branch: "dev",
  })) as any;

  expect(resCheckout.ok).toBe(true);
  expect(resCheckout.current).toBe("dev");
});

test("remote RPC git.branches returns NOT_ALLOWED when mobile access is off", async () => {
  const h = host!;
  seedCatalog(h, "p1", gitDir);
  await setMobileAccess(h, false);

  const res = (await h.handleGitBranchesRpc({
    id: "msg1",
    timestamp: 0,
    type: "request",
    requestId: "r1",
    method: "git.branches",
    params: { projectId: "p1" },
  } as any)) as any;

  expect(res.ok).toBe(false);
  expect(res.error.code).toBe("NOT_ALLOWED");
});

test("remote RPC git.branches returns UNKNOWN_PROJECT for unseeded project", async () => {
  const h = host!;
  await setMobileAccess(h, true);

  const res = (await h.handleGitBranchesRpc({
    id: "msg1",
    timestamp: 0,
    type: "request",
    requestId: "r1",
    method: "git.branches",
    params: { projectId: "unknown" },
  } as any)) as any;

  expect(res.ok).toBe(false);
  expect(res.error.code).toBe("UNKNOWN_PROJECT");
});

test("remote RPC git.branches succeeds for seeded project", async () => {
  const h = host!;
  seedCatalog(h, "p1", gitDir);
  await setMobileAccess(h, true);

  const res = (await h.handleGitBranchesRpc({
    id: "msg1",
    timestamp: 0,
    type: "request",
    requestId: "r1",
    method: "git.branches",
    params: { projectId: "p1" },
  } as any)) as any;

  expect(res.ok).toBe(true);
  expect(res.result.isRepository).toBe(true);
  expect(res.result.branches).toContain("dev");
});

test("active session guard returns ACTIVE_SESSIONS for working or attention session", async () => {
  const h = host!;
  seedCatalog(h, "p1", gitDir);
  await setMobileAccess(h, true);

  // Inject a warm core with working session
  (h as any).cores.set("p1", {
    core: {
      sessionWorkStatuses: { s1: "working" },
      shutdown: async () => {},
    },
    path: gitDir,
    mode: "local",
    lastFocusedMs: 0,
  });

  const res = (await h.handleGitCheckoutRpc({
    id: "msg1",
    timestamp: 0,
    type: "request",
    requestId: "r1",
    method: "git.checkout",
    params: { projectId: "p1", branch: "dev" },
  } as any)) as any;

  expect(res.ok).toBe(false);
  expect(res.error.code).toBe("ACTIVE_SESSIONS");
});

test("active session guard allows checkout with allowActiveSessions: true", async () => {
  const h = host!;
  seedCatalog(h, "p1", gitDir);
  await setMobileAccess(h, true);

  (h as any).cores.set("p1", {
    core: {
      sessionWorkStatuses: { s1: "working" },
      shutdown: async () => {},
    },
    path: gitDir,
    mode: "local",
    lastFocusedMs: 0,
  });

  const res = (await h.handleGitCheckoutRpc({
    id: "msg1",
    timestamp: 0,
    type: "request",
    requestId: "r1",
    method: "git.checkout",
    params: { projectId: "p1", branch: "dev", allowActiveSessions: true },
  } as any)) as any;

  expect(res.ok).toBe(true);
  expect(res.result.current).toBe("dev");
});

test("active session guard does not warn if checking out same current branch", async () => {
  const h = host!;
  seedCatalog(h, "p1", gitDir);
  await setMobileAccess(h, true);

  const catalog = (await h.handleGitBranchesRpc({
    id: "msg1", timestamp: 0, type: "request", requestId: "r1", method: "git.branches", params: { projectId: "p1" },
  } as any)) as any;
  const currentBranch = catalog.result.current;

  (h as any).cores.set("p1", {
    core: {
      sessionWorkStatuses: { s1: "working" },
      shutdown: async () => {},
    },
    path: gitDir,
    mode: "local",
    lastFocusedMs: 0,
  });

  const res = (await h.handleGitCheckoutRpc({
    id: "msg2",
    timestamp: 0,
    type: "request",
    requestId: "r2",
    method: "git.checkout",
    params: { projectId: "p1", branch: currentBranch },
  } as any)) as any;

  expect(res.ok).toBe(true);
  expect(res.result.current).toBe(currentBranch);
});
