import { forkHandoffOrTerminal } from "../fork-handoff";
import type { AgentForkSupport, ForkHandoffOpts } from "../types";
import { codexSnapshot } from "./handoff-snapshot";
import { readTranscript } from "./transcript";

/** Codex's `fork` subcommand creates a new session from the supplied source. */
export function codexNativeForkArgs(sessionId: string): string[] {
  return ["fork", sessionId];
}

/** Codex resolves the captured thread id to its rollout before normalizing it. */
export async function codexForkHandoff(opts: ForkHandoffOpts): Promise<string> {
  return forkHandoffOrTerminal("Codex", (await readTranscript(opts)).msgs, opts);
}

export function codexLegacyForkSource(args: readonly string[]): string | undefined {
  return args.length === 2 && !!args[1] && args[0] === "fork" ? args[1] : undefined;
}

export const codexFork: AgentForkSupport & { nativeForkArgs: (id: string) => string[] } = {
  kind: "native-fork",
  handoff: codexForkHandoff,
  snapshot: codexSnapshot,
  nativeForkArgs: codexNativeForkArgs,
  decodeLegacyArgs: codexLegacyForkSource,
};
