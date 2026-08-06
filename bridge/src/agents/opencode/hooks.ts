import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { atomicWriteFile } from "../../discovery";
import { logger } from "../../logger";
import { bundledPluginPath } from "../../plugin-root";
import { NO_INJECTION } from "../launch-inject";
import type { HookPost } from "../hook-posts";
import type { HookInjectCtx, LaunchAugmentation } from "../types";

const log = logger.child({ component: "agent-launch" });

function writeOpencodeConfig(abDir: string): string | null {
  let pluginUrl: string;
  try {
    // Resolved AND existence-checked before the write. A config naming a plugin
    // file that is not there writes fine, spawns fine, and simply never loads;
    // there is no later signal, so the missing asset has to be caught here.
    pluginUrl = pathToFileURL(bundledPluginPath("opencode", "plugin.ts")).href;
  } catch (err) {
    // Distinct from the write failure below, and at error level: this one is a
    // packaging bug in our own build, not a condition on the user's machine.
    log.error("bundled opencode plugin missing, skipping session-namer config: %s", err);
    return null;
  }
  try {
    const path = join(abDir, "agents", "opencode-session-namer.json");
    atomicWriteFile(path, JSON.stringify({ plugin: [pluginUrl] }, null, 2));
    return path;
  } catch (err) {
    log.warn("failed to write opencode session-namer config: %s", err);
    return null;
  }
}

export function inject({ abDir }: HookInjectCtx): LaunchAugmentation {
  if (process.env.OPENCODE_CONFIG) return NO_INJECTION;
  const cfgPath = writeOpencodeConfig(abDir);
  return cfgPath ? { args: [], env: { OPENCODE_CONFIG: cfgPath } } : NO_INJECTION;
}

// Empty on purpose: the injected plugin runs inside opencode's own Bun runtime
// and POSTs to the loopback API itself, so opencode never shells out to
// `bridge hook` and has no event for the runner to allowlist.
export const events = [] as const;

// Empty for the same reason `events` is: the in-runtime plugin's turn signals
// never pass through `bridge hook`, so nothing here could close an inferred
// turn.
export const turnBoundaryEvents = {
  start: [],
  end: [],
} as const;

// Posted by bridge/plugin/opencode/plugin.ts from inside opencode's own Bun
// runtime, not by `toPosts` — which is why this list is not derivable from
// `events`.
export const posts = ["/session-title", "/notify", "/handler-event"] as const;

// Unreachable while `events` is empty — hook-runner drops every invocation at
// the allowlist check before dispatch. Present so the profile stays one shape
// across agents, and so adding an event here is the only thing needed to make
// opencode dispatchable.
export async function toPosts(): Promise<HookPost[]> {
  return [];
}
