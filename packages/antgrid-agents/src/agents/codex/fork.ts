import type { AgentForkSupport } from "../types";
import { codexEvents } from "./handoff-events";
import { codexSnapshot } from "./handoff-snapshot";

/** Codex's `fork` subcommand creates a new session from the supplied source. */
export function codexNativeForkArgs(sessionId: string): string[] {
  return ["fork", sessionId];
}

export function codexLegacyForkSource(args: readonly string[]): string | undefined {
  return args.length === 2 && !!args[1] && args[0] === "fork" ? args[1] : undefined;
}

export const codexFork: AgentForkSupport & { nativeForkArgs: (id: string) => string[] } = {
  kind: "native-fork",
  snapshot: codexSnapshot,
  events: codexEvents,
  nativeForkArgs: codexNativeForkArgs,
  decodeLegacyArgs: codexLegacyForkSource,
};
