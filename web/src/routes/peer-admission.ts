import { createHmac, timingSafeEqual } from "node:crypto";
import { Hono } from "hono";
import { bodyLimit } from "hono/body-limit";
import { PeerRelayAdmissionRequestSchema } from "antgrid-wire";
import type { DB } from "../db/index.js";
import type { Env } from "../env.js";
import { peerRelayAdmission } from "../models/peer-authorization.js";

export function peerAdmissionRoutes(deps: { db: DB; env: Env }) {
  const r = new Hono();
  const path = "/internal/peer-admission";
  let pending = 0;
  r.use(path, async (c, next) => {
    c.header("Cache-Control", "no-store");
    await next();
  }, bodyLimit({ maxSize: 4096, onError: (c) => c.json({ error: "BODY_TOO_LARGE" }, 413) }));
  r.post(path, async (c) => {
    const secret = deps.env.RELAY_INTERNAL_SECRET;
    const signature = c.req.header("x-antgrid-signature");
    if (!secret || !signature || !/^[0-9a-f]{64}$/.test(signature)) return c.json({ error: "UNAUTHENTICATED" }, 401);
    const raw = await c.req.arrayBuffer();
    const expected = createHmac("sha256", secret).update(Buffer.from(raw)).digest();
    if (!timingSafeEqual(expected, Buffer.from(signature, "hex"))) return c.json({ error: "UNAUTHENTICATED" }, 401);
    let body: unknown;
    try { body = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(raw)); }
    catch { return c.json({ error: "BAD_REQUEST" }, 400); }
    const input = PeerRelayAdmissionRequestSchema.safeParse(body);
    if (!input.success) return c.json({ error: "BAD_REQUEST" }, 400);
    const denied = { allowed: false as const, requestId: input.data.requestId };
    if (Math.abs(Date.now() - input.data.issuedAt) > 30_000) return c.json(denied);
    if (pending >= 32) return c.json(denied, 503);
    pending++;
    try {
      return c.json(await peerRelayAdmission(deps.db, input.data, deps.env.IROH_RELAY_URLS ?? []));
    } catch {
      return c.json(denied, 503);
    } finally { pending--; }
  });
  return r;
}
