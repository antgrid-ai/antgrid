// One refusal vocabulary for the whole bus, so a route's status code and a
// tool's error text are two renderings of one decision rather than two
// independent guesses. The HTTP status is the map's value because the loopback
// API is where a refusal first becomes visible; the MCP tools re-render the same
// code and reason without inventing either.

export const SESSION_BUS_ERRORS = {
  /** Membership is binary: a caller either names a session this bridge holds
   *  or it does not. Not the only 403 — `REMOTE_ACCESS_OFF` below is the
   *  other, and it is about the machine rather than the caller, so a surface
   *  that has lost the code and is reading back from the status alone cannot
   *  tell the two apart. */
  NOT_MEMBER: 403,
  /** A send whose address resolves to nothing: {@link SessionDirectory.rowFor}
   *  found no row, local or mirrored, for the machine/project/session it was
   *  given. Covers both of the row's own dead ends — a session that has since
   *  stopped and been forgotten, and a project this bridge never opened. */
  UNKNOWN_PEER: 404,
  /** A send addressed at a machine `rowFor` cannot currently resolve a row
   *  for — no mirrored card for that machine on this repo key, or the mirror
   *  has gone stale (`REMOTE_CARRIER_SILENCE_MS`). The row may exist on the
   *  far side; this machine simply has nothing current to route it through. */
  PEER_UNREACHABLE: 503,
  /** The caller's own project cannot be addressed at all: it has no git
   *  remote, so it has no repo key and therefore no peers (§5.1 fails closed).
   *  Distinct from an empty directory, which means the key resolved and nobody
   *  else is on it. */
  NOT_ADDRESSABLE: 409,
  UNKNOWN_ARTIFACT: 404,
  /** §7.3: a `notify` addressed at a session that is not running. Refused
   *  rather than queued, because a stopped session never reaches the turn
   *  boundary a notify waits for, and starting it on the sender's behalf is
   *  not available — the session belongs to someone else. The text must name
   *  `post` as the verb that still reaches: a post lands in the mailbox
   *  whether or not anything is running to read it yet. */
  NOT_RUNNING: 409,
  /** §6.3's send half: this machine's own remote-access switch is off, so a
   *  frame addressed at another machine is refused here, where the sending
   *  agent can see why, rather than accepted and left to queue undelivered
   *  forever behind a switch nobody is going to flip from in here. */
  REMOTE_ACCESS_OFF: 403,
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
  return { ok: false, code, error };
}

export function isRefusal(v: unknown): v is SessionBusRefusal {
  return typeof v === "object" && v !== null && (v as { ok?: unknown }).ok === false;
}
