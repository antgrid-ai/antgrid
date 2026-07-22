import { describe, it, expect } from "bun:test";
import { detectInstalledTools, resetToolDetectionCacheForTest } from "../src/tool-detector";
import { mkdtempSync, writeFileSync, chmodSync } from "node:fs";
import { join } from "node:path";
import { tmpdir, platform } from "node:os";

function makeFakeBin(dir: string, name: string) {
  const ext = platform() === "win32" ? ".cmd" : "";
  const file = join(dir, name + ext);
  writeFileSync(file, "#!/bin/sh\necho fake\n", "utf8");
  if (platform() !== "win32") chmodSync(file, 0o755);
  return file;
}

describe("tool-detector", () => {
  it("returns empty array when none of KNOWN_AGENTS are on PATH", () => {
    const empty = mkdtempSync(join(tmpdir(), "antgrid-tools-empty-"));
    const result = detectInstalledTools({ pathOverride: empty });
    expect(result).toEqual([]);
  });

  it("detects an installed known agent by bin name", () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-tools-"));
    makeFakeBin(dir, "claude");
    const result = detectInstalledTools({ pathOverride: dir });
    expect(result.find((t) => t.tool === "claude-code")).toBeDefined();
  });

  it("memoizes the no-override probe (same reference on repeat)", () => {
    resetToolDetectionCacheForTest();
    const a = detectInstalledTools();
    const b = detectInstalledTools();
    expect(b).toBe(a); // cached — no second PATH walk
  });

  it("never caches an explicit pathOverride", () => {
    resetToolDetectionCacheForTest();
    const a = detectInstalledTools({ pathOverride: "" });
    const b = detectInstalledTools({ pathOverride: "" });
    expect(a).not.toBe(b); // re-probed each call
    expect(a).toEqual([]);
  });
});
