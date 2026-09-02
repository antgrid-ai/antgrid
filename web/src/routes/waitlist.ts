import { Hono } from "hono";
import { z } from "zod";
import type { DB } from "../db/index.js";
import type { ClientIpResolver } from "../util/client-ip.js";
import { tokenBucket } from "../util/rate-limit.js";

// `source` is the marketing page that captured the signup ("pricing", "hero",
// "security"). Kept as a bounded slug rather than a closed enum so the static
// site can add a surface without a coordinated web deploy — the site ships from
// its own pipeline (Azure Static Web Apps) and would otherwise start getting
// 400s the moment a new page went live.
const Signup = z.object({
  // Normalise before validating, not after: the unique index is what makes a
  // repeat submit a no-op, and "A@x.com" vs "a@x.com" would otherwise be two
  // rows for one person. The 254 bound is applied to the TRIMMED value, so a
  // mobile keyboard's trailing space is a signup and not a 400; the outer bound
  // only exists to stop an unbounded string reaching `toLowerCase`.
  email: z
    .string()
    .max(1024)
    .transform((s) => s.trim().toLowerCase())
    .pipe(z.email().max(254)),
  source: z.string().min(1).max(40).regex(/^[a-z0-9][a-z0-9_-]*$/),
});

// Anonymous public writer keyed on an attacker-chosen email: burst 5, refill
// 1 per 10s per IP. Far tighter than the analytics ingest — a human submits
// this form once, and the row it writes is not idempotent per-IP the way an
// event batch is.
const signupLimiter = tokenBucket(5, 0.1);

export function waitlistRoutes(deps: { db: DB; clientIp: ClientIpResolver }) {
  const r = new Hono();

  r.post("/api/waitlist", async (c) => {
    // Spoof-safe resolution (peer + trusted-proxy XFF walk); the IP is used
    // only for this bucket and is deliberately never stored on the row.
    const ip = deps.clientIp(c) ?? "unknown";
    if (!signupLimiter(ip)) return c.json({ ok: false, error: "RATE_LIMITED" }, 429);

    // A bare code, no `issues`: this endpoint answers any origin anonymously and
    // neither client reads the detail — both pick their wording from the status —
    // so echoing Zod's paths and received values back is reach with no caller.
    const parsed = Signup.safeParse(await c.req.json().catch(() => null));
    if (!parsed.success) return c.json({ ok: false, error: "BAD_REQUEST" }, 400);

    // createMany + skipDuplicates emits INSERT ... ON CONFLICT DO NOTHING, so
    // two concurrent submits of the same address cannot race into a unique
    // violation — which would surface as app.onError's 500 and tell the caller
    // the address was already on the list.
    await deps.db.waitlistSignup.createMany({
      data: [{ email: parsed.data.email, source: parsed.data.source }],
      skipDuplicates: true,
    });

    // Identical response whether the row was inserted or already existed:
    // membership in the list is not something a stranger may probe for.
    return c.json({ ok: true }, 200);
  });

  return r;
}
