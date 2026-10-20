import { terminalOnlyFork } from "../fork-handoff";
import type { AgentForkSupport } from "../types";
import { snapshotAntigravityTranscript } from "./handoff-snapshot";

export const antigravityFork: AgentForkSupport = {
  ...terminalOnlyFork("Antigravity"),
  snapshot: snapshotAntigravityTranscript,
};
