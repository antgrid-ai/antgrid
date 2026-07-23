import { mkdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { logger } from "./logger";
import { resolveHookCommand, type HookCommand } from "./hook-command";
import { resolveAbDir } from "./antgrid-dir";

export interface KnownAgent {
  bin: string;
  hookDir: string | null;
  /**
   * Default argv prepended whenever we launch this tool by registry key (not on
   * the custom-command or antgrid.yaml fallback paths). Used to coerce an agent
   * into emitting terminal notifications our scanner can see, without asking the
   * user to edit their own config.
   */
  args?: string[];
  /** Where this agent's notifications come from. "plugin" = injected hook/plugin
   *  POSTs to /notify (richer, intent-aware) and the OSC scanner is suppressed
   *  for its terminals; "osc" = rely on the terminal OSC scanner. */
  notificationSource: "plugin" | "osc";
  /** Where this agent's session NAME comes from. "structured" = a hook/plugin
   *  correlates the terminal to an on-disk session file (or, for opencode,
   *  pushes the title inline) and the OSC-2 title scanner is suppressed for its
   *  terminals; "osc" = rely on the terminal's OSC-0/2 window-title escapes.
   *  Deliberately NOT the same set as notificationSource: cursor-agent has
   *  plugin notifications but no structured title source (title-resolver.ts has
   *  no cursor-agent case), so gating its OSC title would kill auto-naming;
   *  github-copilot has a structured title source (materializeCopilotPlugin's
   *  sessionStart hook) despite osc-sourced notifications. See
   *  [[two-perspawn-injection-systems-separate]]-style split — these are
   *  independently-toggled signals, not one flag. */
  titleSource: "structured" | "osc";
}

export const KNOWN_AGENTS: Record<string, KnownAgent> = {
  "claude-code":    { bin: "claude",   hookDir: "~/.claude/hooks",   notificationSource: "plugin", titleSource: "structured" },
  "codex":          { bin: "codex",    hookDir: "~/.codex/hooks",    notificationSource: "plugin", titleSource: "structured" },
  "opencode":       { bin: "opencode", hookDir: "~/.opencode/hooks", notificationSource: "plugin", titleSource: "structured" },
  "cursor-agent":   { bin: "cursor-agent", hookDir: null,            notificationSource: "plugin", titleSource: "osc" },
  "github-copilot": { bin: "copilot",  hookDir: null,                notificationSource: "osc",    titleSource: "structured" },
  // opencode fork: same attention gating (default-off + focus-blur). Enabled
  // via KILO_TUI_CONFIG injection (see resolveAgentEnv); the app's default-blur
  // (DEC 1004) supplies the blur it waits on.
  "kilo":           { bin: "kilo",     hookDir: null,                notificationSource: "osc",    titleSource: "osc" },
  // Signals only with a bare terminal bell (no OSC 9/777). Since the bell now
  // rings audibly instead of raising a desktop notification, kimi is heard, not
  // notified — no OSC notification source exists to coerce it into.
  "kimi":           { bin: "kimi",     hookDir: null,                notificationSource: "osc",    titleSource: "osc" },
  // Textual TUI: notifications default ON, fails CLOSED on Textual focus
  // (DEC 1004-derived), so the default-blur drives it — no injection.
  "mistral-vibe":   { bin: "vibe",     hookDir: null,                notificationSource: "osc",    titleSource: "osc" },
};

function expand(p: string | null): string | null {
  if (!p) return p;
  if (p.startsWith("~")) return join(homedir(), p.slice(2));
  return p;
}

export interface ResolvedAgent {
  bin: string;
  hookDir: string | null;
  /** Default launch argv for this tool (see KnownAgent.args). Never null. */
  args: string[];
}

export function resolveAgent(tool: string): ResolvedAgent {
  const entry = KNOWN_AGENTS[tool];
  if (!entry) throw new Error(`unknown agent: ${tool}`);
  return { bin: entry.bin, hookDir: expand(entry.hookDir), args: entry.args ?? [] };
}

export function listKnownTools(): string[] {
  return Object.keys(KNOWN_AGENTS);
}

/**
 * Per-agent launch environment. Separate from `resolveAgent` (which stays
 * pure) because some agents need a generated config file on disk before
 * launch. Only applied on the registry-key launch path (mirrors how
 * `KnownAgent.args` is applied), not the custom-command / antgrid.yaml paths.
 *
 * Some agents won't emit terminal notifications until a config enables them.
 * We can't edit the user's own config, so we point a per-agent env var at a
 * bridge-owned file that flips the relevant default. Each injected file merges
 * BELOW the user's config (opencode/kilo: TUI_CONFIG precedence), so an
 * explicit user opt-out still wins.
 * Driving the actual focus/blur state is the app+engine's job (DEC 1004) — see
 * the per-agent notes in KNOWN_AGENTS for which agents need injection vs. ride
 * the default-blur alone.
 *
 * Two safety rails (see `injectConfig`): if the user already set the env var we
 * leave it alone (their file wins), and if writing our file fails we omit the
 * var rather than aborting the launch.
 */
export function resolveAgentEnv(
  tool: string,
  abDir: string = resolveAbDir(),
  hookCommand: HookCommand = resolveHookCommand(),
): Record<string, string> {
  switch (tool) {
    case "opencode":
      return injectConfig("OPENCODE_TUI_CONFIG", abDir, "opencode-tui.json", {
        attention: { enabled: true },
      });
    case "kilo":
      return injectConfig("KILO_TUI_CONFIG", abDir, "kilo-tui.json", {
        attention: { enabled: true },
      });
    default:
      return {};
  }
}

export function notificationSourceFor(tool: string): "plugin" | "osc" {
  return KNOWN_AGENTS[tool]?.notificationSource ?? "osc";
}

export function titleSourceFor(tool: string): "structured" | "osc" {
  return KNOWN_AGENTS[tool]?.titleSource ?? "osc";
}

/**
 * Builds the launch-env entry pointing `envVar` at a bridge-owned config file.
 * Returns an empty env (no injection) when either the user already set
 * `envVar` themselves — their value flows through unchanged from `process.env`,
 * so we must not clobber it — or the config file can't be written, in which
 * case the agent still launches (just without the notification default).
 */
function injectConfig(
  envVar: string,
  abDir: string,
  filename: string,
  content: unknown,
): Record<string, string> {
  if (process.env[envVar]) return {};
  const path = ensureJsonConfig(abDir, filename, content);
  return path ? { [envVar]: path } : {};
}

/**
 * Writes (idempotently) a bridge-owned agent config file and returns its path,
 * or null if the write fails (read-only dir, full disk) so the caller can spawn
 * without the env instead of aborting the launch.
 */
function ensureJsonConfig(abDir: string, filename: string, content: unknown): string | null {
  const dir = join(abDir, "agents");
  const path = join(dir, filename);
  try {
    mkdirSync(dir, { recursive: true });
    writeFileSync(path, JSON.stringify(content, null, 2));
    return path;
  } catch (err) {
    logger.warn(`failed to write agent config ${path}: ${err}`);
    return null;
  }
}
