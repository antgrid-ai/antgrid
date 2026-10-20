import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { z } from "zod";
import { atomicWriteFile } from "../../atomic-file";
import { hookShellCommand } from "../../hook-command";
import { logger } from "../../host";
import { compact, parseOrEmpty, titlePost, type HookInvocation, type HookPost } from "../hook-posts";
import { NO_INJECTION } from "../launch-inject";
import { runningUnderTest } from "../test-runner";
import type { HookInjectCtx, HookPostCtx, LaunchAugmentation } from "../types";

const begin = "# BEGIN ANTGRID KIMI IDENTITY";
const end = "# END ANTGRID KIMI IDENTITY";
const Config = z.object({ hooks: z.array(z.unknown()).optional() }).passthrough();
const withoutHooks = ({ hooks: _hooks, ...rest }: z.infer<typeof Config>) => rest;
const equal = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);
const HEADER = /^[ \t]*\[/;
const HOOKS_TABLE = /^[ \t]*\[\[[ \t]*hooks[ \t]*\]\][ \t]*(?:#.*)?$/;
const BLANK_OR_COMMENT = /^[ \t]*(?:#.*)?$/;
const EMPTY_INLINE_HOOKS = /^hooks\s*=\s*\[\s*\][ \t]*(?:#[^\r\n]*)?\r?$/m;

// Ours by what it runs rather than by the markers around it: Kimi's own config
// writer drops comments, and a relocated bridge leaves a command naming the
// old binary, which Kimi would otherwise keep running beside the new one.
function isManaged(hook: unknown): boolean {
  const { event, command } = (hook ?? {}) as { event?: unknown; command?: unknown };
  return event === "SessionStart" && typeof command === "string"
    && /(["'])kimi\1\s+(["'])session-start\2\s*$/.test(command);
}

/** `text` without each `[[hooks]]` table `drop` claims, or the marker lines around it. */
function withoutHooksTables(text: string, drop: (hook: unknown) => boolean): string {
  const lines = text.split(/(?<=\n)/);
  const line = (i: number) => lines[i]!.replace(/\r?\n$/, "");
  const kept: string[] = [];
  for (let i = 0; i < lines.length;) {
    if (!HOOKS_TABLE.test(line(i))) {
      kept.push(lines[i++]!);
      continue;
    }
    let last = i + 1;
    while (last < lines.length && !HEADER.test(line(last))) last++;
    while (last > i + 1 && BLANK_OR_COMMENT.test(line(last - 1))) last--;
    let hooks: unknown[] | undefined;
    // A header-shaped line inside a multi-line string does not parse alone.
    try { hooks = Config.parse(Bun.TOML.parse(lines.slice(i, last).join(""))).hooks; } catch { hooks = undefined; }
    if (hooks?.length === 1 && drop(hooks[0])) {
      if (kept.at(-1)?.trim() === begin) kept.pop();
      if (last < lines.length && line(last).trim() === end) last++;
    } else {
      kept.push(...lines.slice(i, last));
    }
    i = last;
  }
  return kept.join("");
}

/** The `hooks` array a root-level inline `hooks = [...]` declares, if any. */
const inlineHooks = (text: string) => Config.parse(Bun.TOML.parse(withoutHooksTables(text, () => true))).hooks;

export function inject({ kimiHome, hookCommand }: HookInjectCtx): LaunchAugmentation {
  // Kimi exposes only user-level hooks.
  if (kimiHome === undefined && runningUnderTest()) return NO_INJECTION;
  const path = join(kimiHome ?? process.env.KIMI_CODE_HOME ?? join(homedir(), ".kimi-code"), "config.toml");
  try {
    const original = existsSync(path) ? readFileSync(path, "utf8") : "";
    const before = Config.parse(Bun.TOML.parse(original));
    let base = withoutHooksTables(original, isManaged);
    // Kimi's TOML parser rejects an inline `hooks = [...]` beside `[[hooks]]`
    // tables, where Bun's merges the two, so only an empty one can give way.
    const inline = inlineHooks(base);
    if (inline?.length) throw new Error("Cannot add a hook table beside an inline Kimi hooks array");
    if (inline) base = base.replace(EMPTY_INLINE_HOOKS, "");
    // Kimi's hook runner uses Node shell:true (cmd.exe on Windows), not
    // PowerShell. Every kimi on the machine runs this hook and waits for it, so
    // outside an Antgrid terminal, where its post would be dropped anyway, the
    // shell skips starting the bridge binary at all.
    const run = hookShellCommand(hookCommand, "kimi", "session-start", { callOperator: false });
    const command = process.platform === "win32"
      ? `if defined ANTGRID_TERMINAL_ID ${run}`
      : `test -z "$ANTGRID_TERMINAL_ID" || ${run}`;
    const block = `${begin}\n[[hooks]]\nevent = "SessionStart"\ncommand = ${JSON.stringify(command)}\ntimeout = 5\n${end}\n`;
    const next = `${base.trimEnd()}\n\n${block}`;
    const after = Config.parse(Bun.TOML.parse(next));
    if (inlineHooks(next) !== undefined
      || !equal(withoutHooks(before), withoutHooks(after))
      || !equal(after.hooks, [...(before.hooks ?? []).filter((hook) => !isManaged(hook)), { event: "SessionStart", command, timeout: 5 }])) {
      throw new Error("Kimi hook injection would change user configuration");
    }
    if (original !== next) atomicWriteFile(path, next, { fileMode: 0o600 });
    return { args: [], env: {}, observation };
  } catch (error) {
    logger.warn("Could not install Kimi session identity hook: %s", error);
    return NO_INJECTION;
  }
}

export const events = ["session-start"] as const;
export const turnBoundaryEvents = { start: [], end: [] } as const;
export const posts = ["/session-title"] as const;
export const observation = { notifications: false, titles: true, handler: false, turnStart: false, turnEnd: false, hookAlive: false } as const;
const Payload = z.object({ session_id: z.string().nullish(), session_title: z.string().nullish() });

export async function toPosts(invocation: HookInvocation, { port, terminalId, readStdin }: HookPostCtx): Promise<HookPost[]> {
  if (invocation.event !== "session-start" || !terminalId) return [];
  const payload = parseOrEmpty(Payload, await readStdin());
  return payload ? compact([titlePost(port, terminalId, payload.session_id, "kimi", payload.session_title ? { title: payload.session_title } : {})]) : [];
}
