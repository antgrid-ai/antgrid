import { randomBytes, timingSafeEqual } from "node:crypto";

/**
 * Credentials for the browser half of the capture viewer.
 *
 * `host.json`'s bearer cannot be the one a page holds. A browser sends no
 * Authorization header on a navigation, so the only channel from the launcher
 * to the page is the URL — and that token opens `POST /control`, whose verbs
 * start and stop projects, check out branches and disclose checkout paths. A
 * URL reaches browser history, shell scrollback and whatever an operator pastes
 * into a bug report, so what travels there has to be worth strictly less than
 * what it stands in for.
 *
 * Two credentials, therefore, and neither can name a `ControlRequest` of its
 * own choosing:
 *   - a TICKET, single-use and short-lived, which is what rides the URL;
 *   - a SESSION, handed out once in exchange for a ticket, which reads the
 *     capture stream and arms capture.
 *
 * The exchange is the whole point: by the time anyone reads that history the
 * ticket is spent, and a spent one buys nothing.
 */

/** Long enough to cold-start a browser on a loaded machine, short enough that a
 *  ticket which never reached one is dead before the terminal has scrolled. */
export const TICKET_TTL_MS = 120_000;

/** Sliding window on a redeemed session, refreshed by every request that uses
 *  it. A viewer left open all day keeps working; a tab closed at lunch stops
 *  being a credential without anyone having to say so. */
const SESSION_IDLE_MS = 8 * 60 * 60 * 1_000;

/** Bounds what a repeated `--ui` accumulates in a long-lived host. Evicting the
 *  least recently used is right here: the tab someone is actually reading is by
 *  construction the one refreshing its window. */
const MAX_LIVE = 8;

/** token → expiry. Insertion order is LRU order because every refresh
 *  re-inserts, which is what makes the eviction above pick the right one. */
const tickets = new Map<string, number>();
const sessions = new Map<string, number>();

function newToken(): string {
  return randomBytes(32).toString("hex");
}

/** Constant-time over the whole (small) set rather than a Map lookup, matching
 *  what `bearerMatches` does for the host token — these are bearer credentials
 *  for the same plane and are compared the same way. */
function equal(a: string, b: string): boolean {
  const x = Buffer.from(a);
  const y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}

function sweep(store: Map<string, number>, now: number): void {
  for (const [token, expires] of store) if (expires <= now) store.delete(token);
}

function evict(store: Map<string, number>): void {
  while (store.size > MAX_LIVE) {
    const oldest = store.keys().next();
    if (oldest.done) return;
    store.delete(oldest.value);
  }
}

export function mintUiTicket(now: number = Date.now()): string {
  sweep(tickets, now);
  const ticket = newToken();
  tickets.set(ticket, now + TICKET_TTL_MS);
  evict(tickets);
  return ticket;
}

/** Spend a ticket for a session, or `null` if it is unknown, already spent or
 *  lapsed — the three are one answer on purpose, since telling them apart tells
 *  a guesser which half of the guess was right. */
export function redeemUiTicket(ticket: string, now: number = Date.now()): string | null {
  sweep(tickets, now);
  for (const [candidate, expires] of tickets) {
    if (!equal(candidate, ticket)) continue;
    // Burned before the session is minted, and burned even on the lapsed path:
    // a ticket is one launch, so a retry after a lost reply has to fail loudly
    // rather than hand out a second credential for a URL that still exists.
    tickets.delete(candidate);
    if (expires <= now) return null;
    const session = newToken();
    sessions.set(session, now + SESSION_IDLE_MS);
    evict(sessions);
    return session;
  }
  return null;
}

export function validateUiSession(token: string, now: number = Date.now()): boolean {
  sweep(sessions, now);
  for (const [candidate] of sessions) {
    if (!equal(candidate, token)) continue;
    // Delete-then-set slides the window AND moves this entry to the tail for
    // the LRU eviction above. It must return immediately: re-inserting during
    // iteration puts the key back in front of this very iterator.
    sessions.delete(candidate);
    sessions.set(candidate, now + SESSION_IDLE_MS);
    return true;
  }
  return false;
}

/** Test seam. Nothing in the host clears these — they die with the process, the
 *  same lifetime as the ring they read. */
export function resetNetwatchUiCredentials(): void {
  tickets.clear();
  sessions.clear();
}
