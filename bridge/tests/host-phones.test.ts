import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostServer } from "../src/host-server";
import { loadRemoteAccessPolicy } from "../src/remote-access-policy";

let prevAbDir: string | undefined;
let abDir: string;

/** Write a v1 paired-phones.json. `allowedProjects` is the pre-machine-switch
 *  key: still accepted on disk, no longer authorization, and the input the
 *  mobile-access migration reads once. */
function seedPhones(rows: Array<{ pk: string; id: string; label: string; allowedProjects?: string[] }>) {
  const agents = join(abDir, "agents");
  mkdirSync(agents, { recursive: true });
  writeFileSync(
    join(agents, "paired-phones.json"),
    JSON.stringify({
      version: 1,
      phones: rows.map((r) => ({
        phonePubkey: r.pk, phoneDeviceId: r.id, label: r.label,
        pairedAt: "2026-01-01T00:00:00.000Z", lastSeenAt: "2026-01-02T00:00:00.000Z",
        ...(r.allowedProjects ? { allowedProjects: r.allowedProjects } : {}),
      })),
    }, null, 2),
  );
}

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-phones-"));
  process.env.ANTGRID_DIR = abDir;
  seedPhones([
    { pk: "pk-1", id: "ph-1", label: "iPhone" },
    { pk: "pk-2", id: "ph-2", label: "Android" },
  ]);
});

afterEach(() => {
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR; else process.env.ANTGRID_DIR = prevAbDir;
  rmSync(abDir, { recursive: true, force: true });
});

test("listPairedPhones returns the seeded identity rows", () => {
  const host = new HostServer({});
  const phones = host.listPairedPhones();
  expect(phones.length).toBe(2);
  expect(phones.map((p) => p.phonePubkey)).toEqual(["pk-1", "pk-2"]);
  expect(phones[0].label).toBe("iPhone");
  expect(phones[0].lastSeenAt).toBe("2026-01-02T00:00:00.000Z");
});

test("knownProjectsForHub unions seen catalog with warm cores", async () => {
  const host = new HostServer({});
  // No cores opened, no seen catalog yet → empty.
  expect(host.knownProjectsForHub()).toEqual([]);
});

test("phones:unpair removes the phone entirely", async () => {
  const host = new HostServer({});
  const res = await host.handlePhonesVerb({ id: "1", type: "phones:unpair", phonePubkey: "pk-1" });
  expect(res.ok).toBe(true);
  expect(host.listPairedPhones().length).toBe(1);
  expect(host.listPairedPhones()[0].phonePubkey).toBe("pk-2");
});

test("phones:unpair does not touch the machine switch (it is not a revocation)", async () => {
  const host = new HostServer({});
  await host.handleRemoteAccessVerb({ id: "m1", type: "mobile-access:set", enabled: true });
  await host.handlePhonesVerb({ id: "1", type: "phones:unpair", phonePubkey: "pk-1" });

  const get = await host.handleRemoteAccessVerb({ id: "m2", type: "mobile-access:get" });
  expect(get).toMatchObject({ ok: true, enabled: true });
});

test("phones:list returns phones + knownProjects", async () => {
  const host = new HostServer({});
  const res = await host.handlePhonesVerb({ id: "9", type: "phones:list" });
  expect(res.ok).toBe(true);
  expect(res).toMatchObject({ type: "phones:list" });
  const listed = res as Extract<typeof res, { type: "phones:list" }>;
  expect(listed.phones.length).toBe(2);
  expect(listed.phones.some((p) => p.phonePubkey === "pk-1")).toBe(true);
  expect(Array.isArray(listed.knownProjects)).toBe(true);
});

test("mobile-access:get is off on a machine that never granted anything", async () => {
  const host = new HostServer({});
  const get = await host.handleRemoteAccessVerb({ id: "m1", type: "mobile-access:get" });
  expect(get).toMatchObject({ ok: true, enabled: false });
});

test("mobile-access:set flips the machine switch and persists it", async () => {
  const host = new HostServer({});
  const on = await host.handleRemoteAccessVerb({ id: "m1", type: "mobile-access:set", enabled: true });
  expect(on).toMatchObject({ ok: true, type: "mobile-access:set", enabled: true });
  expect(await host.handleRemoteAccessVerb({ id: "m2", type: "mobile-access:get" })).toMatchObject({ enabled: true });
  // A fresh load — i.e. the next host start — sees the same answer.
  expect(loadRemoteAccessPolicy(abDir).isEnabled()).toBe(true);

  const off = await host.handleRemoteAccessVerb({ id: "m3", type: "mobile-access:set", enabled: false });
  expect(off).toMatchObject({ ok: true, enabled: false });
  expect(loadRemoteAccessPolicy(abDir).isEnabled()).toBe(false);
});

test("mobile-access:set is idempotent — re-setting the same value still answers the state", async () => {
  const host = new HostServer({});
  await host.handleRemoteAccessVerb({ id: "m1", type: "mobile-access:set", enabled: true });
  const again = await host.handleRemoteAccessVerb({ id: "m2", type: "mobile-access:set", enabled: true });
  expect(again).toMatchObject({ ok: true, enabled: true });
});

test("a v1 allowlist grant on disk migrates the machine switch on", async () => {
  // The `antgrid phones allow` user must not silently lose mobile access on the
  // first start of a build that no longer has an allowlist.
  seedPhones([
    { pk: "pk-1", id: "ph-1", label: "iPhone", allowedProjects: ["proj-granted"] },
    { pk: "pk-2", id: "ph-2", label: "Android", allowedProjects: [] },
  ]);
  const host = new HostServer({});
  expect(await host.handleRemoteAccessVerb({ id: "m1", type: "mobile-access:get" })).toMatchObject({ enabled: true });
});

test("project:forget does not change the machine switch", async () => {
  const host = new HostServer({});
  await host.handleRemoteAccessVerb({ id: "m1", type: "mobile-access:set", enabled: true });

  await host.forget("proj-gone");

  // Forgetting one project is a catalog edit; mobile access is machine-level.
  expect(await host.handleRemoteAccessVerb({ id: "m2", type: "mobile-access:get" })).toMatchObject({ enabled: true });
});
