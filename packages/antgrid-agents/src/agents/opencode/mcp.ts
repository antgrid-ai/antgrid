import { logger } from "../../host";
import { NO_INJECTION } from "../launch-inject";
import type { LaunchAugmentation, McpInjectCtx, McpProfile } from "../types";

const log = logger.child({ component: "agent-launch" });

/**
 * opencode and its fork kilo take a whole config as JSON in `<PREFIX>_CONFIG_CONTENT`,
 * deep-merged over the user's global, project and `<PREFIX>_CONFIG` layers, so
 * this channel stays independent of the hook profile's `OPENCODE_CONFIG`, which
 * yields to a user-set value. Verified by `scripts/smoke-opencode-chat.ts`:
 * the entry connects next to a user's own servers, and the child inherits the
 * agent's environment, so no `environment` block is declared.
 *
 * A user who already sets the variable keeps every key of theirs; only
 * the `antgrid` server is added (under `mcp.servers` for native V2 configs).
 * A value that is not a JSON object cannot be merged
 * into, and replacing it would discard what they wrote, so nothing is injected.
 */
export function opencodeFamilyMcp(envVar: string): McpProfile {
  return {
    inject({ mcpCommand }: McpInjectCtx): LaunchAugmentation {
      const base = ownConfig(process.env[envVar]);
      if (!base) {
        log.warn("%s is set but is not a JSON object; not adding the antgrid MCP server", envVar);
        return NO_INJECTION;
      }
      const existing = isRecord(base.mcp) ? base.mcp : {};
      const antgrid = { type: "local", command: [mcpCommand.binary, ...mcpCommand.preargs] };
      const mcp = envVar === "OPENCODE_CONFIG_CONTENT" && ("servers" in existing || "timeout" in existing)
        ? { ...existing, servers: { ...(isRecord(existing.servers) ? existing.servers : {}), antgrid } }
        : { ...existing, antgrid };
      return { args: [], env: { [envVar]: JSON.stringify({ ...base, mcp }) } };
    },
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

function ownConfig(value: string | undefined): Record<string, unknown> | null {
  if (!value || !value.trim()) return {};
  try {
    const parsed: unknown = JSON.parse(value);
    return isRecord(parsed) ? parsed : null;
  } catch {
    return null;
  }
}
