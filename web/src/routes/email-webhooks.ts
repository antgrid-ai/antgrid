import { Hono } from "hono";
import { createHash, timingSafeEqual } from "node:crypto";
import type { DB } from "../db/index.js";
import { markDelivery, type DeliveryStatus } from "../models/pending-sign-in.js";
import {
  INVITE_REFERENCE_PREFIX,
  markInviteDelivery,
} from "../models/account-invite.js";

// ZeptoMail wraps BOTH top-level fields in single-element arrays:
// { event_name: ["hardbounce"], event_message: [{ email_info: {...} }] }
// We tolerate the bare (non-array) forms too so a hand-crafted/legacy payload
// can't crash the handler. There is NO "delivered" webhook — the events a live
// Agent emits are hardbounce/softbounce/fbl_compliant (email_open is available
// but not enabled), and of those only a hard bounce is actionable (classify()).
type ZeptoMessage = { email_info?: { client_reference?: unknown } };
type ZeptoEvent = {
  event_name?: string | string[];
  event_message?: ZeptoMessage | ZeptoMessage[];
};

// Names ZeptoMail is configured to send. Used only to scope the breadcrumb
// below: a name OUTSIDE this set means the contract may have changed (e.g.
// hardbounce renamed), which is worth a log line; routine soft bounces and
// complaints are not.
const KNOWN_EVENTS = new Set(["hardbounce", "softbounce", "fbl_compliant"]);

function safeEqual(a: string, b: string): boolean {
  // Hash to fixed 32-byte digests before the constant-time compare: comparing
  // the raw strings would need an early length check, which leaks the secret's
  // length through timing. SHA-256 first makes both operands equal-length.
  const ha = createHash("sha256").update(a).digest();
  const hb = createHash("sha256").update(b).digest();
  return timingSafeEqual(ha, hb);
}

function extractRef(e: ZeptoEvent | null): string | null {
  const msg = Array.isArray(e?.event_message) ? e?.event_message[0] : e?.event_message;
  const ref = msg?.email_info?.client_reference;
  return typeof ref === "string" && ref.length > 0 ? ref : null;
}

function eventName(e: ZeptoEvent | null): string {
  const raw = Array.isArray(e?.event_name) ? e?.event_name[0] : e?.event_name;
  // String() not a bare cast: a hand-crafted payload could send a non-string
  // (e.g. event_name:[123]), and `.toLowerCase()` on that would throw a 500.
  return String(raw ?? "").toLowerCase();
}

function classify(name: string): DeliveryStatus | null {
  // Only a hard bounce is actionable: the address is dead and the link will
  // never arrive, so the app fails fast. softbounce is transient (retryable) and
  // fbl_compliant (complaint) isn't a sign-in failure — both ignored.
  return name === "hardbounce" ? "bounced" : null;
}

function namespaceOf(ref: string | null): string {
  if (ref === null) return "none";
  return ref.startsWith(INVITE_REFERENCE_PREFIX) ? "invite" : "sign-in";
}

function markRef(db: DB, ref: string, status: DeliveryStatus): Promise<number> {
  if (ref.startsWith(INVITE_REFERENCE_PREFIX)) {
    return markInviteDelivery(db, ref.slice(INVITE_REFERENCE_PREFIX.length), status);
  }
  return markDelivery(db, ref, status);
}

export function emailWebhookRoutes(deps: { db: DB; webhookSecret?: string }) {
  const r = new Hono();

  r.post("/webhooks/zeptomail/:key", async (c) => {
    if (!deps.webhookSecret) return c.json({ error: "NOT_CONFIGURED" }, 503);
    if (!safeEqual(c.req.param("key"), deps.webhookSecret))
      return c.json({ error: "UNAUTHORIZED" }, 401);

    const body = (await c.req.json().catch(() => null)) as ZeptoEvent | null;
    const name = eventName(body);
    const ref = extractRef(body);
    const status = classify(name);
    if (status) {
      // A hard bounce we can't persist is the INVISIBLE-failure case the feature
      // must not have: a missing/misplaced client_reference (ref null) or an
      // already-purged row (updateMany matches 0) would otherwise 200 below,
      // mark nothing, and leave the app spinning to expiry with no trail. Log
      // whenever a classified bounce isn't recorded — hasRef distinguishes a
      // parse/contract problem (false) from a benign late/expired bounce (true).
      //
      // Two namespaces share one reference field. A bare reference is a
      // `pending_sign_in` id and stays that way — mail already in flight when
      // the invite feature shipped carries the bare form, so it cannot be
      // migrated to a prefix. Invite mail is prefixed at the send site
      // (`inviteEmailReference`); routed here to the wrong table it would update
      // zero rows and warn as if it were a late bounce.
      const marked = ref ? await markRef(deps.db, ref, status) : 0;
      if (marked === 0) {
        console.warn(
          `[zeptomail-webhook] ${name} not recorded (hasRef=${ref !== null}, ns=${namespaceOf(ref)}): missing client_reference or unmatched/expired row`
        );
      }
    } else if (name && !KNOWN_EVENTS.has(name)) {
      // An event_name outside the known set means the contract may have changed
      // (e.g. hardbounce renamed) — worth a log line; routine ignored events
      // (softbounce, fbl_compliant) are not.
      console.warn(
        `[zeptomail-webhook] unrecognized event_name=${JSON.stringify(body?.event_name)}`
      );
    }

    // Always 200 on an authenticated call so ZeptoMail does not retry events we
    // deliberately ignore (soft bounce, complaint) or that reference a purged row.
    return c.json({ ok: true });
  });

  return r;
}
