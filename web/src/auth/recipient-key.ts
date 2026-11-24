// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { domainToASCII } from "node:url";
import { createHmac } from "node:crypto";
import { hmacBytes } from "../util/hmac.js";

const GMAIL_DOMAINS = new Set(["gmail.com", "googlemail.com"]);

/** Normalised domain: lowercased, one trailing dot dropped, punycoded. Falls back to
 *  the lowercased form when IDNA conversion rejects it, so the key stays stable. */
export function normalizeDomain(domain: string): string {
  const lowered = domain.trim().toLowerCase().replace(/\.$/, "");
  return domainToASCII(lowered) || lowered;
}

/** Gmail delivers dot and +tag variants to one mailbox, so they must share one rate
 *  bucket and one suppression. Other providers are left alone: dots are significant
 *  on Workspace and Outlook. */
export function canonicalMailbox(email: string): string {
  const lowered = email.trim().toLowerCase();
  const at = lowered.lastIndexOf("@");
  if (at < 0) return lowered;
  let local = lowered.slice(0, at);
  let domain = normalizeDomain(lowered.slice(at + 1));
  if (GMAIL_DOMAINS.has(domain)) {
    const plus = local.indexOf("+");
    if (plus >= 0) local = local.slice(0, plus);
    local = local.replaceAll(".", "");
    domain = "gmail.com";
  }
  return `${local}@${domain}`;
}

/** Keyed digest used as the suppression key. The secret is the auth secret, so
 *  rotating it silently empties the suppression list; that fails open for mail and
 *  every entry expires anyway. The prefix keeps it from ever equalling the unprefixed
 *  rate-bucket key derived from the same address. */
export function recipientDigest(secret: string, email: string): Uint8Array<ArrayBuffer> {
  return hmacBytes(secret, "email-suppression:" + canonicalMailbox(email));
}

export function isGmail(email: string): boolean {
  return canonicalMailbox(email).endsWith("@gmail.com");
}

/** Per-recipient hourly send-bucket key. Hex and unprefixed: it indexes stored rows. */
export function recipientBucketKey(secret: string, email: string): string {
  return createHmac("sha256", secret).update(canonicalMailbox(email)).digest("hex");
}
