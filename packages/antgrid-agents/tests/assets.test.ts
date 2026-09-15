import { expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { bundledPluginPath, materializeAgentAssets } from "../src/plugin-root";

test("materialized assets match their source and have stable content addresses", () => {
  const dir = mkdtempSync(join(tmpdir(), "antgrid-assets-"));
  try {
    const first = materializeAgentAssets(dir);
    expect(materializeAgentAssets(dir)).toBe(first);
    for (const file of ["opencode/plugin.ts", "antigravity/post-title.js", "hooks/on-stop", "hooks/on-notification", "hooks/_resolve-api-port.sh"]) {
      expect(readFileSync(join(first, file), "utf8")).toBe(readFileSync(join(import.meta.dir, "../assets", file), "utf8"));
    }
    expect(() => bundledPluginPath(dir, "..", "outside")).toThrow("Unknown bundled agent asset");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
