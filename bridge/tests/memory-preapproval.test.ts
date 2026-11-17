import { describe, expect, it } from "bun:test";
import { MEMORY_MCP_SERVER, MEMORY_PREAPPROVED_TOOLS } from "antgrid-agents/memory-guidance";
import { MEMORY_TOOLS } from "../src/memory-mcp/server";

describe("memory pre-approval", () => {
  const served = MEMORY_TOOLS.map((tool) => tool.name);

  it("names only tools the memory server actually serves", () => {
    for (const tool of MEMORY_PREAPPROVED_TOOLS) expect(served).toContain(tool);
  });

  it("leaves memory_forget under the agent's own approval policy", () => {
    expect(served).toContain("memory_forget");
    expect(MEMORY_PREAPPROVED_TOOLS as readonly string[]).not.toContain("memory_forget");
  });

  it("uses the server name the agents register", () => {
    expect(MEMORY_MCP_SERVER).toBe("antgrid-memory");
  });
});
