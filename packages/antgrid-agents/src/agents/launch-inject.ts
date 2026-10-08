// Primitives shared by the per-agent `inject` implementations.

import { statSync } from "node:fs";
import { atomicWriteFile } from "../atomic-file";
import { logger } from "../host";
import type { LaunchAugmentation, TerminalObservationAvailability } from "./types";

const log = logger.child({ component: "agent-launch" });

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

/** Writes each file as JSON and answers with `hasFiles` over all of them, so a
 *  failed write drops the integration rather than the spawn — unless an
 *  earlier run left the file in place, which is then used as it stands. */
export function materializeJson(label: string, files: Record<string, unknown>): boolean {
  try {
    for (const [path, value] of Object.entries(files)) {
      atomicWriteFile(path, `${JSON.stringify(value, null, 2)}\n`);
    }
  } catch (err) {
    log.warn("failed to materialize %s: %s", label, err);
  }
  return hasFiles(Object.keys(files));
}

export function toPosixPath(value: string): string {
  return value.replace(/\\/g, "/");
}
