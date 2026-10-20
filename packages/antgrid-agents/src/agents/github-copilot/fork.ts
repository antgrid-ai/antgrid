import { terminalOnlyFork } from "../fork-handoff";
import type { AgentForkSupport } from "../types";
import { snapshotCopilotTranscript } from "./handoff-snapshot";

export const copilotFork: AgentForkSupport = {
  ...terminalOnlyFork("GitHub Copilot"),
  snapshot: snapshotCopilotTranscript,
};
