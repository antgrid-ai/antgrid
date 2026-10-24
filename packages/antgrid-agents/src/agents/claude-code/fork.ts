import type { AgentForkSupport } from "../types";
import { claudeHandoffEvents } from "./handoff-events";
import { snapshotClaudeTranscript } from "./handoff-snapshot";

/** `--fork-session` makes Claude create a new conversation instead of resuming
 * the source. Verified against the interactive CLI's resume syntax. */
export function claudeNativeForkArgs(sessionId: string): string[] {
  return ["--resume", sessionId, "--fork-session"];
}

export function claudeLegacyForkSource(args: readonly string[]): string | undefined {
  return args.length === 3 && !!args[1] && args[0] === "--resume" && args[2] === "--fork-session" ? args[1] : undefined;
}

export const claudeFork: AgentForkSupport & { nativeForkArgs: (id: string) => string[] } = {
  kind: "native-fork",
  snapshot: snapshotClaudeTranscript,
  events: claudeHandoffEvents,
  nativeForkArgs: claudeNativeForkArgs,
  decodeLegacyArgs: claudeLegacyForkSource,
};
