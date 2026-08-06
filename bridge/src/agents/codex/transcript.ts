import { findCodexRolloutPath, readLastCodexMessages } from "./rollout-read";
import type { TranscriptOpts } from "../types";

/** Codex posts only a thread id, so the rollout file has to be discovered first.
 *  The discovered path is followable and comes back with the messages. */
export async function readTranscript(opts: TranscriptOpts): Promise<{ msgs: string[]; transcriptPath?: string }> {
  if (!opts.agentSessionId) return { msgs: [] };
  const path = await findCodexRolloutPath(opts.agentSessionId, opts.codexHome);
  if (!path) return { msgs: [] };
  return { msgs: await readLastCodexMessages(path, opts.maxMsgs), transcriptPath: path };
}
