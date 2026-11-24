// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { z } from "zod";
import type { Tx } from "../db/index.js";
import type { MailDomainVerdict } from "./mail-domain.js";
import { isGmail, recipientDigest } from "./recipient-key.js";

const DAY_MS = 86400000;
const EMAIL = z.email();

/** A recipient-side bounce is strong evidence the mailbox is dead; an unclassifiable
 *  one only earns a short pause so a misread reason cannot lock a real user out. */
const SUPPRESSION_TTL_MS = {
  recipient: 180 * DAY_MS,
  unclassified: 7 * DAY_MS,
} as const;

export type BounceClass = "recipient" | "unclassified" | "transient" | "sender";

// Order matters: a sender-side rejection often carries generic "mailbox unavailable"
// wording, so sender is tested before recipient; transient before recipient because
// provider "relaying" errors describe our connection, not the mailbox.
// Status codes are anchored so dotted quads in a diagnostic (an IP, a version) can
// never read as an enhanced status code.
const status = (codes: string) => String.raw`(?:^|[\s;(:])(?:${codes})(?!\d)(?!\.\d)`;
const SENDER = new RegExp(
  String.raw`${status(String.raw`5\.7\.\d{1,3}|5\.1\.[78]`)}|sender.?address|\b(?:spam|virus|blocked|policy|reputation|spf|dkim|dmarc)\b|\b(?:black|block)-?list(?:ed)?\b|\b(?:is|been|are) listed\b|sender.?ip|\bauthenticat`,
  "i",
);
const TRANSIENT = new RegExp(
  String.raw`relay(?:ing)?[ -](?:issues?|denied|not permitted|access denied)|\btime(?:d.?)?out\b|\bconnection\b|\bunreachable\b|not.?reachable|mailbox full|inbox full|\bquota\b|grey.?list|gray.?list|\btemporar|try.?again|${status(String.raw`4\.\d{1,3}\.\d{1,3}`)}|dns.?fail|\brouting\b|\bprotocol\b`,
  "i",
);
const RECIPIENT = new RegExp(
  String.raw`unknown.?user|user.?unknown|\bno.?such\b|\bnot.?found\b|does.?not.?exist|mailbox.?(?:not|unavail)|bad.?mailbox|invalid.?(?:recipient|mailbox|address)|\b(?:inactive|disabled)\b|${status(String.raw`5\.1\.(?:1|2|3|6|10)`)}|domain.?not.?found|invalid.?dns`,
  "i",
);
// ZeptoMail's structured reason vocabulary; a value that is exactly one of these
// names the recipient, whatever free text the diagnostic quotes around it.
const RECIPIENT_CATEGORY = /^(?:unknown-user|bad-mailbox|inactive-mailbox|bad-domain|invalid-[a-z-]+)$/i;

function collectReasons(node: unknown, reasons: string[], diagnostics: string[], depth = 0): void {
  if (depth > 4 || node === null || typeof node !== "object") return;
  if (Array.isArray(node)) { for (const item of node.slice(0, 20)) collectReasons(item, reasons, diagnostics, depth + 1); return; }
  const record = node as Record<string, unknown>;
  if (typeof record.reason === "string") reasons.push(record.reason);
  if (typeof record.diagnostic_message === "string") diagnostics.push(record.diagnostic_message);
  collectReasons(record.event_data, reasons, diagnostics, depth + 1);
  collectReasons(record.details, reasons, diagnostics, depth + 1);
}

/** Classifies a provider bounce message. Nothing it reads is persisted: diagnostics
 *  usually quote the recipient address. */
export function classifyBounce(message: unknown): BounceClass {
  const reasons: string[] = [];
  const diagnostics: string[] = [];
  collectReasons(message, reasons, diagnostics);
  const text = [...reasons, ...diagnostics].join(" ");
  if (SENDER.test(text)) return "sender";
  if (reasons.some((r) => RECIPIENT_CATEGORY.test(r.trim()))) return "recipient";
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
  reason: "recipient" | "unclassified",
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

export const ADMISSION_REFUSAL: Record<Exclude<Admission, "ok">, { code: string; message: string }> = {
  google: { code: "EMAIL_USE_GOOGLE", message: "Gmail addresses sign in with Google. Use Continue with Google." },
  domain: { code: "EMAIL_DOMAIN_UNDELIVERABLE", message: "That email domain can't receive mail. Check the part after the @." },
  suppressed: { code: "EMAIL_UNDELIVERABLE", message: "We can't send email to that address. Check the spelling, or use a different address." },
};

/** The single existence-blind admission decision for outbound sign-in mail: it looks
 *  only at the address, never at whether an account exists. */
export async function admitRecipient(
  db: Tx,
  secret: string,
  email: string,
  domain: MailDomainVerdict,
  opts: { googleOnly: boolean },
): Promise<Admission> {
  if (!EMAIL.safeParse(email).success) return "ok";
  if (opts.googleOnly && isGmail(email)) return "google";
  if (domain === "no_mail") return "domain";
  if (await isSuppressed(db, recipientDigest(secret, email))) return "suppressed";
  return "ok";
}
