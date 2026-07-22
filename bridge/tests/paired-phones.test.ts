import { describe, it, expect, spyOn } from "bun:test";
import { mkdtempSync, rmSync, statSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadPairedPhones } from "../src/paired-phones";
import { logger } from "../src/logger";

/** Write a paired-phones.json with the given raw phone rows and return the abDir. */
function seedFile(phones: unknown[]): string {
  const dir = mkdtempSync(join(tmpdir(), "antgrid-pp-"));
  const agents = join(dir, "agents");
  mkdirSync(agents, { recursive: true });
  writeFileSync(join(agents, "paired-phones.json"), JSON.stringify({ version: 1, phones }, null, 2));
  return dir;
}

function tempAbDir() {
  return mkdtempSync(join(tmpdir(), "antgrid-pp-"));
}

describe("paired-phones store (machine-level)", () => {
  it("returns empty list when file missing", () => {
    const dir = tempAbDir();
    const store = loadPairedPhones(dir);
    expect(store.list()).toEqual([]);
    rmSync(dir, { recursive: true });
  });

  it("upsert defaults allowedProjects to [] and round-trips through disk", () => {
    const dir = tempAbDir();
    const store = loadPairedPhones(dir);
    store.upsert({
      phonePubkey: "pk1", phoneDeviceId: "d1", label: "A",
      pairedAt: "2026-01-01T00:00:00Z", lastSeenAt: "2026-01-01T00:00:00Z",
      admission: "pair-code",
    });
    expect(store.get("pk1")?.allowedProjects).toEqual([]);
    const fresh = loadPairedPhones(dir);
    expect(fresh.list().length).toBe(1);
    expect(fresh.get("pk1")?.admission).toBe("pair-code");
    expect(fresh.get("pk1")?.allowedProjects).toEqual([]);
    rmSync(dir, { recursive: true });
  });

  it("upsert requires and round-trips admission", () => {
    const dir = tempAbDir();
    const store = loadPairedPhones(dir);
    store.upsert({
      phonePubkey: "pk-admit",
      phoneDeviceId: "d-admit",
      pairedAt: "x",
      lastSeenAt: "x",
      admission: "same-account",
      allowedProjects: ["projA"],
    });

    const fresh = loadPairedPhones(dir);
    expect(fresh.get("pk-admit")?.admission).toBe("same-account");
    expect(fresh.get("pk-admit")?.allowedProjects).toEqual(["projA"]);
    rmSync(dir, { recursive: true });
  });

  it("file lives at agents/paired-phones.json (no projectId segment)", () => {
    const dir = tempAbDir();
    loadPairedPhones(dir).upsert({
      phonePubkey: "pk1", phoneDeviceId: "d1",
      pairedAt: "2026-01-01T00:00:00Z", lastSeenAt: "2026-01-01T00:00:00Z",
      admission: "pair-code",
    });
    const path = join(dir, "agents", "paired-phones.json");
    expect(statSync(path).isFile()).toBe(true);
    rmSync(dir, { recursive: true });
  });

  it("recovers from corrupt file as empty list", () => {
    const dir = tempAbDir();
    const agents = join(dir, "agents");
    mkdirSync(agents, { recursive: true });
    writeFileSync(join(agents, "paired-phones.json"), "{not json");
    expect(loadPairedPhones(dir).list()).toEqual([]);
    rmSync(dir, { recursive: true });
  });

  it("remove persists to disk (fresh load reflects deletion)", () => {
    const dir = tempAbDir();
    const store = loadPairedPhones(dir);
    store.upsert({
      phonePubkey: "pk1", phoneDeviceId: "d1",
      pairedAt: "2026-01-01T00:00:00Z", lastSeenAt: "2026-01-01T00:00:00Z",
      admission: "pair-code",
    });
    store.remove("pk1");
    expect(loadPairedPhones(dir).list()).toEqual([]);
    rmSync(dir, { recursive: true });
  });
});

describe("paired-phones allowlist helpers", () => {
  function seeded() {
    const dir = tempAbDir();
    const store = loadPairedPhones(dir);
    store.upsert({
      phonePubkey: "pk1", phoneDeviceId: "d1",
      pairedAt: "2026-01-01T00:00:00Z", lastSeenAt: "2026-01-01T00:00:00Z",
      admission: "pair-code",
      allowedProjects: [],
    });
    return { dir, store };
  }

  it("isAllowed is false until a project is allowed, true after", () => {
    const { dir, store } = seeded();
    expect(store.isAllowed("pk1", "projA")).toBe(false);
    store.allowProject("pk1", "projA");
    expect(store.isAllowed("pk1", "projA")).toBe(true);
    rmSync(dir, { recursive: true });
  });

  it("allowProject is idempotent (no duplicate entries)", () => {
    const { dir, store } = seeded();
    store.allowProject("pk1", "projA");
    store.allowProject("pk1", "projA");
    expect(store.get("pk1")?.allowedProjects).toEqual(["projA"]);
    rmSync(dir, { recursive: true });
  });

  it("denyProject removes the project, returns true, and persists", () => {
    const { dir, store } = seeded();
    store.allowProject("pk1", "projA");
    expect(store.denyProject("pk1", "projA")).toBe(true);
    expect(store.isAllowed("pk1", "projA")).toBe(false);
    expect(loadPairedPhones(dir).isAllowed("pk1", "projA")).toBe(false);
    rmSync(dir, { recursive: true });
  });

  it("denyProject returns false when the grant or phone is absent (no-op)", () => {
    const { dir, store } = seeded();
    expect(store.denyProject("pk1", "projA")).toBe(false); // never granted
    expect(store.denyProject("nope", "projA")).toBe(false); // unknown phone
    rmSync(dir, { recursive: true });
  });

  it("isAllowed is false for an unknown phone", () => {
    const { dir, store } = seeded();
    expect(store.isAllowed("nope", "projA")).toBe(false);
    rmSync(dir, { recursive: true });
  });
});

describe("paired-phones same-account batch grants", () => {
  function twoPhones() {
    const dir = seedFile([
      { phonePubkey: "sa", phoneDeviceId: "d-sa", pairedAt: "x", lastSeenAt: "x", admission: "same-account", allowedProjects: [] },
      { phonePubkey: "pc", phoneDeviceId: "d-pc", pairedAt: "x", lastSeenAt: "x", admission: "pair-code", allowedProjects: ["projA"] },
    ]);
    return { dir, store: loadPairedPhones(dir) };
  }

  it("allowProjectForSameAccount grants same-account phones only and persists", () => {
    const { dir, store } = twoPhones();
    expect(store.allowProjectForSameAccount("projB")).toBe(true);
    const fresh = loadPairedPhones(dir);
    expect(fresh.get("sa")?.allowedProjects).toEqual(["projB"]);
    // pair-code phone untouched by the same-account default
    expect(fresh.get("pc")?.allowedProjects).toEqual(["projA"]);
    // idempotent: re-granting reports no change
    expect(store.allowProjectForSameAccount("projB")).toBe(false);
    rmSync(dir, { recursive: true });
  });

  it("denyProjectForSameAccount revokes same-account phones but keeps pair-code grants", () => {
    const { dir, store } = twoPhones();
    store.allowProjectForSameAccount("projA"); // sa now has projA; pc already had it
    expect(store.denyProjectForSameAccount("projA")).toBe(true);
    const fresh = loadPairedPhones(dir);
    expect(fresh.get("sa")?.allowedProjects).toEqual([]);
    // pair-code phone's explicit grant survives the default toggle
    expect(fresh.get("pc")?.allowedProjects).toEqual(["projA"]);
    // no same-account grant left → no-op
    expect(store.denyProjectForSameAccount("projA")).toBe(false);
    rmSync(dir, { recursive: true });
  });
});

describe("paired-phones legacy-row migration", () => {
  it("drops rows missing admission and warns once", () => {
    const dir = seedFile([
      { phonePubkey: "legacy", phoneDeviceId: "d-old", pairedAt: "x", lastSeenAt: "x", allowedProjects: ["projA"] },
      { phonePubkey: "modern", phoneDeviceId: "d-new", pairedAt: "x", lastSeenAt: "x", admission: "pair-code", allowedProjects: [] },
    ]);
    const warn = spyOn(logger, "warn");
    const store = loadPairedPhones(dir);
    expect(store.list().map((p) => p.phonePubkey)).toEqual(["modern"]);
    expect(warn).toHaveBeenCalledTimes(1);
    warn.mockRestore();
    rmSync(dir, { recursive: true });
  });

  it("does not warn when every row has a known admission", () => {
    const dir = seedFile([
      { phonePubkey: "modern", phoneDeviceId: "d-new", pairedAt: "x", lastSeenAt: "x", admission: "same-account", allowedProjects: [] },
    ]);
    const warn = spyOn(logger, "warn");
    loadPairedPhones(dir);
    expect(warn).not.toHaveBeenCalled();
    warn.mockRestore();
    rmSync(dir, { recursive: true });
  });
});
