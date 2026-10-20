import { terminalForkHandoff } from "../fork-handoff";
import type { AgentForkSupport } from "../types";
import { snapshotVibe } from "./handoff-snapshot";

export const vibeFork: AgentForkSupport = {
  ...terminalForkHandoff("Mistral Vibe"),
  snapshot: snapshotVibe,
};
