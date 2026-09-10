// Artifacts, which is where reference-over-value (D5) becomes real: an envelope
// carries only the HANDLE (id, name, media type, size, digest, summary) and the
// bytes are pulled with `session-bus:fetch` in ARTIFACT_CHUNK_BYTES slices. A
// session that produced a 3 MB diff therefore costs the other machine a line of
// prompt, not 3 MB of one. Messages are conversation and may be dropped; this is
// the half that is not.
//
// SURVIVING THE SESSION IS A PROPERTY OF WHERE THIS LIVES, NOT OF A CLEANUP HOOK
// THAT REMEMBERED TO SKIP IT. The directory is keyed by session id under
// `agents/<projectId>/`, and nothing in the stop/archive path goes near it — so
// stopping the agent, restarting the bridge and archiving the session all leave
// the bytes readable, which is exactly what reading another session's evidence
// needs after that session is long gone. Only the session DELETE removes them
// (`removeSessionBusSession`).

import { createHash } from "node:crypto";
import { existsSync, mkdirSync, openSync, readSync, closeSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { z } from "zod";
import { SessionMemberRefSchema } from "../protocol";
import { MAX_ARTIFACTS, MAX_ARTIFACT_BYTES, MAX_SUMMARY_CHARS } from "./constants";
import { sessionBusSessionDir } from "./store-fs";
import { readBusDb, readRecords, replaceRecords, tryBusDb, withBusDb } from "./bus-db";

export const ArtifactRecordSchema = z.object({
  artifactId: z.string().min(1).max(200),
  contextId: z.string().min(1).max(200),
  /** The thread this artifact was published under, or null for one published
   *  outside any. Nothing writes it today — the publish body carries no thread —
   *  and it is kept nullable as the slot the thread id re-keys into. */
  taskId: z.string().max(200).nullable(),
  /** Who published it, labels included: the row must render on a machine that
   *  can never reach the one that wrote it. */
  author: SessionMemberRefSchema,
  name: z.string().min(1).max(200),
  mediaType: z.string().min(1).max(120),
  bytes: z.number().int().nonnegative(),
  sha256: z.string().length(64),
  summary: z.string().min(1).max(MAX_SUMMARY_CHARS),
  createdAt: z.number(),
});
export type ArtifactRecord = z.infer<typeof ArtifactRecordSchema>;

export interface ArtifactState {
  readonly artifacts: readonly ArtifactRecord[];
}

export function emptyArtifacts(): ArtifactState {
  return { artifacts: [] };
}

/** Add a handle, or return the state unchanged if the id is already known — a
 *  redelivered publish must not double a row the fetch path keys by id. */
export function addArtifact(s: ArtifactState, rec: ArtifactRecord): ArtifactState {
  if (artifactById(s, rec.artifactId)) return s;
  return { artifacts: [...s.artifacts, rec].slice(-MAX_ARTIFACTS) };
}

export function artifactsFor(s: ArtifactState, contextId: string): ArtifactRecord[] {
  return s.artifacts.filter((a) => a.contextId === contextId);
}

export function artifactById(s: ArtifactState, id: string): ArtifactRecord | null {
  return s.artifacts.find((a) => a.artifactId === id) ?? null;
}

export function sha256Hex(data: Uint8Array): string {
  return createHash("sha256").update(data).digest("hex");
}

/** The one refusal the publish path owes its caller. Returned as a code rather
 *  than thrown, because the answer to an oversized artifact is a refusal the
 *  peer can act on, not a crashed handler. */
export function checkArtifactSize(bytes: number): "ARTIFACT_TOO_LARGE" | null {
  return bytes > MAX_ARTIFACT_BYTES ? "ARTIFACT_TOO_LARGE" : null;
}

/** Ids are bridge-issued but encoded anyway: a path separator inside one must
 *  not escape the session's own directory. */
function contentPath(abDir: string, projectId: string, sessionId: string, id: string): string {
  return join(sessionBusSessionDir(abDir, projectId, sessionId), "artifacts", `${encodeURIComponent(id)}.bin`);
}

export function loadArtifacts(abDir: string, projectId: string, sessionId: string): ArtifactState {
  return readBusDb(
    abDir,
    (db) => ({ artifacts: readRecords(db, "bus_artifacts", "record", { projectId, sessionId }, MAX_ARTIFACTS, ArtifactRecordSchema) }),
    emptyArtifacts(),
  );
}

/** Answers whether the index was actually written. `publishArtifact` hands the
 *  agent a handle on the strength of it: the bytes are on disk by then, so a
 *  false here is an id that resolves to nothing rather than a lost artifact,
 *  and the one thing that must not happen is reporting it as published. */
export function saveArtifacts(abDir: string, projectId: string, sessionId: string, s: ArtifactState): boolean {
  return tryBusDb(abDir, `the artifact index for session ${sessionId}`, (db) =>
    replaceRecords(db, "bus_artifacts", "record", { projectId, sessionId }, s.artifacts.slice(-MAX_ARTIFACTS)),
  );
}

/** Write the bytes beside the record. Content first, record second at the call
 *  site: a handle with no bytes under it answers every fetch with nothing, while
 *  bytes with no handle are merely unreferenced. */
export function writeArtifactContent(
  abDir: string,
  projectId: string,
  sessionId: string,
  id: string,
  data: Uint8Array,
): void {
  const path = contentPath(abDir, projectId, sessionId, id);
  mkdirSync(join(sessionBusSessionDir(abDir, projectId, sessionId), "artifacts"), { recursive: true });
  writeFileSync(path, data);
}

/**
 * Read one slice. Returns null when there are no bytes stored for the id at all,
 * which a caller must answer as `ARTIFACT_NOT_FOUND` rather than as an empty
 * artifact — the two are indistinguishable in the returned buffer and mean
 * opposite things to the agent reading the result.
 *
 * `eof` is the slice's own answer, so a fetch loop never needs a second call to
 * learn it has finished.
 */
export function readArtifactContent(
  abDir: string,
  projectId: string,
  sessionId: string,
  id: string,
  offset: number,
  length: number,
): { data: Uint8Array; eof: boolean } | null {
  const path = contentPath(abDir, projectId, sessionId, id);
  if (!existsSync(path)) return null;
  const total = statSync(path).size;
  const start = Math.max(0, Math.min(offset, total));
  const want = Math.max(0, Math.min(length, total - start));
  const buf = Buffer.alloc(want);
  if (want > 0) {
    const fd = openSync(path, "r");
    try {
      let read = 0;
      while (read < want) {
        const n = readSync(fd, buf, read, want - read, start + read);
        if (n <= 0) break;
        read += n;
      }
      return { data: buf.subarray(0, read), eof: start + read >= total };
    } finally {
      closeSync(fd);
    }
  }
  return { data: buf, eof: start >= total };
}
