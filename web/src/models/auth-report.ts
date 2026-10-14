// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { z } from "zod";
import type { DB } from "../db/index.js";
import { Prisma } from "../generated/prisma/client.js";

export const AuthReportQuery = z.object({
  surface: z.enum(["all", "flutter", "web", "unknown"]).default("all"),
  platform: z.enum(["all", "android", "ios", "macos", "windows", "linux", "unknown"]).default("all"),
  method: z.string().max(32).default("all"), version: z.string().max(64).default("all"),
  from: z.iso.date().default(() => new Date(Date.now() - 7 * 86400000).toISOString().slice(0, 10)),
  to: z.iso.date().default(() => new Date().toISOString().slice(0, 10)),
}).strict();
export type AuthReportFilter = z.infer<typeof AuthReportQuery>;
export type FunnelRow = { origin: string; category: string; accepted: number; verified: number; sessions: number; completed: number;
  pending: number; stalled: number; recovered: number; bounced: number; failures: number; seconds: number | null;
  created: number; queued: number; mailAccepted: number; approved: number; failureCategories: Record<string, number> };

export async function loadAuthReport(db: DB, filter: AuthReportFilter) {
  const fields = ["surface", "platform", "method", "version"] as const;
  const predicates = fields.filter((field) => filter[field] !== "all").map((field) => Prisma.sql`j.origin->>${field}=${filter[field]}`);
  const rows = await db.$queryRaw<FunnelRow[]>(Prisma.sql`
    WITH journeys AS (
      SELECT j.id, j.origin, j.category, j.created_at,
        MIN(e.at) FILTER (WHERE e.stage='ownership_verified') AS verified_at,
        MIN(e.at) FILTER (WHERE e.stage='session_issued') AS session_at,
        MIN(e.at) FILTER (WHERE e.stage='first_client_use') AS completed_at,
        BOOL_OR(e.stage='user_created') AS user_created, BOOL_OR(e.stage='mail_queued') AS queued,
        BOOL_OR(e.stage='mail_accepted') AS mail_accepted, BOOL_OR(e.stage='approval_submitted') AS approved,
        BOOL_OR(e.stage='mail_bounced') AS bounced,
        BOOL_OR(e.failure IS NOT NULL OR f.state='failed') AS failed
      FROM auth_journeys j LEFT JOIN auth_flows f ON f.journey_id=j.id LEFT JOIN auth_flow_events e ON e.flow_id=f.id
      WHERE j.created_at >= ${new Date(filter.from).toISOString()}::timestamptz AND j.created_at < ${new Date(new Date(filter.to).getTime() + 86400000).toISOString()}::timestamptz
        ${predicates.length ? Prisma.sql`AND ${Prisma.join(predicates, " AND ")}` : Prisma.empty}
      GROUP BY j.id
    ) SELECT origin::text, category, COUNT(*)::int AS accepted,
      COUNT(*) FILTER (WHERE verified_at <= created_at+interval '24 hours')::int AS verified,
      COUNT(*) FILTER (WHERE session_at <= created_at+interval '24 hours')::int AS sessions,
      COUNT(*) FILTER (WHERE completed_at <= created_at+interval '24 hours')::int AS completed,
      COUNT(*) FILTER (WHERE completed_at IS NULL AND created_at > now()-interval '24 hours')::int AS pending,
      COUNT(*) FILTER (WHERE completed_at IS NULL AND created_at <= now()-interval '24 hours')::int AS stalled,
      COUNT(*) FILTER (WHERE completed_at > created_at+interval '24 hours')::int AS recovered,
      COUNT(*) FILTER (WHERE user_created)::int AS created, COUNT(*) FILTER (WHERE queued)::int AS queued,
      COUNT(*) FILTER (WHERE mail_accepted)::int AS "mailAccepted", COUNT(*) FILTER (WHERE approved)::int AS approved,
      COUNT(*) FILTER (WHERE bounced)::int AS bounced, COUNT(*) FILTER (WHERE failed)::int AS failures,
      AVG(EXTRACT(EPOCH FROM completed_at-created_at))::float8 AS seconds FROM journeys GROUP BY origin::text, category`);
  for (const row of rows) { row.failureCategories = {}; row.origin = JSON.stringify(JSON.parse(row.origin)); }
  const failures = await db.$queryRaw<{ origin: string; category: string; failure: string; count: number }[]>(Prisma.sql`
    SELECT j.origin::text, j.category, e.failure, COUNT(DISTINCT j.id)::int AS count
    FROM auth_journeys j JOIN auth_flows f ON f.journey_id=j.id JOIN auth_flow_events e ON e.flow_id=f.id
    WHERE e.failure IS NOT NULL AND j.created_at >= ${new Date(filter.from).toISOString()}::timestamptz AND j.created_at < ${new Date(new Date(filter.to).getTime()+86400000).toISOString()}::timestamptz
    GROUP BY j.origin::text,j.category,e.failure`);
  for (const failure of failures) {
    const row = rows.find((r) => r.origin === JSON.stringify(JSON.parse(failure.origin)) && r.category === failure.category);
    if (row) row.failureCategories[failure.failure] = failure.count;
  }
  const archived = await db.$queryRaw<{ dimension: string; counts: unknown }[]>`SELECT dimension, counts FROM auth_cohorts
    WHERE day >= ${filter.from}::date AND day <= ${filter.to}::date`;
  for (const cohort of archived) {
    const dimension = z.object({ origin: z.record(z.string(),z.unknown()), category: z.string() }).parse(JSON.parse(cohort.dimension));
    if (fields.some((field) => filter[field] !== "all" && dimension.origin[field] !== filter[field])) continue;
    const counts = z.record(z.string(), z.number()).parse(cohort.counts);
    const key = JSON.stringify(dimension.origin);
    let row = rows.find((r) => JSON.stringify(JSON.parse(r.origin)) === key && r.category === dimension.category);
    if (!row) {
      row = { origin: key, category: dimension.category, accepted: 0, verified: 0, sessions: 0, completed: 0, pending: 0,
        stalled: 0, recovered: 0, bounced: 0, failures: 0, seconds: null, created: 0, queued: 0, mailAccepted: 0, approved: 0, failureCategories: {} };
      rows.push(row);
    }
    const currentCount = row.completed + row.recovered;
    const archivedCount = (counts.completed ?? 0) + (counts.recovered ?? 0);
    const sum = (row.seconds ?? 0) * currentCount + (counts.secondsSum ?? 0);
    for (const field of ["accepted","verified","sessions","completed","pending","stalled","recovered","bounced","failures","created","queued","mailAccepted","approved"] as const) row[field] += counts[field] ?? 0;
    row.seconds = currentCount + archivedCount ? sum / (currentCount + archivedCount) : null;
    for (const [field,count] of Object.entries(counts)) if (field.startsWith("failure:")) row.failureCategories[field.slice(8)] = (row.failureCategories[field.slice(8)] ?? 0) + count;
  }
  const verifiedUsers = await db.user.count({ where: { emailVerified: true, NOT: { email: { endsWith: "@deleted.antgrid.invalid" } } } });
  const pendingUsers = await db.user.count({ where: { emailVerified: false, createdAt: { gt: new Date(Date.now() - 86400000) }, NOT: { email: { endsWith: "@deleted.antgrid.invalid" } } } });
  const staleUsers = await db.user.count({ where: { emailVerified: false, createdAt: { lte: new Date(Date.now() - 86400000) }, NOT: { email: { endsWith: "@deleted.antgrid.invalid" } } } });
  const unknownUsers = await db.user.count({ where: { registrationOrigin: { equals: Prisma.DbNull }, NOT: { email: { endsWith: "@deleted.antgrid.invalid" } } } });
  const queue = await db.emailJob.groupBy({ by: ["state"], _count: true, _min: { createdAt: true, expiresAt: true } });
  const recipientOutcomes = await db.emailRecipientEvent.groupBy({ by: ["kind"], _count: true });
  const sendingPaused = !!await db.authRateBucket.findUnique({ where: { key: "email-sender-paused" } });
  return { rows, verifiedUsers, pendingUsers, staleUsers, unknownUsers, queue, recipientOutcomes, sendingPaused };
}

export async function retainAuthHistory(db: DB) {
  const boundary = new Date(Date.now() - 30 * 86400000);
  await db.$transaction(async (tx) => {
    await tx.$executeRaw`SELECT pg_advisory_xact_lock(717)`;
    // Only aggregate closed cohorts, so resends and late recovery cannot be
    // counted twice by replicas racing this retention pass.
    // Archive by day to preserve cohort filters without retaining account links.
    const days = await tx.$queryRaw<{ day: string }[]>`SELECT DISTINCT ((created_at AT TIME ZONE 'UTC')::date)::text AS day FROM auth_journeys
      WHERE (created_at AT TIME ZONE 'UTC')::date < ${(boundary.toISOString().slice(0, 10))}::date`;
    for (const { day } of days) {
      const daily = await loadAuthReport(tx as DB, AuthReportQuery.parse({ from: day, to: day }));
      for (const row of daily.rows) {
        const { origin,category,seconds,failureCategories,...counts } = row;
        const dimension = JSON.stringify({ origin: JSON.parse(origin),category });
        const value = JSON.stringify({ ...counts, secondsSum: (seconds ?? 0)*(row.completed+row.recovered),
          ...Object.fromEntries(Object.entries(failureCategories).map(([key,count]) => ["failure:"+key,count])) });
        await tx.$executeRaw`INSERT INTO auth_cohorts (day,dimension,counts) VALUES (${day}::date,${dimension},${value}::jsonb)
          ON CONFLICT (day,dimension) DO NOTHING`;
      }
    }
    await tx.authJourney.deleteMany({ where: { createdAt: { lt: new Date(boundary.toISOString().slice(0, 10)) } } });
    await tx.$executeRaw`DELETE FROM auth_cohorts WHERE day < ${new Date(Date.now() - 365 * 86400000).toISOString().slice(0,10)}::date`;
    await tx.pendingSignIn.deleteMany({ where: { createdAt: { lt: boundary } } });
  }, { timeout: 30000 });
}
