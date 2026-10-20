import { scrollbackEvents } from "./handoff/events";
import type { AgentForkSupport } from "./types";

/** The snapshot of an agent with no store to read. A single shared function so
 * a test can tell, by identity, that no registered agent still uses it. */
export const NO_HANDOFF_SNAPSHOT: AgentForkSupport["snapshot"] = async () => undefined;

/** The explicit adapter for agents with no readable native conversation store:
 * nothing to snapshot, and the terminal scrollback stands in for the events. */
export function terminalOnlyFork(): AgentForkSupport {
  return {
    kind: "terminal-transcript",
    snapshot: NO_HANDOFF_SNAPSHOT,
    events: scrollbackEvents,
  };
}
