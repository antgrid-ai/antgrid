// One builder for every AgentError the chat layer emits. The TAXONOMIES stay
// per-agent — codex's error tags and opencode's error names describe different
// failures — so only the shape is shared: a single place decides which optional
// fields exist and in what order they land on the wire.

import type { AgentError } from "../protocol";

/** Category+retryability pair a provider's own failure table resolves to. */
export type ErrorClass = { category: AgentError["category"]; retryable: boolean };

/** The answer for a failure no provider table recognizes: deliberately coarse,
 *  because guessing a category the app parks or retries on is worse than
 *  admitting we don't know. */
const UNKNOWN: ErrorClass = { category: "unknown", retryable: false };

export function agentError(f: {
  category: AgentError["category"];
  message: string;
  retryable: boolean;
  retryAfterMs?: number;
  httpStatus?: number;
  provider?: string;
  raw?: unknown;
}): AgentError {
  return {
    category: f.category,
    message: f.message,
    retryable: f.retryable,
    ...(f.retryAfterMs !== undefined ? { retryAfterMs: f.retryAfterMs } : {}),
    ...(f.httpStatus !== undefined ? { httpStatus: f.httpStatus } : {}),
    ...(f.provider !== undefined ? { provider: f.provider } : {}),
    ...(f.raw !== undefined ? { raw: f.raw } : {}),
  };
}

/** Look a provider's own failure name/tag up in its table. */
export function byName(table: Readonly<Record<string, ErrorClass>>, name: string): ErrorClass {
  return table[name] ?? UNKNOWN;
}
