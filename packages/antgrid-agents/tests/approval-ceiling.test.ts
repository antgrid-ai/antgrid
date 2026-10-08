// The scheduler's approval ceiling reads `defaultApprovalGated` off the
// registry, and a missing fact means gated, so the table below is the only
// place an agent is ever called ungated. Changing a row is a security decision.
import { describe, expect, it } from "bun:test";
import { AGENTS, agentSpec } from "../src/agents/registry";

const EXPECTED: Record<string, boolean> = {
  "claude-code": true,
  codex: true,
  opencode: false,
  "cursor-agent": true,
  "github-copilot": true,
  antigravity: true,
  kilo: true,
  kimi: true,
  "mistral-vibe": true,
};

describe("defaultApprovalGated", () => {
  it("is declared, as a boolean, by every built-in agent", () => {
    for (const [id, spec] of Object.entries(AGENTS)) {
      expect(typeof spec.defaultApprovalGated, id).toBe("boolean");
    }
  });

  it("matches the audited table", () => {
    expect(Object.fromEntries(Object.entries(AGENTS).map(([id, spec]) => [id, spec.defaultApprovalGated]))).toEqual(EXPECTED);
  });

  it("is readable through the lookup the bridge uses", () => {
    expect(agentSpec("opencode")?.defaultApprovalGated).toBe(false);
    expect(agentSpec("claude-code")?.defaultApprovalGated).toBe(true);
    expect(agentSpec("not-an-agent")).toBeUndefined();
  });
});
