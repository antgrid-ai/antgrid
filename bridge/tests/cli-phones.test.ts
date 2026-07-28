import { describe, it, expect, spyOn } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadPairedPhones } from "../src/paired-phones";
import { phonesList, phonesAllow, phonesDeny, phonesRemove } from "../src/cli/phones";

function seeded() {
  const dir = mkdtempSync(join(tmpdir(), "antgrid-cli-"));
  const store = loadPairedPhones(dir);
  store.upsert({
    phonePubkey: "pk1", phoneDeviceId: "d1", label: "Pixel",
    pairedAt: "2026-01-01T00:00:00Z", lastSeenAt: "2026-01-01T00:00:00Z",
    allowedProjects: [],
  });
  return { dir, store };
}

const catalog = {
  resolve(pathOrLabel: string): string | null {
    if (pathOrLabel === "projA" || pathOrLabel === "/work/a" || pathOrLabel === "a") return "projA";
    return null;
  },
};

describe("antgrid phones CLI", () => {
  it("allow resolves a label to projectId and writes the allowlist", async () => {
    const { dir, store } = seeded();
    const code = await phonesAllow(store, catalog, "a", "pk1");
    expect(code).toBe(0);
    expect(store.isAllowed("pk1", "projA")).toBe(true);
    rmSync(dir, { recursive: true });
  });

  it("allow fails closed on an unknown project (no write, non-zero exit)", async () => {
    const { dir, store } = seeded();
    const code = await phonesAllow(store, catalog, "ghost", "pk1");
    expect(code).not.toBe(0);
    expect(store.get("pk1")?.allowedProjects).toEqual([]);
    rmSync(dir, { recursive: true });
  });

  it("deny removes a previously-allowed project", async () => {
    const { dir, store } = seeded();
    await phonesAllow(store, catalog, "a", "pk1");
    const code = await phonesDeny(store, catalog, "projA", "pk1");
    expect(code).toBe(0);
    expect(store.isAllowed("pk1", "projA")).toBe(false);
    rmSync(dir, { recursive: true });
  });

  it("deny resolves a path/label the same way allow did", async () => {
    const { dir, store } = seeded();
    // Grant by label, revoke by a DIFFERENT alias for the same project.
    await phonesAllow(store, catalog, "a", "pk1");
    expect(store.isAllowed("pk1", "projA")).toBe(true);
    const code = await phonesDeny(store, catalog, "/work/a", "pk1");
    expect(code).toBe(0);
    expect(store.isAllowed("pk1", "projA")).toBe(false);
    rmSync(dir, { recursive: true });
  });

  it("deny reports no-change (non-zero exit) when the project was not allowed", async () => {
    const { dir, store } = seeded();
    // Nothing granted → deny must NOT report success.
    const code = await phonesDeny(store, catalog, "projA", "pk1");
    expect(code).not.toBe(0);
    expect(store.isAllowed("pk1", "projA")).toBe(false);
    rmSync(dir, { recursive: true });
  });

  it("deny fails closed on an unknown project ref (nothing revoked)", async () => {
    const { dir, store } = seeded();
    await phonesAllow(store, catalog, "a", "pk1");
    const code = await phonesDeny(store, catalog, "ghost", "pk1");
    expect(code).not.toBe(0);
    // The real grant is untouched — a typo'd ref must never appear to revoke.
    expect(store.isAllowed("pk1", "projA")).toBe(true);
    rmSync(dir, { recursive: true });
  });

  it("list surfaces each phone's last seen (the value the touch refresh keeps current)", () => {
    const { dir, store } = seeded();
    store.touchLastSeen("pk1", "2026-07-27T09:30:00.000Z");
    const lines: string[] = [];
    const log = spyOn(console, "log").mockImplementation((...args: unknown[]) => { lines.push(args.join(" ")); });
    expect(phonesList(store)).toBe(0);
    log.mockRestore();
    expect(lines).toEqual(["Pixel  [d1]  last seen: 2026-07-27T09:30:00.000Z  allowed: (none)"]);
    store.close();
    rmSync(dir, { recursive: true });
  });

  it("list renders a row with no lastSeenAt as unknown, not the string undefined", () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-cli-"));
    mkdirSync(join(dir, "agents"), { recursive: true });
    // A hand-edited file: readFile applies no per-field validation.
    writeFileSync(
      join(dir, "agents", "paired-phones.json"),
      JSON.stringify({ version: 1, phones: [{ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "x", allowedProjects: [] }] }),
    );
    const lines: string[] = [];
    const log = spyOn(console, "log").mockImplementation((...args: unknown[]) => { lines.push(args.join(" ")); });
    phonesList(loadPairedPhones(dir));
    log.mockRestore();
    expect(lines[0]).toContain("last seen: unknown");
    rmSync(dir, { recursive: true });
  });

  it("remove drops the phone entirely", () => {
    const { dir, store } = seeded();
    const code = phonesRemove(store, "pk1");
    expect(code).toBe(0);
    expect(store.has("pk1")).toBe(false);
    rmSync(dir, { recursive: true });
  });

  it("remove fails (exit 2) on an unknown phoneRef, store unchanged", () => {
    const { dir, store } = seeded();
    const code = phonesRemove(store, "nope");
    expect(code).toBe(2);
    expect(store.has("pk1")).toBe(true);
    rmSync(dir, { recursive: true });
  });

  it("remove fails (exit 2) on an ambiguous phoneRef, store unchanged", () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-cli-"));
    const store = loadPairedPhones(dir);
    // Two phones sharing the same label make findPhone return null (>1 match).
    store.upsert({
      phonePubkey: "pkA", phoneDeviceId: "dA", label: "Pixel",
      pairedAt: "2026-01-01T00:00:00Z", lastSeenAt: "2026-01-01T00:00:00Z",
      allowedProjects: [],
    });
    store.upsert({
      phonePubkey: "pkB", phoneDeviceId: "dB", label: "Pixel",
      pairedAt: "2026-01-01T00:00:00Z", lastSeenAt: "2026-01-01T00:00:00Z",
      allowedProjects: [],
    });
    const code = phonesRemove(store, "Pixel");
    expect(code).toBe(2);
    expect(store.has("pkA")).toBe(true);
    expect(store.has("pkB")).toBe(true);
    rmSync(dir, { recursive: true });
  });
});
