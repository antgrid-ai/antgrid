// Thin accessors over the agent registry (./agents/registry). The data itself
// lives there; these exist so call sites that only need one field don't have to
// know about AgentKey widening or the "unknown tool" fallbacks.

import { homedir } from "node:os";
import { join } from "node:path";
import { AGENTS, agentSpec } from "./agents/registry";
import { resolveAbDir } from "./antgrid-dir";

function expand(p: string | null): string | null {
  if (!p) return p;
  if (p.startsWith("~")) return join(homedir(), p.slice(2));
  return p;
}

export interface ResolvedAgent {
  bin: string;
  hookDir: string | null;
  /** Default launch argv for this tool (see AgentSpec.args). Never null. */
  args: string[];
}

export function resolveAgent(tool: string): ResolvedAgent {
  const entry = agentSpec(tool);
  if (!entry) throw new Error(`unknown agent: ${tool}`);
  return { bin: entry.bin, hookDir: expand(entry.hookDir), args: entry.args ?? [] };
}

export function listKnownTools(): string[] {
  return Object.keys(AGENTS);
}

/**
 * Per-agent launch environment. Separate from `resolveAgent` (which stays
 * pure) because some agents need a generated config file on disk before
 * launch. Only applied on the registry-key launch path (mirrors how
 * `AgentSpec.args` is applied), not the custom-command / antgrid.yaml paths.
 *
 * Some agents won't emit terminal notifications until a config enables them.
 * We can't edit the user's own config, so we point a per-agent env var at a
 * bridge-owned file that flips the relevant default. Each injected file merges
 * BELOW the user's config (opencode/kilo: TUI_CONFIG precedence), so an
 * explicit user opt-out still wins.
 * Driving the actual focus/blur state is the app+engine's job (DEC 1004) — see
 * the per-agent notes in AGENTS for which agents need injection vs. ride
 * the default-blur alone.
 *
 * Two safety rails (see `injectConfig`): if the user already set the env var we
 * leave it alone (their file wins), and if writing our file fails we omit the
 * var rather than aborting the launch.
 */
export function resolveAgentEnv(
  tool: string,
  abDir: string = resolveAbDir(),
): Record<string, string> {
  return agentSpec(tool)?.env?.({ abDir }) ?? {};
}

export function notificationSourceFor(tool: string): "plugin" | "osc" {
  return agentSpec(tool)?.notificationSource ?? "osc";
}

export function titleSourceFor(tool: string): "structured" | "osc" {
  return agentSpec(tool)?.titleSource ?? "osc";
}

/**
 * Whether to mute the terminal's OSC notification scanner for one spawn.
 *
 * Two signals, and both have to agree: the spec's `notificationSource` declares
 * the INTENT ("this agent notifies through an injected plugin"), and the spawn's
 * `LaunchAugmentation.notificationsInjected` reports the OUTCOME of actually
 * installing it.
 *
 * An absent outcome is not "unknown, assume the worst": it means that agent's
 * injection has no per-spawn filesystem step that could fail, so intent stands
 * alone. Only an explicit `false` — a materialization we attempted and could not
 * complete — re-opens the scanner, so a session is never left silently muted
 * with no working notification source at all.
 */
export function suppressesOscNotifications(
  tool: string,
  notificationsInjected: boolean | undefined,
): boolean {
  return notificationSourceFor(tool) === "plugin" && notificationsInjected !== false;
}

/**
 * Same rule for the title signal. It reads the notification outcome rather than
 * a second flag because for every "structured" titleSource agent the
 * title-correlation hook ships in the SAME materialized plugin/hooks file as the
 * notification hook — one write, one success/failure signal.
 */
export function suppressesOscTitle(
  tool: string,
  notificationsInjected: boolean | undefined,
): boolean {
  return titleSourceFor(tool) === "structured" && notificationsInjected !== false;
}
