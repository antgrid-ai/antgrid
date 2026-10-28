import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { inject as claude } from "../src/agents/claude-code/mcp";
import { inject as codex } from "../src/agents/codex/mcp";
import { inject as copilot } from "../src/agents/github-copilot/mcp";
import { inject as cursor } from "../src/agents/cursor-agent/mcp";
import { overrideCursorHelp } from "../src/agents/cursor-agent/help";
import { opencodeFamilyMcp } from "../src/agents/opencode/mcp";
import { augmentAgentLaunch } from "../src/agent-launch-augmenter";
import type { McpInjectCtx } from "../src/agents/types";

const directories: string[] = [];
function context(): McpInjectCtx {
  const abDir = mkdtempSync(join(tmpdir(), "antgrid-memory-profile-"));
  directories.push(abDir);
  return {
    abDir,
    mcpCommand: { binary: "C:\\Program Files\\Antgrid\\bridge.exe", preargs: ["mcp"] },
    memoryMcpCommand: { binary: "C:\\Program Files\\Antgrid\\bridge.exe", preargs: ["memory-mcp"] },
  };
}
afterEach(() => {
  for (const directory of directories.splice(0)) rmSync(directory, { recursive: true, force: true });
  overrideCursorHelp(undefined);
});

test("Claude and Copilot add an independent memory server without strict config", () => {
  const ctx = context();
  for (const [inject, file] of [[claude, "claude.json"], [copilot, "copilot.json"]] as const) {
    const launch = inject(ctx);
    expect(launch.args.join(" ")).not.toContain("strict");
    const servers = JSON.parse(readFileSync(join(ctx.abDir, "mcp", file), "utf8")).mcpServers;
    expect(Object.keys(servers)).toEqual(["antgrid", "antgrid-memory"]);
    expect(servers.antgrid.args).toEqual(["mcp"]);
    expect(servers["antgrid-memory"].args).toEqual(["memory-mcp"]);
    expect(servers["antgrid-memory"].command).toBe(ctx.memoryMcpCommand!.binary);
  }
  const servers = JSON.parse(readFileSync(join(ctx.abDir, "mcp", "claude.json"), "utf8")).mcpServers;
  expect(servers["antgrid-memory"].env.ANTGRID_RUN_ID).toBe("${ANTGRID_RUN_ID}");
});

test("Codex forwards live identity independently to both servers", () => {
  const launch = codex(context());
  expect(launch.args).toContain('mcp_servers.antgrid.args=["mcp"]');
  expect(launch.args).toContain('mcp_servers.antgrid-memory.args=["memory-mcp"]');
  expect(launch.args).toContain('mcp_servers.antgrid-memory.env_vars=["ANTGRID_API_PORT","ANTGRID_TERMINAL_ID","ANTGRID_RUN_ID"]');
  expect(launch.args).toContain('mcp_servers.antgrid-memory.command="C:/Program Files/Antgrid/bridge.exe"');
});

test("Cursor memory profile uses symbolic environment and its existing plugin", () => {
  overrideCursorHelp("--plugin-dir");
  const ctx = context();
  cursor(ctx);
  const servers = JSON.parse(readFileSync(join(ctx.abDir, "plugin", "cursor", ".mcp.json"), "utf8")).mcpServers;
  expect(servers["antgrid-memory"].args).toEqual(["memory-mcp"]);
  expect(servers["antgrid-memory"].env.ANTGRID_RUN_ID).toBe("${env:ANTGRID_RUN_ID}");
});

test("OpenCode family preserves user MCP and other config while adding memory", () => {
  const envVar = "ANTGRID_TEST_MEMORY_MCP_CONFIG";
  const previous = process.env[envVar];
  try {
    process.env[envVar] = JSON.stringify({ theme: "mine", mcp: { custom: { type: "remote", url: "https://example.test" } } });
    const launch = opencodeFamilyMcp(envVar).inject(context());
    const config = JSON.parse(launch.env[envVar]!);
    expect(config.theme).toBe("mine");
    expect(config.mcp.custom.url).toBe("https://example.test");
    expect(config.mcp["antgrid-memory"].command.at(-1)).toBe("memory-mcp");
    process.env[envVar] = "not-json";
    expect(opencodeFamilyMcp(envVar).inject(context()).env).toEqual({});
  } finally {
    if (previous === undefined) delete process.env[envVar]; else process.env[envVar] = previous;
  }
});

test("chat launch explicitly suppresses both MCP servers", () => {
  const ctx = context();
  const launch = augmentAgentLaunch("codex", { ...ctx, mcp: false, hookCommand: { binary: "bridge", preargs: ["hook"] } });
  expect(launch.args.some(arg => arg.startsWith("mcp_servers."))).toBe(false);
});
