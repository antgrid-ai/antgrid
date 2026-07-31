import type { Context } from "hono";
import { parseCidr, resolveClientIp } from "antgrid-wire";

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

/**
 * Build the per-app client-IP resolver from TRUSTED_PROXY_IPS (already
 * validated by env.ts). The peer address stands unless the peer is a trusted
 * proxy, in which case the client is recovered from X-Forwarded-For via the
 * shared spoof-safe walk (antgrid-wire client-ip.ts). Null when the peer
 * address is unavailable — callers pick their own fallback bucket.
 */
export function makeClientIpResolver(trustedProxyIps: string[]): ClientIpResolver {
  const trusted = trustedProxyIps.map(parseCidr);
  return (c) => {
    const env = c.env as BunServerEnv | undefined;
    const peer = env?.requestIP?.(c.req.raw)?.address;
    if (!peer) return null;
    return resolveClientIp(peer, c.req.header("x-forwarded-for") ?? null, trusted);
  };
}
