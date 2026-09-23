import { createHash, timingSafeEqual } from "node:crypto";
import { Hono } from "hono";
import { EndpointIdSchema, peerAuthorizationSnapshotSchema } from "antgrid-wire";
import type { DB } from "../db/index.js";
import type { Env } from "../env.js";
import { admitRelayEndpoint } from "../models/peer-authorization.js";

// Upstream runs the whole access check off a detached task with nothing
// server-side bounding it once the client's 101 is sent (`$UP/src/server/
// http_server.rs:631-655,1047`) — this deadline is the only thing standing
// between a stalled dependency here and relay tasks piling up unbounded.
const ACCESS_CHECK_DEADLINE_MS = 2_000;
const MAX_PENDING = 32;
const PATH = "/internal/iroh-access";

function bearerMatches(presented: string, expected: string): boolean {
  // Hash first so timingSafeEqual always compares equal-length buffers —
  // comparing raw strings of different lengths throws instead of failing
  // closed, and would otherwise leak the token's length via the exception.
  return timingSafeEqual(
    createHash("sha256").update(presented).digest(),
    createHash("sha256").update(expected).digest(),
  );
}

export function irohAccessRoutes(
  deps: { db: DB; env: Env },
  // Test-only seam: lets a test stand in a slow/instrumented admission check
  // without spinning up real concurrency or latency against Postgres.
  admit: typeof admitRelayEndpoint = admitRelayEndpoint,
) {
  const r = new Hono();
  // Local env, not the request: the relay may only claim a plaintext origin
  // when this process was itself configured to approve one.
  const allowInsecureRelay = deps.env.ANTGRID_DEV_INSECURE_RELAY === true;
  const relayQuerySchema = peerAuthorizationSnapshotSchema(allowInsecureRelay).shape.relayUrls.element;
  let pending = 0;

  r.post(PATH, async (c) => {
    c.header("Cache-Control", "no-store");
    const token = deps.env.PEER_RELAY_ACCESS_TOKEN;
    const presented = /^Bearer (.+)$/.exec(c.req.header("authorization") ?? "")?.[1];
    if (!token || !presented || !bearerMatches(presented, token)) return c.text("false");

    const endpointId = EndpointIdSchema.safeParse(c.req.header("x-iroh-nodeid"));
    if (!endpointId.success) return c.text("false");

    // `relayUrlsSchema`'s own refine calls `new URL()` unguarded, which
    // throws (rather than failing the check) on a syntactically invalid
    // value — catch that here so a malformed query denies instead of 500s.
    let relayQuery: ReturnType<typeof relayQuerySchema.safeParse>;
    try { relayQuery = relayQuerySchema.safeParse(c.req.query("relay")); }
    catch { return c.text("false"); }
    if (!relayQuery.success) return c.text("false");
    // Compare by normalised href, not raw string equality: `https://x` and
    // `https://x/` both parse as the same origin, and reqwest carries the
    // configured query URL through unmodified (`IntoUrl for Url`). Use the
    // matched CONFIGURED entry (not the raw query) from here on — the model's
    // own admission check does an exact-string match against `IROH_RELAY_URLS`,
    // which a differently-formatted but equivalent query string would fail.
    const matchedRelay = deps.env.IROH_RELAY_URLS.find(
      (approved) => new URL(approved).href === new URL(relayQuery.data).href,
    );
    if (!matchedRelay) return c.text("false");

    if (pending >= MAX_PENDING) return c.text("false", 503);
    pending++;
    // Pass the full configured relay set, never [matchedRelay] — a single-
    // relay call collapses the sorted set `authorizationSnapshot` hashes into
    // `relayConfigHash`, bumping the policy generation (and pushing an
    // outbox row) on every relay-bound admission instead of only on a real
    // config change.
    // `allowInsecureRelay` must reach the model too: the snapshot it mints is
    // re-validated against the same schema, so a dev `http:` relay would
    // otherwise throw there and deny every endpoint.
    const work = admit(deps.db, endpointId.data, matchedRelay, deps.env.IROH_RELAY_URLS, { allowInsecureRelay })
      .catch(() => false)
      .finally(() => { pending--; });
    let timer: ReturnType<typeof setTimeout> | undefined;
    const deadline = new Promise<boolean>((resolve) => {
      timer = setTimeout(() => resolve(false), ACCESS_CHECK_DEADLINE_MS);
    });
    const allowed = await Promise.race([work, deadline]).finally(() => clearTimeout(timer));
    // Never c.json: JSON `true` happens to equal the string "true" today, but
    // a trailing newline or a content-type mismatch would deny everyone —
    // upstream requires the exact text "true" (`$UP/src/main.rs:326`).
    return c.text(allowed ? "true" : "false");
  });

  return r;
}
