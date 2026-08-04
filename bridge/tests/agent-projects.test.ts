import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostServer } from "../src/host-server";
import { computeProjectId } from "../src/project-id";
import { MessageBus } from "../src/message-bus";
import type { AbMessage } from "../src/protocol";

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
  const f = mkdtempSync(join(tmpdir(), "antgrid-host-"));
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

  // With the machine switch off, a re-advertise yields an empty project list.
  host.readvertiseForTest(bus, "pk1");
  const first = seen.filter((m) => m.type === "agent:projects").at(-1) as any;
  expect(first?.projects).toEqual([]);

  // The desktop turns mobile access on. handleRemoteAccessVerb re-advertises
  // itself, so the connected phone must see projA WITHOUT reconnecting.
  await setMobileAccess(host, true);

  const last = seen.filter((m) => m.type === "agent:projects").at(-1) as any;
  expect(last.projects.map((p: any) => p.projectId)).toEqual([projA]);
});
