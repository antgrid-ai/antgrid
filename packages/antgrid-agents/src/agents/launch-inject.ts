// Primitives shared by the per-agent `inject` implementations.

import { statSync } from "node:fs";
import type { LaunchAugmentation, TerminalObservationAvailability } from "./types";

/** A skipped or failed integration must not suppress its fallback channels. */
export const NO_OBSERVATION: Readonly<TerminalObservationAvailability> = Object.freeze({
  notifications: false, titles: false, handler: false,
  turnStart: false, turnEnd: false, hookAlive: false,
});
export const NO_INJECTION: LaunchAugmentation = { args: [], env: {}, notificationsInjected: false, observation: NO_OBSERVATION };

/** Post-write check for agents whose integration is a materialized file.
 *  `atomicWriteFile` fails soft, so the files on disk — not the write call —
 *  decide whether the plugin dir is worth handing to the agent at all. */
export function hasFiles(paths: string[]): boolean {
  try {
    return paths.every((path) => statSync(path).isFile());
  } catch {
    return false;
  }
}
