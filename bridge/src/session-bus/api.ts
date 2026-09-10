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
  type BusEnvelope,
  type BusPart,
} from "../protocol";
import {
  ARTIFACT_CHUNK_BYTES,
  LOCAL_MACHINE_ID,
  MAX_PART_CHARS,
  MAX_PARTS,
  MAX_SUMMARY_CHARS,
  MAX_UNEXPECTED_CHARS,
} from "./constants";
import { addressesSameSession, namesMachine } from "./address";
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
import { entriesForThread, type LoggedEnvelope } from "./message-log";
import { unreadPosts, type MailboxPost } from "./mailbox";
import { threadById, type ThreadRow } from "./thread-store";
import { isRefusal, refuse, type SessionBusRefusal } from "./errors";

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

/** Where a send is aimed. `machineId` is nullable AND optional, and an absent
 *  one means THIS machine: {@link SessionDirectoryRow.machineId} is null in
 *  local mode, so an address copied off a row there has no machine to spell and
 *  requiring one would leave a local-mode agent unable to name its own peers. */
const SendTargetSchema = z
  .object({
    machineId: z.string().min(1).max(200).nullable().optional(),
    projectId: z.string().min(1).max(200),
    sessionId: z.string().min(1).max(200),
  })
  .strict();

/** The fields a message carries whichever verb sends it. Shared as one shape so
 *  the two bodies cannot drift into accepting different messages. */
const messageFields = {
  summary: z.string().min(1).max(MAX_SUMMARY_CHARS),
  text: z.string().min(1).max(MAX_PART_CHARS).optional(),
  artifactIds: z.array(z.string().min(1).max(200)).max(MAX_PARTS).optional(),
  /** "Here is what you asked for, and separately, here is something you did not
   *  ask about" — first-class so it is not a smuggled instruction inside the
   *  text. */
  unexpected: z.string().min(1).max(MAX_UNEXPECTED_CHARS).optional(),
};

// Enforced in the schema, like the publish body's own rule: a message with
// neither text nor an artifact is a caller that does not know what it is
// sending, and it answers 400 rather than crossing as an empty envelope.
const carriesBody = (b: { text?: string | undefined; artifactIds?: string[] | undefined }): boolean =>
  b.text !== undefined || (b.artifactIds?.length ?? 0) > 0;
const CARRIES_BODY_MESSAGE = { message: "pass text, artifactIds, or both" };

export const SendBodySchema = z
  .object({
    /** Optional only when `threadId` names a thread, which already records who
     *  is on the other end. Making an agent respell an address to continue an
     *  exchange is how a continuation lands on the wrong session, and the only
     *  rendering it could copy that address from is a joined string. */
    to: SendTargetSchema.optional(),
    ...messageFields,
    /** Absent OPENS a thread, whose id comes back on the result. §4.3 makes the
     *  id bridge-owned, so the only id an agent may put here is one it was
     *  told. */
    threadId: z.string().min(1).max(200).optional(),
  })
  .strict()
  .refine(carriesBody, CARRIES_BODY_MESSAGE)
  .refine((b) => b.to !== undefined || b.threadId !== undefined, {
    message: "pass to, threadId, or both",
  });

export type SendBody = z.infer<typeof SendBodySchema>;

/** A reply addresses the THREAD: the id is required and the address is not,
 *  because the thread row already records its peer and making an agent respell
 *  an address it was never given is how a reply misroutes. */
export const ReplyBodySchema = z
  .object({
    to: SendTargetSchema.optional(),
    ...messageFields,
    threadId: z.string().min(1).max(200),
  })
  .strict()
  .refine(carriesBody, CARRIES_BODY_MESSAGE);

export type ReplyBody = z.infer<typeof ReplyBodySchema>;

/** The shape both send bodies satisfy, so one implementation answers three
 *  verbs. An absent `to` is legal only beside a thread that records the peer. */
interface SendRequest {
  to?: { machineId?: string | null | undefined; projectId: string; sessionId: string } | undefined;
  summary: string;
  text?: string | undefined;
  artifactIds?: string[] | undefined;
  unexpected?: string | undefined;
  threadId?: string | undefined;
}

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

export interface SendResultView {
  ok: true;
  messageId: string;
  /** Always returned, including for a send that supplied one. §4.3 makes the id
   *  bridge-owned precisely so an agent cannot invent one, which leaves an agent
   *  never told the id unable to reply on the thread it just opened. */
  threadId: string;
  /** That the frame LEFT this machine, never that it arrived: the other end's
   *  receipt is the only honest witness (E6). */
  sent: boolean;
  held: boolean;
  /** Whether this send opened the thread — §7.4's definition of progress. */
  opensThread: boolean;
}

/** An artifact an inbound message NAMES: a reference to bytes on the machine
 *  that published them, never a handle this bridge can serve. */
export interface InboxArtifactView {
  artifactId: string;
  name: string;
  mediaType: string;
  bytes: number;
  sha256: string;
  summary: string;
}

export interface InboxPostView {
  messageId: string;
  threadId: string | null;
  contextId: string;
  at: number;
  from: SessionMemberKey;
  summary: string;
  /** The body, rendered here so a reader needs no second call per row. */
  text: string[];
  unexpected?: string;
  artifacts: InboxArtifactView[];
}

export interface ThreadEntryView {
  direction: "in" | "out";
  at: number;
  peer: SessionMemberKey;
  summary: string;
  text: string[];
  /** Outbound entries only, and its absence is "no receipt yet" rather than a
   *  failure — a receipt is fire-and-forget and an unacked message is never
   *  retried. This read is the only place that stamp is visible at all. */
  deliveredAt?: number;
}

export interface SessionBusApi {
  /** Every session addressable from this terminal's own (§5.5), sorted. Async
   *  where the artifact verbs are not: the branch each row is ranked on is read
   *  fresh, which is a git spawn, and a request is the one place that is
   *  affordable. */
  listSessions(
    terminalId: string | undefined,
  ): Promise<
    | { sessions: SessionDirectoryRow[]; truncated: number; reach: DirectoryReach; machineId: string | null }
    | SessionBusRefusal
  >;
  /** §7.1's two verbs. Both synchronous, and so is everything below them: what a
   *  send consults — one directory row, the pair's budget, this session's own
   *  artifacts — is in memory or on local disk. {@link listSessions} is async
   *  for the one reason a send must not inherit, a git spawn per row, which is
   *  also why nothing here resolves a target through `directory.list()`. */
  post(terminalId: string | undefined, body: SendBody): SendResultView | SessionBusRefusal;
  notify(terminalId: string | undefined, body: SendBody): SendResultView | SessionBusRefusal;
  reply(terminalId: string | undefined, body: ReplyBody): SendResultView | SessionBusRefusal;
  /** Unread posts, and the count of the ones this session will never see.
   *  Reading MARKS READ: what was handed over has been delivered. */
  inbox(terminalId: string | undefined): { posts: InboxPostView[]; dropped: number } | SessionBusRefusal;
  /** One exchange, both directions, with the receipt on each outbound entry. */
  thread(
    terminalId: string | undefined,
    threadId: string,
  ): { threadId: string; contextId: string; entries: ThreadEntryView[] } | SessionBusRefusal;
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
  /** Whether this machine is reachable from mobile at all — the same switch
   *  {@link SessionBusApiDeps.carrierPresent}'s frame delivery answers to. Read
   *  by the verb layer's own gate (§6.3): a leg that leaves this machine with
   *  the switch off is refused where the agent can see the refusal, rather than
   *  queued and silently undelivered. Per-pair spend is NOT here — the
   *  coordinator charges and refuses it at the single point every frame
   *  leaves through, so no caller of this API can spend around it. */
  remoteAccessEnabled: () => boolean;
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

function textPartsOf(envelope: BusEnvelope): string[] {
  const text: string[] = [];
  for (const part of envelope.parts) {
    if (part.kind === "text") text.push(part.text);
  }
  return text;
}

function artifactViewsOf(envelope: BusEnvelope): InboxArtifactView[] {
  const views: InboxArtifactView[] = [];
  for (const part of envelope.parts) {
    if (part.kind !== "artifact") continue;
    views.push({
      artifactId: part.artifactId,
      name: part.name,
      mediaType: part.mediaType,
      bytes: part.bytes,
      sha256: part.sha256,
      summary: part.summary,
    });
  }
  return views;
}

function inboxViewOf(post: MailboxPost): InboxPostView {
  return {
    messageId: post.messageId,
    threadId: post.threadId,
    contextId: post.contextId,
    at: post.at,
    from: post.from,
    summary: post.summary,
    text: textPartsOf(post.envelope),
    ...(post.envelope.metadata.unexpected === undefined
      ? {}
      : { unexpected: post.envelope.metadata.unexpected }),
    artifacts: artifactViewsOf(post.envelope),
  };
}

function threadEntryOf(entry: LoggedEnvelope): ThreadEntryView {
  return {
    direction: entry.direction,
    at: entry.at,
    peer: entry.peer,
    summary: entry.envelope.metadata.summary,
    text: textPartsOf(entry.envelope),
    ...(entry.deliveredAt === undefined ? {} : { deliveredAt: entry.deliveredAt }),
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

  /** Which exchange a message or an artifact belongs to. A session names its own
   *  contexts by its own id, but a thread it did not open rides the context the
   *  OPENER named, and the thread row is the only thing on this machine that
   *  remembers it — filing under the session's own id there hides the artifact
   *  from every thread-scoped read of that exchange, and routes an answer to
   *  this machine's own desktop, which accepts it and reports it sent. */
  function contextOf(m: SessionMembership, thread: ThreadRow | null): string {
    return thread?.contextId ?? m.sessionId;
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

  /**
   * The one send, under whichever verb asked for it.
   *
   * The refusal ORDER is what this function exists to hold. Every rung is a
   * different remedy — read the mail, wait an hour, fetch a human, flip a
   * switch, open the desktop — so a rung that ran out of turn would answer a
   * caller truthfully and still send it after the wrong one.
   */
  function sendMessage(
    terminalId: string | undefined,
    verb: "post" | "notify",
    req: SendRequest,
  ): SendResultView | SessionBusRefusal {
    const m = resolve(terminalId);
    if (!m) return notMember();

    // The THREAD STORE, never the mailbox: a session that was notified holds no
    // mailbox row at all, so a mailbox-side lookup would omit the context for
    // every reply to a notify — and the coordinator then defaults it to the
    // replier's own session, which resolves as a lead and sends the answer to
    // this machine's desktop app, where it is accepted and reported sent.
    let thread: ThreadRow | null = null;
    if (req.threadId !== undefined) {
      thread = threadById(deps.coordinator.threads(m.sessionId), req.threadId);
      // A thread row is the whole of what an id on a send resolves through, so
      // an id naming none is an address that resolves to nothing — the same
      // fact `UNKNOWN_PEER` carries for a member with no row, with the text
      // saying which half is missing. Defaulting instead is the misroute above.
      if (!thread) {
        return refuse(
          "UNKNOWN_PEER",
          `no thread "${req.threadId}" on this session; threads age out, so open a new one by sending without an id`,
        );
      }
    }

    if (!deps.directory) {
      return refuse("AGENT_NOT_READY", "this bridge has no session directory, so it cannot resolve who this addresses");
    }
    const selfMachineId = deps.machineId() ?? LOCAL_MACHINE_ID;

    // The thread's own record of who is on the other end WINS over an address
    // the caller also spelled, and a disagreement is refused rather than
    // reconciled: the context travels from the thread either way, so a send
    // that followed the caller's target instead would reach a session that does
    // not hold that exchange, and file the frame under a peer nobody there
    // recognises.
    if (thread && req.to) {
      const claimed: SessionMemberKey = {
        // An omitted machine means THIS machine everywhere else, but beside a
        // thread id it means unspecified: the caller is naming which session it
        // thinks it is answering, not relocating it. Defaulting to self here
        // would refuse every abbreviated address for a remote thread.
        machineId: req.to.machineId ?? thread.peer.machineId,
        projectId: req.to.projectId,
        sessionId: req.to.sessionId,
      };
      if (!addressesSameSession(thread.peer, claimed)) {
        return refuse(
          "UNKNOWN_PEER",
          "that thread is with a different session; omit `to` to answer it, or omit `threadId` to open a new exchange",
        );
      }
    }
    const addr = thread ? thread.peer : req.to;
    // Unreachable through the body schema — one of the two is required, and a
    // thread row always carries its peer — and a refusal rather than a throw so
    // that stays true if the schema is ever loosened.
    if (!addr) return refuse("UNKNOWN_PEER", "this send names no target and its thread records no peer");

    const target: SessionMemberKey = {
      machineId: addr.machineId ?? selfMachineId,
      projectId: addr.projectId,
      sessionId: addr.sessionId,
    };

    // AHEAD of the row read, because each is a fact about THIS machine that
    // needs no row to decide — and because each is itself what empties the
    // mirror a row would come from. Read after it, both would be reachable only
    // in the seconds between a switch flip and the next push, and every
    // steady-state send would answer "no session with that address": an agent
    // would re-read the directory, find it empty, and conclude the peer does
    // not exist rather than tell its human to flip one switch.
    if (!namesMachine(target.machineId, selfMachineId)) {
      // §6.3's send half, refused where the sending agent can read it rather
      // than accepted and left queued behind a switch only a human at this
      // machine can flip.
      if (!deps.remoteAccessEnabled()) {
        return refuse(
          "REMOTE_ACCESS_OFF",
          "this machine's remote access is off, so nothing may leave it; a session on this machine is still reachable",
        );
      }
      // The desktop app carries every off-machine leg (§6.1). Without it the
      // send would answer sent:false with the message held, which every surface
      // renders as a success.
      if (!deps.carrierPresent()) {
        return refuse(
          "PEER_UNREACHABLE",
          "this machine's desktop app is not attached, and it is what carries a message to another machine",
        );
      }
    }

    // The exact-address read, which is why it is not `list()`: a send must not
    // pay a branch probe per row to learn one row exists.
    const row = deps.directory.rowFor(
      { projectId: deps.projectId },
      { machineId: addr.machineId ?? null, projectId: addr.projectId, sessionId: addr.sessionId },
    );
    if (!row) {
      return refuse(
        "UNKNOWN_PEER",
        "no session with that address is offered here: the row may be gone, or its machine may not be reachable from this one",
      );
    }

    // §7.4, and ahead of liveness on purpose: a halted pair told "that session
    // is not running" would go wait for something that cannot free it, when
    // what it needs is a human on the other session. Read only — the
    // coordinator re-decides on the way through and is the one place that
    // charges it, so nothing is spent here and nothing is spent twice.
    const pairRefusal = deps.coordinator.pairRefusal(m.sessionId, target, verb);
    if (pairRefusal) return pairRefusal;

    // §7.3, and only the state it names: a STOPPED session never reaches a turn
    // boundary. An idle one reaches it at once — the delivery queue hands a line
    // to an idle session immediately — so refusing there would refuse a live
    // peer at rest, which is what every session is between turns.
    if (verb === "notify" && row.activity === "stopped") {
      return refuse(
        "NOT_RUNNING",
        "that session is not running, so it will not reach the turn boundary a notify waits for; antgrid_post lands in its mailbox instead",
      );
    }

    const attached = partsForArtifacts(m.sessionId, req.artifactIds);
    if (isRefusal(attached)) return attached;
    const parts: BusPart[] = [
      ...(req.text === undefined ? [] : [{ kind: "text", text: req.text } as BusPart]),
      ...attached,
    ];

    return deps.coordinator.message({
      sessionId: m.sessionId,
      verb,
      threadId: req.threadId ?? null,
      to: target,
      summary: req.summary,
      parts,
      contextId: contextOf(m, thread),
      ...(req.unexpected === undefined ? {} : { unexpected: req.unexpected }),
    });
  }

  return {
    post(terminalId, body) {
      return sendMessage(terminalId, "post", body);
    },

    notify(terminalId, body) {
      return sendMessage(terminalId, "notify", body);
    },

    // A reply answers on a thread the peer is waiting on, so it takes the
    // interrupting verb. §7.1 puts that choice in the VERB rather than in a
    // flag, which leaves `post` carrying a threadId as the way to answer a
    // thread without interrupting.
    reply(terminalId, body) {
      return sendMessage(terminalId, "notify", body);
    },

    inbox(terminalId) {
      const m = resolve(terminalId);
      if (!m) return notMember();
      const mailbox = deps.coordinator.mailbox(m.sessionId);
      const unread = unreadPosts(mailbox);
      const posts = unread.map(inboxViewOf);
      // Handing it over is what spends the unread flag, which is why the
      // coordinator's getter deliberately does not: a read that did not mark
      // would re-offer the same mail forever.
      if (unread.length > 0) {
        deps.coordinator.markMailboxRead(m.sessionId, unread.map((p) => p.messageId));
      }
      // `dropped` rides every answer, zero included (§7.4): a reader that cannot
      // tell an empty inbox from an emptied one has been told the wrong thing,
      // not merely told less.
      return { posts, dropped: mailbox.dropped };
    },

    thread(terminalId, threadId) {
      const m = resolve(terminalId);
      if (!m) return notMember();
      const row = threadById(deps.coordinator.threads(m.sessionId), threadId);
      if (!row) {
        return refuse("UNKNOWN_PEER", `no thread "${threadId}" on this session; threads age out with the mailbox`);
      }
      return {
        threadId,
        contextId: row.contextId,
        entries: entriesForThread(deps.coordinator.messages(m.sessionId), threadId).map(threadEntryOf),
      };
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
      const rec: ArtifactRecord = {
        artifactId: newId(),
        // Filed under this session's own exchange: the publish body names no
        // thread, so nothing here can say the artifact belongs to one a peer
        // opened.
        contextId: contextOf(m, null),
        threadId: null,
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
      // The caller's own machine, so a renderer can tell a local row from a
      // peer's. A row carries the machine it belongs to and nothing that says
      // which one is home, and deriving it by elimination from the reach report
      // would be wrong in exactly the state that matters: a peer whose rows all
      // expired is still named there while contributing none.
      return { sessions: answer.rows, truncated: answer.truncated, reach: answer.reach, machineId: deps.machineId() };
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
