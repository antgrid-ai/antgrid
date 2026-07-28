import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostServer } from "../src/host-server";

let prevAbDir: string | undefined;
let abDir: string;

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-phones-"));
  process.env.ANTGRID_DIR = abDir;
  // Seed a paired phone with one allowed project.
  const agents = join(abDir, "agents");
  mkdirSync(agents, { recursive: true });
  writeFileSync(
    join(agents, "paired-phones.json"),
    JSON.stringify({
      version: 1,
      phones: [
        {
          phonePubkey: "pk-1", phoneDeviceId: "ph-1", label: "iPhone",
          pairedAt: "2026-01-01T00:00:00.000Z", lastSeenAt: "2026-01-02T00:00:00.000Z",
          allowedProjects: ["proj-allowed"],
        },
        {
          phonePubkey: "pk-2", phoneDeviceId: "ph-2", label: "Android",
          pairedAt: "2026-01-01T00:00:00.000Z", lastSeenAt: "2026-01-02T00:00:00.000Z",
          allowedProjects: ["proj-allowed"],
        },
      ],
    }, null, 2),
  );
});

afterEach(() => {
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR; else process.env.ANTGRID_DIR = prevAbDir;
  rmSync(abDir, { recursive: true, force: true });
});

test("listPairedPhones returns the seeded phones with their allowlists", () => {
  const host = new HostServer({});
  const phones = host.listPairedPhones();
  expect(phones.length).toBe(2);
  expect(phones[0].phonePubkey).toBe("pk-1");
  expect(phones[0].allowedProjects).toEqual(["proj-allowed"]);
  expect(phones[1].phonePubkey).toBe("pk-2");
  expect(phones[1].allowedProjects).toEqual(["proj-allowed"]);
});

test("knownProjectsForHub unions seen catalog with warm cores", async () => {
  const host = new HostServer({});
  // No cores opened, no seen catalog yet → empty.
  expect(host.knownProjectsForHub()).toEqual([]);
});

test("phones:allow adds the project to the phone's allowlist", async () => {
  const host = new HostServer({});
  const res = await host.handlePhonesVerb({ id: "1", type: "phones:allow", phonePubkey: "pk-1", projectId: "proj-new" });
  expect(res.ok).toBe(true);
  const pk1 = host.listPairedPhones().find((p) => p.phonePubkey === "pk-1")!;
  expect(pk1.allowedProjects.sort()).toEqual(["proj-allowed", "proj-new"]);
});

test("phones:deny removes a project; unknown grant still returns ok", async () => {
  const host = new HostServer({});
  const res = await host.handlePhonesVerb({ id: "1", type: "phones:deny", phonePubkey: "pk-1", projectId: "proj-allowed" });
  expect(res.ok).toBe(true);
  const pk1 = host.listPairedPhones().find((p) => p.phonePubkey === "pk-1")!;
  expect(pk1.allowedProjects).toEqual([]);
});

test("phones:unpair removes the phone entirely", async () => {
  const host = new HostServer({});
  const res = await host.handlePhonesVerb({ id: "1", type: "phones:unpair", phonePubkey: "pk-1" });
  expect(res.ok).toBe(true);
  expect(host.listPairedPhones().length).toBe(1);
  expect(host.listPairedPhones()[0].phonePubkey).toBe("pk-2");
});

test("phones:list returns phones + knownProjects", async () => {
  const host = new HostServer({});
  const res: any = await host.handlePhonesVerb({ id: "9", type: "phones:list" });
  expect(res.ok).toBe(true);
  expect(res.type).toBe("phones:list");
  expect(res.phones.length).toBe(2);
  expect(res.phones.some((p: any) => p.phonePubkey === "pk-1")).toBe(true);
  expect(Array.isArray(res.knownProjects)).toBe(true);
});

test("mobile-access:enable-project stores default and grants every known phone", async () => {
  const host = new HostServer({});
  const res = await host.handleMobileAccessVerb({
    id: "m1",
    type: "mobile-access:enable-project",
    projectId: "proj-new",
  });
  expect(res.ok).toBe(true);

  const get: any = await host.handleMobileAccessVerb({ id: "m2", type: "mobile-access:get" });
  expect(get.projectIds).toEqual(["proj-new"]);

  const phones = host.listPairedPhones();
  const pk1 = phones.find((p) => p.phonePubkey === "pk-1")!;
  const pk2 = phones.find((p) => p.phonePubkey === "pk-2")!;
  // every phone in the store receives the new grant immediately — there is no
  // longer a second admitted-but-excluded phone class
  expect(pk1.allowedProjects.sort()).toEqual(["proj-allowed", "proj-new"]);
  expect(pk2.allowedProjects.sort()).toEqual(["proj-allowed", "proj-new"]);
});

test("mobile-access:disable-project clears default and revokes it from every phone", async () => {
  const host = new HostServer({});
  await host.handleMobileAccessVerb({
    id: "m1",
    type: "mobile-access:enable-project",
    projectId: "proj-allowed",
  });

  const res = await host.handleMobileAccessVerb({
    id: "m2",
    type: "mobile-access:disable-project",
    projectId: "proj-allowed",
  });
  expect(res.ok).toBe(true);

  const get: any = await host.handleMobileAccessVerb({ id: "m3", type: "mobile-access:get" });
  expect(get.projectIds).toEqual([]);

  const phones = host.listPairedPhones();
  const pk1 = phones.find((p) => p.phonePubkey === "pk-1")!;
  const pk2 = phones.find((p) => p.phonePubkey === "pk-2")!;
  expect(pk1.allowedProjects).toEqual([]);
  expect(pk2.allowedProjects).toEqual([]);
});

test("mobile-access:disable-project does not touch an unrelated explicit grant", async () => {
  const host = new HostServer({});
  await host.handlePhonesVerb({ id: "p1", type: "phones:allow", phonePubkey: "pk-2", projectId: "proj-other" });
  await host.handleMobileAccessVerb({ id: "m1", type: "mobile-access:enable-project", projectId: "proj-allowed" });

  await host.handleMobileAccessVerb({ id: "m2", type: "mobile-access:disable-project", projectId: "proj-allowed" });

  const pk2 = host.listPairedPhones().find((p) => p.phonePubkey === "pk-2")!;
  // disabling proj-allowed's default must not sweep a grant for a different project
  expect(pk2.allowedProjects).toEqual(["proj-other"]);
});

test("project:forget clears same-account default grant", async () => {
  const host = new HostServer({});
  await host.handleMobileAccessVerb({
    id: "m1",
    type: "mobile-access:enable-project",
    projectId: "proj-allowed",
  });

  await host.forget("proj-allowed");

  const get: any = await host.handleMobileAccessVerb({ id: "m2", type: "mobile-access:get" });
  expect(get.projectIds).toEqual([]);
  for (const phone of host.listPairedPhones()) {
    expect(phone.allowedProjects).toEqual([]);
  }
});
