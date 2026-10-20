import { scrollbackEvents } from "./handoff/events";
import type { AgentForkSupport, ForkHandoffOpts } from "./types";

/** A stable, provider-neutral envelope. It is deliberately text rather than a
 * provider-native resume token: forks must launch a fresh conversation. */
export function normalizedForkHandoff(agent: string, messages: readonly string[]): string {
  const body = messages.map((message) => message.trim()).filter(Boolean).join("\n\n");
  return body ? `[${agent} conversation]\n${body}` : "";
}

/** The one fallback ladder every adapter shares: the provider's own conversation
 * store when it has one to give, otherwise what the terminal saw. Shared rather
 * than restated per agent so a change to the fallback policy — a cap, a
 * different envelope — cannot land on some agents and not others. */
export function forkHandoffOrTerminal(
  agent: string,
  messages: readonly string[],
  opts: ForkHandoffOpts,
): string {
  return normalizedForkHandoff(agent, messages)
    || normalizedForkHandoff(agent, opts.terminalTranscript ? [opts.terminalTranscript] : []);
}

/** The snapshot of an agent with no store to read. A single shared function so
 * a test can tell, by identity, that no registered agent still uses it. */
export const NO_HANDOFF_SNAPSHOT: AgentForkSupport["snapshot"] = async () => undefined;

/** The explicit adapter for agents with no readable native conversation store:
 * nothing to snapshot, and the terminal scrollback stands in for the events. */
export function terminalOnlyFork(agent: string): AgentForkSupport {
  return {
    kind: "terminal-transcript",
    handoff: async (opts: ForkHandoffOpts) => forkHandoffOrTerminal(agent, [], opts),
    snapshot: NO_HANDOFF_SNAPSHOT,
    events: scrollbackEvents,
  };
}
