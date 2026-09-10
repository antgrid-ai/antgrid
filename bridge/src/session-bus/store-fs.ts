// Where the session bus touches the filesystem, which is now only the artifact
// BYTES. Every record it keeps — routes, message logs, held messages, artifact
// handles, queued deliveries — lives in one machine-level database
// (`bus-db.ts`); what is left here is the content those handles point at, and
// the two deletes that have to reclaim both halves together.
//
// The split is deliberate rather than incidental. An artifact is the durable
// half of the protocol and can be megabytes; a row is small and is read back by
// whichever session happens to hold the context next. Putting the bytes in the
// database would make every reclaim a rewrite of the file that holds every
// other project's state.

import { rmSync } from "node:fs";
import { join } from "node:path";
import { deleteScope, tryBusDb, withBusDb } from "./bus-db";

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

/**
 * Every session this MACHINE still holds a message for, across every project.
 *
 * The restart path needs this: a fresh process holds no sessions in memory, so
 * without it nothing would re-arm the retries a killed bridge left queued, and
 * a held message would sit unsent until some unrelated call happened to name
 * that session.
 *
 * HELD messages alone, because a held message is the only thing a resume can
 * act on. A session with a message log and nothing queued has nothing to
 * retry, and hydrating it would only pin its state in memory. The caller still
 * has to check who OWNS each pair — the row says which project the state was
 * FILED under, and the session index is the authority on who holds it now (see
 * `SessionBusCoordinator.resume`).
 */
export function listSessionBusSessions(abDir: string): { projectId: string; sessionId: string }[] {
  return withBusDb(
    abDir,
    (db) =>
      db
        .query("SELECT DISTINCT projectId, sessionId FROM bus_held ORDER BY projectId, sessionId")
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
  const recordsGone = tryBusDb(abDir, `the records for session ${sessionId}`, (db) =>
    deleteScope(db, { projectId, sessionId }),
  );
  rmSync(sessionBusSessionDir(abDir, projectId, sessionId), { recursive: true, force: true });
  if (!recordsGone) throw new Error(`session-bus: the records for session ${sessionId} could not be deleted`);
}

/**
 * Remove every bus record a project owns — its sessions' logs, held messages
 * and artifact handles, its delivery queue, and its carrier routes.
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
  return tryBusDb(abDir, `the bus records for project ${projectId}`, (db) => deleteScope(db, { projectId }));
}
