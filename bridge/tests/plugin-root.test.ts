import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { materializeAgentAssets, bundledPluginPath } from "antgrid-agents/assets";
import { augmentAgentLaunch } from "../../packages/antgrid-agents/src/agent-launch-augmenter";
import type { HookCommand } from "../src/hook-command";

const HOOK_COMMAND: HookCommand = { binary: "/opt/antgrid/antgrid-bridge", preargs: ["hook"] };

const dirs: string[] = [];
function tmp(): string {
  const dir = mkdtempSync(join(tmpdir(), "ab-plugin-root-"));
  dirs.push(dir);
  return dir;
}
afterEach(() => {
  for (const dir of dirs.splice(0)) {
    try {
      rmSync(dir, { recursive: true, force: true });
    } catch {}
  }
});

describe("bundled plugin root", () => {
  test("materializes a stable package asset outside the checkout", () => {
    const dir = tmp();
    const path = bundledPluginPath(dir, "opencode", "plugin.ts");
    expect(path).toBe(join(materializeAgentAssets(dir), "opencode", "plugin.ts"));
    expect(existsSync(path)).toBe(true);
  });
  test("rejects unknown assets", () => {
    expect(() => bundledPluginPath(tmp(), "opencode", "not-shipped.ts")).toThrow(/Unknown bundled agent asset/);
  });
});

describe("opencode launch config", () => {
  test("names a plugin file that exists", () => {
    const abDir = tmp();
    const prev = process.env.OPENCODE_CONFIG;
    delete process.env.OPENCODE_CONFIG;
    let cfgPath: string | undefined;
    try {
      cfgPath = augmentAgentLaunch("opencode", abDir, undefined, HOOK_COMMAND).env
        .OPENCODE_CONFIG;
    } finally {
      if (prev !== undefined) process.env.OPENCODE_CONFIG = prev;
    }
    expect(cfgPath).toBeTruthy();
    const cfg = JSON.parse(readFileSync(cfgPath!, "utf8"));
    // The end-to-end property the anchor exists for: the URL opencode is told to
    // import resolves to a real file.
    expect(existsSync(fileURLToPath(cfg.plugin[0]))).toBe(true);
  });
});
