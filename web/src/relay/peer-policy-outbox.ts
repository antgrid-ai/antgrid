import { createHmac } from "node:crypto";
import { z } from "zod";
import type { DB } from "../db/index.js";

export const PeerPolicyTargetsSchema = z.array(z.strictObject({
  url: z.url().refine((value) => {
    const url = new URL(value);
    return ["https:", "http:"].includes(url.protocol) && !url.username && !url.password &&
      !url.search && !url.hash && url.pathname.startsWith("/internal/");
  }),
  secret: z.string().min(16),
})).max(16);
export type PeerPolicyTarget = z.infer<typeof PeerPolicyTargetsSchema>[number];

export async function deliverPeerPolicyBatch(db: DB, targets: PeerPolicyTarget[], fetchImpl: typeof fetch = fetch) {
  PeerPolicyTargetsSchema.parse(targets);
  if (!targets.some((target) => new URL(target.url).pathname === "/internal/peer-policy")) {
    return { attempted: 0, delivered: 0 };
  }
  return db.$transaction(async (tx) => {
    // A transaction lock spans selection and delivery, including other web processes.
    const [lock] = await tx.$queryRaw<{ acquired: boolean }[]>`SELECT pg_try_advisory_xact_lock(1784629101) AS acquired`;
    if (!lock.acquired) return { attempted: 0, delivered: 0 };
    const rows = await tx.peerAuthorizationOutbox.findMany({ where: {
      deliveredAt: null, nextAttemptAt: { lte: new Date() },
    }, orderBy: [{ createdAt: "asc" }, { id: "asc" }], take: 8 });
    let delivered = 0;
    for (const row of rows) {
      const body = JSON.stringify({ userId: row.userId, generation: row.generation.toString(), issuedAt: Date.now() });
      const outcomes = await Promise.all(targets.map(async (target) => {
        try {
          const response = await fetchImpl(target.url, { method: "POST", redirect: "error",
            headers: { "content-type": "application/json", "x-antgrid-signature":
              createHmac("sha256", target.secret).update(body).digest("hex") },
            body, signal: AbortSignal.timeout(2000) });
          await response.body?.cancel();
          return response.ok;
        } catch { return false; }
      }));
      const success = outcomes.every(Boolean);
      if (success) delivered++;
      await tx.peerAuthorizationOutbox.update({ where: { id: row.id }, data: {
        attempts: { increment: 1 },
        ...(success ? { deliveredAt: new Date() } : {
          nextAttemptAt: new Date(Date.now() + Math.min(60_000, 1000 * 2 ** Math.min(row.attempts, 6))),
        }),
      } });
    }
    return { attempted: rows.length, delivered };
  }, { timeout: 25_000, maxWait: 2000 });
}

export function startPeerPolicyOutbox(db: DB, targets: PeerPolicyTarget[]) {
  let stopped = false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  async function tick() {
    try {
      const result = await deliverPeerPolicyBatch(db, targets);
      if (result.attempted > result.delivered) console.warn("[peer-policy] delivery pending", result);
    } catch { console.warn("[peer-policy] delivery unavailable; durable rows retained"); }
    if (!stopped) { timer = setTimeout(tick, 1000); timer.unref(); }
  }
  if (targets.length) void tick();
  return () => { stopped = true; if (timer) clearTimeout(timer); };
}
