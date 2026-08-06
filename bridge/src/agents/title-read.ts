// Primitives shared by the per-agent `resolveTitle` / `resumable` readers, in
// the same spirit as hook-posts.ts and launch-inject.ts: kept out of any one
// agent's directory so three agents can share them without importing each other.

import { readFile } from "node:fs/promises";
import type { ResolvedTitle } from "./types";

export const generated = (title: string): ResolvedTitle => ({ title, kind: "generated" });
export const firstMessage = (title: string): ResolvedTitle => ({ title, kind: "first-message" });

/** Read a UTF-8 file, returning null on any error (missing / unreadable). Async
 *  so a large Claude transcript can't block the single-threaded bridge event
 *  loop (and its WS sockets) while it's read off the /session-title handler. */
export async function readOrNull(path: string): Promise<string | null> {
  try {
    return await readFile(path, "utf8");
  } catch {
    return null;
  }
}
