// One refusal vocabulary for the whole bus, so a route's status code and a
// tool's error text are two renderings of one decision rather than two
// independent guesses. The HTTP status is the map's value because the loopback
// API is where a refusal first becomes visible; the MCP tools re-render the same
// code and reason without inventing either.

export const SESSION_BUS_ERRORS = {
  NOT_MEMBER: 403,
  NOT_LEAD: 403,
  NOT_PEER: 403,
  UNKNOWN_PEER: 404,
  UNKNOWN_TASK: 404,
  // 400 rather than 404: the caller named no task at all, which is a malformed
  // request and not a task this session cannot find.
  NO_TASK: 400,
  UNKNOWN_ARTIFACT: 404,
  TASK_TERMINAL: 409,
  DUPLICATE_STATE: 409,
  TASK_CAP: 429,
  TASK_RATE: 429,
  NO_PROGRESS: 429,
  ENVELOPE_TOO_LARGE: 413,
  ARTIFACT_TOO_LARGE: 413,
  PEER_UNREACHABLE: 503,
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
