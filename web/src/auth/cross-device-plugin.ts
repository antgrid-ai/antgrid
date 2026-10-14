// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { createAuthEndpoint } from "@better-auth/core/api";
import { APIError } from "better-auth/api";
import { setSessionCookie } from "better-auth/cookies";
import { z } from "zod";
import { PENDING_TTL_SECONDS, createPending, generateBrowserToken, generateNonce,
  findByIdWithHashes, checkNonce } from "../models/pending-sign-in.js";
import type { PrismaClient } from "../generated/prisma/client.js";
import type { SendEmail } from "./email.js";
import type { BetterAuthPlugin } from "better-auth";
import { provisionProductAccountForUser } from "../models/subscription.js";
import { purgeUnprovenPasswordCredential } from "../models/credential.js";
import { authScope, authTransaction, lockAuthAccount } from "./transaction.js";
import { classifyJourney, createFlow, linkFlowUser, recordStage } from "./flows.js";
import { FlowResultSchema, requestOrigin, safeReturnPath } from "./contracts.js";
import { authEmail } from "./templates.js";
import { pruneBrowserBindings } from "./browser-bindings.js";

export type CrossDevicePluginOptions = { db: PrismaClient; sendEmail: SendEmail; baseURL: string };
export const COOKIE_BROWSER_TOKEN = "antgrid.cross_device_token";
export const bindingCookie = (id: string) => `${COOKIE_BROWSER_TOKEN}.${id}`;
export const ERR_ALREADY_APPROVED = "ALREADY_APPROVED";
const idQuery = z.object({ id: z.uuid().optional() });

export const crossDeviceMagicLink = (opts: CrossDevicePluginOptions) => ({
  id: "cross-device-magic-link" as const,
  endpoints: {
    crossDeviceStart: createAuthEndpoint("/sign-in/cross-device/start", {
      method: "POST", requireHeaders: true,
      body: z.object({ email: z.email(), previousId: z.uuid().optional(), returnPath: z.string().optional() }),
    }, async (ctx) => authTransaction(opts.db, async () => {
      const email = ctx.body.email.trim().toLowerCase();
      const hdr = ctx.headers ?? ctx.request?.headers ?? null;
      let journeyId: string | undefined;
      if (ctx.body.previousId) {
        const previous = await findByIdWithHashes(opts.db, ctx.body.previousId);
        const binding = ctx.getCookie(bindingCookie(ctx.body.previousId));
        if (previous && binding && previous.email === email &&
          checkNonce(previous.browserTokenHash, binding, ctx.context.secret)) journeyId = previous.journeyId ?? undefined;
      }
      const flow = await createFlow(opts.db, requestOrigin(hdr, "magic_link"), PENDING_TTL_SECONDS, journeyId);
      const nonce = generateNonce();
      const browserToken = generateBrowserToken();
      const row = await createPending(opts.db, {
        id: flow.id, journeyId: flow.journeyId, returnPath: safeReturnPath(ctx.body.returnPath),
        email, nonce, browserToken, secret: ctx.context.secret,
        requesterUa: hdr?.get("user-agent")?.slice(0, 512) ?? null, requesterIp: hdr?.get("x-forwarded-for")?.split(",").at(-1)?.trim() || null,
      });
      const cookieOptions = { httpOnly: true, sameSite: "lax" as const,
        secure: opts.baseURL.startsWith("https://"), path: "/", maxAge: PENDING_TTL_SECONDS };
      await pruneBrowserBindings(opts.db, ctx.context.secret, hdr, (name) => ctx.getCookie(name),
        (name, value, maxAge) => ctx.setCookie(name, value, { ...cookieOptions, maxAge }),
        { id: flow.id, kind: "cross_device", expiresAt: flow.expiresAt, value: browserToken });
      ctx.setCookie(bindingCookie(row.id), browserToken, cookieOptions);
      // Released native clients read this exact cookie name and send the
      // flow id inside its value. Modern clients retain independent cookies;
      // the alias still authenticates only the one flow named in its value.
      ctx.setCookie(COOKIE_BROWSER_TOKEN, `${row.id}.${browserToken}`, cookieOptions);
      const url = new URL("/login/approve", opts.baseURL);
      url.searchParams.set("id", row.id); url.searchParams.set("t", nonce);
      await opts.sendEmail({ to: email, ...authEmail({ action: "Review sign-in request", url: url.toString(),
        description: "A sign-in was requested for this email address. Continue only if you started it.",
        device: `${row.requesterUa ?? "Unknown device"} (${row.requesterIp ?? "IP hidden"})`, createdAt: row.createdAt, expiresAt: row.expiresAt }),
        clientReference: row.id, expiresAt: row.expiresAt });
      await recordStage(opts.db, flow.id, "mail_queued");
      return ctx.json(FlowResultSchema.parse({ id: row.id, journeyId: flow.journeyId, status: "pending",
        serverTime: new Date().toISOString(), expiresAt: row.expiresAt.toISOString(),
        retryAt: new Date(row.createdAt.getTime() + 45000).toISOString(), delivery: "queued" }));
    })),
    crossDeviceApprove: createAuthEndpoint("/sign-in/cross-device/approve", {
      method: "POST", body: z.object({ id: z.uuid(), token: z.string().min(1).max(128) }),
    }, async (ctx) => authTransaction(opts.db, async () => {
      const requested = await findByIdWithHashes(opts.db, ctx.body.id);
      if (requested) await lockAuthAccount(opts.db, requested.email);
      await opts.db.$queryRaw`SELECT id FROM pending_sign_in WHERE id=${ctx.body.id}::uuid FOR UPDATE`;
      const row = await findByIdWithHashes(opts.db, ctx.body.id);
      if (!row || !checkNonce(row.nonceHash, ctx.body.token, ctx.context.secret)) throw new APIError("BAD_REQUEST", { message: "INVALID" });
      if (row.approvedAt) throw new APIError("BAD_REQUEST", { message: ERR_ALREADY_APPROVED });
      authScope.getStore()!.flowId = row.id;
      await lockAuthAccount(opts.db, row.email);
      let user = (await ctx.context.internalAdapter.findUserByEmail(row.email))?.user;
      await recordStage(opts.db, row.id, "approval_submitted");
      await opts.db.authFlow.update({ where: { id: row.id }, data: { approvalOrigin: requestOrigin(ctx.headers ?? null, "approval") } });
      if (user) await classifyJourney(opts.db, user.id, user.emailVerified);
      if (!user) user = await ctx.context.internalAdapter.createUser({ email: row.email, emailVerified: true, name: row.email });
      if (!user.emailVerified) {
        await purgeUnprovenPasswordCredential(opts.db, user.id);
        user = await ctx.context.internalAdapter.updateUser(user.id, { emailVerified: true });
      }
      await linkFlowUser(opts.db, user.id, "ownership_verified");
      await provisionProductAccountForUser(opts.db, user.id);
      await opts.db.pendingSignIn.update({ where: { id: row.id }, data: { approvedAt: new Date(), approvedUserId: user.id } });
      return ctx.json({ ok: true });
    })),
    crossDeviceStatus: createAuthEndpoint("/sign-in/cross-device/status", {
      method: "GET", requireHeaders: true, query: idQuery,
    }, async (ctx) => authTransaction(opts.db, async () => {
      // A legacy binding is accepted only when it names the requested flow.
      const legacy = ctx.getCookie(COOKIE_BROWSER_TOKEN);
      const id = ctx.query.id ?? legacy?.split(".")[0];
      if (!id || !z.uuid().safeParse(id).success) {
        if (legacy) ctx.setCookie(COOKIE_BROWSER_TOKEN, "", { maxAge: 0, path: "/" });
        return ctx.json({ status: "unbound" });
      }
      const binding = ctx.getCookie(bindingCookie(id)) ?? (legacy?.startsWith(id + ".") ? legacy.slice(id.length + 1) : null);
      if (!binding) return ctx.json({ status: "unbound" });
      const requested = await findByIdWithHashes(opts.db, id);
      if (requested) await lockAuthAccount(opts.db, requested.email);
      await opts.db.$queryRaw`SELECT id FROM pending_sign_in WHERE id=${id}::uuid FOR UPDATE`;
      const row = await findByIdWithHashes(opts.db, id);
      if (!row || !checkNonce(row.browserTokenHash, binding, ctx.context.secret)) {
        ctx.setCookie(bindingCookie(id), "", { maxAge: 0, path: "/" });
        if (legacy?.startsWith(id + ".")) ctx.setCookie(COOKIE_BROWSER_TOKEN, "", { maxAge: 0, path: "/" });
        return ctx.json({ status: "expired" });
      }
      const delivery = await opts.db.emailJob.findFirst({ where: { flowId: id }, orderBy: { createdAt: "desc" }, select: { state: true } });
      const result = (status: string) => ctx.json({ id, journeyId: row.journeyId, status,
        serverTime: new Date().toISOString(), expiresAt: row.expiresAt.toISOString(),
        retryAt: new Date(row.createdAt.getTime() + 45000).toISOString(), delivery: row.deliveryStatus ?? delivery?.state ?? null });
      if (!row.approvedAt || !row.approvedUserId) return result("pending");
      await lockAuthAccount(opts.db, row.email);
      await opts.db.$queryRaw`SELECT id FROM "user" WHERE id=${row.approvedUserId} FOR UPDATE`;
      const user = await opts.db.user.findUnique({ where: { id: row.approvedUserId } });
      if (!user || !user.emailVerified) return result("expired");
      authScope.getStore()!.flowId = id;
      let session;
      if (row.consumedAt) {
        if (!row.issuedSessionId) return result("consumed");
        session = await opts.db.session.findUnique({ where: { id: row.issuedSessionId } });
        if (!session || session.expiresAt <= new Date()) return result("consumed");
      } else {
        session = await ctx.context.internalAdapter.createSession(user.id);
        if (!session) return result("expired");
        await opts.db.pendingSignIn.update({ where: { id }, data: { consumedAt: new Date(), issuedSessionId: session.id } });
        await opts.db.authFlow.updateMany({ where: { id }, data: { state: "redeemed", sessionId: session.id } });
        await recordStage(opts.db, id, "session_issued");
      }
      await setSessionCookie(ctx as unknown as Parameters<typeof setSessionCookie>[0], { session, user });
      return result("ready");
    })),
  },
} satisfies BetterAuthPlugin);
