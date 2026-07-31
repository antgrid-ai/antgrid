import { test, expect, beforeEach, afterEach } from "bun:test";
import { existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostServer, type HostRemoteConfig, type RemoteRuntime } from "../src/host-server";

// --- shared fakes (mirror control-plane-start.test.ts) ---------------------

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

function tempFolder(): string {
  const f = mkdtempSync(join(tmpdir(), "antgrid-cp-forget-proj-"));
  writeFileSync(join(f, "antgrid.yaml"), "name: test-remote\nagent:\n  tool: claude-code\n");
  return f;
}

/** Seed a project's persisted session store, as SessionManager would. The path
 *  mirrors `join(storeDir, "agents", projectId)`. */
function seedSessionStore(projectId: string): string {
  const dir = join(abDir!, "agents", projectId);
  mkdirSync(dir, { recursive: true });
  writeFileSync(
    join(dir, "sessions.json"),
    JSON.stringify({ version: 1, sessions: [{ id: "s1", name: "Session 1", createdAt: 1, lastUsedAt: 1, archived: false }] }),
  );
  return dir;
}

/** Seed the legacy ephemeral-pubkey dir an older bridge would have left under
 *  `projects/<id>/`. Current bridges don't write this; forget() must still
 *  clean it. */
function seedLegacyProjectDir(projectId: string): string {
  const dir = join(abDir!, "projects", projectId);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "session.json"), JSON.stringify({ pubkey: "x" }));
  return dir;
}

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-cp-forget-abdir-"));
  process.env.ANTGRID_DIR = abDir;
  host = new HostServer({
    remote: fakeRemoteConfig(),
    remoteRuntimeFactory: () => Promise.resolve(fakeRuntime()),
  });
});

afterEach(async () => {
  await host?.shutdown();
  host = null;
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR; else process.env.ANTGRID_DIR = prevAbDir;
  if (abDir) rmSync(abDir, { recursive: true, force: true });
});

test("forget() stops a warm core, deletes its session store, and drops the seen-catalog hint", async () => {
  const h = host!;
  await h.open("projA", tempFolder(), "remote");
  const storeDir = seedSessionStore("projA");
  const legacyDir = seedLegacyProjectDir("projA");
  expect(existsSync(storeDir)).toBe(true);
  expect(existsSync(legacyDir)).toBe(true);
  expect(h.get("projA")?.running).toBe(true);

  await h.forget("projA");

  expect(h.get("projA")).toBeNull(); // core stopped
  expect(existsSync(storeDir)).toBe(false); // sessions.json + dir gone
  expect(existsSync(legacyDir)).toBe(false); // legacy projects/<id>/ gone
  // The seen-catalog hint (projects.json) no longer lists the project.
  const projectsJson = join(abDir!, "agents", "projects.json");
  const seen = JSON.parse(readFileSync(projectsJson, "utf8"));
  expect(seen.projects.projA).toBeUndefined();
});

test("forget() leaves the machine-level mobile-access switch alone", async () => {
  const h = host!;
  await h.open("projA", tempFolder(), "local");
  await h.open("projB", tempFolder(), "local");
  seedSessionStore("projA");
  await h.handleMobileAccessVerb({ id: "t", type: "mobile-access:set", enabled: true });

  await h.forget("projA");

  // Deleting ONE project must never turn the machine off (or on) for every
  // other: the switch is machine-wide policy, forget() only edits the catalog.
  const get = (await h.handleMobileAccessVerb({ id: "g", type: "mobile-access:get" })) as any;
  expect(get.enabled).toBe(true);
  expect(h.buildProjectsAdvertisement().map((p) => p.projectId)).toEqual(["projB"]);
});

test("forget() is idempotent for an unknown/already-forgotten id", async () => {
  const h = host!;
  // Never opened, no store, no catalog entry — must resolve without throwing.
  await h.forget("ghost");
  expect(h.get("ghost")).toBeNull();
});
