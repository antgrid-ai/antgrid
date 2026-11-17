// Artifact bytes live outside the shared bus database so large artifacts do
// not inflate every database rewrite. Reclaim must remove both halves.
import { rmSync } from "node:fs";
import { join } from "node:path";
import { deleteScope, readBusDb, reclaimBusDb } from "./bus-db";

/** Where one project's artifact bytes live. Ids are bridge-issued but encoded
 *  anyway: a path separator inside one must not escape the project directory. */
export function sessionBusProjectDir(abDir: string, projectId: string): string {
  return join(abDir, "agents", encodeURIComponent(projectId), "session-bus");
}

/** Where one LOCAL session's artifact bytes live. Each bridge persists only what
 *  its own sessions published; neither machine's directory is ever a mirror of
 *  the other's. */
export function sessionBusSessionDir(abDir: string, projectId: string, sessionId: string): string {
  return join(sessionBusProjectDir(abDir, projectId), encodeURIComponent(sessionId));
}

/** Resume only actionable state: held sends need retries and threads need expiry.
 * The session index still decides who owns each persisted session. */
export function listSessionBusSessions(abDir: string): { projectId: string; sessionId: string }[] {
  return readBusDb(
    abDir,
    (db) =>
      db
        .query(
          `SELECT projectId, sessionId FROM bus_held
           UNION SELECT projectId, sessionId FROM bus_threads
           ORDER BY projectId, sessionId`,
        )
        .all() as { projectId: string; sessionId: string }[],
    [],
  );
}

/**
 * Remove one session's whole bus state, records and artifact bytes together.
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
 *
 * Two reclaims, not one, and BOTH are required. The directory holds only the
 * bytes now; every record naming this session is a row somewhere else, under a
 * project id that nothing on the machine would be able to name again once the
 * session row itself is gone. Gated by session-bus-reclaim.test.ts.
 *
 * THROWS when the rows survive, which is the whole reason the row half is not
 * routed through `withBusDb`: every call site already wraps this in a try/catch
 * that warns `could not remove the session-bus store`, and a reclaim that
 * answers success while the records stand is the one failure none of them could
 * report. The bytes go either way — the session is being deleted, and bytes
 * with no handle are merely unreferenced, where a handle with no bytes answers
 * every fetch with nothing (`publishArtifact` orders itself the same way).
 */
export function removeSessionBusSession(abDir: string, projectId: string, sessionId: string): void {
  const recordsGone = reclaimBusDb(abDir, `the records for session ${sessionId}`, (db) =>
    deleteScope(db, { projectId, sessionId }),
  );
  rmSync(sessionBusSessionDir(abDir, projectId, sessionId), { recursive: true, force: true });
  if (!recordsGone) throw new Error(`session-bus: the records for session ${sessionId} could not be deleted`);
}

/**
 * Remove every bus record a project owns — its sessions' logs, held messages
 * and artifact handles, and its delivery queue.
 *
 * The bytes are NOT this function's business: `HostServer.forget` deletes
 * `agents/<projectId>/` wholesale, which takes them with it. What that delete
 * can no longer reach is the database, which is why this exists at all — the
 * rows would otherwise outlive every other trace of the project, filed under an
 * id nothing left on the machine could name.
 *
 * Reports rather than throws, unlike its per-session sibling: `HostServer.forget`
 * has no error path here and steps after it that must still run. `tryBusDb` has
 * already said what survived by the time this returns false.
 */
export function removeSessionBusProject(abDir: string, projectId: string): boolean {
  return reclaimBusDb(abDir, `the bus records for project ${projectId}`, (db) => deleteScope(db, { projectId }));
}
