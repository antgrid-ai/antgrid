import type { AgentForkSupport } from "../types";
import { antigravityHandoffEvents } from "./handoff-events";
import { snapshotAntigravityTranscript } from "./handoff-snapshot";

export const antigravityFork: AgentForkSupport = {
  kind: "terminal-transcript",
  snapshot: snapshotAntigravityTranscript,
  events: antigravityHandoffEvents,
};
