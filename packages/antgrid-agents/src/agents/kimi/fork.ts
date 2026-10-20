import { terminalOnlyFork } from "../fork-handoff";
import type { AgentForkSupport } from "../types";
import { snapshotKimi } from "./handoff-snapshot";

export const kimiFork: AgentForkSupport = {
  ...terminalOnlyFork("Kimi"),
  kind: "native-fork",
  nativeForkKeepsWorkspace: true,
  snapshot: snapshotKimi,
};
