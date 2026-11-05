// One refusal vocabulary for the whole bus, so a route's status code and a
// tool's error text are two renderings of one decision rather than two
// independent guesses. The HTTP status is the map's value because the loopback
// API is where a refusal first becomes visible; the MCP tools re-render the same
// code and reason without inventing either.

import { logger } from "../logger";
import type { BusHeldReason } from "./relay-transport";

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
  /** A send at another MACHINE that cannot be carried: the relay link has been
   *  down past the outbox's horizon, so there is nowhere for the message to wait,
   *  or a send names a machine the bridge has no way to address at all.
   *
   *  A message that simply could not leave yet is not this: it is held and
   *  retried, and the send answers with the rung it reached and the reason it is
   *  held. This code is for the case where no hold can help.
   *
   *  503 is the transport's answer. A refusal returns before
   *  `coordinator.message`, the only place that charges the pair budget, so a
   *  retry loop here trips no ceiling and costs the caller nothing it would
   *  notice. What clears it is the relay link coming back, so the text must not
   *  tell the caller the peer is gone. */
  PEER_UNREACHABLE: 503,
  /** The caller's own project cannot be addressed at all: it has no git
   *  remote, so it has no repo key and therefore no peers.
   *  Distinct from an empty directory, which means the key resolved and nobody
   *  else is on it — and from `UNKNOWN_PEER`, which is a fact about the
   *  address rather than about the project doing the asking. Raised by the
   *  directory read and by a send alike, because `rowFor` answers null for a
   *  keyless caller before it has looked at the address at all. */
  NOT_ADDRESSABLE: 409,
  UNKNOWN_ARTIFACT: 404,
  /** A `notify` addressed at a session that is not running. A stopped
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
  /** The two per-pair budget ceilings, and they stay two codes on purpose:
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
  /** The recipient machine has not published a bus key, so nothing can be
   *  sealed to it. Clears when it registers one. */
  NO_BUS_KEY: 409,
  /** The sender is not in this account's machine directory. */
  UNKNOWN_SENDER: 403,
  /** The recipient could not open the sealed message, typically because the
   *  sender sealed to a key the recipient has since replaced. */
  UNOPENABLE: 409,
  BAD_SIGNATURE: 403,
  /** The sealed header and the message body disagree about who sent it or who it
   *  is for. */
  HEADER_MISMATCH: 403,
  MALFORMED: 400,
  /** The message outlived its own expiry before it was applied. */
  STALE: 409,
  /** The outbox for one session is full and this message was pushed out by
   *  newer ones before the far side acknowledged it. */
  OUTBOX_FULL: 429,
  /** The message reached its expiry without the far side acknowledging it. */
  EXPIRED: 504,
  PLAINTEXT_TOO_LARGE: 413,
  /** A request-shaped bus frame arrived at a bridge that does not serve
   *  requests. */
  METHOD_NOT_ALLOWED: 403,
  /** The recipient machine's agent reach is off. A human changes it; waiting
   *  does not. */
  NOT_ALLOWED_AGENT_REACH: 403,
  /** The relay refused because the recipient is not an agent of this account. */
  RELAY_NOT_AGENT: 403,
  /** The relay refused because the message named its own sender. */
  RELAY_SELF: 400,
  /** One machine sent more requests in a minute than this one answers. Waiting
   *  clears it. */
  REQUEST_RATE: 429,
  /** A request got no response before its deadline. What it was waiting on, if
   *  anything, is the held reason that travels beside this code. */
  REQUEST_TIMEOUT: 504,
  /** A mutating request came from a machine the account has not made an
   *  orchestrator. Read from the directory, never from the request. */
  NOT_ORCHESTRATOR: 403,
  /** The answer did not fit in one sealed message. */
  RESPONSE_TOO_LARGE: 413,
  /** The session was made with elevated settings by a human, so another
   *  machine may not wake it. */
  SESSION_NOT_BUS_ELIGIBLE: 403,
  /** The request's params did not match the method's schema. */
  BAD_PARAMS: 400,
  UNKNOWN_PROJECT: 404,
  UNKNOWN_SESSION: 404,
  /** The method ran and failed here, or the other machine answered with a code
   *  this bridge has no word for. */
  REQUEST_FAILED: 502,
} as const;

export type SessionBusErrorCode = keyof typeof SESSION_BUS_ERRORS;

/** Every refusal the bus returns has this shape, and the `error` text is
 *  authored once at the point the decision is made — a caller relays it, never
 *  re-words it. */
export interface SessionBusRefusal {
  ok: false;
  code: SessionBusErrorCode;
  error: string;
  /** A request answered with a code this bridge has no entry for: the other
   *  machine's own word, shape-checked and never interpolated into `error`. */
  remoteCode?: string;
  held?: BusHeldReason;
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

/** One fixed sentence per code a message can end in, for the send line and the
 *  thread. Authored once and never interpolated: a code comes off the wire in a
 *  signed ack, and a sentence built from anything a peer controls would put the
 *  peer's words in front of an agent as the bridge's own. */
export const BUS_REFUSAL_TEXT: Record<string, string> = {
  REMOTE_ACCESS_OFF: "remote access is off on that machine, so it takes no messages from other machines",
  NOT_ALLOWED_AGENT_REACH: "that machine does not let other machines' agents reach its sessions",
  UNKNOWN_PEER: "that machine has no session with that address",
  UNKNOWN_SENDER: "that machine does not recognise this machine as part of the account",
  UNOPENABLE: "that machine could not open the message; update Antgrid on it, or wait for its key to refresh",
  BAD_SIGNATURE: "that machine could not verify who sent the message",
  HEADER_MISMATCH: "that machine found the message did not match its own header",
  MALFORMED: "that machine could not read the message",
  STALE: "the message had expired by the time that machine looked at it",
  OUTBOX_FULL: "too many messages were waiting to be sent, so this older one was dropped",
  EXPIRED: "the message expired before that machine acknowledged it",
  PLAINTEXT_TOO_LARGE: "the message is too large to send between machines; publish the bulk as an artifact and reference it",
  METHOD_NOT_ALLOWED: "that machine does not accept this kind of message",
  RELAY_NOT_AGENT: "the relay says the target is not one of this account's machines",
  RELAY_SELF: "a message cannot be addressed to the machine it is sent from",
  NO_BUS_KEY: "that machine has not published a messaging key yet",
  REQUEST_RATE: "that machine is receiving requests from this one faster than it answers; wait a minute and ask again",
  REQUEST_TIMEOUT: "that machine did not answer in time",
  NOT_ORCHESTRATOR: "that machine takes this kind of request only from a machine the account has made an orchestrator",
  RESPONSE_TOO_LARGE: "the answer was too large to send between machines",
  SESSION_NOT_BUS_ELIGIBLE: "that session was set up by a person with settings another machine may not start it under",
  BAD_PARAMS: "the request's parameters were not what that method takes",
  UNKNOWN_PROJECT: "that machine has no such project",
  UNKNOWN_SESSION: "that machine has no such session in that project",
  REQUEST_FAILED: "that machine could not carry out the request",
};

/** The sentence for a terminal code, with a generic one for a code this bridge
 *  has no text for, which is a newer peer's code and not an error here. */
export function refusalSentence(code: string): string {
  return BUS_REFUSAL_TEXT[code] ?? "the other machine refused the message";
}

/** The shape a code another machine sent must have before it is echoed to a
 *  caller. One pattern for the api that forwards it and the tool that prints
 *  it, so a code the one passes is never dropped by the other. */
export const REMOTE_CODE_PATTERN = /^[A-Z0-9_]{1,64}$/;

/** Why a message is still on this machine, for the held send line. Exhaustive,
 *  so a new reason fails to compile until it has a sentence. */
export const BUS_HELD_REASON_TEXT: Record<BusHeldReason, string> = {
  "no-transport": "this bridge has no connection to the relay",
  "central-offline": "this machine is not connected to the relay right now",
  "relay-unsupported": "the relay does not carry messages between machines yet",
  "directory-unavailable": "this machine has not yet learned which machines are on the account",
  "no-bus-key": "the other machine has not published a messaging key yet",
  "paced": "messages are being sent faster than the relay accepts, so this one is waiting its turn",
  "remote-access-off": "remote access is off on this machine",
  "relay-queue-full": "the relay's queue for that machine is full",
  "relay-rate-limited": "the relay is rate limiting this machine",
  "relay-recipient-outdated": "the other machine runs an older Antgrid that cannot receive this; update Antgrid on it",
  "ack-unverified": "the other machine's acknowledgement could not be verified",
  "recipient-key-stale": "the other machine's messaging key changed; this machine is refreshing it",
};
