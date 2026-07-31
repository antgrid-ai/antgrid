// The bundled plugin assets are addressed by a path computed relative to a
// source file, which is the one kind of breakage that leaves no trace: move the
// file that computes it and the config still writes, the agent still spawns, and
// the plugin named by that config simply never loads. These tests pin the anchor
// against a path derived from THIS file, so they fail on the move rather than in
// a user's session weeks later.
import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { PLUGIN_ROOT, bundledPluginPath } from "../src/plugin-root";
import { augmentAgentLaunch } from "../src/agent-launch-augmenter";
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
  test("resolves to bridge/plugin no matter which src/ module asks", () => {
    expect(PLUGIN_ROOT).toBe(join(import.meta.dir, "..", "plugin"));
  });

  test("hands back an asset that is actually on disk", () => {
    const path = bundledPluginPath("opencode", "plugin.ts");
    expect(path).toBe(join(import.meta.dir, "..", "plugin", "opencode", "plugin.ts"));
    expect(existsSync(path)).toBe(true);
  });

  test("throws on a missing asset instead of returning a path nobody can load", () => {
    expect(() => bundledPluginPath("opencode", "not-shipped.ts")).toThrow(
      /bundled plugin asset missing/,
    );
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
