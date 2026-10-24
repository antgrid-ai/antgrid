import type { AgentForkSupport } from "../types";
import { copilotHandoffEvents } from "./handoff-events";
import { snapshotCopilotTranscript } from "./handoff-snapshot";

export const copilotFork: AgentForkSupport = {
  kind: "terminal-transcript",
  snapshot: snapshotCopilotTranscript,
  events: copilotHandoffEvents,
};
