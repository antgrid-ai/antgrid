import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostServer } from "../src/host-server";
import { computeProjectId } from "../src/project-id";
import type { AbMessage } from "../src/protocol";
import { MessageBus, type Channel } from "../src/message-bus";

let host: HostServer | null = null;
const folders: string[] = [];

let prevAbDir: string | undefined;
let abDir: string | undefined;

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-abdir-"));
  process.env.ANTGRID_DIR = abDir;
});

// On Windows the core's file watcher can hold a transient handle on the temp
// folder for a few ms after shutdown() resolves, making rmSync throw EBUSY.
// Retry briefly; never let teardown fail the assertions above (mirrors host-server.test.ts).
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

/** Flip the machine switch through its only mutation path, the loopback verb. */
async function setMobileAccess(h: HostServer, enabled: boolean): Promise<void> {
  await h.handleRemoteAccessVerb({ id: "t", type: "mobile-access:set", enabled });
}

// Regression (Phase C smoke, 2026-07-27): after a bridge restart the host
// re-opens projects on its own, AFTER the handshake advert has already gone out
// — so the phone's catalog stayed a snapshot of a host with nothing open, and
// nothing ever told it the project was back. handleControlPlaneVerb only
// re-advertises for a phone's own project:start, which a phone that believes it
// is still bound never sends.
test("re-advertises agent:projects when a project is opened without a phone asking (restart / desktop-side open)", async () => {
  host = new HostServer({});

  const f = tempFolder();
  const id = computeProjectId(f);
  await setMobileAccess(host, true);

  const bus = new MessageBus();
  const published: { msg: AbMessage; channel: Channel }[] = [];
  bus.subscribe({ deliver: (msg, channel) => published.push({ msg, channel }) });
  // Seed the control-plane wiring with the pre-open catalog — the empty advert
  // a just-restarted host sends at handshake time.
  host.readvertiseForTest(bus, "pk1");
  const seed = published.filter((p) => p.msg.type === "agent:projects").pop()!.msg as AbMessage & {
    projects: { projectId: string }[];
  };
  expect(seed.projects.find((p) => p.projectId === id)).toBeUndefined();
  published.length = 0;

  await host.open(id, f, "local");

  const projectsMsgs = published.filter((p) => p.msg.type === "agent:projects");
  expect(projectsMsgs.length).toBeGreaterThan(0);
  const last = projectsMsgs[projectsMsgs.length - 1]!.msg as AbMessage & {
    projects: { projectId: string; running: boolean }[];
  };
  expect(last.projects.find((p) => p.projectId === id)).toBeDefined();
});

test("re-advertises agent:projects on core eviction (evicted flips to running:false / absent)", async () => {
  host = new HostServer({ warmCap: 1 });

  const fA = tempFolder();
  const idA = computeProjectId(fA);
  await host.open(idA, fA, "local");

  const fB = tempFolder();
  const idB = computeProjectId(fB);

  await setMobileAccess(host, true);

  // Real MessageBus + a TransportSubscriber: publish delivers synchronously to
  // subscribers in-loop, so anything emitted during the awaited open() below is
  // captured by the time we assert. The seed advert ([idA]) and the eviction
  // advert ([idB], idA dropped) differ in membership, so the bus payload-dedup
  // keeps the eviction frame after we clear the seed. (running is uniformly false
  // here — these are warm-but-unpromoted local cores, never relay-admitted.)
  const bus = new MessageBus();
  const published: { msg: AbMessage; channel: Channel }[] = [];
  bus.subscribe({ deliver: (msg, channel) => published.push({ msg, channel }) });
  host.readvertiseForTest(bus, "pk1");
  published.length = 0; // ignore the seed advert; only the eviction one matters

  await host.open(idB, fB, "local"); // cores.size = 2 > cap 1 → evicts idA

  const projectsMsgs = published.filter((p) => p.msg.type === "agent:projects");
  expect(projectsMsgs.length).toBeGreaterThan(0);

  const last = projectsMsgs[projectsMsgs.length - 1]!.msg as AbMessage & {
    projects: { projectId: string; running: boolean }[];
  };
  const entryA = last.projects.find((p) => p.projectId === idA);
  // Evicted project: absent (dropped from seenProjects) OR present-but-not-running.
  expect(entryA === undefined || entryA.running === false).toBe(true);

  // The surviving core idB is LISTED in the re-advert (the point of the test);
  // its running flag is false because a warm-but-unpromoted local core has no
  // relay slot (running now means relay-admitted, not warm).
  const entryB = last.projects.find((p) => p.projectId === idB);
  expect(entryB).toBeDefined();
  expect(entryB?.running).toBe(false);
});
