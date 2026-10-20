import { terminalForkHandoff } from "../fork-handoff";
import { opencodeLegacyForkSource, opencodeNativeForkArgs } from "../opencode/fork";

export const kiloFork = {
  ...terminalForkHandoff("Kilo"),
  kind: "native-fork" as const,
  nativeForkArgs: opencodeNativeForkArgs,
  decodeLegacyArgs: opencodeLegacyForkSource,
};
