import { existsSync, readFileSync } from "node:fs";
import { z } from "zod";
import { atomicWriteFile } from "../atomic-file";

// Shared by the agents whose hooks live in a user-level TOML file as `[[hooks]]`
// tables (Kimi, Mistral Vibe). Both read it with a strict parser that rejects
// an inline `hooks = [...]` beside the tables, and both run every user's hook,
// so the merge must change nothing but our own table.

const Config = z.object({ hooks: z.array(z.unknown()).optional() }).passthrough();
const withoutHooks = ({ hooks: _hooks, ...rest }: z.infer<typeof Config>) => rest;
const equal = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);
const HEADER = /^[ \t]*\[/;
const HOOKS_TABLE = /^[ \t]*\[\[[ \t]*hooks[ \t]*\]\][ \t]*(?:#.*)?$/;
const BLANK_OR_COMMENT = /^[ \t]*(?:#.*)?$/;
const EMPTY_INLINE_HOOKS = /^hooks\s*=\s*\[\s*\][ \t]*(?:#[^\r\n]*)?\r?$/m;

/** `text` without each `[[hooks]]` table `drop` claims, or the marker lines around it. */
function withoutHooksTables(text: string, begin: string, end: string, drop: (hook: unknown) => boolean): string {
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
const inlineHooks = (text: string, begin: string, end: string) =>
  Config.parse(Bun.TOML.parse(withoutHooksTables(text, begin, end, () => true))).hooks;

export interface ManagedTomlHook {
  path: string;
  begin: string;
  end: string;
  /** Recognizes a previous install by what it runs, since an agent's own config
   * writer may drop the marker comments and a relocated bridge changes the command. */
  isManaged: (hook: unknown) => boolean;
  /** Written in this order; every value must be a TOML-compatible JSON scalar. */
  fields: Record<string, string | number>;
  agent: string;
}

/** Throws rather than write when the merge would alter anything but our table. */
export function installManagedTomlHook({ path, begin, end, isManaged, fields, agent }: ManagedTomlHook): void {
  const original = existsSync(path) ? readFileSync(path, "utf8") : "";
  const before = Config.parse(Bun.TOML.parse(original));
  let base = withoutHooksTables(original, begin, end, isManaged);
  const inline = inlineHooks(base, begin, end);
  if (inline?.length) throw new Error(`Cannot add a hook table beside an inline ${agent} hooks array`);
  if (inline) base = base.replace(EMPTY_INLINE_HOOKS, "");
  const body = Object.entries(fields).map(([key, value]) => `${key} = ${JSON.stringify(value)}\n`).join("");
  const next = `${base.trimEnd()}\n\n${begin}\n[[hooks]]\n${body}${end}\n`;
  const after = Config.parse(Bun.TOML.parse(next));
  if (inlineHooks(next, begin, end) !== undefined
    || !equal(withoutHooks(before), withoutHooks(after))
    || !equal(after.hooks, [...(before.hooks ?? []).filter((hook) => !isManaged(hook)), fields])) {
    throw new Error(`${agent} hook injection would change user configuration`);
  }
  if (original !== next) atomicWriteFile(path, next, { fileMode: 0o600 });
}
