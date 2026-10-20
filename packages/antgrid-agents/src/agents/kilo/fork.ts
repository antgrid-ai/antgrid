import { terminalForkHandoff } from "../fork-handoff";
import { opencodeLegacyForkSource, opencodeNativeForkArgs } from "../opencode/fork";
import { kiloSnapshot } from "./handoff-snapshot";

export const kiloFork = {
  ...terminalForkHandoff("Kilo"),
  kind: "native-fork" as const,
  nativeForkArgs: opencodeNativeForkArgs,
  decodeLegacyArgs: opencodeLegacyForkSource,
  snapshot: kiloSnapshot,
};
