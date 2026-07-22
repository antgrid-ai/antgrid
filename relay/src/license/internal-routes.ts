import { createHmac, timingSafeEqual } from "node:crypto";
import { z } from "zod";
import type { ServerWebSocket } from "bun";
import { logger } from "../logger.js";
import type { LicenseCache } from "./cache.js";
import type { Connections, Connection, WsData } from "../connections.js";
import type { Grants } from "../grants.js";

export interface InternalRouteDeps {
  licenseCache: LicenseCache;
  connections: Connections;
  grants: Grants;
  relayInternalSecret: string;
}

const RevokeBody = z.object({ deviceId: z.string().min(1).max(128) });
const ExpireBody = z.object({ userId: z.string().min(1).max(256) });
const ListConnectionsBody = z.object({
  issuedAt: z.number().int(),
  userId: z.string().min(1).max(256).optional(),
});

// /internal/connections is read-only, so its HMAC body never varies the way
// revoke/expire's (deviceId/userId) does. Without a freshness field its signed
// bytes would be constant and a captured request replayable forever. Bound
// acceptance to a tight clock-skew window over the signed `issuedAt`.
const CONNECTIONS_MAX_SKEW_MS = 30_000;

interface VerifiedBody<T> {
  ok: true;
  data: T;
}
interface VerifyFailure {
  ok: false;
  response: Response;
}

async function verifyAndParse<T>(
  req: Request,
  secret: string,
  schema: z.ZodType<T>,
): Promise<VerifiedBody<T> | VerifyFailure> {
  const sigHex = req.headers.get("x-antgrid-signature") ?? "";
  const raw = await req.text();
  const expected = createHmac("sha256", secret).update(raw).digest("hex");

  if (sigHex.length !== expected.length) {
    return { ok: false, response: Response.json({ error: "UNAUTHORIZED" }, { status: 401 }) };
  }
  let sigBuf: Buffer;
  try {
    sigBuf = Buffer.from(sigHex, "hex");
  } catch {
    return { ok: false, response: Response.json({ error: "UNAUTHORIZED" }, { status: 401 }) };
  }
  const expectedBuf = Buffer.from(expected, "hex");
  if (sigBuf.length !== expectedBuf.length || !timingSafeEqual(sigBuf, expectedBuf)) {
    return { ok: false, response: Response.json({ error: "UNAUTHORIZED" }, { status: 401 }) };
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { ok: false, response: Response.json({ error: "INVALID_JSON" }, { status: 400 }) };
  }
  const result = schema.safeParse(parsed);
  if (!result.success) {
    return { ok: false, response: Response.json({ error: "INVALID_BODY" }, { status: 400 }) };
  }
  return { ok: true, data: result.data };
}

function closeWithLicense(conn: Connection, code: "LICENSE_REVOKED" | "LICENSE_EXPIRED"): boolean {
  const ws: ServerWebSocket<WsData> = conn.ws;
  if (ws.readyState !== 1) return false;
  try {
    ws.send(JSON.stringify({ type: "error", code, message: code, retryable: false }));
  } catch {
    // ignore — proceed to close
  }
  try {
    ws.close(4002, code);
  } catch {
    // ignore
  }
  return true;
}

/**
 * Sever the agent's grants and notify each granted phone (`grant-revoked` +
 * `peer-offline`, sockets stay open per design §6.4). Called BEFORE the agent
 * socket closes so its close handler finds no grants to double-notify.
 */
function revokeAgentGrants(deps: InternalRouteDeps, agentDeviceId: string): void {
  for (const g of deps.grants.peersOf(agentDeviceId)) {
    deps.grants.revoke(g.agentDeviceId, g.phonePubkey, "REVOKED");
    const phone = deps.connections.getByDeviceId(g.phoneDeviceId);
    if (phone && phone.ws.readyState === 1) {
      phone.ws.send(JSON.stringify({ type: "grant-revoked", peerDeviceId: agentDeviceId, reason: "REVOKED" }));
      phone.ws.send(JSON.stringify({ type: "peer-offline", peerId: agentDeviceId }));
    }
  }
}

export async function handleRevoke(req: Request, deps: InternalRouteDeps): Promise<Response> {
  const verified = await verifyAndParse(req, deps.relayInternalSecret, RevokeBody);
  if (!verified.ok) {
    if (verified.response.status === 401) logger.warn("license_revoke.bad_signature", {});
    return verified.response;
  }
  const { deviceId } = verified.data;
  deps.licenseCache.markRevoked(deviceId);
  const conn = deps.connections.getByDeviceId(deviceId);
  let wsClosed = false;
  if (conn) {
    revokeAgentGrants(deps, deviceId);
    wsClosed = closeWithLicense(conn, "LICENSE_REVOKED");
  }
  logger.info("license_revoke", { deviceId, wsClosed });
  return Response.json({ ok: true });
}

export async function handleListConnections(req: Request, deps: InternalRouteDeps): Promise<Response> {
  const verified = await verifyAndParse(req, deps.relayInternalSecret, ListConnectionsBody);
  if (!verified.ok) {
    if (verified.response.status === 401) logger.warn("connections_list.bad_signature", {});
    return verified.response;
  }
  if (Math.abs(Date.now() - verified.data.issuedAt) > CONNECTIONS_MAX_SKEW_MS) {
    logger.warn("connections_list.stale", {});
    return Response.json({ error: "STALE_REQUEST" }, { status: 401 });
  }
  const connections = verified.data.userId !== undefined
    ? deps.connections.listConnectionsForUser(verified.data.userId)
    : deps.connections.listConnections();
  // Log whether the call was scoped, not WHICH user — keep relay logs identity-light.
  logger.info("connections_list", { count: connections.length, scoped: verified.data.userId !== undefined });
  return Response.json({ connections });
}

export async function handleExpire(req: Request, deps: InternalRouteDeps): Promise<Response> {
  const verified = await verifyAndParse(req, deps.relayInternalSecret, ExpireBody);
  if (!verified.ok) {
    if (verified.response.status === 401) logger.warn("license_expire.bad_signature", {});
    return verified.response;
  }
  const { userId } = verified.data;
  const ids = deps.licenseCache.dropByUser(userId);
  let closed = 0;
  for (const conn of deps.connections.getConnectionsForUser(userId)) {
    if (conn.deviceType === "agent") revokeAgentGrants(deps, conn.deviceId);
    if (closeWithLicense(conn, "LICENSE_EXPIRED")) closed += 1;
  }
  logger.info("license_expire", { userId, devicesRevoked: ids.length, wsClosed: closed });
  return Response.json({ ok: true });
}
