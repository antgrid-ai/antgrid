import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostServer } from "../src/host-server";
import { computeProjectId } from "../src/project-id";
import { MessageBus } from "../src/message-bus";
import { createMessage, type AbMessage } from "../src/protocol";

let host: HostServer | null = null;
const folders: string[] = [];

// Isolate ANTGRID_DIR so paired-phones.json / projects.json land in a temp dir,
// never the real ~/.antgrid (mirrors host-server.test.ts).
let prevAbDir: string | undefined;
let abDir: string | undefined;

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-abdir-"));
  process.env.ANTGRID_DIR = abDir;
});

async function rmWithRetry(path: string): Promise<void> {
  for (let i = 0; i < 20; i++) {
    try { rmSync(path, { recursive: true, force: true }); return; }
    catch { await new Promise((r) => setTimeout(r, 25)); }
  }
}

afterEach(async () => {
  await host?.shutdown();
  host = null;
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR; else process.env.ANTGRID_DIR = prevAbDir;
  if (abDir) rmSync(abDir, { recursive: true, force: true });
  while (folders.length) await rmWithRetry(folders.pop()!);
});

function tempFolder(): string {
  // Canonical: the host catalogs the realpath.
  const f = realpathSync.native(mkdtempSync(join(tmpdir(), "antgrid-host-")));
  folders.push(f);
  return f;
}

/** Open a fresh temp project under the id the host resolves for it — `open`
 *  rejects any other id (PROJECT_ID_MISMATCH). */
async function openTemp(h: HostServer, mode: "local" | "remote" = "local"): Promise<string> {
  const folder = tempFolder();
  const projectId = computeProjectId(folder);
  await h.open(projectId, folder, mode);
  return projectId;
}

/** Flip the machine switch through the loopback verb — its only mutation path
 *  (the policy store has no watcher, so writing the file behind a live host is
 *  never observed). */
async function setMobileAccess(h: HostServer, enabled: boolean): Promise<void> {
  await h.handleRemoteAccessVerb({ id: "t", type: "mobile-access:set", enabled });
}

test("advertises the machine's whole catalog; running = relay-admitted", async () => {
  host = new HostServer({});
  const projA = await openTemp(host);   // warm + seen
  const projB = await openTemp(host);
  const projC = await openTemp(host);
  await host.stop(projB);                            // now known-but-stopped (in seenProjects, not in cores)
  await setMobileAccess(host, true);

  const adv = host.buildProjectsAdvertisement();
  expect(adv.map((p) => p.projectId).sort()).toEqual([projA, projB, projC].sort());
  // running now means DIALABLE (relay-admitted), not merely warm. projA is warm
  // on the host but was never promoted → no relay slot → running:false; projB is
  // stopped → also false. (A promoted+registered core reading running:true is
  // covered in host-promotion.test.ts.) Both are still LISTED — the visibility
  // filter includes warm cores; only the dialable flag differs.
  expect(adv.find((p) => p.projectId === projA)?.running).toBe(false);
  expect(adv.find((p) => p.projectId === projB)?.running).toBe(false);
});

test("known-but-stopped project carries its catalog label + path", async () => {
  host = new HostServer({});
  const folderB = tempFolder();
  const projB = computeProjectId(folderB);
  await host.open(projB, folderB, "local");
  await host.stop(projB);
  await setMobileAccess(host, true);

  const adv = host.buildProjectsAdvertisement();
  const b = adv.find((p) => p.projectId === projB);
  expect(b).toBeDefined();
  expect(b?.running).toBe(false);
  expect(b?.path).toBe(folderB);
  expect(b?.label).toBe(folderB.split(/[\\/]/).pop());
});

test("advertised projects carry lastActiveAt when known", async () => {
  host = new HostServer({});
  const before = new Date().toISOString();
  const projA = await openTemp(host);   // stamps lastActiveAt on startCore
  await setMobileAccess(host, true);

  const adv = host.buildProjectsAdvertisement();
  const a = adv.find((p) => p.projectId === projA);
  expect(a?.lastActiveAt).toBeDefined();
  // ISO string at or after the moment we captured before opening.
  expect(a!.lastActiveAt! >= before).toBe(true);
});

test("warm core advertises runningSessions; a stopped project omits it (like status)", async () => {
  host = new HostServer({});
  const projA = await openTemp(host);
  const projB = await openTemp(host);
  await host.stop(projB);
  await setMobileAccess(host, true);

  const adv = host.buildProjectsAdvertisement();
  // Warm, no sessions started yet → an explicit 0 (the app's re-peek trigger
  // needs the baseline to detect the first session starting on the desktop).
  expect(adv.find((p) => p.projectId === projA)?.runningSessions).toBe(0);
  // Cold → omitted, matching the status field's warm-only contract.
  expect(adv.find((p) => p.projectId === projB)?.runningSessions).toBeUndefined();
});

test("the advert is the full catalog when enabled and empty when disabled", async () => {
  host = new HostServer({});
  const projA = await openTemp(host);
  const projB = await openTemp(host);

  // Default for a fresh machine is off — a new install must not be reachable.
  expect(host.buildProjectsAdvertisement()).toEqual([]);

  await setMobileAccess(host, true);
  expect(host.buildProjectsAdvertisement().map((p) => p.projectId).sort()).toEqual([projA, projB].sort());

  await setMobileAccess(host, false);
  expect(host.buildProjectsAdvertisement()).toEqual([]);
});

test("mobile-access:set re-advertises to the connected control-plane phone", async () => {
  host = new HostServer({});
  const projA = await openTemp(host);

  const bus = new MessageBus();
  const seen: AbMessage[] = [];
  bus.subscribe({ deliver: (m) => seen.push(m) });

  // With the machine switch off, a re-advertise yields an empty project list,
  // and the machine-level flag says WHY — false, not merely absent (a fresh
  // machine defaults off).
  host.readvertiseForTest(bus);
  const first = seen.filter((m) => m.type === "agent:projects").at(-1) as any;
  expect(first?.projects).toEqual([]);
  expect(first?.remoteAccessEnabled).toBe(false);

  // The desktop turns mobile access on. handleRemoteAccessVerb re-advertises
  // itself, so the connected phone must see projA WITHOUT reconnecting.
  await setMobileAccess(host, true);

  const last = seen.filter((m) => m.type === "agent:projects").at(-1) as any;
  expect(last.projects.map((p: any) => p.projectId)).toEqual([projA]);
  expect(last.remoteAccessEnabled).toBe(true);

  // Off again: the same advert that empties the catalog flips the flag, so the
  // phone can render "remote access is off" instead of a neutral empty machine.
  await setMobileAccess(host, false);

  const off = seen.filter((m) => m.type === "agent:projects").at(-1) as any;
  expect(off.projects).toEqual([]);
  expect(off.remoteAccessEnabled).toBe(false);
});

test("state.snapshot recompute stamps remoteAccessEnabled on the fresh advert", async () => {
  host = new HostServer({});
  await openTemp(host);
  await setMobileAccess(host, true);

  const bus = new MessageBus();
  const seen: AbMessage[] = [];
  bus.subscribe({ deliver: (m) => seen.push(m) });

  // Welcome-replay path: the snapshot RPC re-publishes agent:projects before
  // answering, so the replayed frame must carry the flag too — a phone whose
  // only advert comes from replay would otherwise never learn the switch state.
  host.dispatchControlPlaneInbound(
    createMessage("request", { requestId: "r1", method: "state.snapshot", params: { types: ["*"] } }) as any,
    "control",
    bus,
  );

  const advert = seen.filter((m) => m.type === "agent:projects").at(-1) as any;
  expect(advert).toBeDefined();
  expect(advert.remoteAccessEnabled).toBe(true);
  expect(advert.projects.length).toBe(1);
});

async function git(cwd: string, args: string[]): Promise<void> {
  const proc = Bun.spawn(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  await proc.exited;
}

async function waitUntil(cond: () => boolean, timeoutMs = 5000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!cond()) {
    if (Date.now() > deadline) throw new Error("condition not met in time");
    await new Promise((r) => setTimeout(r, 20));
  }
}

test("the advert carries each project's normalized git remote, re-advertised once the probe lands", async () => {
  host = new HostServer({});
  await setMobileAccess(host, true);
  const bus = new MessageBus();
  const seen: AbMessage[] = [];
  bus.subscribe({ deliver: (m) => seen.push(m) });
  host.readvertiseForTest(bus);

  const repo = tempFolder();
  await git(repo, ["init", "-b", "main"]);
  await git(repo, ["remote", "add", "origin", "https://user:token@github.com/Owner/Repo.git"]);
  const repoId = computeProjectId(repo);
  await host.open(repoId, repo, "local");
  const plainId = await openTemp(host);

  // The core-start advert goes out before git answers, so the key must arrive
  // on a LATER advert rather than only on the next unrelated one.
  const lastFor = (id: string) =>
    (seen.filter((m) => m.type === "agent:projects").at(-1) as any)?.projects.find((p: any) => p.projectId === id);
  await waitUntil(() => lastFor(repoId)?.gitRemote !== undefined && lastFor(plainId)?.gitRemote !== undefined);

  expect(lastFor(repoId).gitRemote).toBe("github.com/owner/repo");
  // Probed with no remote is null, never absent: absent means "not probed yet".
  expect(lastFor(plainId).gitRemote).toBeNull();
  expect(host.list().find((p) => p.projectId === repoId)?.gitRemote).toBe("github.com/owner/repo");
});
