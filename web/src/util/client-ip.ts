import type { Context } from "hono";
import { resolveClientIp, type Cidr, type ClientIpDegradation } from "antgrid-wire";

/**
 * Bun.serve({ fetch: app.fetch }) passes the Bun server as Hono's env, so the
 * socket peer is reachable via env.requestIP. Tests (app.request / app.fetch
 * with no env) have no socket — the resolver then returns null rather than
 * trusting any header, unless a test injects a fake server as the env arg.
 */
type BunServerEnv = {
  requestIP?: (req: Request) => { address: string } | null;
};

export type ClientIpResolver = (c: Context) => string | null;

const WARN_THROTTLE_MS = 60_000;

/**
 * Build the per-app client-IP resolver from TRUSTED_PROXY_IPS (parsed by
 * env.ts). The peer address stands unless the peer is a trusted proxy, in which
 * case the client is recovered from X-Forwarded-For via the shared spoof-safe
 * walk (antgrid-wire client-ip.ts). Null when the peer address is unavailable —
 * callers pick their own fallback bucket.
 *
 * A fallback taken while a header WAS present collapses every client into the
 * proxy's single rate-limit bucket, which presents as "sign-in randomly
 * rate-limited" with nothing pointing at TRUSTED_PROXY_IPS — so warn, throttled
 * per kind the way the relay does.
 */
export function makeClientIpResolver(trusted: Cidr[]): ClientIpResolver {
  const lastWarnAt = new Map<ClientIpDegradation["kind"], number>();
  const onDegraded = (event: ClientIpDegradation): void => {
    const now = Date.now();
    if (now - (lastWarnAt.get(event.kind) ?? -Infinity) < WARN_THROTTLE_MS) return;
    lastWarnAt.set(event.kind, now);
    console.warn(
      `[client-ip] ${event.kind} (${event.detail}) — X-Forwarded-For ignored, ` +
        "per-IP limits are keyed on the proxy; check TRUSTED_PROXY_IPS",
    );
  };
  return (c) => {
    const env = c.env as BunServerEnv | undefined;
    const peer = env?.requestIP?.(c.req.raw)?.address;
    if (!peer) return null;
    return resolveClientIp(peer, c.req.header("x-forwarded-for") ?? null, trusted, onDegraded);
  };
}
