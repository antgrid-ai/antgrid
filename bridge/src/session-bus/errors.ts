// One refusal vocabulary for the whole bus, so a route's status code and a
// tool's error text are two renderings of one decision rather than two
// independent guesses. The HTTP status is the map's value because the loopback
// API is where a refusal first becomes visible; the MCP tools re-render the same
// code and reason without inventing either.

import { logger } from "../logger";

const log = logger.child({ component: "session-bus" });

export const SESSION_BUS_ERRORS = {
  /** Membership is binary: a caller either names a session this bridge holds
   *  or it does not. Shares its 403 with {@link REMOTE_ACCESS_OFF}, so a
   *  surface reading back from the status alone must read the code too — both
   *  are "not allowed", and neither clears by waiting. */
  NOT_MEMBER: 403,
  /** This machine's remote-access switch is off, and the target is on another
   *  machine. The switch gates BOTH directions: inbound has always been refused
   *  by `remoteFrameAllowed`, and since it governs whether this machine takes
   *  part in cross-machine messaging at all, a send out is refused on the same
   *  fact rather than left as the one leg that still leaves.
   *
   *  403 rather than 503 because nothing about this is transport, and no retry
   *  resolves it — a human flips a switch or it stays refused. It fires for a
   *  REPLY on a peer-opened thread as readily as for a first contact: half an
   *  exchange is the one-way channel this was turned off to prevent, and the
   *  peer cannot answer back through a gate that is already closed to it.
   *  Same-machine sends never reach it. */
  REMOTE_ACCESS_OFF: 403,
  /** A send whose address resolves to nothing HERE, where "here" is the live
   *  session index: no session by that id on this machine, or one in a
   *  repository the caller's project does not share. Terminal, which is why it
   *  keeps the 404 — a hallucinated address is the most common way to reach
   *  this code, and nothing about waiting makes it resolve. Also the answer to
   *  a thread id this session does not hold, and to a thread whose recorded
   *  peer disagrees with the address the caller also spelled. */
  UNKNOWN_PEER: 404,
  /** A send at another MACHINE that this one cannot currently route: no
   *  mirrored row for it, and no thread whose peer answered on it recently
   *  enough, over a live carrier route, to fall back on. The row may exist on
   *  the far side — a machine with remote access off publishes none at all — so
   *  the failure is about this machine's knowledge, not the peer's existence.
   *
   *  503 is the transport's answer, and the two ADDRESSING refusals under it —
   *  no row and no thread to route by, and a thread whose way home has lapsed —
   *  are not an invitation to retry, which is why both of those texts say so: a
   *  refusal returns before `coordinator.message`, the only place that charges
   *  the pair budget, so a retry loop here trips no ceiling and costs the caller
   *  nothing it would notice. What clears them is a frame from that machine or a
   *  row once it is reachable again, never another attempt.
   *
   *  The third text under this code is the carrier one — this machine's own
   *  desktop app is not attached, and it is what carries an exchange this
   *  session is OPENING — and it deliberately makes no such claim, because that
   *  condition does clear on its own the moment the app reattaches. */
  PEER_UNREACHABLE: 503,
  /** The caller's own project cannot be addressed at all: it has no git
   *  remote, so it has no repo key and therefore no peers (§5.1 fails closed).
   *  Distinct from an empty directory, which means the key resolved and nobody
   *  else is on it — and from `UNKNOWN_PEER`, which is a fact about the
   *  address rather than about the project doing the asking. Raised by the
   *  directory read and by a send alike, because `rowFor` answers null for a
   *  keyless caller before it has looked at the address at all. */
  NOT_ADDRESSABLE: 409,
  UNKNOWN_ARTIFACT: 404,
  /** §7.3: a `notify` addressed at a session that is not running. A stopped
   *  session never reaches the turn boundary a notify waits for — but for a
   *  SAME-MACHINE target this host can start on its own authority, `api.ts`
   *  wakes it instead of refusing (see `SessionBusApiDeps.startSession`), and
   *  this code never fires for that case. It still fires whenever waking is
   *  not available: a cross-machine target (starting a process on someone
   *  else's machine on the sender's behalf is not this host's call), a
   *  same-machine target on a project this host has not warmed, or any caller
   *  with no `startSession` hook wired at all. The text must name `post` as
   *  the verb that still reaches: a post lands in the mailbox whether or not
   *  anything is running to read it yet. */
  NOT_RUNNING: 409,
  /** The two per-pair ceilings of §7.4, and they stay two codes on purpose:
   *  `NOTIFY_RATE` is a rolling-hour rate limit the pair simply waits out and
   *  refuses one verb, naming `post` as the one that still reaches; `NO_PROGRESS`
   *  is a halt that time does not clear — only a human does
   *  (`SessionBusCoordinator.clearHalt`) — and it refuses every verb, not only
   *  `notify`. Collapsing them into one code would tell a caller who only needs
   *  to wait an hour that nothing but a human can free it. */
  NO_PROGRESS: 429,
  NOTIFY_RATE: 429,
  ENVELOPE_TOO_LARGE: 413,
  ARTIFACT_TOO_LARGE: 413,
  AGENT_NOT_READY: 503,
  /** The bus could not persist what the caller is about to be told it did. A
   *  refusal rather than a success with a warning in the log, because the agent
   *  acts on the answer: an artifact id it cannot resolve later is worse than a
   *  publish it knows to retry. */
  STORE_UNAVAILABLE: 503,
} as const;

export type SessionBusErrorCode = keyof typeof SESSION_BUS_ERRORS;

/** Every refusal the bus returns has this shape, and the `error` text is
 *  authored once at the point the decision is made — a caller relays it, never
 *  re-words it. */
export interface SessionBusRefusal {
  ok: false;
  code: SessionBusErrorCode;
  error: string;
}

export function refuse(code: SessionBusErrorCode, error: string): SessionBusRefusal {
  // The CODE alone, never the reason text. Every reason is bridge-authored
  // prose today, but several interpolate a caller-supplied id and nothing stops
  // the next one interpolating a summary — and this is the bus's single refusal
  // site, so a rule that holds here holds everywhere. The code is what a walk
  // through `host.log` needs: it says which decision refused, and the caller was
  // handed the sentence.
  log.debug({ code }, "bus refused");
  return { ok: false, code, error };
}

export function isRefusal(v: unknown): v is SessionBusRefusal {
  return typeof v === "object" && v !== null && (v as { ok?: unknown }).ok === false;
}
