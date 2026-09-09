// The one place the session bus touches disk. Every store above it is a pure
// fold; this is the thin wrapper the repo already splits out
// (`handler/session-store.ts` is the same shape), which is what lets those folds
// be tested with no filesystem at all.
//
// A parse failure returns the EMPTY store, never a throw and never a partial. A
// half-read file would put a message back on the wire under a state nothing
// wrote; an empty one costs at most a held message that was allowed to be lost.

import { chmodSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { z } from "zod";

/** Where one project's bus state lives. Ids are bridge-issued but encoded
 *  anyway: a path separator inside one must not escape the project directory. */
export function sessionBusProjectDir(abDir: string, projectId: string): string {
  return join(abDir, "agents", encodeURIComponent(projectId), "session-bus");
}

/** Where one LOCAL session's bus state lives. Each bridge persists only what its
 *  own sessions said and were told; neither directory is ever a mirror of the
 *  other machine's. */
export function sessionBusSessionDir(abDir: string, projectId: string, sessionId: string): string {
  return join(sessionBusProjectDir(abDir, projectId), encodeURIComponent(sessionId));
}

/** Where one project's delivery queue lives. Named separately from
 *  `sessionBusProjectDir` even though the path is identical today: the queue is
 *  per-project BY DESIGN, because the turn-open set it drains against is one
 *  `ProjectCore`'s own reduction (delivery-queue.ts:170-175) — a machine-level
 *  move that later relocates the rest of session-bus state must not carry the
 *  queue with it as an incidental side effect. */
export function sessionBusDeliveryDir(abDir: string, projectId: string): string {
  return join(abDir, "agents", encodeURIComponent(projectId), "session-bus");
}

/**
 * Every session this project has bus state on disk for.
 *
 * The restart path needs this: a fresh process holds no sessions in memory, so
 * without enumerating the directory nothing would re-arm the retries a killed
 * bridge left queued, and a held message would sit unsent until some unrelated
 * call happened to name that session.
 */
export function listSessionBusSessions(abDir: string, projectId: string): string[] {
  const dir = sessionBusProjectDir(abDir, projectId);
  try {
    return readdirSync(dir, { withFileTypes: true })
      .filter((e) => e.isDirectory())
      .map((e) => {
        try {
          return decodeURIComponent(e.name);
        } catch {
          // A directory name this bridge did not encode. Skipping is right:
          // there is no session id it could name.
          return null;
        }
      })
      .filter((id): id is string => id !== null);
  } catch {
    return [];
  }
}

/** Read and validate a store file, falling back to [empty] on anything at all:
 *  a missing file, a truncated write, a version this bridge cannot read. */
export function readStoreFile<T>(path: string, schema: z.ZodType<T>, empty: T): T {
  if (!existsSync(path)) return empty;
  try {
    const parsed = schema.safeParse(JSON.parse(readFileSync(path, "utf8")));
    return parsed.success ? parsed.data : empty;
  } catch {
    return empty;
  }
}

/** Write a store file atomically: temp file, rename, then owner-only off
 *  Windows. The rename is what makes a crash mid-write leave the previous
 *  contents rather than a truncated file that loads as empty. */
export function writeStoreFile(path: string, dir: string, value: unknown): void {
  mkdirSync(dir, { recursive: true });
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, JSON.stringify(value, null, 2), "utf8");
  renameSync(tmp, path);
  if (process.platform !== "win32") {
    try { chmodSync(path, 0o600); } catch { /* best effort */ }
  }
}

/**
 * Remove one session's whole bus directory, records and artifact bytes together.
 *
 * The ONLY thing that deletes an artifact. Stopping an agent, restarting the
 * bridge and archiving a session all leave the store readable, which is what
 * "an artifact survives however the session ended" means in practice — survival
 * is a property of where the bytes are, not of a cleanup hook that remembered to
 * skip them. This is called from the session delete path and nowhere else.
 */
export function removeSessionBusSession(abDir: string, projectId: string, sessionId: string): void {
  rmSync(sessionBusSessionDir(abDir, projectId, sessionId), { recursive: true, force: true });
}
