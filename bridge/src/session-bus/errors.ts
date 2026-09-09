// One refusal vocabulary for the whole bus, so a route's status code and a
// tool's error text are two renderings of one decision rather than two
// independent guesses. The HTTP status is the map's value because the loopback
// API is where a refusal first becomes visible; the MCP tools re-render the same
// code and reason without inventing either.

export const SESSION_BUS_ERRORS = {
  /** The single 403. A caller either names a session this bridge holds or it
   *  does not; there is no second kind of caller left to refuse. */
  NOT_MEMBER: 403,
  /** Two refusals with no producer in the tree today, and neither is dead code:
   *  a directory row can name a session that has since stopped, and a send to a
   *  machine whose control plane is gone has to say which of the two happened. */
  UNKNOWN_PEER: 404,
  PEER_UNREACHABLE: 503,
  UNKNOWN_ARTIFACT: 404,
  NO_PROGRESS: 429,
  ENVELOPE_TOO_LARGE: 413,
  ARTIFACT_TOO_LARGE: 413,
  AGENT_NOT_READY: 503,
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
