import { readLastOpencodeMessages } from "./db-read";
import type { TranscriptOpts } from "../types";

/** No transcriptPath out: a SQLite DB is not a followable file hint for a judge.
 *  The reader is synchronous on purpose (see ./db-read.ts). */
export async function readTranscript(opts: TranscriptOpts): Promise<{ msgs: string[]; transcriptPath?: string }> {
  if (!opts.agentSessionId) return { msgs: [] };
  return { msgs: readLastOpencodeMessages(opts.agentSessionId, opts.maxMsgs, opts.opencodeDbPath) };
}
