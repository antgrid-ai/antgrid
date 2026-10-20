import { terminalForkHandoff } from "../fork-handoff";
import type { AgentForkSupport } from "../types";
import { snapshotCopilotTranscript } from "./handoff-snapshot";

export const copilotFork: AgentForkSupport = {
  ...terminalForkHandoff("GitHub Copilot"),
  snapshot: snapshotCopilotTranscript,
};
