import { terminalForkHandoff } from "../fork-handoff";
import type { AgentForkSupport } from "../types";
import { snapshotAntigravityTranscript } from "./handoff-snapshot";

export const antigravityFork: AgentForkSupport = {
  ...terminalForkHandoff("Antigravity"),
  snapshot: snapshotAntigravityTranscript,
};
