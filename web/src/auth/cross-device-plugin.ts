import { createAuthEndpoint } from "@better-auth/core/api";
import { APIError } from "better-auth/api";
import { setSessionCookie } from "better-auth/cookies";
import { z } from "zod";
import {
  PENDING_TTL_SECONDS,
  createPending,
  generateBrowserToken,
  generateNonce,
  findByIdWithHashes,
  checkNonce,
  markApproved,
  markConsumed,
} from "../models/pending-sign-in.js";
import type { PrismaClient } from "../generated/prisma/client.js";
import type { SendEmail } from "./email.js";
import type { BetterAuthPlugin } from "better-auth";
import { provisionProductAccountForUser } from "../models/subscription.js";

export type CrossDevicePluginOptions = {
  db: PrismaClient;
  sendEmail: SendEmail;
  baseURL: string;
};

const startBody = z.object({
  email: z.email(),
});

/**
 * Cookie set on Browser A at /sign-in/cross-device/start. Carries the pending
 * row id and the browser-binding token so /sign-in/cross-device/status (Task 5)
 * can prove the poller is the same browser that initiated the flow. Format:
 *   "<row.id>.<browserToken>"
 * httpOnly + sameSite=lax. Expires when the row does (10 min).
 */
export const COOKIE_BROWSER_TOKEN = "antgrid.cross_device_token";

/**
 * Rejection message for an approve that lands on an already-approved row. This
 * is the one approve failure that means the work succeeded — a re-submitted
 * form or a re-opened link — so callers key off it to report success. Import it
 * rather than re-typing the literal; a silent rename here would otherwise
 * downgrade those callers back to a generic error (see routes/ui.tsx).
 */
export const ERR_ALREADY_APPROVED = "ALREADY_APPROVED";

export const crossDeviceMagicLink = (opts: CrossDevicePluginOptions) => {
  return {
    id: "cross-device-magic-link" as const,
    endpoints: {
      crossDeviceStart: createAuthEndpoint(
        "/sign-in/cross-device/start",
        { method: "POST", body: startBody, requireHeaders: true },
        async (ctx) => {
          const email = ctx.body.email.toLowerCase();
          const nonce = generateNonce();
          const browserToken = generateBrowserToken();
          // Read from ctx.headers, NOT ctx.request: this endpoint is always
          // invoked via auth.api.crossDeviceStart() (server-to-server from the
          // /ui/login/start Hono route), where Better-Auth populates ctx.headers
          // from the passed `headers` but leaves ctx.request undefined. Reading
          // ctx.request silently dropped UA + IP in every environment.
          const hdr = ctx.headers ?? ctx.request?.headers ?? null;
          const rawUa = hdr?.get("user-agent")?.trim() || null;
          const ua = rawUa ? rawUa.slice(0, 512) : null;
          const ip =
            hdr?.get("x-forwarded-for")?.split(",")[0]?.trim() ||
            hdr?.get("x-real-ip")?.trim() ||
            null;

          const row = await createPending(opts.db, {
            email,
            nonce,
            browserToken,
            secret: ctx.context.secret,
            requesterUa: ua,
            requesterIp: ip,
          });

          ctx.setCookie(COOKIE_BROWSER_TOKEN, `${row.id}.${browserToken}`, {
            httpOnly: true,
            sameSite: "lax",
            secure: opts.baseURL.startsWith("https://"),
            path: "/",
            maxAge: PENDING_TTL_SECONDS,
          });

          const approveUrl = new URL(
            `/login/approve?id=${row.id}&t=${nonce}`,
            opts.baseURL
          ).toString();

          await opts.sendEmail({
            to: email,
            subject: "Approve sign-in to Antgrid",
            text:
              `Approve sign-in: ${approveUrl}\n\n` +
              `Requested from: ${ua ?? "unknown"} (${ip ?? "ip hidden"}).\n` +
              `Link expires in 10 minutes. If you did not request this, ignore this email.`,
            clientReference: row.id,
          });

          return ctx.json({ id: row.id });
        }
      ),
      crossDeviceApprove: createAuthEndpoint(
        "/sign-in/cross-device/approve",
        {
          method: "POST",
          body: z.object({
            id: z.string().uuid(),
            token: z.string().min(1),
          }),
        },
        async (ctx) => {
          const row = await findByIdWithHashes(opts.db, ctx.body.id);
          if (!row) throw new APIError("BAD_REQUEST", { message: "INVALID" });
          if (row.expiresAt < new Date())
            throw new APIError("BAD_REQUEST", { message: "EXPIRED" });
          if (!checkNonce(row.nonceHash, ctx.body.token, ctx.context.secret))
            throw new APIError("BAD_REQUEST", { message: "INVALID" });
          // After the nonce, never before: this reply tells approved apart from
          // pending, and the row id alone must not buy that. The id travels in
          // the emailed URL and survives in history, logs and referrers; the
          // nonce is what proves the caller actually holds the link.
          if (row.approvedAt)
            throw new APIError("BAD_REQUEST", { message: ERR_ALREADY_APPROVED });

          // Find or create the user (signup-on-approve, like the original magic-link plugin).
          let user = (await ctx.context.internalAdapter.findUserByEmail(row.email))?.user;
          if (!user) {
            user = await ctx.context.internalAdapter.createUser({
              email: row.email,
              emailVerified: true,
              name: row.email,
            });
          }

          await provisionProductAccountForUser(opts.db, user.id);
          if (!user.emailVerified) {
            user = await ctx.context.internalAdapter.updateUser(user.id, {
              emailVerified: true,
            });
          }

          await markApproved(opts.db, row.id, user.id);
          return ctx.json({ ok: true });
        }
      ),
      crossDeviceStatus: createAuthEndpoint(
        "/sign-in/cross-device/status",
        { method: "GET", requireHeaders: true },
        async (ctx) => {
          const cookie = ctx.getCookie(COOKIE_BROWSER_TOKEN);
          if (!cookie) return ctx.json({ status: "unbound" });
          const dot = cookie.indexOf(".");
          if (dot < 0) return ctx.json({ status: "unbound" });
          const id = cookie.slice(0, dot);
          const browserToken = cookie.slice(dot + 1);

          const row = await findByIdWithHashes(opts.db, id);
          if (!row) return ctx.json({ status: "expired" });
          if (!checkNonce(row.browserTokenHash, browserToken, ctx.context.secret))
            return ctx.json({ status: "expired" });
          if (row.consumedAt) return ctx.json({ status: "consumed" });
          if (!row.approvedAt || !row.approvedUserId)
            return ctx.json({ status: "pending", delivery: row.deliveryStatus ?? null });

          // Approved + not yet consumed → mint session, set cookie, mark consumed.
          const user = (await ctx.context.internalAdapter.findUserByEmail(row.email))?.user;
          if (!user) return ctx.json({ status: "expired" });
          // NOTE: internalAdapter.createSession signature is
          //   (userId, dontRememberMe?, override?, overrideAll?)
          // — the docs snippet's `(userId, ctx)` shape is stale.
          const session = await ctx.context.internalAdapter.createSession(user.id);
          if (!session) return ctx.json({ status: "expired" });
          // Cast: `@better-auth/core/api`'s EndpointContext and
          // `better-auth/cookies`'s GenericEndpointContext have drifted
          // (the former lacks `hasPlugin`). Runtime shape is identical;
          // every first-party Better-Auth endpoint passes its own ctx here.
          await setSessionCookie(
            ctx as unknown as Parameters<typeof setSessionCookie>[0],
            { session, user }
          );
          await markConsumed(opts.db, row.id);
          // Clear the pending cookie — it has served its purpose.
          ctx.setCookie(COOKIE_BROWSER_TOKEN, "", { maxAge: 0, path: "/" });
          return ctx.json({ status: "ready" });
        }
      ),
    },
  } satisfies BetterAuthPlugin;
};
