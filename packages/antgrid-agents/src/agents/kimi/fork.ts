import type { AgentForkSupport } from "../types";
import { kimiEvents } from "./handoff-events";
import { snapshotKimi } from "./handoff-snapshot";

export const kimiFork: AgentForkSupport = {
  kind: "native-fork",
  nativeForkKeepsWorkspace: true,
  snapshot: snapshotKimi,
  events: kimiEvents,
};
