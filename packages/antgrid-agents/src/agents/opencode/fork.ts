import type { AgentForkSupport } from "../types";
import { opencodeFamilyEvents } from "./handoff-events";
import { opencodeSnapshot } from "./handoff-snapshot";

/** `opencode --session <id> --fork` clones instead of resuming the source. */
export function opencodeNativeForkArgs(sessionId: string): string[] {
  return ["--session", sessionId, "--fork"];
}

export function opencodeLegacyForkSource(args: readonly string[]): string | undefined {
  return args.length === 3 && !!args[1] && args[0] === "--session" && args[2] === "--fork" ? args[1] : undefined;
}

export const opencodeFork: AgentForkSupport & { nativeForkArgs: (sessionId: string) => string[] } = {
  kind: "native-fork",
  nativeForkArgs: opencodeNativeForkArgs,
  decodeLegacyArgs: opencodeLegacyForkSource,
  snapshot: opencodeSnapshot,
  events: opencodeFamilyEvents,
};
