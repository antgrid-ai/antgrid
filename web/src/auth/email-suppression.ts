// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { z } from "zod";
import type { Tx } from "../db/index.js";
import type { MailDomainVerdict } from "./mail-domain.js";
import { canonicalMailbox, recipientDigest } from "./recipient-key.js";

const DAY_MS = 86400000;

/** A recipient-side bounce is strong evidence the mailbox is dead; an unclassifiable
 *  one only earns a short pause so a misread reason cannot lock a real user out. */
export const SUPPRESSION_TTL_MS = {
  recipient: 180 * DAY_MS,
  unclassified: 7 * DAY_MS,
  complaint: 30 * DAY_MS,
} as const;

export type BounceClass = "recipient" | "unclassified" | "transient" | "sender";

// Order matters: a sender-side rejection often carries generic "mailbox unavailable"
// wording, so sender is tested before recipient; transient before recipient because
// provider "relaying" errors describe our connection, not the mailbox.
const SENDER = /5\.7\.\d|spam|virus|black.?list|block|listed|policy|reputation|sender.?ip|spf|dkim|dmarc|authenticat/i;
const TRANSIENT = /relay|timeout|timed.?out|connect|refused|unreachable|not.?reachable|quota|full|grey.?list|gray.?list|temporar|try.?again|4\.\d\.\d|dns.?fail|routing|protocol/i;
const RECIPIENT = /unknown.?user|user.?unknown|no.?such|not.?found|does.?not.?exist|mailbox.?(not|unavail)|bad.?mailbox|invalid.?(recipient|mailbox|address)|inactive|disabled|5\.1\.\d|domain.?not.?found|invalid.?dns/i;

function collectReasons(node: unknown, out: string[], depth = 0): void {
  if (depth > 4 || node === null || typeof node !== "object") return;
  if (Array.isArray(node)) { for (const item of node.slice(0, 20)) collectReasons(item, out, depth + 1); return; }
  const record = node as Record<string, unknown>;
  for (const key of ["reason", "diagnostic_message"]) if (typeof record[key] === "string") out.push(record[key]);
  collectReasons(record.event_data, out, depth + 1);
  collectReasons(record.details, out, depth + 1);
}

/** Classifies a provider bounce message. Nothing it reads is persisted: diagnostics
 *  usually quote the recipient address. */
export function classifyBounce(message: unknown): BounceClass {
  const reasons: string[] = [];
  collectReasons(message, reasons);
  const text = reasons.join(" ");
  if (SENDER.test(text)) return "sender";
  if (TRANSIENT.test(text)) return "transient";
  if (RECIPIENT.test(text)) return "recipient";
  return "unclassified";
}

export async function isSuppressed(db: Tx, hash: Uint8Array<ArrayBuffer>): Promise<boolean> {
  const row = await db.emailSuppression.findFirst({
    where: { recipientHash: hash, liftedAt: null, expiresAt: { gt: new Date() } },
    select: { recipientHash: true },
  });
  return row !== null;
}

/** Raw SQL so merge, replay and lift semantics are one atomic statement. The WHERE
 *  clause lets a late retry of a bounce for a job sent before a lift leave the lift
 *  alone, while a bounce from a later send suppresses again. */
export async function suppressRecipient(
  tx: Tx,
  hash: Uint8Array<ArrayBuffer>,
  reason: "recipient" | "unclassified" | "complaint",
  jobCreatedAt: Date,
): Promise<void> {
  const ttlMs = SUPPRESSION_TTL_MS[reason];
  await tx.$executeRaw`
    INSERT INTO email_suppressions (recipient_hash, reason, expires_at)
    VALUES (${hash}::bytea, ${reason}, now() + ${ttlMs}::double precision * interval '1 millisecond')
    ON CONFLICT (recipient_hash) DO UPDATE SET
      expires_at = GREATEST(CASE WHEN email_suppressions.lifted_at IS NULL THEN email_suppressions.expires_at ELSE now() END, EXCLUDED.expires_at),
      reason     = CASE WHEN email_suppressions.lifted_at IS NULL AND email_suppressions.reason = 'recipient' THEN 'recipient' ELSE EXCLUDED.reason END,
      lifted_at  = NULL, events = email_suppressions.events + 1, updated_at = now()
    WHERE email_suppressions.lifted_at IS NULL OR email_suppressions.lifted_at < ${jobCreatedAt}::timestamptz`;
}

export async function liftSuppression(db: Tx, hash: Uint8Array<ArrayBuffer>): Promise<void> {
  await db.$executeRaw`
    UPDATE email_suppressions SET lifted_at = now(), updated_at = now()
    WHERE recipient_hash = ${hash}::bytea AND lifted_at IS NULL`;
}

/** Lifted rows linger so the lift guard can absorb late bounce retries. */
export async function sweepSuppressions(db: Tx): Promise<void> {
  await db.$executeRaw`
    DELETE FROM email_suppressions
    WHERE expires_at < now() - interval '1 day' OR lifted_at < now() - interval '30 days'`;
}

export type Admission = "ok" | "google" | "domain" | "suppressed";

/** The single existence-blind admission decision for outbound sign-in mail: it looks
 *  only at the address, never at whether an account exists. */
export async function admitRecipient(
  db: Tx,
  secret: string,
  email: string,
  domain: MailDomainVerdict,
  opts: { googleOnly: boolean },
): Promise<Admission> {
  if (!z.email().safeParse(email).success) return "ok";
  if (opts.googleOnly && canonicalMailbox(email).endsWith("@gmail.com")) return "google";
  if (domain === "no_mail") return "domain";
  if (await isSuppressed(db, recipientDigest(secret, email))) return "suppressed";
  return "ok";
}
