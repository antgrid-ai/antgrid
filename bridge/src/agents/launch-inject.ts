// Primitives shared by the per-agent `inject` implementations.

import { statSync } from "node:fs";
import type { LaunchAugmentation } from "./types";

/** Nothing injected, and no outcome reported. An absent `notificationsInjected`
 *  is not "failed": it means this path has no per-spawn filesystem step that
 *  could fail, so the spec's static notificationSource stands on its own. */
export const NO_INJECTION: LaunchAugmentation = { args: [], env: {} };

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
