// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { createHmac } from "node:crypto";
import type { Tx } from "../db/index.js";
import { authScope } from "./transaction.js";

export async function recipientLimit(db: Tx, secret: string, email: string): Promise<number> {
  const key = createHmac("sha256", secret).update(email.trim().toLowerCase()).digest("hex");
  if (authScope.getStore()?.charged.has(key)) return 0;
  await db.$executeRaw`SELECT pg_advisory_xact_lock(hashtextextended(${key}, 714))`;
  const now = new Date();
  const row = await db.authRateBucket.findUnique({ where: { key } });
  const stamps = (row?.stamps ?? []).filter((s) => now.getTime() - s.getTime() < 3600000);
  const cooldown = stamps.length ? 45 - (now.getTime() - stamps.at(-1)!.getTime()) / 1000 : 0;
  const hourly = stamps.length >= 5 ? 3600 - (now.getTime() - stamps[0].getTime()) / 1000 : 0;
  const retry = Math.ceil(Math.max(cooldown, hourly, 0));
  if (retry) return retry;
  stamps.push(now);
  await db.authRateBucket.upsert({ where: { key }, create: { key, stamps }, update: { stamps, updatedAt: now } });
  authScope.getStore()?.charged.add(key);
  return 0;
}

export async function sharedIpLimit(db: Tx, ip: string, family: string, capacity: number, rate: number): Promise<number> {
  const key = "ip:" + createHmac("sha256", "auth-ip").update(ip + ":" + family).digest("hex");
  const now = Date.now();
  await db.$executeRaw`SELECT pg_advisory_xact_lock(hashtextextended(${key}, 714))`;
  const stored = await db.authRateBucket.findUnique({ where: { key } });
  const stamps = (stored?.stamps ?? []).filter((s) => now - s.getTime() < capacity / rate * 1000);
  let tokens = capacity;
  let last = stamps[0]?.getTime() ?? now;
  for (const stamp of stamps) { tokens = Math.min(capacity, tokens + (stamp.getTime() - last) / 1000 * rate) - 1; last = stamp.getTime(); }
  tokens = Math.min(capacity, tokens + (now - last) / 1000 * rate);
  if (tokens < 1) return Math.ceil((1 - tokens) / rate);
  stamps.push(new Date(now));
  await db.authRateBucket.upsert({ where: { key }, create: { key, stamps }, update: { stamps, updatedAt: new Date(now) } });
  return 0;
}
