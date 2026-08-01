import { describe, it, expect, spyOn } from "bun:test";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadPairedPhones } from "../src/paired-phones";
import { loadRemoteAccessPolicy } from "../src/remote-access-policy";
import { phonesList, phonesRemove } from "../src/cli/phones";

function seeded() {
  const dir = mkdtempSync(join(tmpdir(), "antgrid-cli-"));
  const store = loadPairedPhones(dir);
  store.upsert({
    phonePubkey: "pk1", phoneDeviceId: "d1", label: "Pixel",
    pairedAt: "2026-01-01T00:00:00Z", lastSeenAt: "2026-01-01T00:00:00Z",
  });
  return { dir, store };
}

/** `phonesRemove` prints an advisory note on stderr; capture it so the suite
 *  output stays readable and the note itself stays assertable. */
function captureStderr<T>(fn: () => T): { result: T; lines: string[] } {
  const lines: string[] = [];
  const err = spyOn(console, "error").mockImplementation((...args: unknown[]) => { lines.push(args.join(" ")); });
  try {
    return { result: fn(), lines };
  } finally {
    err.mockRestore();
  }
}

describe("antgrid phones CLI", () => {
  it("list surfaces each phone's last seen (the value the touch refresh keeps current)", () => {
    const { dir, store } = seeded();
    store.touchLastSeen("pk1", "2026-07-27T09:30:00.000Z");
    const lines: string[] = [];
    const log = spyOn(console, "log").mockImplementation((...args: unknown[]) => { lines.push(args.join(" ")); });
    expect(phonesList(store)).toBe(0);
    log.mockRestore();
    expect(lines).toEqual(["Pixel  [d1]  last seen: 2026-07-27T09:30:00.000Z"]);
    store.close();
    rmSync(dir, { recursive: true });
  });

  it("list renders a row with no lastSeenAt as unknown, not the string undefined", () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-cli-"));
    mkdirSync(join(dir, "agents"), { recursive: true });
    // A hand-edited file: readFile applies no per-field validation.
    writeFileSync(
      join(dir, "agents", "paired-phones.json"),
      JSON.stringify({ version: 1, phones: [{ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "x" }] }),
    );
    const lines: string[] = [];
    const log = spyOn(console, "log").mockImplementation((...args: unknown[]) => { lines.push(args.join(" ")); });
    phonesList(loadPairedPhones(dir));
    log.mockRestore();
    expect(lines[0]).toContain("last seen: unknown");
    rmSync(dir, { recursive: true });
  });

  it("remove drops the phone entirely and says it is not a revocation", () => {
    const { dir, store } = seeded();
    const { result: code, lines } = captureStderr(() => phonesRemove(store, "pk1", dir));
    expect(code).toBe(0);
    expect(store.has("pk1")).toBe(false);
    expect(lines.join(" ")).toContain("does not revoke");
    rmSync(dir, { recursive: true });
  });

  it("remove fails (exit 2) on an unknown phoneRef, store unchanged", () => {
    const { dir, store } = seeded();
    const { result: code } = captureStderr(() => phonesRemove(store, "nope", dir));
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
    });
    store.upsert({
      phonePubkey: "pkB", phoneDeviceId: "dB", label: "Pixel",
      pairedAt: "2026-01-01T00:00:00Z", lastSeenAt: "2026-01-01T00:00:00Z",
    });
    const { result: code } = captureStderr(() => phonesRemove(store, "Pixel", dir));
    expect(code).toBe(2);
    expect(store.has("pkA")).toBe(true);
    expect(store.has("pkB")).toBe(true);
    rmSync(dir, { recursive: true });
  });

  // The CLI can be the FIRST new-build process to touch a v1 abDir, and its
  // flush sheds the `allowedProjects` the mobile-access migration derives the
  // machine switch from. Running the migration first is what keeps a user who
  // only ever granted through `antgrid phones allow` mobile-reachable.
  it("remove runs the mobile-access migration before its flush strips the v1 grants", () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-cli-"));
    mkdirSync(join(dir, "agents"), { recursive: true });
    writeFileSync(
      join(dir, "agents", "paired-phones.json"),
      JSON.stringify({
        version: 1,
        phones: [
          { phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "x", lastSeenAt: "x", allowedProjects: ["projA"] },
          { phonePubkey: "pk2", phoneDeviceId: "d2", pairedAt: "x", lastSeenAt: "x", allowedProjects: [] },
        ],
      }, null, 2),
    );

    const store = loadPairedPhones(dir);
    const { result: code } = captureStderr(() => phonesRemove(store, "pk2", dir));
    expect(code).toBe(0);

    // The grants are gone from disk now...
    const raw = JSON.parse(
      readFileSync(join(dir, "agents", "paired-phones.json"), "utf8"),
    ) as { phones: { allowedProjects?: string[] }[] };
    expect(raw.phones.every((p) => p.allowedProjects === undefined)).toBe(true);
    // ...but the migration already saw them, so the machine stays reachable.
    expect(loadRemoteAccessPolicy(dir).isEnabled()).toBe(true);

    rmSync(dir, { recursive: true });
  });

  it("remove leaves the switch off when there was nothing to migrate", () => {
    const { dir, store } = seeded();
    captureStderr(() => phonesRemove(store, "pk1", dir));
    expect(loadRemoteAccessPolicy(dir).isEnabled()).toBe(false);
    rmSync(dir, { recursive: true });
  });
});
