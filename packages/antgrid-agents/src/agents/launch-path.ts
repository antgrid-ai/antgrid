// Resolve the exact on-disk binary the bridge would spawn: PATH shim ->
// realpath, so a multi-install PATH can't make us target the wrong one. Falls
// back to the bare command name.
//
// Shared rather than per-agent because spawning and self-updating MUST agree on
// one install: an "update available" chip computed from a different binary than
// the session actually runs is a chip that never goes away. Kept out of any one
// agent's directory in the same spirit as title-read.ts and hook-posts.ts.

import { realpathSync } from "node:fs";

export function resolveToolLaunchPath(command: string, path?: string): string {
  const onPath = Bun.which(command, path ? { PATH: path } : undefined);
  if (!onPath) return command;
  try { return realpathSync.native(onPath); } catch { return onPath; }
}
