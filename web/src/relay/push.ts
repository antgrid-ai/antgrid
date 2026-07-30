import { createHmac } from "node:crypto";
import { z } from "zod";

export type RelayPushConfig = {
  baseUrl?: string;
  secret?: string;
};

function sign(secret: string, body: string): string {
  return createHmac("sha256", secret).update(body).digest("hex");
}

// Both push calls are best-effort with a token-TTL fallback, so they must fail
// FAST when the relay is unreachable (down, or a stale LAN address that drops/
// refuses slowly). Without a bound the OS connect can hang ~10s per call; the
// account-deletion path revokes once per device and then expires, so an unbounded
// hang there stacks past Bun.serve's 10s idleTimeout and 500s the whole request.
const RELAY_PUSH_TIMEOUT_MS = 3000;

export async function pushRevoke(cfg: RelayPushConfig, deviceId: string, fetchImpl: typeof fetch = fetch): Promise<void> {
  if (!cfg.baseUrl || !cfg.secret) return;
  const body = JSON.stringify({ deviceId });
  const signature = sign(cfg.secret, body);
  try {
    await fetchImpl(`${cfg.baseUrl}/internal/revoke`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-antgrid-signature": signature },
      body,
      signal: AbortSignal.timeout(RELAY_PUSH_TIMEOUT_MS),
    });
  } catch (e) {
    console.warn("[relay-push] revoke failed, falling back to TTL", e);
  }
}

/**
 * Identity-free liveness row returned by the relay's /internal/connections.
 * Keep in lockstep with relay's `src/connections.ts` ConnectionSummary.
 *
 * `openStreamCount` is the billable quantity: an agent holds ONE socket under
 * its bare account `deviceUuid` and multiplexes projects as sealed streams, so
 * the deviceId alone says nothing about how many sessions are running. The
 * relay cannot resolve those streams to projects, so only the count exists.
 */
const ConnectionSummarySchema = z.object({
  deviceId: z.string(),
  deviceType: z.enum(["agent", "app"]),
  connectedAt: z.number(),
  lastSeen: z.number(),
  openStreamCount: z.number().int().nonnegative(),
});
const ConnectionsResponseSchema = z.object({
  connections: z.array(ConnectionSummarySchema).default([]),
});

export type ConnectionSummary = z.infer<typeof ConnectionSummarySchema>;

async function postConnections(
  cfg: RelayPushConfig,
  extra: Record<string, unknown>,
  fetchImpl: typeof fetch,
): Promise<ConnectionSummary[]> {
  if (!cfg.baseUrl || !cfg.secret) throw new Error("relay internal config missing");
  const body = JSON.stringify({ issuedAt: Date.now(), ...extra });
  const signature = sign(cfg.secret, body);
  const res = await fetchImpl(`${cfg.baseUrl}/internal/connections`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-antgrid-signature": signature },
    body,
    // Fail fast to the caller's error state if the relay address blackholes
    // packets (firewall/NAT drop) rather than hanging the request handler.
    signal: AbortSignal.timeout(RELAY_PUSH_TIMEOUT_MS),
  });
  if (!res.ok) throw new Error(`relay connections fetch failed: ${res.status}`);
  // Validated, not cast: this projection is the relay's shape, versioned by the
  // relay's deploy, and both callers now do arithmetic on `openStreamCount`. A
  // relay that predates the field would otherwise sum to NaN and render a
  // confident wrong number — throwing here routes to the caller's honest
  // "couldn't reach the relay" state until the deploys converge.
  const parsed = ConnectionsResponseSchema.safeParse(await res.json());
  if (!parsed.success) throw new Error(`relay connections shape rejected: ${parsed.error.message}`);
  return parsed.data.connections;
}

/**
 * Fetch the relay's full live connection snapshot (operator surveillance feed).
 * The signed `issuedAt` is the freshness nonce the relay bounds for replay.
 * Throws on missing config or non-2xx so the caller can render an explicit
 * error rather than a silently empty list.
 */
export async function fetchConnections(
  cfg: RelayPushConfig,
  fetchImpl: typeof fetch = fetch,
): Promise<ConnectionSummary[]> {
  return postConnections(cfg, {}, fetchImpl);
}

/**
 * Fetch only the given user's live connections. `userId` is sent inbound (like
 * /internal/expire); the relay filters by the userId it already stores and
 * returns the same identity-free projection, so the full connection map never
 * crosses the wire.
 */
export async function fetchUserConnections(
  cfg: RelayPushConfig,
  userId: string,
  fetchImpl: typeof fetch = fetch,
): Promise<ConnectionSummary[]> {
  return postConnections(cfg, { userId }, fetchImpl);
}

export async function pushExpire(cfg: RelayPushConfig, userId: string, fetchImpl: typeof fetch = fetch): Promise<void> {
  if (!cfg.baseUrl || !cfg.secret) return;
  const body = JSON.stringify({ userId });
  const signature = sign(cfg.secret, body);
  try {
    await fetchImpl(`${cfg.baseUrl}/internal/expire`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-antgrid-signature": signature },
      body,
      signal: AbortSignal.timeout(RELAY_PUSH_TIMEOUT_MS),
    });
  } catch (e) {
    console.warn("[relay-push] expire failed, falling back to TTL", e);
  }
}
