import { terminalOnlyFork } from "../fork-handoff";
import type { AgentForkSupport } from "../types";
import { cursorSnapshot } from "./handoff-snapshot";

export const cursorAgentFork: AgentForkSupport = {
  ...terminalOnlyFork("Cursor"),
  snapshot: cursorSnapshot,
};
