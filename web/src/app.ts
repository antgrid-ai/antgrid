import { Hono } from "hono";
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import { secureHeaders } from "hono/secure-headers";
import { serveStatic } from "hono/bun";
import { health } from "./routes/health.js";
import { deviceRoutes } from "./routes/devices.js";
import { agentRoutes } from "./routes/agents.js";
import { subscriptionRoutes } from "./routes/subscriptions.js";
import { billingRoutes } from "./routes/billing.js";
import { webhookRoutes } from "./routes/webhooks.js";
import { emailWebhookRoutes } from "./routes/email-webhooks.js";
import { devBillingRoutes } from "./routes/dev-billing.js";
import { oauthHandoffRoutes } from "./routes/oauth-handoff.js";
import { oauthStartRoutes } from "./routes/oauth-start.js";
import { eventsRoutes } from "./routes/events.js";
import { waitlistRoutes } from "./routes/waitlist.js";
import { uiRoutes } from "./routes/ui.js";
import { setPublicOrigin } from "./ui/origin.js";
import type { DB } from "./db/index.js";
import type { Auth } from "./auth/better-auth.js";
import type { Env } from "./env.js";
import type { RelayPushConfig } from "./relay/push.js";
import type { SendEmail } from "./auth/email.js";
import { makeClientIpResolver } from "./util/client-ip.js";

export type AppDeps = {
  db: DB;
  auth: Auth;
  env: Env;
  corsOrigins: string[];
  relay: RelayPushConfig;
  /** Also handed to Better-Auth by the caller. The UI router needs its own
   *  reference: invite mail is sent from a plain Hono handler, which has no
   *  `auth.api.*` endpoint behind it to borrow the sender from. */
  sendEmail: SendEmail;
};

export function buildApp(deps: AppDeps) {
  const app = new Hono();
  const clientIp = makeClientIpResolver(deps.env.TRUSTED_PROXY_IPS);
  // Layout renders og:image, which a scraper fetches with no page to resolve a
  // relative URL against. This is the one place that knows the public origin.
  setPublicOrigin(deps.env.BETTER_AUTH_URL);

  // The ZeptoMail webhook authenticates via a secret in its URL path
  // (/webhooks/zeptomail/:key). Hono's logger prints the full path, so redact
  // that segment before it reaches stdout/any log sink — keep the line for
  // status/timing, drop the secret. Other webhooks sign via a header and are
  // unaffected.
  app.use(
    "*",
    logger((message: string, ...rest: string[]) => {
      console.log(
        message.replace(/(\/webhooks\/zeptomail\/)\S+/, "$1<redacted>"),
        ...rest
      );
    })
  );

  app.use(
    "*",
    secureHeaders({
      xFrameOptions: "DENY",
      crossOriginOpenerPolicy: "same-origin-allow-popups",
      contentSecurityPolicy: { frameAncestors: ["'none'"] },
    })
  );

  app.use(
    "*",
    cors({
      origin: (origin) => (deps.corsOrigins.includes(origin) ? origin : null),
      credentials: true,
      allowHeaders: ["content-type", "authorization"],
      allowMethods: ["GET", "POST", "DELETE", "OPTIONS"],
      // Without this the fetch spec caches a preflight for 5 seconds, so every
      // retry on a cross-origin JSON POST (the marketing site's waitlist form)
      // pays a second round trip before the one that carries the body.
      maxAge: 86400,
    })
  );

  // Every `/build/*` URL is content-hashed (emitted via the Vite
  // manifest by `asset()`), so caching is unconditionally immutable.
  app.use("/build/*", async (c, next) => {
    await next();
    if (c.res.ok) {
      c.header("Cache-Control", "public, max-age=31536000, immutable");
    }
  });
  app.use("/build/*", serveStatic({ root: "./public" }));

  // Brand/logo assets (favicons, app icons). Served from public/logo at the
  // /logo/* path — referenced by the favicon <link> tags in ui/layout.tsx.
  app.use("/logo/*", serveStatic({ root: "./public" }));

  // The social card, on its own path rather than under /logo: a link-preview
  // scraper is an anonymous, unauthenticated fetch, and this is the only asset
  // here meant for one.
  app.use("/og/*", serveStatic({ root: "./public" }));

  // Better-Auth gets the request with X-Forwarded-For already collapsed to the
  // resolved client, so its handlers (the cross-device plugin's requester IP,
  // its own IP-keyed rate buckets) see the same spoof-safe value the /ui routes
  // do. These endpoints are reachable over HTTP as well as via `auth.api.*`, so
  // without this the raw client-supplied chain would reach them untouched. No
  // peer address (no socket) means nothing here is trustworthy — drop it.
  app.all("/api/auth/*", (c) => {
    const headers = new Headers(c.req.raw.headers);
    const ip = clientIp(c);
    if (ip) headers.set("x-forwarded-for", ip);
    else headers.delete("x-forwarded-for");
    return deps.auth.handler(new Request(c.req.raw, { headers }));
  });
  app.route("/", health);
  app.route("/", eventsRoutes({ db: deps.db, clientIp }));
  app.route("/", waitlistRoutes({ db: deps.db, clientIp }));
  app.route("/", deviceRoutes({ db: deps.db, auth: deps.auth, relay: deps.relay }));
  app.route("/", agentRoutes({ db: deps.db, auth: deps.auth, env: deps.env }));
  app.route("/", subscriptionRoutes({ db: deps.db, auth: deps.auth }));
  app.route("/", billingRoutes({ db: deps.db, auth: deps.auth, env: deps.env, relay: deps.relay, clientIp }));
  app.route(
    "/",
    webhookRoutes({
      db: deps.db,
      relay: deps.relay,
      paddleWebhookSecret: deps.env.PADDLE_WEBHOOK_SECRET,
      razorpayWebhookSecret: deps.env.RAZORPAY_WEBHOOK_SECRET,
    })
  );
  app.route("/", emailWebhookRoutes({ db: deps.db, webhookSecret: deps.env.ZEPTOMAIL_WEBHOOK_SECRET }));
  // Dev-only subscription control. Double-gated: the explicit opt-in flag is
  // ignored unless we're also off production, so the route cannot exist on a
  // live deployment even if DEV_BILLING_ENABLED leaks into its env.
  if (deps.env.NODE_ENV !== "production" && deps.env.DEV_BILLING_ENABLED === true) {
    console.warn(
      "[server] DEV billing endpoints ENABLED (POST /dev/billing/subscription, POST /dev/billing/contract, POST /dev/billing/member) — never enable in production"
    );
    app.route("/", devBillingRoutes({ db: deps.db }));
  }

  app.route("/", oauthHandoffRoutes({ auth: deps.auth }));
  app.route("/", oauthStartRoutes({ auth: deps.auth }));
  app.route("/", uiRoutes({
    db: deps.db,
    auth: deps.auth,
    env: deps.env,
    relay: deps.relay,
    clientIp,
    sendEmail: deps.sendEmail,
  }));

  // Last-resort logger for anything thrown past a route handler — without this,
  // Hono's logger() only prints the status line and the exception is lost.
  // Routes that catch-and-return (e.g. billing's typed errors) bypass this;
  // they log at their own catch site.
  app.onError((err, c) => {
    console.error(`[server] unhandled error ${c.req.method} ${c.req.path}`, err);
    // Browser-navigable routes (e.g. /oauth/start) get a readable page, not raw
    // JSON; API clients get JSON. Negotiate on Accept.
    if (c.req.header("accept")?.includes("text/html")) {
      return c.text("Something went wrong. Please try again.", 500);
    }
    return c.json({ error: "INTERNAL" }, 500);
  });

  return app;
}
