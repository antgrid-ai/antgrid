import { Hono } from "hono";
import { bodyLimit } from "hono/body-limit";
import { EndpointChallengeRequestSchema, EndpointRegistrationRequestSchema } from "antgrid-wire";
import type { DB } from "../db/index.js";
import type { Auth } from "../auth/better-auth.js";
import type { Env } from "../env.js";
import type { AuthVars } from "../auth/middleware.js";
import { requireDeviceBearerJwt } from "../auth/jwt-bearer.js";
import { createEndpointChallenge, registerEndpoint, peerAuthorizationSnapshot, PeerAuthorizationError } from "../models/peer-authorization.js";
import { tokenBucket } from "../util/rate-limit.js";

export function peerAuthorizationRoutes(deps: { db: DB; auth: Auth; env: Env }) {
  const r = new Hono<{ Variables: AuthVars }>();
  r.onError((error, c) => {
    if (!(error instanceof PeerAuthorizationError)) throw error;
    return c.json({ error: error.code }, error.code === "UNAUTHENTICATED" ? 401 :
      error.code === "INVALID_SIGNATURE" || error.code === "NOT_ENTITLED" ? 403 : 409);
  });
  const prefix = "/account/devices/me";
  const limiter = tokenBucket(10, 0.5);
  for (const path of ["endpoint-challenge", "endpoint-registration", "authorization"]) {
    r.use(`${prefix}/${path}`, requireDeviceBearerJwt(deps), bodyLimit({ maxSize: 4096 }), async (c, next) => {
      c.header("Cache-Control", "no-store");
      if (!limiter(c.get("deviceAuthorization")!.enrollmentId)) return c.json({ error: "RATE_LIMITED" }, 429);
      await next();
    });
  }
  r.post(`${prefix}/endpoint-challenge`, async (c) => {
    const input = EndpointChallengeRequestSchema.safeParse(await c.req.json().catch(() => null));
    if (!input.success) return c.json({ error: "BAD_REQUEST" }, 400);
    return c.json(await createEndpointChallenge(deps.db,
      { ...c.get("deviceAuthorization")!, userId: c.get("userId") }, input.data));
  });
  r.post(`${prefix}/endpoint-registration`, async (c) => {
    const input = EndpointRegistrationRequestSchema.safeParse(await c.req.json().catch(() => null));
    if (!input.success) return c.json({ error: "BAD_REQUEST" }, 400);
    return c.json(await registerEndpoint(deps.db,
      { ...c.get("deviceAuthorization")!, userId: c.get("userId") }, input.data));
  });
  r.get(`${prefix}/authorization`, async (c) => c.json(await peerAuthorizationSnapshot(deps.db,
    { ...c.get("deviceAuthorization")!, userId: c.get("userId") }, deps.env.IROH_RELAY_URLS ?? [])));
  return r;
}
