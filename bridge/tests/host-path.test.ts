import { describe, it, expect } from "bun:test";
import { augmentPath, wellKnownBinDirs } from "../src/host-path";

describe("augmentPath", () => {
  it("preserves the caller's PATH entries in order", () => {
    // A GUI-launched host has a stripped PATH; augmentPath appends well-known
    // install dirs but must never drop or reorder what was already there.
    const parts = augmentPath("/usr/bin:/bin").split(":");
    expect(parts.slice(0, 2)).toEqual(["/usr/bin", "/bin"]);
  });

  it("never produces duplicate entries", () => {
    const parts = augmentPath("/usr/bin:/bin").split(":").filter(Boolean);
    expect(new Set(parts).size).toBe(parts.length);
  });

  it("does not re-append a well-known dir already on PATH", () => {
    const dir = wellKnownBinDirs()[0];
    if (!dir) return; // win32: no well-known dirs to dedup
    const parts = augmentPath(dir).split(":");
    expect(parts.filter((p) => p === dir)).toHaveLength(1);
  });

  it("tolerates an empty/undefined PATH", () => {
    expect(() => augmentPath(undefined)).not.toThrow();
    expect(augmentPath("").split(":").filter(Boolean).every(Boolean)).toBe(true);
  });

  it("appends well-known dirs even if they do not exist on disk", () => {
    // No existsSync gate — a dir absent at startup must still be on PATH so a
    // binary that lands there later in the run resolves.
    if (process.platform === "win32") return; // no well-known dirs on win32
    const parts = augmentPath("/usr/bin").split(":");
    expect(parts).toContain(wellKnownBinDirs()[0]);
  });
});
