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
 * Best-effort local-store availability hint for mode switching and fork checks.
 * Launches pass saved identities directly to the provider: this hint must never
 * erase an identity or select a fresh conversation.
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

/**
 * Does the agent POSITIVELY disown this id — not "we couldn't find it", but
 * "the store answered, and this is not one of mine"? The only verdict a caller
 * may refuse work on, and narrower than `!sessionResumable(...)` twice over.
 *
 * It splits from that function on the MIDDLE answer: a store that cannot be
 * read is `false` here and `true` there, which is the whole point of keeping
 * the spec's verdict tri-state. And it answers `false` for every agent that has
 * not claimed `sessionStoreIsAuthoritative` — a store the resume flag does not
 * itself consult can be stale without the conversation being gone.
 *
 * Deliberately id-only, with no transcript-path branch. The path an agent posts
 * lags the conversation it names (claude's SessionStart fires before the file
 * exists), so a path that isn't there yet is not evidence of anything; a caller
 * refusing on it would reject the very first report of a live session.
 */
export function agentSessionGone(args: {
  tool: string;
  agentSessionId: string;
  codexHome?: string;
  copilotHome?: string;
}): boolean {
  const spec = agentSpec(args.tool);
  if (!spec?.sessionStoreIsAuthoritative) return false;
  return spec.resumable?.({
    agentSessionId: args.agentSessionId,
    codexHome: args.codexHome,
    copilotHome: args.copilotHome,
  }) === false;
}
