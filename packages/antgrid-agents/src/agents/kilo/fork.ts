import { opencodeLegacyForkSource, opencodeNativeForkArgs } from "../opencode/fork";
import type { AgentForkSupport } from "../types";
import { kiloSnapshot } from "./handoff-snapshot";
import { kiloHandoffEvents } from "./handoff-events";

export const kiloFork: AgentForkSupport & { nativeForkArgs: (sessionId: string) => string[] } = {
  kind: "native-fork",
  nativeForkArgs: opencodeNativeForkArgs,
  decodeLegacyArgs: opencodeLegacyForkSource,
  snapshot: kiloSnapshot,
  events: kiloHandoffEvents,
};
