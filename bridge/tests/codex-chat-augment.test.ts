import { describe, expect, it } from "bun:test";
import { buildChatSpawnAugment } from "../src/agent-core";
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
