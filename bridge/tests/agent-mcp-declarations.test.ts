// Which agents are pointed at the Antgrid MCP server, pinned per key. Typed as
// a total record so ADDING an AgentKey is a compile error until someone decides
// — the same shape (and the same purpose) as the `posts` table in
// agent-hook-declarations.test.ts. An MCP entry reaches further than a hook for
// the agents whose only carrier is a machine-global config, so silence must
// never be the default an omission falls into.
import { describe, expect, test } from "bun:test";
import { AGENTS } from "../src/agents/registry";
import type { AgentKey } from "../src/agents/types";

// Read off the registry, never hand-listed: a table total over `AgentKey`
// forces the DECISION for a new agent, and only iterating the registry checks
// that decision against what the new agent actually declares.
const AGENT_KEYS = Object.keys(AGENTS) as AgentKey[];

/** Compile-time completeness: a table missing a key fails to typecheck. */
type PerAgent<T> = Record<AgentKey, T>;

describe("mcp profile declarations", () => {
  test("only the agents with a measured per-spawn mechanism declare mcp", () => {
    const declares: PerAgent<boolean> = {
      // `--mcp-config`, measured against the installed CLI.
      "claude-code": true,
      // `-c mcp_servers.*`, measured via `codex mcp get antgrid --json`.
      codex: true,
      // Its config injection could plausibly carry an `mcp` block, but the CLI
      // could not be run to verify the schema, and injection is conditional on
      // the user not owning OPENCODE_CONFIG.
      opencode: false,
      // Hooks are machine-global (`~/.cursor/hooks.json`) and safe only because
      // an unrelated run arrives with no ANTGRID_API_PORT and no-ops. A global
      // MCP entry has the same reach and no such no-op.
      "cursor-agent": false,
      // `--additional-mcp-config` exists, but copilot is the one agent whose
      // plugin host is known to drop our env — identity is exactly what would
      // fail, and nobody has run the probe.
      "github-copilot": false,
      // No per-spawn flag at all; its `mcpServers` live in the same global
      // config its hooks do, with the cursor-agent hazard.
      antigravity: false,
      // An opencode fork down to the env-var names, so it inherits opencode's
      // unverified status.
      kilo: false,
      kimi: false,
      "mistral-vibe": false,
    };
    for (const key of AGENT_KEYS) {
      expect(!!AGENTS[key].mcp).toBe(declares[key]);
    }
  });
});
