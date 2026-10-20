import type { AgentForkSupport } from "../types";
import { vibeEvents } from "./handoff-events";
import { snapshotVibe } from "./handoff-snapshot";

export const vibeFork: AgentForkSupport = {
  kind: "terminal-transcript",
  snapshot: snapshotVibe,
  events: vibeEvents,
};
