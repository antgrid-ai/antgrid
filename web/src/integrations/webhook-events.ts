// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { createHash } from "node:crypto";
import type { DB, Tx } from "../db/index.js";
import type { Prisma } from "../generated/prisma/client.js";

/**
 * The `webhook_events` store, for providers that insert a delivery and respond
 * before doing the work.
 *
 * This is a **different shape from billing**, which inserts its dedup row inside
 * the effect's own transaction and stamps `processed_at` at insert:
 * exactly-once-per-effect. Insert-then-202 trades that for
 * at-most-once-with-a-hole — a crash between the insert and the work leaves a
 * row the provider will never retry, because we already 202'd. `recordDelivery`
 * closes the hole: a manual redelivery re-arms a row that has not been
 * processed instead of being swallowed as a duplicate.
 */

/**
 * How many drain passes a row gets before it is left alone.
 *
 * A poison payload otherwise spins for the life of the deployment. Rows that
 * reach the ceiling stay `processed_at IS NULL` with their last error attached
 * — `listGivenUpDeliveries` is what makes them findable rather than invisible —
 * and a redelivery from the provider's UI is the recovery path (see
 * `recordDelivery`).
 */
export const MAX_WEBHOOK_ATTEMPTS = 5;

/** Errors carry provider text; the column is unbounded and the log line is not. */
const MAX_ERROR_CHARS = 1000;

/**
 * Exponential-backoff bounds for a failed delivery's `next_attempt_at`, mirroring
 * `task_sync_ops`' outbox backoff (`SYNC_OP_BACKOFF_BASE_SECONDS`/`_MAX_SECONDS`
 * in `tasks/sync-op.ts`). Without it a failing row was reclaimed on the very
 * next drain pass and burned `MAX_WEBHOOK_ATTEMPTS` inside one invocation's
 * first few passes rather than over any real spread of time.
 */
export const WEBHOOK_BACKOFF_BASE_SECONDS = 30;
export const WEBHOOK_BACKOFF_MAX_SECONDS = 30 * 60;

/**
 * The idempotency key for a delivery whose provider signs the body and nothing
 * else: a hash of the exact bytes the signature covers.
 *
 * A delivery-id header sits *outside* the signature, so one captured
 * `(body, signature)` pair replays for ever — every replay verifies, mints a
 * fresh key, and is processed again. Hash before parsing: re-serializing a
 * parsed object gives a different key for the same delivery the first time a
 * JSON library or a key order changes.
 *
 * The cost is that two genuinely distinct events with byte-identical bodies
 * collapse into one, which has to be argued per event type rather than in
 * general. For every GitHub event we subscribe to it is unreachable: each
 * payload embeds the full object (an `issues` payload carries the issue's own
 * `updated_at`), plus `sender` and, for lifecycle events, the installation.
 */
export function bodyDeliveryKey(raw: Uint8Array): string {
  return createHash("sha256").update(raw).digest("hex");
}

/**
 * Serialize a payload for a `jsonb` column, with NUL characters removed.
 *
 * Postgres rejects a NUL escape (backslash-u-0000) inside `jsonb` — the type
 * has no representation for it, so the cast raises `unsupported Unicode escape
 * sequence` and the whole insert fails. On the request path that is a 500 for a
 * delivery that verified, which the provider then redelivers into the same 500
 * for as long as it retries. Dropping the character loses nothing that could
 * have been stored anyway.
 *
 * Stripping the character before serialization, rather than the escape after
 * it, is what keeps it honest: a payload whose text genuinely contains the six
 * characters that spell that escape is ordinary content Postgres accepts, and a
 * rewrite of the finished JSON cannot tell the two apart without counting
 * backslash runs. Object *keys* are not reachable from a replacer, but every
 * key in a provider payload is a fixed field name.
 */
const NUL = String.fromCharCode(0);

function serializeJsonbPayload(value: unknown): string {
  return JSON.stringify(value ?? null, (_key, inner) =>
    typeof inner === "string" && inner.includes(NUL) ? inner.split(NUL).join("") : inner
  );
}

export type RecordDeliveryArgs = {
  provider: string;
  providerEventId: string;
  type: string;
  payload: unknown;
};

export type RecordedDelivery = {
  id: string;
  /** False for a redelivery or a replay — the row already existed. */
  inserted: boolean;
  /** True when the existing row had already been processed, so nothing moved. */
  alreadyProcessed: boolean;
};

/**
 * Insert a delivery, or re-arm the one already recorded.
 *
 * The conflict arm is the whole point and Prisma cannot express it: a row that
 * has not been processed goes back into the queue with its error cleared, while
 * a processed row is left exactly as it is. Without this a manual redelivery —
 * the operator's only lever after a crash or a bug — looks like a duplicate and
 * the hole is unrecoverable.
 *
 * `attempts` is bumped so the counter still reads as "deliveries seen", but
 * clamped below the ceiling: a redelivery of a row that has given up is the
 * operator explicitly asking for another pass, and leaving it at the ceiling
 * would make the recovery path a no-op.
 */
export async function recordDelivery(
  db: DB,
  args: RecordDeliveryArgs
): Promise<RecordedDelivery> {
  const rows = await db.$queryRaw<{ id: string; inserted: boolean; processed: boolean }[]>`
    INSERT INTO webhook_events (provider, provider_event_id, type, payload)
    VALUES (
      ${args.provider},
      ${args.providerEventId},
      ${args.type},
      ${serializeJsonbPayload(args.payload)}::jsonb
    )
    ON CONFLICT (provider, provider_event_id) DO UPDATE SET
      attempts = CASE
        WHEN webhook_events.processed_at IS NULL
        THEN LEAST(webhook_events.attempts + 1, ${MAX_WEBHOOK_ATTEMPTS - 1})
        ELSE webhook_events.attempts
      END,
      last_error = CASE
        WHEN webhook_events.processed_at IS NULL THEN NULL
        ELSE webhook_events.last_error
      END,
      -- A redelivery is the operator explicitly asking for another pass now,
      -- not a reason to make them wait out a backoff a PRIOR failure set.
      next_attempt_at = CASE
        WHEN webhook_events.processed_at IS NULL THEN now()
        ELSE webhook_events.next_attempt_at
      END
    RETURNING
      id::text AS id,
      -- xmax is zero only on a row this statement inserted; on the conflict arm
      -- it carries the updating transaction's id.
      (xmax = 0) AS inserted,
      (processed_at IS NOT NULL) AS processed`;

  const row = rows[0];
  if (!row) throw new Error("recordDelivery: insert returned no row");
  return { id: row.id, inserted: row.inserted, alreadyProcessed: row.processed };
}

/**
 * Stamp a delivery done. `note` is attached for an outcome that succeeded
 * without being applied — a payload no schema accepts is never going to parse on
 * a retry, so it is closed rather than left to burn the ceiling, and the note is
 * what says so afterwards.
 */
export async function markDeliveryProcessed(
  tx: Tx,
  id: string,
  note?: string
): Promise<void> {
  await tx.webhookEvent.update({
    where: { id },
    data: { processedAt: new Date(), lastError: note ? truncate(note) : null },
  });
}

/**
 * Count the failure and lease the row out by an exponential backoff, mirroring
 * `failOp` in `tasks/sync-op.ts`. Returns the new attempt count so the caller
 * can see the pass that hit the ceiling.
 *
 * Left claimable (never `given_up`) at the ceiling, unlike the outbox: a
 * poison delivery stays `processed_at IS NULL` so `listGivenUpDeliveries` can
 * still find it, and the claim query's own `attempts < MAX_WEBHOOK_ATTEMPTS`
 * is what stops the drain from touching it again.
 */
export async function recordDeliveryFailure(
  db: DB,
  id: string,
  error: string
): Promise<number> {
  const rows = await db.$queryRaw<{ attempts: number }[]>`
    UPDATE webhook_events SET
      attempts = attempts + 1,
      last_error = ${truncate(error)},
      next_attempt_at = now() + make_interval(secs =>
        LEAST(
          ${WEBHOOK_BACKOFF_MAX_SECONDS}::double precision,
          ${WEBHOOK_BACKOFF_BASE_SECONDS}::double precision * power(2, attempts)
        ))
    WHERE id = ${id}::uuid
    RETURNING attempts`;

  const row = rows[0];
  if (!row) throw new Error(`recordDeliveryFailure: no delivery ${id}`);
  return row.attempts;
}

export type GivenUpDelivery = {
  id: string;
  type: string;
  providerEventId: string;
  attempts: number;
  lastError: string | null;
  receivedAt: Date;
};

/** Deliveries that exhausted the ceiling. The drain will not touch them again,
 *  so this is the only thing standing between "gave up" and "vanished". */
export async function listGivenUpDeliveries(
  db: Tx,
  provider: string,
  limit = 100
): Promise<GivenUpDelivery[]> {
  return db.webhookEvent.findMany({
    where: { provider, processedAt: null, attempts: { gte: MAX_WEBHOOK_ATTEMPTS } },
    orderBy: { receivedAt: "asc" },
    take: limit,
    select: {
      id: true,
      type: true,
      providerEventId: true,
      attempts: true,
      lastError: true,
      receivedAt: true,
    },
  });
}

/** How long a processed delivery is kept. Long enough to answer "what did we do
 *  with delivery X" while a user still remembers the issue that moved, short
 *  enough that a busy repository's full payload copies do not become the largest
 *  table in the database. */
export const WEBHOOK_EVENT_RETENTION_DAYS = 30;

export function retentionCutoff(now: Date, days = WEBHOOK_EVENT_RETENTION_DAYS): Date {
  return new Date(now.getTime() - days * 24 * 60 * 60 * 1000);
}

/** What a purged row's payload becomes. Never `null` — the column is `NOT
 *  NULL` — and distinct from any real delivery body, so a purge run is
 *  idempotent: a row already carrying this is excluded rather than rewritten
 *  every day for the rest of its retained life. */
const PURGED_PAYLOAD = { purged: true } satisfies Prisma.InputJsonValue;

/**
 * Retire a processed delivery's payload, older than the cutoff, for one
 * provider — the ROW stays.
 *
 * The row, not just its body, is what makes `recordDelivery`'s `ON CONFLICT`
 * dedup work: `[provider, provider_event_id]` is the unique it upserts against,
 * and a captured `(body, signature)` pair GitHub's provider-side retry would
 * otherwise redeliver for ever, hashed to the same key, replays into the SAME
 * key however long ago it was first seen. Deleting the row — the previous
 * shape of this function — reopened that: a replay past the retention cutoff
 * inserted as new and was processed a second time. Only the `payload` column is
 * cleared, which is what retention is actually for: the billing rows sharing
 * this table are the idempotency guard a late gateway redelivery is checked
 * against, and it is their BODY that is unbounded growth, never their key.
 * Unprocessed rows are never touched — they are the backlog, including the
 * deferred event types a later phase turns on.
 */
export async function purgeProcessedWebhookEvents(
  db: DB,
  args: { provider: string; before: Date }
): Promise<number> {
  const result = await db.webhookEvent.updateMany({
    where: {
      provider: args.provider,
      processedAt: { not: null, lt: args.before },
      // NOT `{ not: { equals: PURGED_PAYLOAD } } }` — Prisma's JSON filter takes
      // the comparison value directly under `not`, and a nested `equals` is
      // itself a JSON object no stored payload is ever shaped like, so that
      // form matches every row and this purge would never become a no-op.
      payload: { not: PURGED_PAYLOAD },
    },
    data: { payload: PURGED_PAYLOAD },
  });
  return result.count;
}

function truncate(value: string): string {
  return value.length > MAX_ERROR_CHARS ? `${value.slice(0, MAX_ERROR_CHARS)}…` : value;
}
