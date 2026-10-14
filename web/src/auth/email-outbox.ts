// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { createCipheriv, createDecipheriv, randomBytes, randomUUID } from "node:crypto";
import { z } from "zod";
import type { DB } from "../db/index.js";
import { authScope, scopedAuthDb } from "./transaction.js";
import { retainAuthHistory } from "../models/auth-report.js";
import { recordStage } from "./flows.js";
import { EmailProviderError, type SendEmail } from "./email.js";

const Payload = z.object({ to: z.email(), subject: z.string().max(512), text: z.string().max(65536), html: z.string().max(65536).optional(), clientReference: z.string().max(128).optional() });
export class EmailKeyring {
  private keys: Map<string, Buffer>;
  constructor(public active: string, raw: Record<string, string>) {
    this.keys = new Map(Object.entries(z.record(z.string().regex(/^[a-zA-Z0-9_-]{1,32}$/), z.string()).parse(raw)).map(([id, value]) => {
      const key = Buffer.from(value, "base64");
      if (key.length !== 32) throw new Error("Email encryption keys must contain 32 bytes");
      return [id, key];
    }));
    if (!this.keys.has(active)) throw new Error("Active email encryption key is missing");
  }
  seal(id: string, value: unknown) {
    const nonce = randomBytes(12);
    const cipher = createCipheriv("aes-256-gcm", this.keys.get(this.active)!, nonce);
    cipher.setAAD(Buffer.from(id));
    const data = Buffer.concat([cipher.update(JSON.stringify(value)), cipher.final()]);
    return Buffer.concat([nonce, cipher.getAuthTag(), data]);
  }
  open(id: string, version: string, value: Uint8Array) {
    const key = this.keys.get(version);
    if (!key) throw new EmailProviderError("configuration");
    const bytes = Buffer.from(value);
    const cipher = createDecipheriv("aes-256-gcm", key, bytes.subarray(0, 12));
    cipher.setAAD(Buffer.from(id)); cipher.setAuthTag(bytes.subarray(12, 28));
    return Payload.parse(JSON.parse(Buffer.concat([cipher.update(bytes.subarray(28)), cipher.final()]).toString()));
  }
}

export function createOutboxSender(database: DB, keys: EmailKeyring): SendEmail {
  const db = scopedAuthDb(database);
  return async (mail) => {
    const id = randomUUID();
    const payload = Payload.parse(mail);
    const flowId = authScope.getStore()?.flowId;
    const expiresAt = mail.expiresAt ?? new Date(Date.now() + 3600000);
    await db.emailJob.create({ data: { id, flowId, reference: id, relatedReference: payload.clientReference,
      payload: keys.seal(id, payload), keyVersion: keys.active, expiresAt } });
    await recordStage(db, flowId, "mail_queued");
  };
}

const DELAYS = [10, 30, 90, 180];
export async function sendNextEmail(db: DB, keys: EmailKeyring, send: SendEmail): Promise<boolean> {
  const lease = randomUUID();
  const claimed = await db.$queryRaw<{ id: string }[]>`
    WITH candidate AS (SELECT id FROM email_jobs WHERE
      (state='queued' OR (state='sending' AND lease_until < now())) AND next_at <= now()
      AND NOT EXISTS (SELECT 1 FROM auth_rate_buckets WHERE key='email-sender-paused')
      ORDER BY next_at FOR UPDATE SKIP LOCKED LIMIT 1)
    UPDATE email_jobs SET state='sending', lease_id=${lease}::uuid, lease_until=now()+interval '30 seconds', attempts=attempts+1
    FROM candidate WHERE email_jobs.id=candidate.id RETURNING email_jobs.id`;
  if (!claimed.length) return false;
  const job = await db.emailJob.findUniqueOrThrow({ where: { id: claimed[0].id } });
  const where = { id: job.id, leaseId: lease, state: "sending" };
  const clear = { payload: null, keyVersion: null, leaseUntil: null, leaseId: null };
  if (job.expiresAt.getTime() - Date.now() < 60000 || job.attempts > 5) {
    const failure = job.attempts > 5 ? "attempts_exhausted" : "expired";
    await db.$transaction(async (tx) => {
      const updated = await tx.emailJob.updateMany({ where, data: { ...clear, state: failure === "expired" ? "expired" : "failed", failure } });
      if (updated.count) await recordStage(tx, job.flowId ?? undefined, "mail_failed", failure);
    });
    return true;
  }
  const renew = setInterval(() => {
    void db.emailJob.updateMany({ where, data: { leaseUntil: new Date(Date.now() + 30000) } }).catch(() => {});
  }, 5000);
  try {
    if (!job.payload || !job.keyVersion) throw new EmailProviderError("permanent");
    const payload = keys.open(job.id, job.keyVersion, job.payload);
    // The same link and reference survive ambiguous timeouts and lease recovery.
    const accepted = await send({ ...payload, clientReference: job.reference, expiresAt: job.expiresAt });
    await db.$transaction(async (tx) => {
      const updated = await tx.emailJob.updateMany({ where, data: { ...clear, state: "provider_accepted", providerId: accepted?.providerId } });
      if (updated.count) await recordStage(tx, job.flowId ?? undefined, "mail_accepted");
    });
  } catch (error) {
    const failure = error instanceof EmailProviderError ? error.kind : "transient";
    if (failure === "configuration") {
      await db.authRateBucket.upsert({ where: { key: "email-sender-paused" }, create: { key: "email-sender-paused", stamps: [] }, update: {} });
      await db.emailJob.updateMany({ where, data: { state: "queued", leaseId: null, leaseUntil: null, attempts: Math.max(0, job.attempts - 1), failure } });
      console.error("[email] sending paused: provider configuration or encryption key unavailable");
    } else {
      const delay = Math.max((DELAYS[job.attempts - 1] ?? 180) * (0.8 + Math.random() * 0.4),
        error instanceof EmailProviderError ? error.retryAfter ?? 0 : 0);
      const nextAt = new Date(Date.now() + delay * 1000);
      const terminal = failure === "permanent" || job.attempts >= 5;
      const expired = job.expiresAt.getTime() - nextAt.getTime() < 60000;
      await db.emailJob.updateMany({ where, data: terminal || expired
        ? { ...clear, state: expired ? "expired" : "failed", failure }
        : { state: "queued", leaseId: null, leaseUntil: null, nextAt, failure } });
    }
    const updatedJob = await db.emailJob.findUnique({ where: { id: job.id } });
    if (updatedJob?.state === "failed" || updatedJob?.state === "expired") await recordStage(db, job.flowId ?? undefined, "mail_failed", updatedJob.failure ?? updatedJob.state);
  } finally { clearInterval(renew); }
  return true;
}

export async function expireEmailPayloads(db: DB) {
  await db.$transaction(async (tx) => {
    await tx.$executeRaw`DELETE FROM auth_rate_buckets WHERE key LIKE 'auth-browser-binding:%' AND stamps[1] <= now()`;
    const expired = await tx.$queryRaw<{ flow_id: string | null }[]>`UPDATE email_jobs
      SET state='expired', failure='expired', payload=NULL, key_version=NULL, lease_id=NULL, lease_until=NULL
      WHERE expires_at < now() AND state IN ('queued','sending') RETURNING flow_id`;
    for (const job of expired) await recordStage(tx, job.flow_id ?? undefined, "mail_failed", "expired");
  });
}

export function startEmailOutbox(db: DB, keys: EmailKeyring, send: SendEmail, paused = false) {
  let busy = false;
  let lastRetention = 0;
  const tick = async () => {
    if (busy) return;
    busy = true;
    try {
      if (!paused) await Promise.all([sendNextEmail(db, keys, send), sendNextEmail(db, keys, send)]);
      await expireEmailPayloads(db);
      if (Date.now() - lastRetention > 3600000) { await retainAuthHistory(db); lastRetention = Date.now(); }
      await db.emailJob.deleteMany({ where: { createdAt: { lt: new Date(Date.now() - 30 * 86400000) } } });
      await db.authRateBucket.deleteMany({ where: { key: { not: "email-sender-paused" }, updatedAt: { lt: new Date(Date.now() - 86400000) } } });
    } catch { console.error("[email] outbox database operation failed"); }
    finally { busy = false; }
  };
  const timer = setInterval(() => { void tick(); }, 1000);
  void tick();
  return () => clearInterval(timer);
}
