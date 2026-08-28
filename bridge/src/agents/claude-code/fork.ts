import { forkHandoffOrTerminal } from "../fork-handoff";
import type { ForkHandoffOpts } from "../types";
import { messageText, readTranscript } from "./transcript";
import { readClaudeTranscript } from "./transcript-read";

/** `--fork-session` makes Claude create a new conversation instead of resuming
 * the source. Verified against the interactive CLI's resume syntax. */
export function claudeNativeForkArgs(sessionId: string): string[] {
  return ["--resume", sessionId, "--fork-session"];
}

/** Claude hook transcripts are JSONL files, normalized by its reader. */
export async function claudeForkHandoff(opts: ForkHandoffOpts): Promise<string> {
  const transcript = await readTranscript(opts);
  if (transcript.msgs.length > 0) return forkHandoffOrTerminal("Claude Code", transcript.msgs, opts);
  // Chat-mode Claude sessions report an SDK id rather than a hook path. The
  // SDK itself exposes no read API, but the same local JSONL store backs its
  // cold-resume replay, so use that verified reader before refusing the fork.
  const entries = opts.agentSessionId
    ? await readClaudeTranscript(opts.projectPath, opts.agentSessionId)
    : [];
  return forkHandoffOrTerminal(
    "Claude Code",
    entries.map((entry) => messageText(entry?.message?.content) ?? ""),
    opts,
  );
}
