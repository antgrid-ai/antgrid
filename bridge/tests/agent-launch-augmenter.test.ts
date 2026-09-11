import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { augmentAgentLaunch } from "../src/agent-launch-augmenter";
import { type HookCommand } from "../src/hook-command";
import { cursorHookCommand } from "../src/agents/cursor-agent/global-hooks";
import { codexNotifyOnlyArgs } from "../src/agents/codex/driver";
import { pluginDirArg } from "../src/agents/claude-code/driver";
import { AGENTS } from "../src/agents/registry";
import type { AgentKey, LaunchAugmentation } from "../src/agents/types";

const dirs: string[] = [];
function abdir() { const d = mkdtempSync(join(tmpdir(), "ab-aug-")); dirs.push(d); return d; }
afterEach(() => { for (const d of dirs.splice(0)) try { rmSync(d, { recursive: true, force: true }); } catch {} });

const HOOK_COMMAND: HookCommand = {
  binary: "C:\\Program Files\\Antgrid\\antgrid-bridge.exe",
  preargs: ["hook"],
};

// The single self-invocation decision `augmentAgentLaunch` derives both the
// hook command and the MCP command from; resolves to HOOK_COMMAND above.
const BRIDGE_SELF = { compiled: true, binary: HOOK_COMMAND.binary };

const AGENT_KEYS = Object.keys(AGENTS) as AgentKey[];

/** The config path out of claude's single `--mcp-config=<path>` token. */
function mcpConfigPath(a: LaunchAugmentation): string {
  const arg = a.args.find((x) => x.startsWith("--mcp-config="))!;
  return arg.slice("--mcp-config=".length);
}

/** The `antgrid` entry claude is pointed at, read back off the file the
 *  injection wrote — argv alone only proves which path was named. */
function mcpEntry(a: LaunchAugmentation): { command: string; args: string[] } {
  const { command, args } = JSON.parse(readFileSync(mcpConfigPath(a), "utf8")).mcpServers.antgrid;
  return { command, args };
}

/** The same two values as codex renders them into its `-c` overrides. */
function codexMcpEntry(a: LaunchAugmentation): { command: string; args: string } {
  const value = (key: string) =>
    a.args.find((x) => x.startsWith(`mcp_servers.antgrid.${key}=`))!.split("=").slice(1).join("=");
  return { command: value("command"), args: value("args") };
}

describe("augmentAgentLaunch", () => {
  test("claude materializes a bridge-backed plugin with one command per event", () => {
    const a = augmentAgentLaunch("claude-code", { abDir: abdir(), self: BRIDGE_SELF });
    expect(a.args[0]).toBe("--plugin-dir");
    expect(a.args[1].replace(/\\/g, "/")).toMatch(/\/plugin\/claude$/);
    expect(a.env).toEqual({});
    expect(a.notificationsInjected).toBe(true);
    const hooks = JSON.parse(readFileSync(join(a.args[1], "hooks", "hooks.json"), "utf8"));
    for (const event of ["SessionStart", "Stop", "StopFailure", "Notification", "UserPromptSubmit"]) {
      expect(hooks.hooks[event]).toHaveLength(1);
      expect(hooks.hooks[event][0].hooks).toHaveLength(1);
      expect(hooks.hooks[event][0].hooks[0].command).toBe(HOOK_COMMAND.binary);
      expect(hooks.hooks[event][0].hooks[0].args).toContain("hook");
      expect(hooks.hooks[event][0].hooks[0].args.join(" ")).not.toMatch(/\bnode(?:\.exe)?\b/i);
    }
  });

  test("codex uses the bridge for notify and command hooks", () => {
    const a = augmentAgentLaunch("codex", { abDir: abdir(), self: BRIDGE_SELF });
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
      const a = augmentAgentLaunch("opencode", { abDir: abdir(), self: BRIDGE_SELF });
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
      expect(augmentAgentLaunch("opencode", { abDir: abdir(), self: BRIDGE_SELF })).toEqual({ args: [], env: {} });
    } finally {
      if (prev === undefined) delete process.env.OPENCODE_CONFIG; else process.env.OPENCODE_CONFIG = prev;
    }
  });

  test("unknown tool has no injection", () => {
    expect(augmentAgentLaunch("some-shell", { abDir: abdir(), self: BRIDGE_SELF })).toEqual({ args: [], env: {} });
  });

  test("cursor-agent merges bridge hooks into the global hooks file", () => {
    const abDir = abdir();
    const cursorDir = abdir();
    const a = augmentAgentLaunch("cursor-agent", { abDir, cursorDir, self: BRIDGE_SELF });
    expect(a.args).toEqual(["--trust"]);
    expect(a.env).toEqual({});
    expect(a.notificationsInjected).toBe(true);

    const hooks = JSON.parse(readFileSync(join(cursorDir, "hooks.json"), "utf8"));
    expect(hooks.hooks.sessionStart[0].command).toContain("antgrid-bridge.exe");
    // cursor-agent tokenizes the command into argv itself (cmd.exe on Windows,
    // never PowerShell), so the command must be double-quoted on every
    // platform and must never start with PowerShell's `&` call operator — a
    // leading `&` becomes the program name and breaks every cursor hook on
    // Windows. Pin both independently here: the toBe equalities below track
    // the producer (cursorHookCommand) and would follow a regression in it.
    for (const event of ["sessionStart", "stop"] as const) {
      const command: string = hooks.hooks[event][0].command;
      expect(command.startsWith("&")).toBe(false);
      expect(command.startsWith('"')).toBe(true);
    }
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
    augmentAgentLaunch("cursor-agent", { abDir, cursorDir, self: BRIDGE_SELF });
    const first = JSON.parse(readFileSync(join(cursorDir, "hooks.json"), "utf8"));
    expect(first.hooks.stop.some((h: any) => h.command === "echo mine")).toBe(true);
    expect(first.hooks.stop.some((h: any) => h.command.includes("antgrid-bridge.exe"))).toBe(true);

    augmentAgentLaunch("cursor-agent", { abDir, cursorDir, self: BRIDGE_SELF });
    const second = JSON.parse(readFileSync(join(cursorDir, "hooks.json"), "utf8"));
    expect(second).toEqual(first);
  });

  test("cursor-agent enables OSC fallback when hooks.json writing fails", () => {
    const abDir = abdir();
    const cursorDirAsFile = join(abdir(), "not-a-dir");
    writeFileSync(cursorDirAsFile, "");
    const a = augmentAgentLaunch("cursor-agent", { abDir, cursorDir: cursorDirAsFile, self: BRIDGE_SELF });
    // --trust survives the failed write: workspace trust is independent of the
    // hooks channel, and the spawn must not regress to a trust prompt.
    expect(a).toEqual({ args: ["--trust"], env: {}, notificationsInjected: false });
  });

  test("claude launches without plugin-dir and enables OSC fallback when materialization fails", () => {
    const abDirAsFile = join(abdir(), "not-a-dir");
    writeFileSync(abDirAsFile, "");
    expect(augmentAgentLaunch("claude-code", { abDir: abDirAsFile, self: BRIDGE_SELF })).toEqual({
      args: [],
      env: {},
      notificationsInjected: false,
    });
  });

  test("antigravity → merges PreInvocation+Stop hooks into the global hooks.json, sets GODEBUG fallback-roots", () => {
    const abDir = abdir();
    const geminiConfigDir = abdir();
    const a = augmentAgentLaunch("antigravity", { abDir, geminiConfigDir, self: BRIDGE_SELF });
    expect(a.args).toEqual([]);
    expect(a.env).toEqual({ GODEBUG: "x509usefallbackroots=1" });
    expect(a.notificationsInjected).toBe(true);

    const hooks = JSON.parse(readFileSync(join(geminiConfigDir, "hooks.json"), "utf8"));
    const group = hooks["antgrid-session-title"];
    // Deliberately unquoted (see antigravityHookCommand) — no trailing `"` before the event name.
    expect(group.PreInvocation[0].command.replace(/\\/g, "/")).toMatch(
      /antigravity\/post-title\.js PreInvocation$/,
    );
    expect(group.Stop[0].command.replace(/\\/g, "/")).toMatch(/antigravity\/post-title\.js Stop$/);
  });

  test("antigravity hooks.json merge is idempotent and preserves other top-level groups", () => {
    const abDir = abdir();
    const geminiConfigDir = abdir();
    writeFileSync(
      join(geminiConfigDir, "hooks.json"),
      JSON.stringify({ "some-other-plugin": { Stop: [{ type: "command", command: "echo mine", timeout: 5 }] } }),
    );
    augmentAgentLaunch("antigravity", { abDir, geminiConfigDir, self: BRIDGE_SELF });
    const first = JSON.parse(readFileSync(join(geminiConfigDir, "hooks.json"), "utf8"));
    expect(first["some-other-plugin"].Stop[0].command).toBe("echo mine");
    expect(first["antgrid-session-title"].Stop[0].command).toContain("post-title.js");

    augmentAgentLaunch("antigravity", { abDir, geminiConfigDir, self: BRIDGE_SELF });
    const second = JSON.parse(readFileSync(join(geminiConfigDir, "hooks.json"), "utf8"));
    expect(second).toEqual(first);
  });

  test("antigravity → notificationsInjected is false when the hooks.json write fails", () => {
    const abDir = abdir();
    // A file (not a directory) at the gemini-config-dir path makes the hooks.json
    // write fail, exercising ensureAntigravityHook's fail-open catch.
    const geminiConfigDirAsFile = join(abdir(), "not-a-dir");
    writeFileSync(geminiConfigDirAsFile, "");
    const a = augmentAgentLaunch("antigravity", { abDir, geminiConfigDir: geminiConfigDirAsFile, self: BRIDGE_SELF });
    expect(a).toEqual({
      args: [],
      env: { GODEBUG: "x509usefallbackroots=1" },
      notificationsInjected: false,
    });
  });

  test("antigravity → appends to, rather than clobbers, an existing GODEBUG value", () => {
    const abDir = abdir();
    const geminiConfigDir = abdir();
    const prevGodebug = process.env.GODEBUG;
    process.env.GODEBUG = "http2client=0";
    try {
      const a = augmentAgentLaunch("antigravity", { abDir, geminiConfigDir, self: BRIDGE_SELF });
      expect(a.env.GODEBUG).toBe("http2client=0,x509usefallbackroots=1");
    } finally {
      if (prevGodebug === undefined) delete process.env.GODEBUG;
      else process.env.GODEBUG = prevGodebug;
    }
  });

  test("antigravity → does not duplicate x509usefallbackroots if the user already set it", () => {
    const abDir = abdir();
    const geminiConfigDir = abdir();
    const prevGodebug = process.env.GODEBUG;
    process.env.GODEBUG = "x509usefallbackroots=0";
    try {
      const a = augmentAgentLaunch("antigravity", { abDir, geminiConfigDir, self: BRIDGE_SELF });
      expect(a.env.GODEBUG).toBe("x509usefallbackroots=0");
    } finally {
      if (prevGodebug === undefined) delete process.env.GODEBUG;
      else process.env.GODEBUG = prevGodebug;
    }
  });
});

describe("augmentAgentLaunch MCP injection", () => {
  test("claude points --mcp-config at a file outside the plugin dir", () => {
    const abDir = abdir();
    const a = augmentAgentLaunch("claude-code", { abDir, self: BRIDGE_SELF });
    const pluginDir = join(abDir, "plugin", "claude");
    const configPath = join(abDir, "mcp", "claude.json");
    // One token, not a separated pair: `--mcp-config` is variadic, and a
    // session's own args are folded in directly after this, so the separated
    // form reads the user's first word as another config path.
    expect(a.args).toEqual(["--plugin-dir", pluginDir, `--mcp-config=${configPath}`]);
    // The trap this layout exists to avoid: `--plugin-dir` also loads a
    // `.mcp.json` inside the plugin tree, so a config written there would
    // register the same server twice under two different tool-name prefixes.
    expect(configPath.startsWith(pluginDir)).toBe(false);
    // `--strict-mcp-config` would drop every server the user configured.
    expect(a.args).not.toContain("--strict-mcp-config");
    expect(a.args.join(" ")).not.toMatch(/\bnode(?:\.exe)?\b/i);

    expect(JSON.parse(readFileSync(configPath, "utf8"))).toEqual({
      mcpServers: {
        antgrid: {
          type: "stdio",
          command: HOOK_COMMAND.binary,
          args: ["mcp"],
          // Symbolic, not resolved: claude expands these against its own
          // environment at spawn, which is what lets one file serve every
          // terminal on the machine.
          env: {
            ANTGRID_API_PORT: "${ANTGRID_API_PORT}",
            ANTGRID_TERMINAL_ID: "${ANTGRID_TERMINAL_ID}",
          },
        },
      },
    });
  });

  test("codex renders the mcp_servers overrides the way it renders notify", () => {
    const a = augmentAgentLaunch("codex", { abDir: abdir(), self: BRIDGE_SELF });
    expect(a.args).toContain('mcp_servers.antgrid.command="C:/Program Files/Antgrid/antgrid-bridge.exe"');
    expect(a.args).toContain('mcp_servers.antgrid.args=["mcp"]');
    // Forwarded by name because codex passes none of its own environment down
    // to an MCP server, so the values resolve per PTY at spawn.
    expect(a.args).toContain('mcp_servers.antgrid.env_vars=["ANTGRID_API_PORT","ANTGRID_TERMINAL_ID"]');
    for (const arg of a.args.filter((x) => x.startsWith("mcp_servers."))) {
      expect(a.args[a.args.indexOf(arg) - 1]).toBe("-c");
      expect(arg).not.toContain("\\");
    }
    expect(a.args.join(" ")).not.toMatch(/\bnode(?:\.exe)?\b/i);
  });

  test("codex chat mode drops the mcp overrides rather than choking on them", () => {
    const a = augmentAgentLaunch("codex", { abDir: abdir(), self: BRIDGE_SELF });
    const notify = a.args[1];
    expect(codexNotifyOnlyArgs(a.args)).toEqual(["-c", notify]);
  });

  test("one `self` decides both commands, so a spawn cannot mix compiled and dev", () => {
    const compiledAbDir = abdir();
    const compiled = { compiled: true, binary: "/opt/antgrid bridge/antgrid-bridge" };
    const claudeCompiled = augmentAgentLaunch("claude-code", { abDir: compiledAbDir, self: compiled });
    expect(mcpEntry(claudeCompiled)).toEqual({ command: compiled.binary, args: ["mcp"] });
    expect(codexMcpEntry(augmentAgentLaunch("codex", { abDir: abdir(), self: compiled }))).toEqual({
      command: `"${compiled.binary}"`,
      args: '["mcp"]',
    });

    const devAbDir = abdir();
    const dev = {
      compiled: false,
      binary: "C:\\Users\\O'Brien\\.bun\\bin\\bun.exe",
      entrypoint: "C:\\repo path\\bridge\\src\\index.ts",
    };
    const claudeDev = augmentAgentLaunch("claude-code", { abDir: devAbDir, self: dev });
    expect(mcpEntry(claudeDev)).toEqual({ command: dev.binary, args: [dev.entrypoint, "mcp"] });
    expect(codexMcpEntry(augmentAgentLaunch("codex", { abDir: abdir(), self: dev }))).toEqual({
      command: '"C:/Users/O\'Brien/.bun/bin/bun.exe"',
      args: '["C:/repo path/bridge/src/index.ts","mcp"]',
    });
  });

  test("an agent with no mcp profile gets no MCP argv", () => {
    for (const key of AGENT_KEYS.filter((k) => !AGENTS[k].mcp)) {
      const a = augmentAgentLaunch(key, { abDir: abdir(), cursorDir: abdir(), self: BRIDGE_SELF });
      expect(a.args.join(" ")).not.toContain("mcp");
    }
  });

  // The mixed state the two profiles made reachable: one fails, the other does
  // not, so the arg list no longer has a fixed shape.
  test("a failed plugin write leaves the chat driver with no plugin dir", () => {
    const abDir = abdir();
    // A stale regular file where the plugin tree belongs: materialization dies
    // of ENOTDIR while `<abDir>/mcp/claude.json` writes fine.
    writeFileSync(join(abDir, "plugin"), "");
    const a = augmentAgentLaunch("claude-code", { abDir, self: BRIDGE_SELF });
    expect(a.args).toEqual([`--mcp-config=${join(abDir, "mcp", "claude.json")}`]);
    expect(a.notificationsInjected).toBe(false);
    // Reading `args[indexOf("--plugin-dir") + 1]` unchecked lands on args[0]
    // here and launches `claude --plugin-dir --mcp-config`, turning a session
    // that merely loses its title plugin into one that fails to start.
    expect(pluginDirArg(a.args)).toBeUndefined();
  });

  test("a throwing mcp.inject costs the tools and nothing else", () => {
    const spec = AGENTS["claude-code"];
    const real = spec.mcp!;
    // Cast: the registry is frozen-by-convention, not by type, and this is the
    // only way to exercise the augmenter's own catch.
    (spec as { mcp?: typeof real }).mcp = {
      inject() { throw new Error("boom"); },
    };
    try {
      const abDir = abdir();
      const a = augmentAgentLaunch("claude-code", { abDir, self: BRIDGE_SELF });
      expect(a.args).toEqual(["--plugin-dir", join(abDir, "plugin", "claude")]);
      expect(a.notificationsInjected).toBe(true);
    } finally {
      (spec as { mcp?: typeof real }).mcp = real;
    }
  });
});
