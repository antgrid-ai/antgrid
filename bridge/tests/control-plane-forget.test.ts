import { test, expect, beforeEach, afterEach } from "bun:test";
import { existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostServer, type HostRemoteConfig, type RemoteRuntime } from "../src/host-server";
import { computeProjectId } from "../src/project-id";

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

// Project ids are host-resolved: `open` rejects any id that is not
// computeProjectId(folder) (PROJECT_ID_MISMATCH). These helpers keep the
// readable "projX" aliases while using the real id on the wire.
const projectIds = new Map<string, string>();
function proj(alias: string): string {
  const id = projectIds.get(alias);
  if (!id) throw new Error(`project alias not opened: ${alias}`);
  return id;
}
async function openAs(h: HostServer, alias: string, mode: "local" | "remote"): Promise<OpenResultLike> {
  const folder = tempFolder();
  const projectId = computeProjectId(folder);
  projectIds.set(alias, projectId);
  return h.open(projectId, folder, mode);
}
type OpenResultLike = Awaited<ReturnType<HostServer["open"]>>;

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
  await openAs(h, "projA", "remote");
  const storeDir = seedSessionStore(proj("projA"));
  const legacyDir = seedLegacyProjectDir(proj("projA"));
  expect(existsSync(storeDir)).toBe(true);
  expect(existsSync(legacyDir)).toBe(true);
  expect(h.get(proj("projA"))?.running).toBe(true);

  await h.forget(proj("projA"));

  expect(h.get(proj("projA"))).toBeNull(); // core stopped
  expect(existsSync(storeDir)).toBe(false); // sessions.json + dir gone
  expect(existsSync(legacyDir)).toBe(false); // legacy projects/<id>/ gone
  // The seen-catalog hint (projects.json) no longer lists the project.
  const projectsJson = join(abDir!, "agents", "projects.json");
  const seen = JSON.parse(readFileSync(projectsJson, "utf8"));
  expect(seen.projects[proj("projA")]).toBeUndefined();
});

test("forget() leaves the machine-level mobile-access switch alone", async () => {
  const h = host!;
  await openAs(h, "projA", "local");
  await openAs(h, "projB", "local");
  seedSessionStore(proj("projA"));
  await h.handleRemoteAccessVerb({ id: "t", type: "mobile-access:set", enabled: true });

  await h.forget(proj("projA"));

  // Deleting ONE project must never turn the machine off (or on) for every
  // other: the switch is machine-wide policy, forget() only edits the catalog.
  const get = (await h.handleRemoteAccessVerb({ id: "g", type: "mobile-access:get" })) as any;
  expect(get.enabled).toBe(true);
  expect(h.buildProjectsAdvertisement().map((p) => p.projectId)).toEqual([proj("projB")]);
});

test("forget() is idempotent for an unknown/already-forgotten id", async () => {
  const h = host!;
  // Never opened, no store, no catalog entry — must resolve without throwing.
  await h.forget("ghost");
  expect(h.get("ghost")).toBeNull();
});
