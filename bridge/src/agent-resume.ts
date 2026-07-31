import { existsSync } from "node:fs";
import { agentSpec } from "./agents/registry";
import type { ResumableArgs } from "./agents/types";

/**
 * Argv appended to a tool's base launch args to resume a specific agent-native
 * conversation. Keyed by the AGENTS registry key. Tools without verified
 * resume-by-id support return [] (fresh start). See the per-agent resume table
 * in docs/superpowers/plans/2026-06-23-agent-session-resume.md.
 *
 * Codex is a SUBCOMMAND form (`codex [global -c flags] resume <uuid>`): the
 * caller appends this AFTER the global `-c` flags it already injects, so the
 * ordering (globals → subcommand) is preserved.
 */
export function resumeArgv(tool: string, agentSessionId: string): string[] {
  return agentSpec(tool)?.resume(agentSessionId) ?? [];
}

/**
 * Best-effort, SYNCHRONOUS pre-flight: would resuming this stored id land in a
 * real conversation? Returns true unless the agent can POSITIVELY confirm the
 * session is gone — a false negative silently starts a fresh conversation, so we
 * only refuse when sure. Kept sync (existsSync / bun:sqlite are) so
 * SessionManager.start() can stay sync.
 *
 * The transcript-path check sits AHEAD of the per-agent dispatch because it is
 * keyed on the shape of the args, not on the tool: whichever agent posted a
 * path is answered by that path. Only claude-code's hooks post one today, but
 * folding it into claude's spec would answer the next agent that starts posting
 * one optimistically and silently.
 *
 * The wire field is `agentTranscriptPath` and the spec field is
 * `transcriptPath` (mirroring TitleArgs) — drop the mapping below and every
 * claude session reads as resumable.
 */
export function sessionResumable(args: {
  tool: string;
  agentSessionId: string;
  agentTranscriptPath?: string;
  codexHome?: string;
  copilotHome?: string;
}): boolean {
  const forSpec: ResumableArgs = {
    agentSessionId: args.agentSessionId,
    transcriptPath: args.agentTranscriptPath,
    codexHome: args.codexHome,
    copilotHome: args.copilotHome,
  };
  if (forSpec.transcriptPath) return existsSync(forSpec.transcriptPath);
  return agentSpec(args.tool)?.resumable?.(forSpec) ?? true;
}
