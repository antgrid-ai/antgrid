// The one place the session bus touches disk. Every store above it is a pure
// fold; this is the thin wrapper the repo already splits out
// (`handler/session-store.ts` is the same shape), which is what lets those folds
// be tested with no filesystem at all.
//
// A parse failure returns the EMPTY store, never a throw and never a partial. A
// half-read file would put a message back on the wire under a state nothing
// wrote; for a per-session store an empty one costs at most a held message
// that was allowed to be lost. `sessionBusMachineDir`'s routes.json is the
// exception: it is machine-level (E9/§5.4), so the same fallback there empties
// every project's carrier bindings at once, not one session's.

import { chmodSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { z } from "zod";
import { logger } from "../logger";

const log = logger.child({ component: "session-bus" });

/** The machine-level session-bus root (E9/§5.4). One file lives here today —
 *  routes.json — because a carrier route is looked up by context id, which may
 *  name a session in any project this machine has open, so no single project's
 *  directory can hold it. Waves 2-3 add siblings here (directory.json,
 *  mailbox/, budget.json), never a subdirectory keyed by project. */
export function sessionBusMachineDir(abDir: string): string {
  return join(abDir, "session-bus");
}

/** Where one project's bus state lives — the per-session message log, held
 *  store and artifact bytes, plus the delivery queue (`sessionBusDeliveryDir`,
 *  same path today, named separately by design). Carrier routes moved out to
 *  `sessionBusMachineDir` (E9/§5.4); this directory holds none. Ids are
 *  bridge-issued but encoded anyway: a path separator inside one must not
 *  escape the project directory. */
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
 * Every session this MACHINE has bus state on disk for, across every project.
 *
 * The restart path needs this: a fresh process holds no sessions in memory, so
 * without enumerating the directory nothing would re-arm the retries a killed
 * bridge left queued, and a held message would sit unsent until some unrelated
 * call happened to name that session. Machine-wide since E9/§5.4: one
 * coordinator now resumes for every project a host has open, not one project's
 * own directory, so the shape widens from a bare session id to the pair the
 * caller needs to resolve a store path from (`sessionBusSessionDir`).
 */
export function listSessionBusSessions(abDir: string): { projectId: string; sessionId: string }[] {
  const root = join(abDir, "agents");
  let projectDirs: string[];
  try {
    projectDirs = readdirSync(root, { withFileTypes: true }).filter((e) => e.isDirectory()).map((e) => e.name);
  } catch (err) {
    // Distinct from "no project has bus state": an unreadable root is
    // otherwise indistinguishable from a machine that has never held anything.
    log.warn({ err }, "session-bus: could not enumerate agents/ while resuming — treating as no sessions");
    return [];
  }
  const out: { projectId: string; sessionId: string }[] = [];
  for (const encProjectId of projectDirs) {
    let projectId: string;
    try {
      projectId = decodeURIComponent(encProjectId);
    } catch {
      continue; // A directory name this bridge did not encode.
    }
    const dir = sessionBusProjectDir(abDir, projectId);
    let sessionEntries;
    try {
      sessionEntries = readdirSync(dir, { withFileTypes: true });
    } catch {
      continue; // This project has no session-bus subdirectory at all.
    }
    for (const e of sessionEntries) {
      if (!e.isDirectory()) continue;
      try {
        out.push({ projectId, sessionId: decodeURIComponent(e.name) });
      } catch {
        // A directory name this bridge did not encode. Skipping is right:
        // there is no session id it could name.
      }
    }
  }
  return out;
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
 * skip them. Called from every session-delete path and nowhere else: the
 * `session:delete` AbMessage arm and `AgentCore.deleteSession` (the control-plane
 * `sessions.delete` RPC's warm branch, which a cold delete with an open racing in
 * also funnels through) in agent-core.ts, and `HostServer`'s own cold-delete path
 * for a project with no warm core at all.
 */
export function removeSessionBusSession(abDir: string, projectId: string, sessionId: string): void {
  rmSync(sessionBusSessionDir(abDir, projectId, sessionId), { recursive: true, force: true });
}
