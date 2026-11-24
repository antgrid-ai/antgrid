// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { createHash } from "node:crypto";
import type { DB } from "./db/index.js";
import type { Env } from "./env.js";
import { EmailKeyring, createOutboxSender } from "./auth/email-outbox.js";
import { createEmailSender, type SendEmail } from "./auth/email.js";
import { acceptAllMailDomains, createMailDomainCheck, type MailDomainCheck } from "./auth/mail-domain.js";

/** One composition point so a test can pin that the outbox writes recipient digests
 *  and that the real domain check is wired. */
export function composeMail(env: Env, db: DB): { keys: EmailKeyring; providerSend: SendEmail; sendEmail: SendEmail; mailDomain: MailDomainCheck } {
  const keys = new EmailKeyring(env.EMAIL_OUTBOX_ACTIVE_KEY ?? "dev", env.EMAIL_OUTBOX_KEYS ? JSON.parse(env.EMAIL_OUTBOX_KEYS) :
    { dev: createHash("sha256").update("development-email-only:" + env.BETTER_AUTH_SECRET).digest("base64") });
  const sender = createEmailSender({ zeptoToken: env.ZEPTOMAIL_TOKEN, from: env.EMAIL_FROM, replyTo: env.EMAIL_REPLY_TO });
  // The provider log is shared across stacks, so the subject says which one sent a mail.
  const providerSend: SendEmail = env.NODE_ENV !== "production" && env.ZEPTOMAIL_TOKEN
    ? (mail) => sender({ ...mail, subject: `[${env.NODE_ENV}] ${mail.subject}` })
    : sender;
  const sendEmail = createOutboxSender(db, keys, { recipientSecret: env.BETTER_AUTH_SECRET });
  // Keyed on the token, not NODE_ENV: any stack that can really send must refuse dead
  // domains, while console-mail dev stacks keep signing in as reserved-TLD fixtures.
  const mailDomain = env.ZEPTOMAIL_TOKEN ? createMailDomainCheck() : acceptAllMailDomains;
  return { keys, providerSend, sendEmail, mailDomain };
}
