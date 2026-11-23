// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { Hono } from "hono";
import { bodyLimit } from "hono/body-limit";
import { createHash, timingSafeEqual } from "node:crypto";
import { z } from "zod";
import type { DB } from "../db/index.js";
import { markDelivery } from "../models/pending-sign-in.js";
import { INVITE_REFERENCE_PREFIX, markInviteDelivery } from "../models/account-invite.js";
import { recordStage } from "../auth/flows.js";
import { classifyBounce, suppressRecipient, type BounceClass } from "../auth/email-suppression.js";

const Info = z.object({ client_reference: z.string().max(128).optional(), request_id: z.string().max(128).optional() }).passthrough();
const Message = z.object({ email_info: Info.optional(), request_id: z.string().max(128).optional() }).passthrough();
const Event = z.object({ event_name: z.union([z.string().max(64), z.array(z.string().max(64)).max(100)]).optional(),
  event_message: z.union([Message, z.array(Message).max(100)]).optional(), webhook_request_id: z.string().max(128).optional() }).passthrough();
const Payload = z.union([Event, z.array(Event).max(100)]);
/** First provider reason for the log, dropped when it could quote an address. */
function reasonOf(message: unknown): string | null {
  const data = (message as { event_data?: unknown })?.event_data;
  const first = (Array.isArray(data) ? data[0] : data) as { details?: unknown } | undefined;
  const details = first?.details;
  const reason = (Array.isArray(details) ? details[0] : details) as { reason?: unknown } | undefined;
  const text = typeof reason?.reason === "string" ? reason.reason.slice(0, 64) : null;
  return text && !text.includes("@") ? text : null;
}
const hash = (s: string) => createHash("sha256").update(s).digest();

export function emailWebhookRoutes(deps: { db: DB; webhookSecret?: string }) {
  const r = new Hono();
  r.use("/webhooks/zeptomail/:key", async (c, next) => {
    if (!deps.webhookSecret) return c.json({ error: "NOT_CONFIGURED" }, 503);
    if (!timingSafeEqual(hash(c.req.param("key") ?? ""), hash(deps.webhookSecret))) return c.json({ error: "UNAUTHORIZED" }, 401);
    await next();
  });
  r.use("/webhooks/zeptomail/:key", bodyLimit({ maxSize: 65536, onError: (c) => c.json({ error: "BODY_TOO_LARGE" }, 413) }));
  r.post("/webhooks/zeptomail/:key", async (c) => {
    const parsed = Payload.safeParse(await c.req.json().catch(() => null));
    if (!parsed.success) return c.json({ error: "INVALID_PAYLOAD" }, 400);
    for (const event of Array.isArray(parsed.data) ? parsed.data : [parsed.data]) {
      const names = Array.isArray(event.event_name) ? event.event_name : [event.event_name ?? ""];
      const messages = Array.isArray(event.event_message) ? event.event_message : [event.event_message ?? {}];
      for (const message of messages) for (const name of names) {
        const kind = ({ hardbounce: "hard_bounce", softbounce: "soft_bounce", fbl_compliant: "complaint", fbl_complaint: "complaint" } as Record<string, string>)[name.toLowerCase()];
        if (!kind) continue;
        const ref = message.email_info?.client_reference;
        const providerId = message.request_id ?? message.email_info?.request_id;
        if (!ref && !providerId) continue;
        await deps.db.$transaction(async (tx) => {
          const job = await tx.emailJob.findFirst({ where: ref ? { reference: ref } : { providerId } });
          if (job && providerId && job.providerId && job.providerId !== providerId) return;
          const legacyRef = job?.relatedReference ?? ref;
          if (job) {
            const id = hash(JSON.stringify([job.id, kind, providerId ?? ref, event.webhook_request_id ?? ""])).toString("hex");
            // The key comes from the job we sent, never from an address in the webhook body,
            // so a forged or replayed body cannot suppress an address we did not mail.
            const inserted = await tx.emailRecipientEvent.createMany({ data: [{ id, jobId: job.id, kind }], skipDuplicates: true });
            if (kind === "hard_bounce") await recordStage(tx, job.flowId ?? undefined, "mail_bounced");
            if (inserted.count && kind === "hard_bounce") {
              const cls: BounceClass = classifyBounce(message);
              console.info(JSON.stringify({ evt: "email.bounce", kind, class: cls, reason: reasonOf(message) }));
              // Sender-side and transient bounces describe our reputation or the provider
              // link, not the mailbox, so they must not lock a real user out.
              if (job.recipientHash && (cls === "recipient" || cls === "unclassified")) {
                await suppressRecipient(tx, job.recipientHash as Uint8Array<ArrayBuffer>, cls, job.createdAt);
              }
              const recent = await tx.emailRecipientEvent.count({ where: { kind: "hard_bounce", at: { gt: new Date(Date.now() - 86400000) } } });
              if (recent === 3) console.error("[email] 3 hard bounces in 24h — provider bounce-rate limit at risk");
            }
          }
          if (kind === "hard_bounce" && legacyRef) {
            // Resends rotate invitation tokens; an earlier message's bounce
            // must not overwrite delivery feedback for the current token.
            const latest = await tx.emailJob.findFirst({ where: { relatedReference: legacyRef }, orderBy: { createdAt: "desc" }, select: { id: true } });
            if (latest && latest.id !== job?.id) return;
            if (legacyRef.startsWith(INVITE_REFERENCE_PREFIX)) await markInviteDelivery(tx, legacyRef.slice(INVITE_REFERENCE_PREFIX.length), "bounced");
            else await markDelivery(tx, legacyRef, "bounced");
          }
        });
      }
    }
    return c.json({ ok: true });
  });
  return r;
}
