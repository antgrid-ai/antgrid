import { execFileSync } from "node:child_process";
import { bundledPluginPath } from "../../plugin-root";

export interface AntigravityCommandHook {
  type: "command";
  command: string;
  timeout: number;
}

/** Group name antigravity's hook engine tracks this entry under in the global
 *  `~/.gemini/config/hooks.json` — purely a label for hook-id logging, unrelated
 *  to any plugin-store registration (antigravity has no per-spawn hook channel,
 *  so this is a direct global-file merge, mirroring cursor-agent's approach —
 *  see `inject` in ./hooks.ts). */
export const ANTIGRAVITY_HOOK_GROUP = "antgrid-session-title";

/**
 * agy's hook runner splits its command string on whitespace with NO quote
 * handling (a quoted path reaches `node` with the literal quotes attached — see
 * antigravityHookCommand), so a script path containing a space is unusable. On
 * Windows a packaged bridge can live under a profile path that has one
 * (`C:\Users\John Doe\...`). Fold the path to its 8.3 short form, which never
 * contains a space, so the unquoted command survives. Best-effort and never
 * throws: if 8.3 generation is disabled on the volume the long path comes back
 * unchanged (no worse than before). No-op off Windows and for space-free paths.
 */
function spaceSafePath(p: string): string {
  if (process.platform !== "win32" || !p.includes(" ")) return p;
  try {
    const short = execFileSync("cmd.exe", ["/d", "/c", `for %I in ("${p}") do @echo %~sI`], {
      encoding: "utf8",
      windowsHide: true,
    }).trim();
    return short && !short.includes(" ") ? short : p;
  } catch {
    return p;
  }
}

/** Absolute path to the bundled antigravity hook script, run through
 *  spaceSafePath so a spaced Windows install path can't break agy's unquoted
 *  hook command. */
export function antigravityScriptPath(): string {
  return spaceSafePath(bundledPluginPath("antigravity", "post-title.js"));
}

/**
 * Single composed `node <script> <event>` command line — confirmed against a
 * real `agy` install that its hook runner passes no separate argv, only a bare
 * command string, so the event name must be baked in here. Deliberately NOT
 * quoted: confirmed live that agy's command parser does naive whitespace
 * splitting, not shell-style parsing — a quoted path arrives at `node` with
 * the literal `"` characters still attached (`Cannot find module 'C:\...\"C:\
 * ...post-title.js"'`), breaking module resolution entirely. Quoting can't be
 * the fix, so a spaced path is instead neutralized upstream — antigravityScriptPath
 * folds it to a space-free 8.3 short path on Windows (see spaceSafePath).
 */
export function antigravityHookCommand(scriptPath: string, event: "PreInvocation" | "Stop"): string {
  return `node ${scriptPath} ${event}`;
}

export interface AntigravityHookSpec {
  event: "PreInvocation" | "Stop";
  command: string;
}

/**
 * Returns the next hooks.json object with the given hook entries merged in
 * under ANTIGRAVITY_HOOK_GROUP (additive — any other groups/hooks already in
 * the file, from the user or another tool, are preserved), or `null` if every
 * entry is already present (caller should skip the write; idempotent). Like
 * cursor-hooks.ts's replaceManagedCursorHookEntries, but antigravity's shape has
 * no "hooks" wrapper or "version" field — event names key directly under the
 * named group (confirmed against a real `agy` install).
 */
export function mergeAntigravityHookEntries(
  data: any,
  specs: readonly AntigravityHookSpec[],
): any | null {
  const next: any = data && typeof data === "object" && !Array.isArray(data) ? { ...data } : {};
  const existingGroup = next[ANTIGRAVITY_HOOK_GROUP];
  const group: any = existingGroup && typeof existingGroup === "object" && !Array.isArray(existingGroup)
    ? { ...existingGroup }
    : {};
  let changed = false;
  for (const { event, command } of specs) {
    const existing: AntigravityCommandHook[] = Array.isArray(group[event]) ? group[event] : [];
    if (existing.some((h) => h?.command === command)) continue;
    group[event] = [...existing, { type: "command", command, timeout: 5 }];
    changed = true;
  }
  if (!changed) return null;
  next[ANTIGRAVITY_HOOK_GROUP] = group;
  return next;
}
