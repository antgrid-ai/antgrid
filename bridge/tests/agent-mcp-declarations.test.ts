// Which agents are pointed at the Antgrid MCP server, pinned per key. Typed as
// a total record so ADDING an AgentKey is a compile error until someone decides
// — the same shape (and the same purpose) as the `posts` table in
// agent-hook-declarations.test.ts. An MCP entry reaches further than a hook for
// the agents whose only carrier is a machine-global config, so silence must
// never be the default an omission falls into.
import { describe, expect, test } from "bun:test";
import { AGENTS } from "../src/agent-runtime";
import type { AgentKey } from "../../packages/antgrid-agents/src/agents/types";

// Read off the registry, never hand-listed: a table total over `AgentKey`
// forces the DECISION for a new agent, and only iterating the registry checks
// that decision against what the new agent actually declares.
const AGENT_KEYS = Object.keys(AGENTS) as AgentKey[];

/** Compile-time completeness: a table missing a key fails to typecheck. */
type PerAgent<T> = Record<AgentKey, T>;

describe("mcp profile declarations", () => {
  test("only the agents with a measured per-spawn mechanism declare mcp", () => {
    const declares: PerAgent<boolean> = {
      // `--mcp-config=<file>`, measured against the installed CLI.
      "claude-code": true,
      // `-c mcp_servers.*`, measured via `codex mcp get antgrid --json`.
      codex: true,
      // `OPENCODE_CONFIG_CONTENT` is deep-merged over every user layer and the
      // child inherits our env (measured, opencode 1.18.35).
      opencode: true,
      // `--plugin-dir` with a `.mcp.json` plugin; cursor strips the child's env
      // but expands `${env:VAR}` in the entry (measured, 2026.10.01).
      "cursor-agent": true,
      // `--additional-mcp-config @<file>`, session-only (measured, 1.0.93).
      "github-copilot": true,
      // Its only carrier is the machine-global `mcp_config.json`: an unrelated
      // run would hold a live server against whichever core started last.
      antigravity: false,
      // Same mechanism as opencode, under `KILO_CONFIG_CONTENT` (measured, 7.8.8).
      kilo: true,
      // Only carrier is the machine-global `~/.kimi/mcp.json`, same hazard.
      kimi: false,
      // Inherits no env into MCP children and expands no variables, so the
      // server could not learn its caller; the only carrier is also global.
      "mistral-vibe": false,
    };
    for (const key of AGENT_KEYS) {
      expect(!!AGENTS[key].mcp).toBe(declares[key]);
    }
  });
});
