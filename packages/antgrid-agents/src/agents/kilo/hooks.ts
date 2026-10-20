import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { bundledPluginPath } from "../../plugin-root";
import { materializeJson, NO_INJECTION } from "../launch-inject";
import type { HookPost } from "../hook-posts";
import type { HookInjectCtx, LaunchAugmentation } from "../types";

export function inject({ abDir }: HookInjectCtx): LaunchAugmentation {
  if (process.env.KILO_CONFIG || process.env.KILO_PURE === "1") return NO_INJECTION;
  const path = join(abDir, "agents", "kilo-session-identity.json");
  const plugin = pathToFileURL(bundledPluginPath(abDir, "kilo", "plugin.ts")).href;
  return materializeJson("Kilo session identity", { [path]: { plugin: [plugin] } })
    ? { args: [], env: { KILO_CONFIG: path } }
    : NO_INJECTION;
}

// The in-process plugin reports identity only; OSC still supplies notifications.
export const events = [] as const;
export const turnBoundaryEvents = { start: [], end: [] } as const;
export const posts = ["/session-title"] as const;
export const observation = { notifications: false, titles: true, handler: false, turnStart: false, turnEnd: false, hookAlive: false } as const;
export async function toPosts(): Promise<HookPost[]> { return []; }
