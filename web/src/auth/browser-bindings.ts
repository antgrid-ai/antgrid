// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { createHash, createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import { z } from "zod";
import type { DB } from "../db/index.js";
import { hmacMatches } from "../util/hmac.js";
import { authTransaction, scopedAuthDb } from "./transaction.js";

export const BROWSER_ID_COOKIE = "antgrid.auth_browser";
const kinds = ["cross_device", "request", "native"] as const;
type BindingKind = typeof kinds[number];
const prefixes: Record<BindingKind, string> = {
  cross_device: "antgrid.cross_device_token.", request: "antgrid.request_flow.", native: "antgrid.native.",
};
const hash = (value: string) => createHash("sha256").update(value).digest();
const hashMatches = (stored: Uint8Array | null, value: string) => !!stored && stored.length === 32 && timingSafeEqual(stored, hash(value));
type Binding = { id: string; kind: BindingKind; expiresAt: Date; value: string };

// The inventory includes responses the browser has not received yet. Cookie
// counting alone cannot bound concurrent starts using the same cookie snapshot.
export async function pruneBrowserBindings(database: DB, secret: string, headers: Headers | null,
  cookie: (name: string) => string | null | undefined, setCookie: (name: string, value: string, maxAge: number) => void,
  incoming: Binding) {
  const db = scopedAuthDb(database);
  await authTransaction(db, async () => {
    const supplied = cookie(BROWSER_ID_COOKIE);
    const browser = supplied && /^[A-Za-z0-9_-]{43}$/.test(supplied) ? supplied : randomBytes(32).toString("base64url");
    const owner = createHmac("sha256", secret).update("auth-browser:" + browser).digest("hex");
    const registryPrefix = "auth-browser-binding:" + owner + ":";
    await db.$executeRaw`SELECT pg_advisory_xact_lock(hashtextextended(${registryPrefix}, 714))`;
    const names = [...new Set((headers?.get("cookie") ?? "").split(";").map((part) => part.trim().split("=")[0]))];
    const entries = new Map<string, { id: string; kind: BindingKind; expiresAt: Date; createdAt: Date }>();
    const remove = async (id: string, kind: BindingKind) => {
      // Preserve the emailed ownership proof and valid sessions when evicting
      // the initiating browser's binding.
      if (kind === "cross_device") await db.pendingSignIn.updateMany({ where: { id }, data: { browserTokenHash: randomBytes(32) } });
      await db.authFlow.updateMany({ where: { id }, data: { bindingHash: null } });
      await db.authRateBucket.deleteMany({ where: { key: registryPrefix + kind + ":" + id } });
      setCookie(prefixes[kind] + id, "", 0);
    };
    for (const registered of await db.authRateBucket.findMany({ where: { key: { startsWith: registryPrefix } } })) {
      const [rawKind, id] = registered.key.slice(registryPrefix.length).split(":");
      const kind = kinds.find((value) => value === rawKind);
      const flow = kind && z.uuid().safeParse(id).success ? await db.authFlow.findUnique({ where: { id } }) : null;
      if (!kind || !flow || flow.expiresAt <= new Date() || !flow.bindingHash) {
        await db.authRateBucket.delete({ where: { key: registered.key } });
        if (kind && id) setCookie(prefixes[kind] + id, "", 0);
        continue;
      }
      entries.set(kind + ":" + id, { id, kind, expiresAt: flow.expiresAt, createdAt: flow.createdAt });
    }
    // Adopt valid bindings issued before the inventory rollout, and clear
    // expired or forged cookies rather than charging them against the budget.
    for (const name of names) {
      const kind = kinds.find((value) => name.startsWith(prefixes[value]));
      if (!kind) continue;
      const id = name.slice(prefixes[kind].length);
      const flow = z.uuid().safeParse(id).success ? await db.authFlow.findUnique({ where: { id } }) : null;
      const value = cookie(name);
      const pending = kind === "cross_device" && flow ? await db.pendingSignIn.findUnique({ where: { id } }) : null;
      const valid = flow && flow.expiresAt > new Date() && value && (kind === "cross_device"
        ? pending && pending.expiresAt > new Date() && hmacMatches(pending.browserTokenHash, value, secret)
        : hashMatches(flow.bindingHash, value));
      if (!valid) { setCookie(name, "", 0); continue; }
      if (kind === "cross_device" && !flow.bindingHash) await db.authFlow.update({ where: { id }, data: { bindingHash: hash(value) } });
      entries.set(kind + ":" + id, { id, kind, expiresAt: flow.expiresAt, createdAt: flow.createdAt });
    }
    // Register before eviction so every simultaneous request sees all earlier
    // accepted attempts, even when their cookies are absent from its snapshot.
    await db.authFlow.update({ where: { id: incoming.id }, data: { bindingHash: hash(incoming.value) } });
    const newest = await db.authFlow.findUniqueOrThrow({ where: { id: incoming.id } });
    entries.set(incoming.kind + ":" + incoming.id, { ...incoming, createdAt: newest.createdAt });
    const active = [...entries.values()].sort((a, b) => a.createdAt.getTime() - b.createdAt.getTime() || a.id.localeCompare(b.id));
    // Always retain the attempt this response is establishing.
    const old = active.filter((entry) => entry.id !== incoming.id);
    for (const entry of old.slice(0, Math.max(0, active.length - 5))) {
      await remove(entry.id, entry.kind);
      entries.delete(entry.kind + ":" + entry.id);
    }
    for (const entry of entries.values()) {
      const key = registryPrefix + entry.kind + ":" + entry.id;
      await db.authRateBucket.upsert({ where: { key }, create: { key, stamps: [entry.expiresAt] }, update: { stamps: [entry.expiresAt], updatedAt: new Date() } });
    }
    setCookie(BROWSER_ID_COOKIE, browser, 86400);
  });
}
