import { Hono } from "hono";
import { z } from "zod";
import type { DB } from "../db/index.js";
import type { ClientIpResolver } from "../util/client-ip.js";
import { tokenBucket } from "../util/rate-limit.js";

// Keep in lockstep with the app's AnalyticsEvents allowlist (app/lib/analytics/events.dart).
const EVENT_NAMES = [
  "sign_in_started", "sign_in_completed", "device_provisioned", "agent_paired",
  "session_opened", "terminal_used", "file_explorer_opened", "file_opened",
  "preview_opened", "session_resumed", "search_used", "git_viewed",
  "upgrade_dialog_shown", "pricing_viewed", "checkout_opened", "app_active",
] as const;

const PropValue = z.union([z.string().max(120), z.number(), z.boolean()]);

const EventInput = z.object({
  installId: z.string().uuid(),
  name: z.enum(EVENT_NAMES),
  ts: z.string().datetime(),
  platform: z.enum(["android", "ios", "macos", "windows", "linux", "unknown"]),
  appVersion: z.string().min(1).max(40),
  props: z.record(z.string(), PropValue).optional(),
});

const Batch = z.object({ events: z.array(EventInput).min(1).max(50) });

// Public ingest: burst 60, refill 1/sec per IP. IP is used only for rate-limiting and is never stored.
const ingestLimiter = tokenBucket(60, 1);

export function eventsRoutes(deps: { db: DB; clientIp: ClientIpResolver }) {
  const r = new Hono();

  r.post("/events", async (c) => {
    // Spoof-safe resolution (peer + trusted-proxy XFF walk) — a forged
    // leftmost hop must not mint a fresh rate-limit bucket. Null (peer
    // address unavailable) shares one "unknown" bucket.
    const ip = deps.clientIp(c) ?? "unknown";
    if (!ingestLimiter(ip)) return c.json({ error: "RATE_LIMITED" }, 429);

    const parsed = Batch.safeParse(await c.req.json().catch(() => null));
    if (!parsed.success) return c.json({ error: "BAD_REQUEST", issues: parsed.error.issues }, 400);

    await deps.db.analyticEvent.createMany({
      data: parsed.data.events.map((e) => ({
        installId: e.installId,
        name: e.name,
        ts: new Date(e.ts),
        platform: e.platform,
        appVersion: e.appVersion,
        props: e.props ?? undefined,
      })),
    });

    return c.json({ ok: true, accepted: parsed.data.events.length }, 202);
  });

  return r;
}
