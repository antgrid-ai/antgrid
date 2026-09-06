// The session bus as the loopback API sees it: one method per verb of spec 4.5,
// each returning either a plain result or a `SessionBusRefusal`.
//
// This layer exists so the MCP tools stay thin. A tool is a name, a schema and
// one HTTP call; every decision — who may call this, is the task still open, is
// the budget spent — is made HERE, on the bridge, where the stores are. The MCP
// server runs one process per agent invocation and is the thing being bounded,
// so anything it could decide for itself is a bound it could also skip.
//
// ROLE IS DERIVED, NEVER DECLARED (spec 4.5). The caller names a terminal, the
// terminal names a session, and the session's own membership row says whether it
// leads, works or neither. A body field claiming a role would let an agent that
// guessed the field name assign itself work on another machine's behalf.

import { z } from "zod";
import {
  type SessionMember,
  type SessionMemberKey,
  type SessionMemberOf,
  type SessionMemberRef,
  type BusPart,
} from "../protocol";
import {
  ARTIFACT_CHUNK_BYTES,
  MAX_FINDING_CHARS,
  MAX_PART_CHARS,
  MAX_SUMMARY_CHARS,
  MAX_UNEXPECTED_CHARS,
  TASK_EXPIRY_MS,
} from "./constants";
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
import { loadBrief } from "./brief-store";
import type { BusRole, SessionBusCoordinator } from "./coordinator";
import { isRefusal, refuse, type SessionBusRefusal } from "./errors";
import {
  answerRequest,
  fitQuestion,
  loadPending,
  openRequest,
  requestsForTask,
  savePending,
  type PendingRequest,
} from "./pending-store";
import type { GuardBudget } from "./task-guard";
import { isTerminal, type TaskRecord } from "./task-store";

/** How long a peer's question to its lead stays open before the pending row
 *  lapses. The lead is an agent on another machine, not a human, so this is the
 *  same order as a task's own life rather than the days a human question can
 *  take — and the clock pauses the moment a human is what the answer waits on. */
const ASK_EXPIRY_MS = TASK_EXPIRY_MS;

// -- request bodies ---------------------------------------------------------
// `.strict()` on every one: a body carrying `taskId` or `seq` where the route
// resolves them itself is a caller trying to author a bridge-owned field, and
// answering 400 says so where silently ignoring it would not.

/** A peer named by the id `list_peers` prints, or spelled out in full for a
 *  caller that has the whole address. */
const PeerSelectorSchema = z.union([
  z.string().min(1).max(200),
  z
    .object({
      machineId: z.string().min(1).max(200),
      projectId: z.string().min(1).max(200),
      sessionId: z.string().min(1).max(200),
    })
    .strict(),
]);

export const AssignBodySchema = z
  .object({
    peer: PeerSelectorSchema,
    summary: z.string().min(1).max(MAX_SUMMARY_CHARS),
    instruction: z.string().min(1).max(MAX_PART_CHARS),
    artifactIds: z.array(z.string().min(1).max(200)).max(8).optional(),
    unexpected: z.string().max(MAX_UNEXPECTED_CHARS).optional(),
  })
  .strict();

export const CancelBodySchema = z
  .object({ reason: z.string().min(1).max(500) })
  .strict();

export const AnswerBodySchema = z
  .object({
    summary: z.string().min(1).max(MAX_SUMMARY_CHARS),
    answer: z.string().min(1).max(MAX_PART_CHARS),
  })
  .strict();

export const ReportBodySchema = z
  .object({
    summary: z.string().min(1).max(MAX_SUMMARY_CHARS),
    text: z.string().max(MAX_PART_CHARS).optional(),
    artifactIds: z.array(z.string().min(1).max(200)).max(8).optional(),
    unexpected: z.string().max(MAX_UNEXPECTED_CHARS).optional(),
  })
  .strict();

export const FindingBodySchema = z
  .object({
    taskId: z.string().min(1).max(200).optional(),
    summary: z.string().min(1).max(MAX_SUMMARY_CHARS),
    text: z.string().max(MAX_FINDING_CHARS).optional(),
    unexpected: z.string().max(MAX_UNEXPECTED_CHARS).optional(),
  })
  .strict();

export const AskBodySchema = z
  .object({
    taskId: z.string().min(1).max(200),
    summary: z.string().min(1).max(MAX_SUMMARY_CHARS),
    question: z.string().min(1).max(MAX_PART_CHARS),
  })
  .strict();

export const PublishArtifactBodySchema = z
  .object({
    taskId: z.string().min(1).max(200).optional(),
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

export type AssignBody = z.infer<typeof AssignBodySchema>;
export type CancelBody = z.infer<typeof CancelBodySchema>;
export type AnswerBody = z.infer<typeof AnswerBodySchema>;
export type ReportBody = z.infer<typeof ReportBodySchema>;
export type FindingBody = z.infer<typeof FindingBodySchema>;
export type AskBody = z.infer<typeof AskBodySchema>;
export type PublishArtifactBody = z.infer<typeof PublishArtifactBodySchema>;

// -- views ------------------------------------------------------------------

/** What the caller's terminal resolved to. `role` is what the tool list is built
 *  from; `null` is a terminal that is not in a multi-machine session at all, and
 *  is answered 200 rather than refused — "you have no session tools" is an
 *  answer, not an error, and a tool list that failed would be retried forever. */
export interface RoleView {
  role: BusRole | null;
  /** A machine can lead one session and work another, so both can be true. */
  lead: boolean;
  peer: boolean;
  sessionId: string | null;
  sessionName?: string;
  /** The identifier both machines use for this exchange: the lead's session id. */
  contextId?: string;
  machineId?: string;
  projectId?: string;
}

/** One member as a lead's tools see it. Extends the ref rather than restating
 *  it, which is what carries the Capability Card through: spec 3.3 requires
 *  list-peers to answer with each peer's OS and repo, and the card is on the
 *  member row because only the peer's own bridge could observe it. */
export interface PeerView extends SessionMemberRef {
  state: SessionMember["state"];
  joinedAt: number;
  /** Whether a frame addressed here could leave this bridge right now. This
   *  bridge can never observe the peer machine (D7), so it answers only for its
   *  own half: an active member with a carrier attached. A false here is "I
   *  cannot send", never "the peer is down". */
  reachable: boolean;
}

export interface TaskView {
  taskId: string;
  contextId: string;
  role: BusRole;
  state: TaskRecord["state"];
  waitingOn?: TaskRecord["waitingOn"];
  title: string;
  peer: SessionMemberRef;
  createdAt: number;
  updatedAt: number;
  expiresAt?: number;
  expiredAt?: number;
  canceledAt?: number;
  cancelReason?: string;
  findings: TaskRecord["findings"];
  artifacts: ArtifactHandleView[];
}

export interface ArtifactHandleView {
  artifactId: string;
  name: string;
  mediaType: string;
  bytes: number;
  sha256: string;
  summary: string;
  taskId: string | null;
  createdAt: number;
}

export interface SessionView {
  role: BusRole | null;
  lead: boolean;
  peer: boolean;
  sessionId: string;
  contextId: string;
  self: SessionMemberRef;
  memberOf?: SessionMemberOf;
  members: PeerView[];
  /** Restated on every task and answer this session sends or receives. */
  scope: { label: string; text: string }[];
  brief?: string;
  budget: GuardBudget;
  openTaskIds: string[];
}

export interface SessionBusApi {
  role(terminalId: string | undefined): RoleView;
  session(terminalId: string | undefined): SessionView | SessionBusRefusal;
  brief(terminalId: string | undefined): { brief: string; scope: SessionView["scope"]; lead: SessionMemberOf } | SessionBusRefusal;
  peers(terminalId: string | undefined): { peers: PeerView[] } | SessionBusRefusal;
  listTasks(terminalId: string | undefined): { tasks: TaskView[] } | SessionBusRefusal;
  getTask(terminalId: string | undefined, taskId: string): TaskView | SessionBusRefusal;
  assign(terminalId: string | undefined, body: AssignBody): { ok: true; taskId: string; delivered: boolean } | SessionBusRefusal;
  cancelTask(terminalId: string | undefined, taskId: string, body: CancelBody): { ok: true } | SessionBusRefusal;
  answerPeer(terminalId: string | undefined, taskId: string, body: AnswerBody): { ok: true } | SessionBusRefusal;
  openTask(terminalId: string | undefined, taskId: string): { ok: true } | SessionBusRefusal;
  reportComplete(terminalId: string | undefined, taskId: string, body: ReportBody): { ok: true } | SessionBusRefusal;
  reportFailure(terminalId: string | undefined, taskId: string, body: ReportBody): { ok: true } | SessionBusRefusal;
  reportFinding(
    terminalId: string | undefined,
    body: FindingBody,
  ): { ok: true; sent: boolean; held: boolean } | SessionBusRefusal;
  askLead(terminalId: string | undefined, body: AskBody): { ok: true; requestId: string } | SessionBusRefusal;
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

/** The membership facts one session carries, as the session manager holds them. */
export interface SessionMembership {
  sessionId: string;
  sessionName?: string;
  members: SessionMember[];
  memberOf?: SessionMemberOf;
}

export interface SessionBusApiDeps {
  coordinator: SessionBusCoordinator;
  abDir: string;
  projectId: string;
  projectName?: string;
  /** This machine's relay device id, or null in local mode where no frame can
   *  leave the machine to need an address. */
  machineId: () => string | null;
  /** Membership for a terminal, or null when the terminal names no session. The
   *  terminal id IS the session id for every agent session; a service PTY names
   *  none and resolves to null, which is what makes a non-member expose no
   *  session tools. */
  membership: (terminalId: string) => SessionMembership | null;
  /** Whether a lead's carrier — this machine's own desktop app — is attached. */
  carrierPresent: () => boolean;
  now?: () => number;
  newId?: () => string;
}

function keyOf(ref: SessionMemberKey | SessionMemberRef): SessionMemberKey {
  return { machineId: ref.machineId, projectId: ref.projectId, sessionId: ref.sessionId };
}

function notMember(): SessionBusRefusal {
  return refuse("NOT_MEMBER", "this session is not a member of a multi-machine session");
}

function unknownTask(): SessionBusRefusal {
  return refuse("UNKNOWN_TASK", "no such task on this session");
}

function handleOf(rec: ArtifactRecord): ArtifactHandleView {
  return {
    artifactId: rec.artifactId,
    name: rec.name,
    mediaType: rec.mediaType,
    bytes: rec.bytes,
    sha256: rec.sha256,
    summary: rec.summary,
    taskId: rec.taskId,
    createdAt: rec.createdAt,
  };
}

export function createSessionBusApi(deps: SessionBusApiDeps): SessionBusApi {
  const now = deps.now ?? Date.now;
  const newId = deps.newId ?? (() => crypto.randomUUID());

  /** The one resolution every route runs first. A missing terminal id, a
   *  terminal that names no session, or a session with no membership row all
   *  reduce to the same answer, because they are the same fact: this caller has
   *  no business on the bus. */
  function resolve(terminalId: string | undefined): (SessionMembership & { lead: boolean; peer: boolean }) | null {
    if (!terminalId) return null;
    const m = deps.membership(terminalId);
    if (!m) return null;
    const lead = m.members.some((x) => x.state === "active");
    const peer = m.memberOf !== undefined;
    if (!lead && !peer) return null;
    return { ...m, lead, peer };
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

  /** The lead's session id on a peer, this session's own id on a lead. */
  function contextOf(m: SessionMembership & { peer: boolean }): string {
    return m.peer && m.memberOf ? m.memberOf.sessionId : m.sessionId;
  }

  function scopeOf(sessionId: string): SessionView["scope"] {
    return loadBrief(deps.abDir, deps.projectId, sessionId)?.scope ?? [];
  }

  function artifactsOf(sessionId: string): ReturnType<typeof loadArtifacts> {
    return loadArtifacts(deps.abDir, deps.projectId, sessionId);
  }

  function viewTask(sessionId: string, rec: TaskRecord): TaskView {
    const store = artifactsOf(sessionId);
    return {
      taskId: rec.taskId,
      contextId: rec.contextId,
      role: rec.role,
      state: rec.state,
      ...(rec.waitingOn === undefined ? {} : { waitingOn: rec.waitingOn }),
      title: rec.title,
      peer: rec.peer,
      createdAt: rec.createdAt,
      updatedAt: rec.updatedAt,
      ...(rec.expiresAt === undefined ? {} : { expiresAt: rec.expiresAt }),
      ...(rec.expiredAt === undefined ? {} : { expiredAt: rec.expiredAt }),
      ...(rec.canceledAt === undefined ? {} : { canceledAt: rec.canceledAt }),
      ...(rec.cancelReason === undefined ? {} : { cancelReason: rec.cancelReason }),
      findings: rec.findings,
      // Only handles this machine actually holds bytes for. An id that arrived
      // in an envelope from the other machine is deliberately not listed: naming
      // an artifact `get_artifact` cannot serve teaches the agent to distrust the
      // list, and cross-machine fetch is not wired on this route yet.
      artifacts: rec.artifactIds.flatMap((id) => {
        const found = artifactById(store, id);
        return found ? [handleOf(found)] : [];
      }),
    };
  }

  /** Resolve the artifact ids an agent attached to a task or a report into wire
   *  parts, refusing the whole call on the first id this session cannot serve:
   *  a report that silently dropped its evidence reads on the other machine as a
   *  report that had none. */
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

  function report(
    terminalId: string | undefined,
    taskId: string,
    body: ReportBody,
    state: "completed" | "failed",
  ): { ok: true } | SessionBusRefusal {
    const m = resolve(terminalId);
    if (!m) return notMember();
    if (!m.peer) return refuse("NOT_PEER", "only a session working a task reports on it");
    const rec = deps.coordinator.task(m.sessionId, taskId);
    if (!rec || rec.role !== "peer") return unknownTask();

    const artifacts = partsForArtifacts(m.sessionId, body.artifactIds);
    if (isRefusal(artifacts)) return artifacts;
    const parts: BusPart[] = [{ kind: "text", text: body.text ?? body.summary }, ...artifacts];
    const sent = deps.coordinator.report(
      {
        sessionId: m.sessionId,
        taskId,
        summary: body.summary,
        parts,
        ...(body.unexpected === undefined ? {} : { unexpected: body.unexpected }),
      },
      state,
    );
    return isRefusal(sent) ? sent : { ok: true };
  }

  return {
    role(terminalId): RoleView {
      const m = resolve(terminalId);
      if (!m) return { role: null, lead: false, peer: false, sessionId: null };
      const machineId = deps.machineId();
      return {
        // Lead wins the singular field on a machine that is both: it is the role
        // that can spend the budget, so a client rendering one word should
        // render that one.
        role: m.lead ? "lead" : "peer",
        lead: m.lead,
        peer: m.peer,
        sessionId: m.sessionId,
        ...(m.sessionName ? { sessionName: m.sessionName } : {}),
        contextId: contextOf(m),
        ...(machineId ? { machineId } : {}),
        projectId: deps.projectId,
      };
    },

    session(terminalId) {
      const m = resolve(terminalId);
      if (!m) return notMember();
      const self = selfRef(m);
      if (!self) return refuse("AGENT_NOT_READY", "this machine has no relay identity, so it has no bus address");
      const carrier = deps.carrierPresent();
      return {
        role: m.lead ? "lead" : "peer",
        lead: m.lead,
        peer: m.peer,
        sessionId: m.sessionId,
        contextId: contextOf(m),
        self,
        ...(m.memberOf ? { memberOf: m.memberOf } : {}),
        members: m.members.map((x) => ({ ...x, reachable: x.state === "active" && carrier })),
        scope: scopeOf(m.sessionId),
        ...(m.peer ? { brief: loadBrief(deps.abDir, deps.projectId, m.sessionId)?.brief } : {}),
        budget: deps.coordinator.budget(m.sessionId),
        openTaskIds: deps.coordinator
          .tasks(m.sessionId)
          .filter((t) => !isTerminal(t.state))
          .map((t) => t.taskId),
      };
    },

    brief(terminalId) {
      const m = resolve(terminalId);
      if (!m) return notMember();
      if (!m.peer || !m.memberOf) return refuse("NOT_PEER", "only a session created as a member of another has a brief");
      const stored = loadBrief(deps.abDir, deps.projectId, m.sessionId);
      if (!stored) {
        return refuse("UNKNOWN_TASK", "no brief was stored for this session");
      }
      return { brief: stored.brief, scope: stored.scope, lead: stored.lead };
    },

    peers(terminalId) {
      const m = resolve(terminalId);
      if (!m) return notMember();
      if (!m.lead) return refuse("NOT_LEAD", "only the lead session of a multi-machine session has peers");
      const carrier = deps.carrierPresent();
      return { peers: m.members.map((x) => ({ ...x, reachable: x.state === "active" && carrier })) };
    },

    listTasks(terminalId) {
      const m = resolve(terminalId);
      if (!m) return notMember();
      return { tasks: deps.coordinator.tasks(m.sessionId).map((t) => viewTask(m.sessionId, t)) };
    },

    getTask(terminalId, taskId) {
      const m = resolve(terminalId);
      if (!m) return notMember();
      const rec = deps.coordinator.task(m.sessionId, taskId);
      return rec ? viewTask(m.sessionId, rec) : unknownTask();
    },

    assign(terminalId, body) {
      const m = resolve(terminalId);
      if (!m) return notMember();
      if (!m.lead) return refuse("NOT_LEAD", "only a lead session assigns work to another machine");
      const wanted = body.peer;
      const member = m.members.find((x) =>
        x.state === "active"
        && (typeof wanted === "string"
          ? x.sessionId === wanted
          : x.machineId === wanted.machineId && x.projectId === wanted.projectId && x.sessionId === wanted.sessionId),
      );
      if (!member) {
        return refuse("UNKNOWN_PEER", "no active member of this session with that id; call antgrid_list_peers");
      }
      const artifacts = partsForArtifacts(m.sessionId, body.artifactIds);
      if (isRefusal(artifacts)) return artifacts;

      const assigned = deps.coordinator.assign({
        sessionId: m.sessionId,
        peer: member,
        summary: body.summary,
        parts: [{ kind: "text", text: body.instruction }, ...artifacts],
        ...(body.unexpected === undefined ? {} : { unexpected: body.unexpected }),
      });
      if (isRefusal(assigned)) return assigned;
      // Recorded after the mint so the ids the peer will name in a fetch are on
      // the lead's own task row too.
      return { ok: true, taskId: assigned.taskId, delivered: assigned.delivered };
    },

    cancelTask(terminalId, taskId, body) {
      const m = resolve(terminalId);
      if (!m) return notMember();
      if (!m.lead) return refuse("NOT_LEAD", "only the session that assigned a task can withdraw it");
      const rec = deps.coordinator.task(m.sessionId, taskId);
      if (!rec || rec.role !== "lead") return unknownTask();
      const done = deps.coordinator.cancel(m.sessionId, taskId, body.reason);
      return isRefusal(done) ? done : { ok: true };
    },

    answerPeer(terminalId, taskId, body) {
      const m = resolve(terminalId);
      if (!m) return notMember();
      if (!m.lead) return refuse("NOT_LEAD", "only the lead answers a peer's question");
      const rec = deps.coordinator.task(m.sessionId, taskId);
      if (!rec || rec.role !== "lead") return unknownTask();
      if (isTerminal(rec.state)) return refuse("TASK_TERMINAL", `this task is already ${rec.state}`);
      // The answer IS the hand-back: it moves the task out of input-required, so
      // a task that is not waiting on this session has nothing for it to carry.
      // Refused rather than sent as a bare message, because a peer that is not
      // blocked would read it mid-turn as an answer to something else.
      if (rec.state !== "input-required" || rec.waitingOn !== "lead") {
        return refuse("DUPLICATE_STATE", "this task is not waiting on an answer from this session");
      }
      const sent = deps.coordinator.report(
        {
          sessionId: m.sessionId,
          taskId,
          summary: body.summary,
          parts: [{ kind: "text", text: body.answer }],
        },
        "working",
      );
      return isRefusal(sent) ? sent : { ok: true };
    },

    openTask(terminalId, taskId) {
      const m = resolve(terminalId);
      if (!m) return notMember();
      if (!m.peer) return refuse("NOT_PEER", "only the session a task was assigned to can start it");
      const rec = deps.coordinator.task(m.sessionId, taskId);
      if (!rec || rec.role !== "peer") return unknownTask();
      const sent = deps.coordinator.report(
        { sessionId: m.sessionId, taskId, summary: `started: ${rec.title}`, parts: [{ kind: "text", text: rec.title }] },
        "working",
      );
      return isRefusal(sent) ? sent : { ok: true };
    },

    reportComplete(terminalId, taskId, body) {
      return report(terminalId, taskId, body, "completed");
    },

    reportFailure(terminalId, taskId, body) {
      return report(terminalId, taskId, body, "failed");
    },

    reportFinding(terminalId, body) {
      const m = resolve(terminalId);
      if (!m) return notMember();
      if (!m.peer || !m.memberOf) return refuse("NOT_PEER", "only a session working for a lead reports findings to it");
      if (body.taskId) {
        const rec = deps.coordinator.task(m.sessionId, body.taskId);
        if (!rec || rec.role !== "peer") return unknownTask();
      }
      const sent = deps.coordinator.message({
        sessionId: m.sessionId,
        taskId: body.taskId ?? null,
        to: m.memberOf,
        summary: body.summary,
        parts: [{ kind: "text", text: body.text ?? body.summary }],
        ...(body.unexpected === undefined ? {} : { unexpected: body.unexpected }),
        contextId: m.memberOf.sessionId,
      });
      return isRefusal(sent) ? sent : { ok: true, sent: sent.sent, held: sent.held };
    },

    askLead(terminalId, body) {
      const m = resolve(terminalId);
      if (!m) return notMember();
      if (!m.peer) return refuse("NOT_PEER", "only a session working a task asks its lead");
      const rec = deps.coordinator.task(m.sessionId, body.taskId);
      if (!rec || rec.role !== "peer") return unknownTask();

      // The block is reported FIRST: the pending row is this bridge's private
      // record of what was asked, and one written for a transition the
      // coordinator then refused would leave the peer showing a question nobody
      // was ever told about.
      const sent = deps.coordinator.report(
        {
          sessionId: m.sessionId,
          taskId: body.taskId,
          summary: body.summary,
          parts: [{ kind: "text", text: body.question }],
          // From the CAUSE, not from a body field (spec 3.4): this route exists
          // for exactly one cause, and it is the lead being asked.
          waitingOn: "lead",
        },
        "input-required",
      );
      if (isRefusal(sent)) return sent;

      const at = now();
      const requestId = newId();
      const row: PendingRequest = {
        requestId,
        taskId: body.taskId,
        contextId: rec.contextId,
        kind: "ask-lead",
        // The QUESTION, not its summary: this row is what `takeAskedQuestion`
        // hands the answer renderer, and the lead answered the question.
        question: fitQuestion(body.question),
        askedAt: at,
        expiresAt: at + ASK_EXPIRY_MS,
      };
      savePending(
        deps.abDir,
        deps.projectId,
        m.sessionId,
        openRequest(loadPending(deps.abDir, deps.projectId, m.sessionId), row, at),
      );
      return { ok: true, requestId };
    },

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
      if (body.taskId) {
        const rec = deps.coordinator.task(m.sessionId, body.taskId);
        if (!rec) return unknownTask();
      }
      const rec: ArtifactRecord = {
        artifactId: newId(),
        contextId: contextOf(m),
        taskId: body.taskId ?? null,
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
      saveArtifacts(deps.abDir, deps.projectId, m.sessionId, addArtifact(artifactsOf(m.sessionId), rec));
      return { ok: true, artifact: handleOf(rec) };
    },

    listArtifacts(terminalId) {
      const m = resolve(terminalId);
      if (!m) return notMember();
      return { artifacts: artifactsOf(m.sessionId).artifacts.map(handleOf) };
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

/** The pending row a peer's answer belongs to: the newest open `ask-lead` on
 *  that task, answered as the answer is rendered. Exported for the delivery
 *  path, which needs the question to echo — the ask and the answer can be hours
 *  and a context window apart, and an answer that reads on its own is the whole
 *  reason the row is kept. */
export function takeAskedQuestion(
  abDir: string,
  projectId: string,
  sessionId: string,
  taskId: string,
  at: number,
): string | null {
  const state = loadPending(abDir, projectId, sessionId);
  const open = requestsForTask(state, taskId)
    .filter((r) => r.kind === "ask-lead" && r.answeredAt === undefined && r.canceledAt === undefined)
    .sort((a, b) => a.askedAt - b.askedAt);
  const row = open[open.length - 1];
  if (!row) return null;
  const { next } = answerRequest(state, row.requestId, at);
  savePending(abDir, projectId, sessionId, next);
  return row.question;
}
