import { terminalOnlyFork } from "../fork-handoff";
import type { AgentForkSupport } from "../types";
import { snapshotVibe } from "./handoff-snapshot";

export const vibeFork: AgentForkSupport = {
  ...terminalOnlyFork("Mistral Vibe"),
  snapshot: snapshotVibe,
};
