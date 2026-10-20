import { terminalForkHandoff } from "../fork-handoff";
import type { AgentForkSupport } from "../types";
import { cursorSnapshot } from "./handoff-snapshot";

export const cursorAgentFork: AgentForkSupport = {
  ...terminalForkHandoff("Cursor"),
  snapshot: cursorSnapshot,
};
