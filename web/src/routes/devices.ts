import { Hono } from "hono";
import { z } from "zod";
import type { DB } from "../db/index.js";
import type { Auth } from "../auth/better-auth.js";
import { requireUser, type AuthVars } from "../auth/middleware.js";
import { checkCapAndUpsert, listActiveDevices, type DeviceKind } from "../models/device.js";
import { revokeUserDevice } from "../services/device.js";
import { deleteUserAccount } from "../services/account.js";
import {
  activeSubscriptionForUser,
  provisionProductAccountForUser,
  resolveEntitlement,
} from "../models/subscription.js";
import { createDeviceOAuthClient, deleteDeviceOAuthClient } from "../models/device-oauth.js";
import { tokenBucket } from "../util/rate-limit.js";
import type { RelayPushConfig } from "../relay/push.js";

const UuidSchema = z.uuid();

const CreateDeviceBody = z.object({
  deviceUuid: z.string().uuid(),
  ed25519Pub: z.string().min(1),
  x25519Pub: z.string().min(1),
  platform: z.enum(["macos", "windows", "linux", "ios", "android"]),
  displayName: z.string().min(1).max(120),
  // Desktop controllers register as kind:"app" despite a desktop platform —
  // the peers inventory (bridge E2E admission) serves kind:"app" rows only.
  kind: z.enum(["app", "agent"]).optional(),
});

export function deviceRoutes(deps: { db: DB; auth: Auth; relay: RelayPushConfig }) {
  const r = new Hono<{ Variables: AuthVars }>();
  // Scoped narrowly to the routes this router actually defines. Using a
  // `/account/*` wildcard here would also intercept routes mounted on other
  // routers under `/account/...` (notably the agent's Bearer-JWT-authed
  // `/account/devices/me/heartbeat` in `agentRoutes`).
  const gate = requireUser({ auth: deps.auth });
  r.use("/account/devices", gate);
  r.use("/account/devices/:id", gate);
  r.use("/account/me", gate);

  // Per-user burst limiter for device creation. Authenticated, so keying on
  // userId (not IP) is the right unit; cap matches the "few devices per user"
  // device-cap regime rather than throttling network noise.
  const createDeviceLimiter = tokenBucket(10, 0.1); // burst 10, 1 per 10s

  r.post("/account/devices", async (c) => {
    const userId = c.get("userId");
    if (!createDeviceLimiter(userId)) {
      return c.json({ error: "RATE_LIMITED" }, 429);
    }
    const parsed = CreateDeviceBody.safeParse(await c.req.json().catch(() => null));
    if (!parsed.success) return c.json({ error: "BAD_REQUEST", issues: parsed.error.issues }, 400);
    const body = parsed.data;

    // Phones are `app` devices; desktops/servers that host agents are `agent`.
    // The kind is load-bearing: `listMobileEnabledAgents` (the machine picker)
    // reads `agent`, while `listAppDeviceKeys` (same-account pair-membership
    // proof) reads `app`.
    const kind: DeviceKind =
      body.kind ?? (body.platform === "ios" || body.platform === "android" ? "app" : "agent");

    // If this device UUID already exists, the desktop app may have lost its
    // keychain copy of the OAuth client secret. Create a fresh OAuth client and
    // update/reactivate the existing row instead of inserting a duplicate.
    const existing = await deps.db.device.findUnique({
      where: { userId_deviceId: { userId, deviceId: body.deviceUuid } },
    });

    await provisionProductAccountForUser(deps.db, userId);
    const sub = await activeSubscriptionForUser(deps.db, userId);
    if (!sub) return c.json({ error: "NO_SUBSCRIPTION" }, 500);
    const { deviceLimit, workerLimit } = resolveEntitlement(sub);

    // Two caps, both settled here at registration — a calm moment — rather than
    // mid-work: the fair-use `deviceLimit` across all kinds, and the paid
    // `workerLimit` on agent machines.
    const capResult = await deps.db.$transaction((tx) =>
      checkCapAndUpsert(tx, {
        userId,
        deviceLimit,
        workerLimit,
        deviceId: body.deviceUuid,
        publicKey: Buffer.from(body.ed25519Pub, "base64"),
        kind,
        platform: body.platform,
        displayName: body.displayName,
      })
    );
    if (capResult.kind === "cap") {
      return c.json(
        {
          error: "DEVICE_CAP",
          limit: capResult.limit,
          devices: capResult.devices.map((d) => ({
            id: d.id,
            device_id: d.deviceId,
            display_name: d.displayName,
          })),
        },
        402
      );
    }
    // Deliberately NOT folded into DEVICE_CAP: the remedy differs. DEVICE_CAP
    // is fair-use and is only ever resolved by removing a device, while
    // WORKER_CAP is the paid axis and upgrading resolves it too.
    if (capResult.kind === "worker_cap") {
      return c.json(
        {
          error: "WORKER_CAP",
          limit: capResult.limit,
          devices: capResult.devices.map((d) => ({
            id: d.id,
            device_id: d.deviceId,
            display_name: d.displayName,
          })),
        },
        402
      );
    }

    // Already provisioned and not a re-provision — return existing client id only.
    if (capResult.device.oauthClientId && !existing) {
      return c.json(
        {
          deviceUuid: body.deviceUuid,
          clientId: capResult.device.oauthClientId,
          clientSecret: null,
        },
        200
      );
    }

    if (existing?.oauthClientId) {
      await deleteDeviceOAuthClient(deps.auth, existing.oauthClientId, c.req.raw.headers).catch(
        () => {}
      );
    }

    // Create OAuth client for this device. Pass request headers so Better-Auth
    // can resolve the caller's session inside adminCreateOAuthClient.
    const oauth = await createDeviceOAuthClient(
      deps.auth,
      {
        userId,
        deviceUuid: body.deviceUuid,
        ed25519Pub: body.ed25519Pub,
        displayName: body.displayName,
      },
      c.req.raw.headers,
    );

    const isNewDevice = !existing;
    try {
      // checkCapAndUpsert already ensured the device row exists.
      await deps.db.device.update({
        where: { userId_deviceId: { userId, deviceId: body.deviceUuid } },
        data: {
          kind,
          platform: body.platform,
          displayName: body.displayName,
          publicKey: Buffer.from(body.ed25519Pub, "base64"),
          oauthClientId: oauth.clientId,
          revokedAt: null,
        },
      });
    } catch (err) {
      // Roll back the OAuth client if the device row insertion/update fails.
      await deleteDeviceOAuthClient(deps.auth, oauth.clientId, c.req.raw.headers).catch(() => {});
      throw err;
    }

    return c.json(
      { deviceUuid: body.deviceUuid, clientId: oauth.clientId, clientSecret: oauth.clientSecret },
      isNewDevice ? 201 : 200,
    );
  });

  r.get("/account/me", async (c) => {
    const userId = c.get("userId");
    const email = c.get("userEmail");
    await provisionProductAccountForUser(deps.db, userId);
    const sub = await activeSubscriptionForUser(deps.db, userId);
    if (!sub) return c.json({ error: "NO_SUBSCRIPTION" }, 500);
    const { tier, workerLimit, deviceLimit, promotional } = resolveEntitlement(sub);
    return c.json({
      userId,
      email,
      tier,
      worker_limit: workerLimit,
      // `session_limit` is the retired name for `worker_limit`, kept in
      // lockstep with the `/billing/plans` mirror (web/src/routes/billing.ts)
      // that app builds predating the rename hard-require. Drop them together
      // once no such build is still in the field.
      session_limit: workerLimit,
      device_limit: deviceLimit,
      promotional,
    });
  });

  r.delete("/account/me", async (c) => {
    const userId = c.get("userId");
    const result = await deleteUserAccount(deps.db, deps.relay, deps.auth, {
      userId,
      headers: c.req.raw.headers,
    });
    if (result === "blocked_subscription") {
      return c.json({ error: "SUBSCRIPTION_ACTIVE" }, 409);
    }
    return c.json({ ok: true });
  });

  r.get("/account/devices", async (c) => {
    const userId = c.get("userId");
    const devices = await listActiveDevices(deps.db, userId);
    return c.json({
      devices: devices.map((d) => ({
        id: d.id,
        device_id: d.deviceId,
        kind: d.kind,
        platform: d.platform,
        display_name: d.displayName,
        activated_at: d.activatedAt,
        last_seen_at: d.lastSeenAt,
      })),
    });
  });

  r.delete("/account/devices/:id", async (c) => {
    const userId = c.get("userId");
    const id = c.req.param("id");
    if (!UuidSchema.safeParse(id).success) return c.json({ error: "NOT_FOUND" }, 404);

    const result = await revokeUserDevice(deps.db, deps.relay, deps.auth, {
      userId,
      deviceUuid: id,
      headers: c.req.raw.headers,
    });
    if (result === "not_found") return c.json({ error: "NOT_FOUND" }, 404);
    return c.json({ ok: true });
  });

  return r;
}
