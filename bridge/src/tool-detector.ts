import { findOnPath } from "./path-probe";
export { findOnPath } from "./path-probe";
import { delimiter } from "node:path";

import { AGENTS } from "./agent-runtime";
import { agentRuntime } from "./agent-runtime";
import type { AgentRuntime } from "antgrid-agents/runtime";

export interface DetectedTool {
  tool: string;
  path: string;
  /** Carried from the registry so the app renders a name it never had to know.
   *  Sourced here, where the spec entry is already in hand, rather than looked
   *  up from the key later — a later lookup would need a fallback for a miss
   *  that cannot happen, since every key here comes from AGENTS. */
  label: string;
}

export interface DetectOptions {
  pathOverride?: string; // PATH-style string, used in tests
}

/** Memoized result of the production (no-override) probe. Installed tools don't
 *  change within a process, yet detection runs on every control-plane handshake,
 *  re-advertise, and `tools:list` — each call walks the whole PATH × AGENTS
 *  matrix (hundreds of `statSync`s). Cache the no-override result; an explicit
 *  `pathOverride` (tests) always re-probes and never reads or writes this cache. */
let cachedTools: DetectedTool[] | null = null;

export function detectInstalledTools(opts: DetectOptions = {}): DetectedTool[] {
  if (opts.pathOverride === undefined && cachedTools !== null) return cachedTools;
  const pathStr = opts.pathOverride ?? process.env.PATH ?? "";
  const dirs = pathStr.split(delimiter).filter((d) => d.length > 0);
  const out: DetectedTool[] = [];
  for (const [tool, entry] of Object.entries(AGENTS)) {
    if (!entry.cli?.bin) continue;
    const found = findOnPath(entry.cli.bin, dirs);
    if (found) out.push({ tool, path: found, label: entry.label });
  }
  if (opts.pathOverride === undefined) cachedTools = out;
  return out;
}

/** Test seam: drop the memoized no-override probe so a test that exercises the
 *  production path starts from a clean cache. */
export function resetToolDetectionCacheForTest(): void {
  cachedTools = null;
  agentRuntime.invalidateDiscovery();
}

export async function detectAvailableTools(opts: DetectOptions & { refresh?: boolean } = {}, runtime: AgentRuntime = agentRuntime) {
  const results = await Promise.all(Object.entries(runtime.agents).map(async ([tool, spec]) => {
    const discovered = await runtime.discover(tool, { path: opts.pathOverride, refresh: opts.refresh || opts.pathOverride !== undefined });
    return discovered.status === "available" ? { tool, path: discovered.executable, label: spec.label } : null;
  }));
  return results.filter((result): result is NonNullable<typeof result> => result !== null);
}
