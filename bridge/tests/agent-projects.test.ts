import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostServer } from "../src/host-server";
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

test("advertises allowed ∩ catalog, excludes non-allowed; running = relay-admitted", async () => {
  host = new HostServer({});
  await host.open("projA", tempFolder(), "local");   // warm + seen
  await host.open("projB", tempFolder(), "local");
  await host.open("projC", tempFolder(), "local");   // warm + seen, but NOT allowed
  await host.stop("projB");                            // now known-but-stopped (in seenProjects, not in cores)

  host.pairedPhones.upsert({ phonePubkey: "pk1", phoneDeviceId: "d1",
    pairedAt: "x", lastSeenAt: "x", admission: "pair-code", allowedProjects: ["projA", "projB"] });

  const adv = host.buildProjectsAdvertisement("pk1");
  expect(adv.map((p) => p.projectId).sort()).toEqual(["projA", "projB"]);
  // running now means DIALABLE (relay-admitted), not merely warm. projA is warm
  // on the host but was never promoted → no relay slot → running:false; projB is
  // stopped → also false. (A promoted+registered core reading running:true is
  // covered in host-promotion.test.ts.) Both are still LISTED — the visibility
  // filter includes warm cores; only the dialable flag differs.
  expect(adv.find((p) => p.projectId === "projA")?.running).toBe(false);
  expect(adv.find((p) => p.projectId === "projB")?.running).toBe(false);
  // projC is warm+seen but NOT allowed → excluded
  expect(adv.find((p) => p.projectId === "projC")).toBeUndefined();
});

test("known-but-stopped project carries its catalog label + path", async () => {
  host = new HostServer({});
  const folderB = tempFolder();
  await host.open("projB", folderB, "local");
  await host.stop("projB");

  host.pairedPhones.upsert({ phonePubkey: "pk1", phoneDeviceId: "d1",
    pairedAt: "x", lastSeenAt: "x", admission: "pair-code", allowedProjects: ["projB"] });

  const adv = host.buildProjectsAdvertisement("pk1");
  const b = adv.find((p) => p.projectId === "projB");
  expect(b).toBeDefined();
  expect(b?.running).toBe(false);
  expect(b?.path).toBe(folderB);
  expect(b?.label).toBe(folderB.split(/[\\/]/).pop());
});

test("advertised projects carry lastActiveAt when known", async () => {
  host = new HostServer({});
  const before = new Date().toISOString();
  await host.open("projA", tempFolder(), "local");   // stamps lastActiveAt on startCore

  host.pairedPhones.upsert({ phonePubkey: "pk1", phoneDeviceId: "d1",
    pairedAt: "x", lastSeenAt: "x", admission: "pair-code", allowedProjects: ["projA"] });

  const adv = host.buildProjectsAdvertisement("pk1");
  const a = adv.find((p) => p.projectId === "projA");
  expect(a?.lastActiveAt).toBeDefined();
  // ISO string at or after the moment we captured before opening.
  expect(a!.lastActiveAt! >= before).toBe(true);
});

test("phone with empty allowlist gets an empty advertisement", async () => {
  host = new HostServer({});
  await host.open("projA", tempFolder(), "local");
  host.pairedPhones.upsert({ phonePubkey: "pk2", phoneDeviceId: "d2",
    pairedAt: "x", lastSeenAt: "x", admission: "pair-code", allowedProjects: [] });
  expect(host.buildProjectsAdvertisement("pk2")).toEqual([]);
});

test("unknown phone gets an empty advertisement", async () => {
  host = new HostServer({});
  await host.open("projA", tempFolder(), "local");
  expect(host.buildProjectsAdvertisement("nope")).toEqual([]);
});

test("allowlist change re-advertises to the connected control-plane phone", async () => {
  host = new HostServer({});
  await host.open("projA", tempFolder(), "local");
  host.pairedPhones.upsert({ phonePubkey: "pk1", phoneDeviceId: "d1",
    pairedAt: "x", lastSeenAt: "x", admission: "pair-code", allowedProjects: [] }); // connected, nothing allowed yet

  const bus = new MessageBus();
  const seen: AbMessage[] = [];
  bus.subscribe({ deliver: (m) => seen.push(m) });

  // Before allowing, a re-advertise yields an empty project list.
  host.readvertiseForTest(bus, "pk1");
  const first = seen.filter((m) => m.type === "agent:projects").at(-1) as any;
  expect(first?.projects).toEqual([]);

  // Operator allows projA (as `antgrid phones allow` would). The watch callback
  // fires readvertiseToControlPlane; the connected phone must now see projA
  // WITHOUT reconnecting.
  host.pairedPhones.allowProject("pk1", "projA");
  host.readvertiseForTest(bus, "pk1");

  const last = seen.filter((m) => m.type === "agent:projects").at(-1) as any;
  expect(last.projects.map((p: any) => p.projectId)).toEqual(["projA"]);
});
