import type { AgentForkSupport } from "../types";
import { cursorHandoffEvents } from "./handoff-events";
import { cursorSnapshot } from "./handoff-snapshot";

export const cursorAgentFork: AgentForkSupport = {
  kind: "terminal-transcript",
  snapshot: cursorSnapshot,
  events: cursorHandoffEvents,
};
