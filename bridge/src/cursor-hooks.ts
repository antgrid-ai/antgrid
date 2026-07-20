import { hookShellCommand, type HookCommand } from "./hook-command";

export interface ManagedCursorCommands {
  sessionStart: string;
  stop: string;
}

export function cursorHookCommand(
  command: HookCommand,
  event: "session-start" | "stop",
): string {
  // No call operator: cursor-agent parses this command string into an argv and
  // spawns the first token as the executable (cross-spawn; the Windows shell is
  // cmd.exe, never PowerShell) — it does NOT wrap it in a `& <command>`
  // invocation. A leading `&` would be the program name — a bogus executable to
  // the tokenizer and a syntax error to cmd.exe ("& was unexpected at this
  // time") — so it must be omitted.
  return hookShellCommand(command, "cursor", event, { callOperator: false });
}

// The two managed `.cursor/hooks.json` command strings for a given bridge
// binary. Single source of truth so the per-spawn augmenter and the external
// installer/uninstaller can't drift.
export function managedCursorCommands(command: HookCommand): ManagedCursorCommands {
  return {
    sessionStart: cursorHookCommand(command, "session-start"),
    stop: cursorHookCommand(command, "stop"),
  };
}

function normalized(command: unknown): string {
  return typeof command === "string" ? command.replace(/\\/g, "/") : "";
}

// Basename of the first (quoted) token of a managed command — the bridge binary
// (`antgrid-bridge`, a locally-built `dist/antgrid`, or `index.ts` in dev). Used
// to recognise our own stale entries after a binary rename/relocation without
// hardcoding a single expected name.
function binaryToken(current: string): string {
  // hookShellCommand always quotes the binary — double quotes on Windows,
  // single on POSIX — so an install path with spaces (Windows' default
  // `C:/Program Files/...`) must be read whole, not truncated at the first
  // space. Match a "..."/'...' quoted token, else an unquoted run.
  const match = normalized(current).match(/^\s*(?:"([^"]*)"|'([^']*)'|([^\s]+))/);
  const first = match ? (match[1] ?? match[2] ?? match[3] ?? "") : "";
  return first.split("/").pop() ?? "";
}

function isManagedCommand(
  command: unknown,
  event: "sessionStart" | "stop",
  current: string,
): boolean {
  if (command === current) return true;
  const value = normalized(command);
  const legacyScript = event === "sessionStart" ? "post-title.js" : "post-notify.js";
  if (
    /^\s*node(?:\.exe)?\s+/i.test(value) &&
    value.includes(`/plugin/cursor/${legacyScript}`)
  ) {
    return true;
  }
  const hookEvent = event === "sessionStart" ? "session-start" : "stop";
  const token = binaryToken(current);
  return (
    (value.includes("antgrid-bridge") ||
      value.includes("/bridge/src/index.ts") ||
      // Junk minted by pre-isolation bridge test runs: Bun.main under `bun
      // test` is the TEST FILE, so the baked command was `<bun> <x.test.ts>
      // hook cursor <event>`. Recognize so real spawns replace them.
      value.includes(".test.ts") ||
      (token.length > 0 && value.includes(token))) &&
    value.includes("hook") &&
    value.includes("cursor") &&
    value.includes(hookEvent)
  );
}

export function replaceManagedCursorHookEntries(
  data: any,
  commands: ManagedCursorCommands,
): any | null {
  const original = JSON.stringify(data);
  const next: any =
    data && typeof data === "object" && !Array.isArray(data)
      ? { ...data, hooks: { ...(data.hooks ?? {}) } }
      : { hooks: {} };
  for (const event of ["sessionStart", "stop"] as const) {
    const current = commands[event];
    const existing = Array.isArray(next.hooks[event]) ? next.hooks[event] : [];
    const preserved = existing.filter(
      (entry: any) => !isManagedCommand(entry?.command, event, current),
    );
    next.hooks[event] = [...preserved, { command: current, timeout: 5 }];
  }

  if (JSON.stringify(next) === original) return null;
  if (next.version === undefined) next.version = 1;
  return next;
}

export function removeManagedCursorHookEntries(
  data: any,
  commands: ManagedCursorCommands,
): any {
  const next: any =
    data && typeof data === "object" && !Array.isArray(data)
      ? { ...data, hooks: { ...(data.hooks ?? {}) } }
      : {};
  for (const event of ["sessionStart", "stop"] as const) {
    if (!Array.isArray(next.hooks?.[event])) continue;
    next.hooks[event] = next.hooks[event].filter(
      (entry: any) => !isManagedCommand(entry?.command, event, commands[event]),
    );
    if (next.hooks[event].length === 0) delete next.hooks[event];
  }
  if (next.hooks && Object.keys(next.hooks).length === 0) delete next.hooks;
  return next;
}
