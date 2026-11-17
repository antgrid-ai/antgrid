import { describe, expect, it } from "bun:test";
import { buildChatSpawnAugment } from "../src/agent-core";
import { augmentAgentLaunch } from "antgrid-agents/agent-launch-augmenter";
import { codexChatAugmentArgs, codexUnifiedExecArgs } from "../../packages/antgrid-agents/src/agents/codex/driver";

describe("codex chat-mode augment", () => {
  it("forwards the notify and MCP settings", () => {
    const sliced = codexChatAugmentArgs(
      buildChatSpawnAugment("codex", "slot-7", 8790).args,
    );
    expect(sliced.length).toBeGreaterThan(2);
    expect(sliced[0]).toBe("-c");
    expect(sliced[1]?.startsWith("notify=")).toBe(true);
    expect(sliced.some((a) => a.startsWith("mcp_servers.antgrid.command="))).toBe(true);
    expect(sliced.some((a) => a.startsWith("mcp_servers.antgrid.env_vars="))).toBe(true);
  });

  it("keeps the memory pre-approval settings when Memory is registered", () => {
    const bin = { binary: "bridge", preargs: ["mcp"] };
    const aug = augmentAgentLaunch("codex", {
      mode: "chat", abDir: process.env.TEMP ?? ".", mcpCommand: bin, memoryMcpCommand: { binary: "bridge", preargs: ["memory-mcp"] },
      hookCommand: { binary: "bridge", preargs: ["hook"] },
    });
    const sliced = codexChatAugmentArgs(aug.args);
    for (const tool of ["memory_search", "memory_get", "memory_save"]) {
      expect(sliced).toContain(`mcp_servers.antgrid-memory.tools.${tool}.approval_mode="approve"`);
    }
    expect(sliced.some((a) => a.includes("memory_forget"))).toBe(false);
  });

  it("drops every hooks.* arg (app-server's -c parser rejects them)", () => {
    const sliced = codexChatAugmentArgs(
      buildChatSpawnAugment("codex", "slot-7", 8790).args,
    );
    expect(sliced.some((a) => a.includes("hooks."))).toBe(false);
  });

  it("stamps the slot id into the correlation env", () => {
    expect(buildChatSpawnAugment("codex", "slot-7", 8790).env.ANTGRID_TERMINAL_ID).toBe("slot-7");
  });

  it("forces unified exec on (codex defaults it OFF on Windows; background terminals need it)", () => {
    expect(codexUnifiedExecArgs()).toEqual(["-c", "experimental_use_unified_exec_tool=true"]);
  });
});
