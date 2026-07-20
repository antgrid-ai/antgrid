import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { augmentAgentLaunch } from "../src/agent-launch-augmenter";
import { type HookCommand } from "../src/hook-command";
import { cursorHookCommand } from "../src/cursor-hooks";

const dirs: string[] = [];
function abdir() { const d = mkdtempSync(join(tmpdir(), "ab-aug-")); dirs.push(d); return d; }
afterEach(() => { for (const d of dirs.splice(0)) try { rmSync(d, { recursive: true, force: true }); } catch {} });

const HOOK_COMMAND: HookCommand = {
  binary: "C:\\Program Files\\Antgrid\\antgrid-bridge.exe",
  preargs: ["hook"],
};

describe("augmentAgentLaunch", () => {
  test("claude materializes a bridge-backed plugin with one command per event", () => {
    const a = augmentAgentLaunch("claude-code", abdir(), undefined, HOOK_COMMAND);
    expect(a.args[0]).toBe("--plugin-dir");
    expect(a.args[1].replace(/\\/g, "/")).toMatch(/\/plugin\/claude$/);
    expect(a.env).toEqual({});
    expect(a.notificationsInjected).toBe(true);
    const hooks = JSON.parse(readFileSync(join(a.args[1], "hooks", "hooks.json"), "utf8"));
    for (const event of ["SessionStart", "Stop", "Notification"]) {
      expect(hooks.hooks[event]).toHaveLength(1);
      expect(hooks.hooks[event][0].hooks).toHaveLength(1);
      expect(hooks.hooks[event][0].hooks[0].command).toBe(HOOK_COMMAND.binary);
      expect(hooks.hooks[event][0].hooks[0].args).toContain("hook");
      expect(hooks.hooks[event][0].hooks[0].args.join(" ")).not.toMatch(/\bnode(?:\.exe)?\b/i);
    }
  });

  test("codex uses the bridge for notify and command hooks", () => {
    const a = augmentAgentLaunch("codex", abdir(), undefined, HOOK_COMMAND);
    expect(a.args[0]).toBe("-c");
    expect(a.args[1]).toBe(
      'notify=["C:/Program Files/Antgrid/antgrid-bridge.exe","hook","codex","after-agent"]',
    );
    expect(a.args.join(" ")).not.toMatch(/\bnode(?:\.exe)?\b/i);
  });

  test("opencode emits its existing runtime-owned plugin config", () => {
    const prev = process.env.OPENCODE_CONFIG;
    delete process.env.OPENCODE_CONFIG;
    try {
      const a = augmentAgentLaunch("opencode", abdir(), undefined, HOOK_COMMAND);
      expect(a.args).toEqual([]);
      const cfgPath = a.env.OPENCODE_CONFIG;
      expect(cfgPath).toBeTruthy();
      const cfg = JSON.parse(readFileSync(cfgPath, "utf8"));
      expect(Array.isArray(cfg.plugin)).toBe(true);
      expect(cfg.plugin[0]).toMatch(/^file:\/\/.*opencode\/plugin\.ts$/);
    } finally { if (prev !== undefined) process.env.OPENCODE_CONFIG = prev; }
  });

  test("opencode respects a user-set OPENCODE_CONFIG", () => {
    const prev = process.env.OPENCODE_CONFIG;
    process.env.OPENCODE_CONFIG = "/user/own.json";
    try {
      expect(augmentAgentLaunch("opencode", abdir(), undefined, HOOK_COMMAND)).toEqual({ args: [], env: {} });
    } finally {
      if (prev === undefined) delete process.env.OPENCODE_CONFIG; else process.env.OPENCODE_CONFIG = prev;
    }
  });

  test("unknown tool has no injection", () => {
    expect(augmentAgentLaunch("some-shell", abdir(), undefined, HOOK_COMMAND)).toEqual({ args: [], env: {} });
  });

  test("cursor-agent merges bridge hooks into the global hooks file", () => {
    const abDir = abdir();
    const cursorDir = abdir();
    const a = augmentAgentLaunch("cursor-agent", abDir, cursorDir, HOOK_COMMAND);
    expect(a.args).toEqual(["--trust"]);
    expect(a.env).toEqual({});
    expect(a.notificationsInjected).toBe(true);

    const hooks = JSON.parse(readFileSync(join(cursorDir, "hooks.json"), "utf8"));
    expect(hooks.hooks.sessionStart[0].command).toContain("antgrid-bridge.exe");
    // cursorHookCommand quotes per host platform and (unlike raw
    // hookShellCommand) omits the `&` call operator that Cursor supplies itself,
    // so assert against it rather than a literal quoting style.
    expect(hooks.hooks.sessionStart[0].command).toBe(
      cursorHookCommand(HOOK_COMMAND, "session-start"),
    );
    expect(hooks.hooks.stop[0].command).toBe(cursorHookCommand(HOOK_COMMAND, "stop"));
    expect(JSON.stringify(hooks)).not.toMatch(/\bnode(?:\.exe)?\b/i);
  });

  test("cursor-agent merge is idempotent and preserves user hooks", () => {
    const abDir = abdir();
    const cursorDir = abdir();
    writeFileSync(
      join(cursorDir, "hooks.json"),
      JSON.stringify({ version: 1, hooks: { stop: [{ command: "echo mine", timeout: 5 }] } }),
    );
    augmentAgentLaunch("cursor-agent", abDir, cursorDir, HOOK_COMMAND);
    const first = JSON.parse(readFileSync(join(cursorDir, "hooks.json"), "utf8"));
    expect(first.hooks.stop.some((h: any) => h.command === "echo mine")).toBe(true);
    expect(first.hooks.stop.some((h: any) => h.command.includes("antgrid-bridge.exe"))).toBe(true);

    augmentAgentLaunch("cursor-agent", abDir, cursorDir, HOOK_COMMAND);
    const second = JSON.parse(readFileSync(join(cursorDir, "hooks.json"), "utf8"));
    expect(second).toEqual(first);
  });

  test("cursor-agent enables OSC fallback when hooks.json writing fails", () => {
    const abDir = abdir();
    const cursorDirAsFile = join(abdir(), "not-a-dir");
    writeFileSync(cursorDirAsFile, "");
    const a = augmentAgentLaunch("cursor-agent", abDir, cursorDirAsFile, HOOK_COMMAND);
    // --trust survives the failed write: workspace trust is independent of the
    // hooks channel, and the spawn must not regress to a trust prompt.
    expect(a).toEqual({ args: ["--trust"], env: {}, notificationsInjected: false });
  });

  test("claude launches without plugin-dir and enables OSC fallback when materialization fails", () => {
    const abDirAsFile = join(abdir(), "not-a-dir");
    writeFileSync(abDirAsFile, "");
    expect(augmentAgentLaunch("claude-code", abDirAsFile, undefined, HOOK_COMMAND)).toEqual({
      args: [],
      env: {},
      notificationsInjected: false,
    });
  });
});
