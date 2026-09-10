// The session bus as the loopback API sees it: one method per verb, each
// returning either a plain result or a `SessionBusRefusal`.
//
// This layer exists so the MCP tools stay thin. A tool is a name, a schema and
// one HTTP call; every decision — does this terminal name a session, does that
// artifact exist, is the budget spent — is made HERE, on the bridge, where the
// stores are. The MCP server runs one process per agent invocation and is the
// thing being bounded, so anything it could decide for itself is a bound it
// could also skip.
//
// THE CALLER NAMES A TERMINAL AND NOTHING ELSE. The terminal names a session and
// the session is the identity; there is no role, and a body field claiming one
// would let an agent that guessed the field name act as somebody else
// (`docs/session-messaging.md` §4.3).

import { z } from "zod";
import {
  type SessionMemberKey,
  type SessionMemberRef,
  type BusPart,
} from "../protocol";
import {
  ARTIFACT_CHUNK_BYTES,
  MAX_SUMMARY_CHARS,
} from "./constants";
import type { DirectoryReach, SessionDirectory, SessionDirectoryRow } from "./directory";
import {
  addArtifact,
  artifactById,
  checkArtifactSize,
  loadArtifacts,
  readArtifactContent,
  saveArtifacts,
  sha256Hex,
  writeArtifactContent,
  type ArtifactRecord,
} from "./artifact-store";
import type { SessionBusCoordinator } from "./coordinator";
import { refuse, type SessionBusRefusal } from "./errors";

// -- request bodies ---------------------------------------------------------
// `.strict()` on every one: a body carrying a field the route resolves itself is
// a caller trying to author a bridge-owned one, and answering 400 says so where
// silently ignoring it would not.

export const PublishArtifactBodySchema = z
  .object({
    name: z.string().min(1).max(200),
    mediaType: z.string().min(1).max(120).default("text/plain"),
    summary: z.string().min(1).max(MAX_SUMMARY_CHARS),
    /** Text, or base64 for anything that is not. Exactly one is required: a
     *  publish that carried both would leave the bridge choosing which one the
     *  sha256 in the handle describes. */
    content: z.string().optional(),
    contentBase64: z.string().optional(),
  })
  .strict()
  // Enforced in the schema so it answers 400 like every other malformed body: a
  // publish with no content and one with two contents are both a caller that
  // does not know what it is storing, not a missing artifact.
  .refine((b) => (b.content === undefined) !== (b.contentBase64 === undefined), {
    message: "pass exactly one of content or contentBase64",
  });

export type PublishArtifactBody = z.infer<typeof PublishArtifactBodySchema>;

// -- views ------------------------------------------------------------------

export interface ArtifactHandleView {
  artifactId: string;
  name: string;
  mediaType: string;
  bytes: number;
  sha256: string;
  summary: string;
  createdAt: number;
}

export interface SessionBusApi {
  /** Every session addressable from this terminal's own (§5.5), sorted. Async
   *  where the artifact verbs are not: the branch each row is ranked on is read
   *  fresh, which is a git spawn, and a request is the one place that is
   *  affordable. */
  listSessions(
    terminalId: string | undefined,
  ): Promise<{ sessions: SessionDirectoryRow[]; truncated: number; reach: DirectoryReach } | SessionBusRefusal>;
  publishArtifact(
    terminalId: string | undefined,
    body: PublishArtifactBody,
  ): { ok: true; artifact: ArtifactHandleView } | SessionBusRefusal;
  listArtifacts(terminalId: string | undefined): { artifacts: ArtifactHandleView[] } | SessionBusRefusal;
  getArtifact(
    terminalId: string | undefined,
    artifactId: string,
    offset: number,
    length: number,
  ): { artifactId: string; offset: number; eof: boolean; text: string } | SessionBusRefusal;
}

/** What a terminal id resolves to: the session it names, and the label a
 *  directory row renders it by. */
export interface SessionMembership {
  sessionId: string;
  sessionName?: string;
}

export interface SessionBusApiDeps {
  coordinator: SessionBusCoordinator;
  /** The machine-level directory (§5.5). Absent for a core with no host above
   *  it — a bare bus in a unit test — where `listSessions` is REFUSED rather
   *  than answered from this one project: a directory that silently narrows to
   *  the caller's own project is the exact reach failure the rescope exists to
   *  fix, and it would look like a correct empty answer. */
  directory?: SessionDirectory;
  abDir: string;
  projectId: string;
  projectName?: string;
  /** This machine's relay device id, or null in local mode where no frame can
   *  leave the machine to need an address. */
  machineId: () => string | null;
  /** The session a terminal names, or null when it names none. The terminal id
   *  IS the session id for every agent session; a service PTY names none and
   *  resolves to null, which is what makes it expose no session tools. */
  membership: (terminalId: string) => SessionMembership | null;
  /** Whether this machine's own desktop app — the carrier for a remote leg — is
   *  attached. */
  carrierPresent: () => boolean;
  now?: () => number;
  newId?: () => string;
}

function keyOf(ref: SessionMemberKey | SessionMemberRef): SessionMemberKey {
  return { machineId: ref.machineId, projectId: ref.projectId, sessionId: ref.sessionId };
}

function notMember(): SessionBusRefusal {
  return refuse("NOT_MEMBER", "this terminal names no session on this bridge");
}

function handleOf(rec: ArtifactRecord): ArtifactHandleView {
  return {
    artifactId: rec.artifactId,
    name: rec.name,
    mediaType: rec.mediaType,
    bytes: rec.bytes,
    sha256: rec.sha256,
    summary: rec.summary,
    createdAt: rec.createdAt,
  };
}

export function createSessionBusApi(deps: SessionBusApiDeps): SessionBusApi {
  const now = deps.now ?? Date.now;
  const newId = deps.newId ?? (() => crypto.randomUUID());

  /** The one resolution every route runs first: does this caller name a session
   *  this bridge holds. A missing terminal id and a terminal that names no
   *  session are the same answer, because they are the same fact. */
  function resolve(terminalId: string | undefined): SessionMembership | null {
    if (!terminalId) return null;
    return deps.membership(terminalId) ?? null;
  }

  function selfRef(m: SessionMembership): SessionMemberRef | null {
    const machineId = deps.machineId();
    if (!machineId) return null;
    return {
      machineId,
      projectId: deps.projectId,
      sessionId: m.sessionId,
      ...(deps.projectName ? { projectLabel: deps.projectName } : {}),
      ...(m.sessionName ? { sessionName: m.sessionName } : {}),
    };
  }

  /** The exchange an artifact was published under. A session names its own
   *  contexts by its own id; a thread it did not open is named by the id that
   *  opened it, which is carried on the frame rather than looked up here. */
  function contextOf(m: SessionMembership): string {
    return m.sessionId;
  }

  function artifactsOf(sessionId: string): ReturnType<typeof loadArtifacts> {
    return loadArtifacts(deps.abDir, deps.projectId, sessionId);
  }

  /** Resolve the artifact ids an agent attached to a message into wire parts,
   *  refusing the whole call on the first id this session cannot serve: a
   *  message that silently dropped its evidence reads on the other machine as a
   *  message that had none. */
  function partsForArtifacts(
    sessionId: string,
    ids: readonly string[] | undefined,
  ): BusPart[] | SessionBusRefusal {
    if (!ids || ids.length === 0) return [];
    const store = artifactsOf(sessionId);
    const parts: BusPart[] = [];
    for (const id of ids) {
      const rec = artifactById(store, id);
      if (!rec) return refuse("UNKNOWN_ARTIFACT", `no artifact "${id}" published by this session`);
      parts.push({
        kind: "artifact",
        artifactId: rec.artifactId,
        name: rec.name,
        mediaType: rec.mediaType,
        bytes: rec.bytes,
        sha256: rec.sha256,
        summary: rec.summary,
      });
    }
    return parts;
  }

  return {
    publishArtifact(terminalId, body) {
      const m = resolve(terminalId);
      if (!m) return notMember();
      const data =
        body.content !== undefined
          ? new TextEncoder().encode(body.content)
          : new Uint8Array(Buffer.from(body.contentBase64!, "base64"));
      const tooLarge = checkArtifactSize(data.byteLength);
      if (tooLarge) {
        return refuse(tooLarge, "this artifact is larger than the bus stores; publish the part that matters");
      }
      const rec: ArtifactRecord = {
        artifactId: newId(),
        contextId: contextOf(m),
        taskId: null,
        author: selfRef(m) ?? { machineId: "local", projectId: deps.projectId, sessionId: m.sessionId },
        name: body.name,
        mediaType: body.mediaType,
        bytes: data.byteLength,
        sha256: sha256Hex(data),
        summary: body.summary,
        createdAt: now(),
      };
      // Bytes first, handle second — a handle with nothing under it answers every
      // fetch with nothing, while bytes with no handle are merely unreferenced.
      writeArtifactContent(deps.abDir, deps.projectId, m.sessionId, rec.artifactId, data);
      if (!saveArtifacts(deps.abDir, deps.projectId, m.sessionId, addArtifact(artifactsOf(m.sessionId), rec))) {
        return refuse("STORE_UNAVAILABLE", "this artifact's bytes were written but its handle was not, so it is not published");
      }
      return { ok: true, artifact: handleOf(rec) };
    },

    listArtifacts(terminalId) {
      const m = resolve(terminalId);
      if (!m) return notMember();
      return { artifacts: artifactsOf(m.sessionId).artifacts.map(handleOf) };
    },

    async listSessions(terminalId) {
      const m = resolve(terminalId);
      if (!m) return notMember();
      if (!deps.directory) {
        return refuse("AGENT_NOT_READY", "this bridge has no session directory, so it cannot say who else is reachable");
      }
      const answer = await deps.directory.list({ projectId: deps.projectId, sessionId: m.sessionId });
      if (!answer.ok) {
        return answer.reason === "no-remote"
          ? refuse("NOT_ADDRESSABLE", "this project has no git remote, so no other session can name it and it can name none")
          : refuse("AGENT_NOT_READY", "this project's git remote has not been read yet; it becomes addressable on its own");
      }
      return { sessions: answer.rows, truncated: answer.truncated, reach: answer.reach };
    },

    getArtifact(terminalId, artifactId, offset, length) {
      const m = resolve(terminalId);
      if (!m) return notMember();
      const rec = artifactById(artifactsOf(m.sessionId), artifactId);
      if (!rec) {
        // An id from an envelope names bytes on the OTHER machine, and this route
        // reads only what this session published. Saying so beats a bare 404,
        // which reads as "that artifact does not exist".
        return refuse("UNKNOWN_ARTIFACT", "no artifact with that id on this machine; its bytes stay where they were published");
      }
      const slice = readArtifactContent(
        deps.abDir,
        deps.projectId,
        m.sessionId,
        artifactId,
        Math.max(0, offset),
        Math.min(Math.max(1, length), ARTIFACT_CHUNK_BYTES),
      );
      if (!slice) return refuse("UNKNOWN_ARTIFACT", "this artifact's handle is stored but its content is not");
      return {
        artifactId,
        offset: Math.max(0, offset),
        eof: slice.eof,
        text: new TextDecoder().decode(slice.data),
      };
    },
  };
}
