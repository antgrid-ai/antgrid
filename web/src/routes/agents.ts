import { Hono } from "hono";
import { z } from "zod";
import type { DB } from "../db/index.js";
import type { Auth } from "../auth/better-auth.js";
import type { Env } from "../env.js";
import { requireUser, type AuthVars } from "../auth/middleware.js";
import { requireBearerJwt } from "../auth/jwt-bearer.js";
import { listMobileEnabledAgents } from "../models/agent-inventory.js";
import { listAppDeviceKeys } from "../models/device.js";

const HeartbeatBody = z.object({
  deviceUuid: z.string().uuid(),
  mobileAccessEnabled: z.boolean(),
  relayUrl: z.string().url().nullable().optional(),
  machineName: z.string().min(1).max(120).nullable().optional(),
});

export function agentRoutes(deps: { db: DB; auth: Auth; env: Env }) {
  const r = new Hono<{ Variables: AuthVars }>();

  // Heartbeat is called by the agent, which presents an OAuth
  // `client_credentials` JWT (NOT a Better-Auth session cookie). Gate it
  // with Bearer-JWT verification against web's own JWKS.
  r.use(
    "/account/devices/me/heartbeat",
    requireBearerJwt({ auth: deps.auth, env: deps.env })
  );

  // Peers is called by the bridge to discover enrolled app-device Ed25519 keys
  // for the same account. Bearer-JWT gated (same OAuth client_credentials path
  // as heartbeat). Path uses `me/peers` (two segments after /devices) to avoid
  // Hono matching `/account/devices/:id` in deviceRoutes, which gates on a
  // cookie-based requireUser and would reject Bearer tokens.
  r.use(
    "/account/devices/me/peers",
    requireBearerJwt({ auth: deps.auth, env: deps.env })
  );

  // All other `/account/*` routes are called by the Flutter app's UI session
  // (signed-in user cookie). Keep them on the cookie-based gate.
  r.use("/account/agents", requireUser({ auth: deps.auth }));

  r.get("/account/agents", async (c) => {
    const userId = c.get("userId");
    const agents = await listMobileEnabledAgents(deps.db, userId);
    return c.json({
      agents: agents.map((a) => ({
        deviceUuid: a.deviceId,
        displayName: a.displayName,
        platform: a.platform,
        ed25519Pub: Buffer.from(a.publicKey).toString("base64"),
        relayUrl: a.relayUrl,
        machineName: a.machineName,
        lastSeenAt: a.lastSeenAt?.toISOString() ?? null,
      })),
    });
  });

  r.get("/account/devices/me/peers", async (c) => {
    const userId = c.get("userId");
    const keys = await listAppDeviceKeys(deps.db, userId);
    return c.json({ keys: keys.map((k) => k.toString("base64")) });
  });

  r.post("/account/devices/me/heartbeat", async (c) => {
    const userId = c.get("userId");
    const parsed = HeartbeatBody.safeParse(await c.req.json().catch(() => null));
    if (!parsed.success) return c.json({ error: "BAD_REQUEST", issues: parsed.error.issues }, 400);
    const body = parsed.data;

    const result = await deps.db.device.updateMany({
      where: { userId, deviceId: body.deviceUuid, revokedAt: null },
      data: {
        lastSeenAt: new Date(),
        mobileAccessEnabled: body.mobileAccessEnabled,
        relayUrl: body.relayUrl ?? null,
        ...(body.machineName != null ? { machineName: body.machineName } : {}),
      },
    });
    if (result.count === 0) return c.json({ error: "NOT_FOUND" }, 404);

    return c.json({ ok: true });
  });

  return r;
}
