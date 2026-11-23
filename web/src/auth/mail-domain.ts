// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { Resolver } from "node:dns/promises";
import { normalizeDomain } from "./recipient-key.js";

export type MailDomainVerdict = "deliverable" | "no_mail" | "unknown";
export type MailDomainCheck = (email: string) => Promise<MailDomainVerdict>;
export type MailResolver = {
  resolveMx(d: string): Promise<{ exchange: string; priority: number }[]>;
  resolve4(d: string): Promise<string[]>;
  resolve6(d: string): Promise<string[]>;
};

export const acceptAllMailDomains: MailDomainCheck = async () => "deliverable";

const SPECIAL_USE_LABELS = new Set(["local", "localhost", "test", "invalid", "example", "internal", "onion", "alt", "arpa"]);
const RESERVED_DOMAINS = new Set(["example.com", "example.net", "example.org"]);
const ABSENT_CODES = new Set(["ENOTFOUND", "ENODATA"]);

export function mailDomainOf(email: string): string | null {
  const at = email.lastIndexOf("@");
  if (at < 0) return null;
  const domain = normalizeDomain(email.slice(at + 1));
  return domain === "" ? null : domain;
}

function isSpecialUse(domain: string): boolean {
  if (domain.startsWith("[")) return true;
  if (!domain.includes(".")) return true;
  if (RESERVED_DOMAINS.has(domain)) return true;
  return SPECIAL_USE_LABELS.has(domain.slice(domain.lastIndexOf(".") + 1));
}

function errorCode(err: unknown): string | undefined {
  const code = (err as { code?: unknown } | null)?.code;
  return typeof code === "string" ? code : undefined;
}

// Arrow wrappers: the Resolver methods depend on `this`.
function systemResolver(): MailResolver {
  const r = new Resolver({ timeout: 1000, tries: 1 });
  return {
    resolveMx: (d) => r.resolveMx(d),
    resolve4: (d) => r.resolve4(d),
    resolve6: (d) => r.resolve6(d),
  };
}

type Cached = { verdict: MailDomainVerdict; until: number };

const CACHE_MAX = 4096;
const DELIVERABLE_TTL_MS = 6 * 3600000;
const NO_MAIL_TTL_MS = 15 * 60000;
const CANARY_HEALTHY_MS = 60000;
const CANARY_UNHEALTHY_MS = 10000;

/** Checks that a domain can receive mail. It only ever answers `no_mail` for proof of
 *  absence, and fails open to `unknown` on every resolver fault, so a DNS outage can
 *  degrade the check but never block sign-in. */
export function createMailDomainCheck(opts: {
  resolver?: MailResolver; deadlineMs?: number; maxInFlight?: number;
  canaryDomain?: string; now?: () => number;
} = {}): MailDomainCheck {
  const resolver = opts.resolver ?? systemResolver();
  const deadlineMs = opts.deadlineMs ?? 1500;
  const maxInFlight = opts.maxInFlight ?? 16;
  const canaryDomain = opts.canaryDomain ?? "gmail.com";
  const now = opts.now ?? Date.now;
  const cache = new Map<string, Cached>();
  const pending = new Map<string, Promise<MailDomainVerdict>>();
  let inFlight = 0;
  let canary: { healthy: boolean; until: number } | null = null;

  const remember = (domain: string, verdict: MailDomainVerdict) => {
    if (verdict === "unknown") return;
    cache.delete(domain);
    if (cache.size >= CACHE_MAX) cache.delete(cache.keys().next().value as string);
    cache.set(domain, { verdict, until: now() + (verdict === "deliverable" ? DELIVERABLE_TTL_MS : NO_MAIL_TTL_MS) });
  };

  // A resolver answering "not found" for everything would otherwise condemn every
  // domain, so a no_mail finding is believed only while a known-good domain resolves.
  const canaryHealthy = async (): Promise<boolean> => {
    if (canary && canary.until > now()) return canary.healthy;
    let healthy = false;
    try {
      const records = await resolver.resolveMx(canaryDomain);
      healthy = records.some((r) => r.exchange !== "" && r.exchange !== ".");
    } catch { healthy = false; }
    canary = { healthy, until: now() + (healthy ? CANARY_HEALTHY_MS : CANARY_UNHEALTHY_MS) };
    return healthy;
  };

  const lookup = async (domain: string): Promise<MailDomainVerdict> => {
    let records: { exchange: string }[];
    try {
      records = await resolver.resolveMx(domain);
    } catch (err) {
      if (!ABSENT_CODES.has(errorCode(err) ?? "")) return "unknown";
      records = [];
    }
    if (records.length === 1 && (records[0].exchange === "" || records[0].exchange === ".")) return "no_mail";
    if (records.length > 0) return "deliverable";
    // Bun reports NODATA as ENOTFOUND, so absence of MX alone proves nothing: a domain
    // with only an address record is still deliverable (implicit MX).
    const [v4, v6] = await Promise.allSettled([resolver.resolve4(domain), resolver.resolve6(domain)]);
    for (const r of [v4, v6]) if (r.status === "fulfilled" && r.value.length > 0) return "deliverable";
    for (const r of [v4, v6]) if (r.status === "rejected" && !ABSENT_CODES.has(errorCode(r.reason) ?? "")) return "unknown";
    return (await canaryHealthy()) ? "no_mail" : "unknown";
  };

  return async (email) => {
    try {
      const domain = mailDomainOf(email);
      if (domain === null) return "unknown";
      if (isSpecialUse(domain)) return "no_mail";
      const hit = cache.get(domain);
      if (hit && hit.until > now()) return hit.verdict;
      if (hit) cache.delete(domain);
      // Callers asking about one domain share a lookup, so a single hostile zone
      // can hold at most one slot however many requests name it.
      let work = pending.get(domain);
      if (!work) {
        if (inFlight >= maxInFlight) return "unknown";
        inFlight++;
        // The slot is released when the lookup itself settles, not when the deadline
        // fires, so hung lookups keep counting against the cap.
        work = lookup(domain).catch((): MailDomainVerdict => "unknown").finally(() => { inFlight--; pending.delete(domain); });
        pending.set(domain, work);
      }
      let timer: ReturnType<typeof setTimeout> | undefined;
      const deadline = new Promise<MailDomainVerdict>((resolve) => { timer = setTimeout(() => resolve("unknown"), deadlineMs); });
      const verdict = await Promise.race([work, deadline]);
      clearTimeout(timer);
      remember(domain, verdict);
      return verdict;
    } catch {
      return "unknown";
    }
  };
}
