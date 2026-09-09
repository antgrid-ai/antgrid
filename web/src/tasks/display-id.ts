/**
 * The display id a person sees and types: `ANT-14`.
 *
 * `Task.number` is the address, but it is never the string a user holds — a task
 * is written as `ANT-14` in the UI, in a branch name, and in the link this app
 * writes into a GitHub issue body. Both forms therefore have to resolve, or a
 * link somebody copied out of an issue 404s.
 *
 * The prefix is one constant rather than a literal at each call site because the
 * only reason it is not already per-account is that v1 has no reason to make it
 * one. When it becomes a column, this is the single place that changes.
 */
export const TASK_ID_PREFIX = "ANT";

/** The upper bound is the int4 column and the `[1-9]` floor is the sequence: the
 *  point is that an out-of-range literal is a miss here rather than a driver
 *  error from Postgres. */
const NUMBER_PATTERN = /^[1-9][0-9]{0,8}$/;

export function formatTaskId(number: number): string {
  return `${TASK_ID_PREFIX}-${number}`;
}

/**
 * Read `14` or `ANT-14` — case-insensitively, because a user typing the id into
 * a search box types it however they type it, and a URL is not case-normalized
 * on its way here.
 *
 * Returns null for anything else, including another account's prefix: this is a
 * parser, and refusing here is what keeps the route's 404 the only answer a
 * caller ever gets for an id it may not have.
 */
export function parseTaskId(raw: string): number | null {
  const trimmed = raw.trim();
  const bare = trimmed.toUpperCase().startsWith(`${TASK_ID_PREFIX}-`)
    ? trimmed.slice(TASK_ID_PREFIX.length + 1)
    : trimmed;
  if (!NUMBER_PATTERN.test(bare)) return null;
  return Number(bare);
}
