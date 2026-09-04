import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { MAX_CAPABILITY_CARD_PROJECTS } from "../src/capability-card";
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

function seedCatalog(h: HostServer, projectId: string, path: string, label?: string, lastActiveAt?: string): void {
  (h as any).seenProjects.set(projectId, { path, label: label ?? projectId, lastActiveAt });
}

async function setMobileAccess(h: HostServer, enabled: boolean): Promise<void> {
  await h.handleRemoteAccessVerb({ id: "t", type: "mobile-access:set", enabled });
}

function cardRequest(params: unknown) {
  return {
    id: "msg1",
    timestamp: 0,
    type: "request",
    requestId: "r1",
    method: "machine.capability-card",
    params,
  } as any;
}

beforeEach(async () => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-cp-card-"));
  process.env.ANTGRID_DIR = abDir;

  gitDir = mkdtempSync(join(tmpdir(), "antgrid-card-repo-"));
  await run(gitDir, ["init", "-b", "main"]);
  await run(gitDir, ["config", "user.email", "test@antgrid.local"]);
  await run(gitDir, ["config", "user.name", "Test"]);
  writeFileSync(join(gitDir, "init.txt"), "v1\n");
  await run(gitDir, ["add", "."]);
  await run(gitDir, ["commit", "-m", "initial"]);
  await run(gitDir, ["remote", "add", "origin", "https://github.com/Owner/Repo.git"]);

  host = new HostServer({ remote: fakeRemoteConfig(), remoteRuntimeFactory: () => Promise.resolve(fakeRuntime()) });
});

afterEach(async () => {
  await host?.shutdown();
  host = null;
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR; else process.env.ANTGRID_DIR = prevAbDir;
  if (abDir) rmSync(abDir, { recursive: true, force: true });
  if (gitDir) rmSync(gitDir, { recursive: true, force: true });
});

test("machine.capability-card answers a cold project with no core warmed", async () => {
  const h = host!;
  seedCatalog(h, "p1", gitDir, "repo");
  await setMobileAccess(h, true);

  const res = (await h.handleCapabilityCardRpc(cardRequest({ projectIds: ["p1"] }))) as any;

  expect(res.ok).toBe(true);
  expect(res.result.os.name.length).toBeGreaterThan(0);
  expect(res.result.projects.p1).toEqual({ label: "repo", remote: "github.com/owner/repo", branch: "main" });
  expect(h.get("p1")).toBeNull();
});

test("machine.capability-card covers the whole catalog when projectIds is omitted", async () => {
  const h = host!;
  seedCatalog(h, "p1", gitDir, "repo");
  await setMobileAccess(h, true);

  const res = (await h.handleCapabilityCardRpc(cardRequest({}))) as any;

  expect(res.ok).toBe(true);
  expect(Object.keys(res.result.projects)).toEqual(["p1"]);
});

test("the whole-catalog default is bounded, most recently active first", async () => {
  const h = host!;
  // A catalog only grows: nothing prunes a project whose path still exists, so
  // an install that has opened hundreds is ordinary — and with no id list to
  // bound it, the default would fan a git probe out over every one of them.
  const stale = join(gitDir, "gone");
  const total = MAX_CAPABILITY_CARD_PROJECTS + 10;
  for (let i = 0; i < total; i++) {
    // Ascending time, so the ids that must survive the cut are the LAST seeded
    // and the map's own insertion order cannot be what produces a passing run.
    seedCatalog(h, `p${i}`, stale, `p${i}`, new Date(1_800_000_000_000 + i * 1000).toISOString());
  }
  seedCatalog(h, "recent", gitDir, "repo", new Date(1_900_000_000_000).toISOString());
  await setMobileAccess(h, true);

  const res = (await h.handleCapabilityCardRpc(cardRequest({}))) as any;

  expect(res.ok).toBe(true);
  const answered = Object.keys(res.result.projects);
  expect(answered).toHaveLength(MAX_CAPABILITY_CARD_PROJECTS);
  expect(answered).toContain("recent");
  expect(answered).not.toContain("p0");
  expect(res.result.projects.recent.branch).toBe("main");
}, 30_000);

test("machine.capability-card refuses more ids than one card may answer for", async () => {
  const h = host!;
  await setMobileAccess(h, true);

  const projectIds = Array.from({ length: MAX_CAPABILITY_CARD_PROJECTS + 1 }, (_, i) => `p${i}`);
  const res = (await h.handleCapabilityCardRpc(cardRequest({ projectIds }))) as any;

  expect(res.ok).toBe(false);
  expect(res.error.code).toBe("E_BAD_PARAMS");
});

test("machine.capability-card returns NOT_ALLOWED when mobile access is off", async () => {
  const h = host!;
  seedCatalog(h, "p1", gitDir);
  await setMobileAccess(h, false);

  const res = (await h.handleCapabilityCardRpc(cardRequest({ projectIds: ["p1"] }))) as any;

  expect(res.ok).toBe(false);
  expect(res.error.code).toBe("NOT_ALLOWED");
});

test("machine.capability-card omits an uncatalogued id instead of failing the card", async () => {
  const h = host!;
  seedCatalog(h, "p1", gitDir, "repo");
  await setMobileAccess(h, true);

  const mixed = (await h.handleCapabilityCardRpc(cardRequest({ projectIds: ["p1", "ghost"] }))) as any;
  expect(mixed.ok).toBe(true);
  expect(Object.keys(mixed.result.projects)).toEqual(["p1"]);

  const wholly = (await h.handleCapabilityCardRpc(cardRequest({ projectIds: ["ghost"] }))) as any;
  expect(wholly.ok).toBe(true);
  expect(wholly.result.projects).toEqual({});
  expect(wholly.result.os.arch).toBe(process.arch);
});

test("machine.capability-card rejects an unsafe projectId", async () => {
  const h = host!;
  await setMobileAccess(h, true);

  const res = (await h.handleCapabilityCardRpc(cardRequest({ projectIds: ["../etc/passwd"] }))) as any;

  expect(res.ok).toBe(false);
  expect(res.error.code).toBe("E_BAD_PARAMS");
});

test("machine.capability-card rejects malformed params", async () => {
  const h = host!;
  await setMobileAccess(h, true);

  const res = (await h.handleCapabilityCardRpc(cardRequest({ projectIds: "p1" }))) as any;

  expect(res.ok).toBe(false);
  expect(res.error.code).toBe("E_BAD_PARAMS");
});

test("dispatchControlPlaneInbound routes machine.capability-card and publishes the response", async () => {
  const h = host!;
  seedCatalog(h, "p1", gitDir, "repo");
  await setMobileAccess(h, true);

  const published: any[] = [];
  const bus = { publish: (msg: any) => published.push(msg) } as any;
  h.dispatchControlPlaneInbound(cardRequest({ projectIds: ["p1"] }), "control", bus);

  await Bun.sleep(200);
  expect(published).toHaveLength(1);
  expect(published[0].requestId).toBe("r1");
  expect(published[0].ok).toBe(true);
  expect(published[0].result.projects.p1.remote).toBe("github.com/owner/repo");
});
