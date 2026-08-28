import { forkHandoffOrTerminal } from "../fork-handoff";
import type { ForkHandoffOpts } from "../types";
import { readTranscript } from "./transcript";

/** `opencode --session <id> --fork` clones instead of resuming the source. */
export function opencodeNativeForkArgs(sessionId: string): string[] {
  return ["--session", sessionId, "--fork"];
}

/** OpenCode's adapter reads the session rows from its local SQLite store. */
export async function opencodeForkHandoff(opts: ForkHandoffOpts): Promise<string> {
  return forkHandoffOrTerminal("OpenCode", (await readTranscript(opts)).msgs, opts);
}
