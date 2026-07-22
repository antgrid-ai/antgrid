import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { codexThreadExistsSync, copilotSessionExistsSync } from "./title-resolver";

/**
 * Argv appended to a tool's base launch args to resume a specific agent-native
 * conversation. Keyed by the KNOWN_AGENTS registry key. Tools without verified
 * resume-by-id support return [] (fresh start). See the per-agent resume table
 * in docs/superpowers/plans/2026-06-23-agent-session-resume.md.
 *
 * Codex is a SUBCOMMAND form (`codex [global -c flags] resume <uuid>`): the
 * caller appends this AFTER the global `-c` flags it already injects, so the
 * ordering (globals → subcommand) is preserved.
 */
export function resumeArgv(tool: string, agentSessionId: string): string[] {
  switch (tool) {
    case "claude-code":
    case "qwen":
      return ["--resume", agentSessionId];
    case "gemini":
      // resolveSession matches UUID-first (sessionUtils.ts:471-477) — verified.
      return ["--resume", agentSessionId];
    case "opencode":
      return ["--session", agentSessionId];
    case "codex":
      return ["resume", agentSessionId];
    case "github-copilot":
      // Copilot's optional-value --resume drops a space-separated value.
      return [`--resume=${agentSessionId}`];
    case "cursor-agent":
      return ["--resume", agentSessionId];
    default:
      return [];
  }
}

/**
 * Best-effort, SYNCHRONOUS pre-flight: would resuming this stored id land in a
 * real conversation? Returns true unless it can POSITIVELY confirm the session
 * is gone — false negatives would silently break resume, so we only refuse when
 * sure. Keeps SessionManager.start() synchronous (existsSync / bun:sqlite are
 * sync).
 *   - transcript path present (claude/gemini/qwen) → exact existsSync check.
 *   - codex (no path posted) → query the threads table; optimistic if the DB is
 *     undeterminable.
 *   - opencode and everything else → optimistic (the agent's own bad-id handling
 *     is the backstop).
 */
export function sessionResumable(args: {
  tool: string;
  agentSessionId: string;
  agentTranscriptPath?: string;
  codexHome?: string;
  copilotHome?: string;
}): boolean {
  if (args.agentTranscriptPath) return existsSync(args.agentTranscriptPath);
  if (args.tool === "codex") {
    const home = args.codexHome ?? join(homedir(), ".codex");
    const exists = codexThreadExistsSync(args.agentSessionId, home);
    return exists === null ? true : exists; // null = undeterminable → optimistic
  }
  if (args.tool === "github-copilot") {
    const home = args.copilotHome ?? process.env.COPILOT_HOME ?? join(homedir(), ".copilot");
    const exists = copilotSessionExistsSync(args.agentSessionId, home);
    return exists === null ? true : exists;
  }
  return true;
}
