import { agentSpec } from "./agents/registry";

/**
 * Argv appended LAST to a tool's launch argv so its interactive TUI opens with
 * an initial user prompt already submitted. Keyed by the AGENTS registry
 * key, mirroring resumeArgv in agent-resume.ts. Tools without a VERIFIED
 * interactive initial-prompt form return [] — the session starts blank rather
 * than risking a flag misparse (github-copilot's CLI has no verified form).
 *
 * The prompt travels as its own argv element (never concatenated); callers keep
 * it discrete, or shellQuoteArg it when folding into a shell line, so user
 * quoting/newlines can't break the command or inject flags.
 *
 * A prompt that begins with a dash ("--fix the enum", "-p is broken") would be
 * eaten as a CLI flag by an agent that takes the prompt POSITIONALLY. Agents
 * whose end-of-options `--` separator is VERIFIED get it emitted right before
 * the prompt so everything after is forced to be the positional prompt. Because
 * `--` rides at the END of this argv, it lands after any resume tokens the
 * caller appends first — including codex's `resume <uuid>` subcommand
 * (`codex … resume <uuid> -- <prompt>`, verified). VERIFY a CLI's `--` handling
 * before adding it here; a separator the parser rejects is worse than the
 * misparse it guards against.
 *   - claude-code (commander) — `--` verified, fresh and after `--resume <id>`.
 *   - codex (clap) — `--` verified, fresh and after the `resume <uuid>`
 *     subcommand; codex itself suggests `-- <arg>` on the misparse.
 *   - cursor-agent (commander) — `--` verified, fresh and after its
 *     optional-value `--resume <id>` flag.
 *   - opencode — flagged `--prompt <value>`; the value token is consumed by the
 *     flag regardless of a leading dash, so no `--` is needed (or wanted).
 */
export function initialPromptArgv(tool: string, prompt: string): string[] {
  // Trimming is shared, not per-agent: an all-whitespace prompt means "start
  // blank" for every tool, and no spec should have to re-derive that.
  const p = prompt.trim();
  if (!p) return [];
  return agentSpec(tool)?.initialPrompt(p) ?? [];
}
