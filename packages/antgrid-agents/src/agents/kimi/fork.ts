import { terminalForkHandoff } from "../fork-handoff";
import type { AgentForkSupport } from "../types";
import { snapshotKimi } from "./handoff-snapshot";

export const kimiFork: AgentForkSupport = {
  ...terminalForkHandoff("Kimi"),
  kind: "native-fork",
  nativeForkKeepsWorkspace: true,
  snapshot: snapshotKimi,
};
