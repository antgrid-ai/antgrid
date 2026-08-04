import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostServer, type HostRemoteConfig, type RemoteRuntime } from "../src/host-server";
import { CheckoutStore } from "../src/worktrees/checkout-store";

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
let abDir: string;
let projectDir: string;
let worktreeDir: string;

function seedCatalog(h: HostServer, projectId: string, path: string): void {
  (h as any).seenProjects.set(projectId, { path, label: projectId });
}

function ask(h: HostServer, projectId: string, checkoutId: string): Promise<any> {
  return (h as any).handleControl({ id: "req", type: "checkout:path", projectId, checkoutId });
}

beforeEach(async () => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-cp-path-"));
  process.env.ANTGRID_DIR = abDir;

  projectDir = mkdtempSync(join(tmpdir(), "antgrid-project-"));
  worktreeDir = join(abDir, "worktrees", "p1", "wt1");
  mkdirSync(worktreeDir, { recursive: true });

  host = new HostServer({ remote: fakeRemoteConfig(), remoteRuntimeFactory: () => Promise.resolve(fakeRuntime()) });
  seedCatalog(host, "p1", projectDir);
  await new CheckoutStore(abDir, "p1").put({
    id: "wt1",
    projectId: "p1",
    kind: "managed-worktree",
    path: worktreeDir,
    branch: "session/refactor",
    baseRef: "main",
    managed: true,
    sessionId: "s1",
    createdAt: 1,
  });
});

afterEach(async () => {
  await host?.shutdown();
  host = null;
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR; else process.env.ANTGRID_DIR = prevAbDir;
  rmSync(abDir, { recursive: true, force: true });
  rmSync(projectDir, { recursive: true, force: true });
});

test("checkout:path resolves main from the catalog without creating a core", async () => {
  const h = host!;
  const res = await ask(h, "p1", "main");
  expect(res.ok).toBe(true);
  expect(res.path).toBe(projectDir);
  expect(h.get("p1")).toBeNull();
});

test("checkout:path resolves a managed worktree from the checkout store", async () => {
  const res = await ask(host!, "p1", "wt1");
  expect(res.ok).toBe(true);
  expect(res.path).toBe(worktreeDir);
});

test("checkout:path refuses a project with no path on record", async () => {
  const res = await ask(host!, "p2", "main");
  expect(res.ok).toBe(false);
  expect(res.error.code).toBe("UNKNOWN_PROJECT");
});

test("checkout:path refuses a checkout that belongs to no session of this project", async () => {
  const res = await ask(host!, "p1", "wt-other");
  expect(res.ok).toBe(false);
  expect(res.error.code).toBe("UNKNOWN_CHECKOUT");
});

test("checkout:path refuses a traversing project id before it reaches the store", async () => {
  const res = await ask(host!, "../escape", "main");
  expect(res.ok).toBe(false);
  expect(res.error.code).toBe("INVALID_PROJECT");
});

test("checkout:path reports a worktree whose directory is gone", async () => {
  rmSync(worktreeDir, { recursive: true, force: true });
  const res = await ask(host!, "p1", "wt1");
  expect(res.ok).toBe(false);
  expect(res.error.code).toBe("CHECKOUT_MISSING");
});
