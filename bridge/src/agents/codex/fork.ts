import { forkHandoffOrTerminal } from "../fork-handoff";
import type { ForkHandoffOpts } from "../types";
import { readTranscript } from "./transcript";

/** Codex's `fork` subcommand creates a new session from the supplied source. */
export function codexNativeForkArgs(sessionId: string): string[] {
  return ["fork", sessionId];
}

/** Codex resolves the captured thread id to its rollout before normalizing it. */
export async function codexForkHandoff(opts: ForkHandoffOpts): Promise<string> {
  return forkHandoffOrTerminal("Codex", (await readTranscript(opts)).msgs, opts);
}
