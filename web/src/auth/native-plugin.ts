// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { createAuthEndpoint } from "@better-auth/core/api";
import { APIError } from "better-auth/api";
import { setSessionCookie } from "better-auth/cookies";
import type { BetterAuthPlugin } from "better-auth";
import { z } from "zod";
import type { DB } from "../db/index.js";
import { createFlow, recordStage } from "./flows.js";
import { requestOrigin } from "./contracts.js";
import { authScope, authTransaction, lockAuthAccount } from "./transaction.js";

export const digest = (s: string) => createHash("sha256").update(s).digest();
export const matches = (hash: Uint8Array | null, s: string) => !!hash && hash.length === 32 && timingSafeEqual(hash, digest(s));
export const nativeCookie = (id: string) => `antgrid.native.${id}`;
export const nativeAuth = (db: DB, baseURL: string) => ({
  id: "native-handoff",
  endpoints: {
    nativeStart: createAuthEndpoint("/sign-in/native/start", { method: "POST", requireHeaders: true,
      body: z.object({ provider: z.enum(["github", "google", "apple"]), challenge: z.string().regex(/^[A-Za-z0-9_-]{43}$/) }),
    }, async (ctx) => authTransaction(db, async () => {
      const flow = await createFlow(db, requestOrigin(ctx.headers ?? null, ctx.body.provider), 600);
      const launch = randomBytes(32).toString("base64url");
      await db.authFlow.update({ where: { id: flow.id }, data: { challenge: ctx.body.challenge, launchHash: digest(launch) } });
      const url = new URL("/oauth/start", baseURL);
      url.searchParams.set("provider", ctx.body.provider); url.searchParams.set("flow", flow.id); url.searchParams.set("launch", launch);
      return ctx.json({ id: flow.id, journeyId: flow.journeyId, url: url.toString(), expiresAt: flow.expiresAt.toISOString(), serverTime: new Date().toISOString() });
    })),
    nativeComplete: createAuthEndpoint("/sign-in/native/complete", { method: "POST", requireHeaders: true,
      body: z.object({ id: z.uuid() }),
    }, async (ctx) => authTransaction(db, async () => {
      const requested = await db.authFlow.findUnique({ where: { id: ctx.body.id } });
      const ownerSession = requested?.sessionId ? await db.session.findUnique({ where: { id: requested.sessionId }, include: { user: true } }) : null;
      if (ownerSession) await lockAuthAccount(db, ownerSession.user.email);
      await db.$queryRaw`SELECT id FROM auth_flows WHERE id=${ctx.body.id}::uuid FOR UPDATE`;
      const flow = await db.authFlow.findUnique({ where: { id: ctx.body.id } });
      const binding = ctx.getCookie(nativeCookie(ctx.body.id));
      if (!flow || flow.expiresAt <= new Date() || flow.state !== "pending" || !binding || !matches(flow.bindingHash, binding)) throw new APIError("BAD_REQUEST");
      const session = await ctx.context.internalAdapter.findSession(ctx.getSignedCookie
        ? await ctx.getSignedCookie(ctx.context.authCookies.sessionToken.name, ctx.context.secret) || "" : "");
      if (!session || flow.sessionId !== session.session.id || session.session.expiresAt <= new Date()) throw new APIError("UNAUTHORIZED");
      const code = randomBytes(32).toString("base64url");
      await db.authFlow.update({ where: { id: flow.id }, data: { state: "handoff", sessionId: session.session.id,
        codeHash: digest(code), expiresAt: new Date(Math.min(flow.expiresAt.getTime(), Date.now() + 180000)) } });
      return ctx.json({ code });
    })),
    nativeRedeem: createAuthEndpoint("/sign-in/native/redeem", { method: "POST",
      body: z.object({ id: z.uuid(), code: z.string().regex(/^[A-Za-z0-9_-]{43}$/), verifier: z.string().regex(/^[A-Za-z0-9_-]{43,128}$/) }),
    }, async (ctx) => authTransaction(db, async () => {
      const requested = await db.authFlow.findUnique({ where: { id: ctx.body.id } });
      const ownerSession = requested?.sessionId ? await db.session.findUnique({ where: { id: requested.sessionId }, include: { user: true } }) : null;
      if (ownerSession) await lockAuthAccount(db, ownerSession.user.email);
      await db.$queryRaw`SELECT id FROM auth_flows WHERE id=${ctx.body.id}::uuid FOR UPDATE`;
      const flow = await db.authFlow.findUnique({ where: { id: ctx.body.id } });
      const challenge = digest(ctx.body.verifier).toString("base64url");
      if (!flow || flow.expiresAt <= new Date() || !["handoff", "redeemed"].includes(flow.state) ||
        !flow.challenge || !matches(digest(flow.challenge), challenge) || !matches(flow.codeHash, ctx.body.code) || !flow.sessionId) throw new APIError("BAD_REQUEST");
      const session = await db.session.findUnique({ where: { id: flow.sessionId }, include: { user: true } });
      if (!session || session.expiresAt <= new Date()) throw new APIError("UNAUTHORIZED");
      authScope.getStore()!.flowId = flow.id;
      await db.authFlow.update({ where: { id: flow.id }, data: { state: "redeemed", consumedAt: flow.consumedAt ?? new Date() } });
      await recordStage(db, flow.id, "session_issued");
      await setSessionCookie(ctx as unknown as Parameters<typeof setSessionCookie>[0], { session, user: session.user });
      return ctx.json({ ok: true });
    })),
  },
} satisfies BetterAuthPlugin);
