import { terminalOnlyFork } from "../fork-handoff";
import { opencodeLegacyForkSource, opencodeNativeForkArgs } from "../opencode/fork";
import { kiloSnapshot } from "./handoff-snapshot";

export const kiloFork = {
  ...terminalOnlyFork("Kilo"),
  kind: "native-fork" as const,
  nativeForkArgs: opencodeNativeForkArgs,
  decodeLegacyArgs: opencodeLegacyForkSource,
  snapshot: kiloSnapshot,
};
