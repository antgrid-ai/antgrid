import { Hono } from "hono";
import { z } from "zod";
import { isAPIError } from "better-auth/api";
import type { DB } from "../db/index.js";
import type { Auth } from "../auth/better-auth.js";
import type { Env } from "../env.js";
import type { RelayPushConfig } from "../relay/push.js";
import { findByIdWithHashes, checkNonce } from "../models/pending-sign-in.js";
import { ERR_ALREADY_APPROVED } from "../auth/cross-device-plugin.js";
import { ApproveSignInPage } from "../ui/approve-sign-in.js";
import { ApprovedPage } from "../ui/approved.js";
import {
  requireUser,
  requireUserOrRedirect,
  type AuthVars,
} from "../auth/middleware.js";
import { listActiveDevices } from "../models/device.js";
import {
  activeSubscriptionForUser,
  isPendingCancellation,
  provisionProductAccountForUser,
  resolveEntitlement,
} from "../models/subscription.js";
import { revokeUserDevice } from "../services/device.js";
import { tokenBucket } from "../util/rate-limit.js";
import { LoginPage } from "../ui/login.js";
import { DashboardPage } from "../ui/dashboard.js";
import { DevicesPage } from "../ui/devices.js";
import { PricingPage } from "../ui/pricing.js";
import { CheckoutPage, type CheckoutPlan } from "../ui/checkout.js";
import {
  anyCheckoutReady,
  checkoutReadiness,
} from "../billing/checkout.js";
import { displayPriceCents, FREE_TIER, isPlanId } from "../billing/plans.js";
// import { type PlanId } from "../billing/plans.js"; // TEMP-PROMO: restore with the /pricing currentPlanSlug block below once IAP ships.
import { listActivePlans } from "../models/plan.js";
import {
  ensureProductAccount,
  ensureProductAccountCountry,
  isBillingProviderLocked,
  lockBillingProvider,
  previewBillingProvider,
} from "../models/product-account.js";
import { clientIpFromHeaders, detectCountryFromIp } from "../billing/geo.js";
import {
  cancelRecurringSubscription,
  resumeRecurringSubscription,
} from "../billing/cancel-subscription.js";
import { PendingPage } from "../ui/pending.js";
import { ConnectionsPage } from "../ui/connections.js";
import { fetchConnections } from "../relay/push.js";
import { listUserSessions, type UserSession } from "../services/sessions.js";
import { AccountPage, AccountDeletedPage } from "../ui/account.js";
import { deleteUserAccount, hasRenewingPaidSubscription } from "../services/account.js";

// Internal relay-connections view is restricted to named operators. Gate on
// email (lowercased) — Better-Auth verifies email ownership at sign-in, so it's
// a safe identity anchor here. Non-operators get 404, not 403: don't reveal the
// route exists.
const INTERNAL_OPERATOR_EMAILS = new Set(["bharathm@radhaai.com"]);

export function uiRoutes(deps: {
  db: DB;
  auth: Auth;
  env: Env;
  relay: RelayPushConfig;
}) {
  const r = new Hono<{ Variables: AuthVars }>();
  const startLimiter = tokenBucket(5, 0.2); // 5 burst, 1 per 5s, per IP
  const approveSignInLimiter = tokenBucket(10, 0.5); // 10 burst, 1 per 2s, per IP

  function ipKey(c: import("hono").Context): string {
    return (
      c.req.header("x-forwarded-for")?.split(",")[0]?.trim() ??
      c.req.header("x-real-ip") ??
      "unknown"
    );
  }

  r.get("/", (c) => c.redirect("/dashboard"));

  // Better-Auth's POST /api/auth/sign-out returns `{success:true}` JSON, not a
  // redirect — pointing a server-rendered form at it dumps JSON in the browser.
  // Drive sign-out through the server API and forward its cookie-clearing
  // Set-Cookie onto a 302 back to the app root (which bounces to /login when
  // signed out). No-op safe: signOut clears the cookie even without a session.
  r.post("/logout", async (c) => {
    const res = await deps.auth.api.signOut({
      headers: c.req.raw.headers,
      asResponse: true,
    });
    // Forward EACH Set-Cookie as its own header. signOut can clear more than
    // one cookie, and `headers.get("set-cookie")` would comma-join them — fatal
    // here because the clearing cookies carry `Expires=...GMT` (a comma the
    // browser can't disambiguate). Mirrors oauth-start.ts / the login handlers.
    for (const sc of res.headers.getSetCookie()) {
      c.header("set-cookie", sc, { append: true });
    }
    return c.redirect("/");
  });

  r.get("/login", (c) => {
    const sent = c.req.query("sent") ?? null;
    const error = c.req.query("error") ?? null;
    return c.html(<LoginPage sent={sent} error={error} />);
  });

  r.post("/ui/login/start", async (c) => {
    if (!startLimiter(ipKey(c))) {
      return c.redirect("/login?error=Too%20many%20requests");
    }
    const form = await c.req.formData();
    const email = String(form.get("email") ?? "").trim();
    if (!email) return c.redirect("/login?error=Email%20required");

    const res = await deps.auth.api.crossDeviceStart({
      method: "POST",
      headers: {
        "content-type": "application/json",
        "user-agent": c.req.header("user-agent") ?? "",
        "x-forwarded-for": c.req.header("x-forwarded-for") ?? "",
        "x-real-ip": c.req.header("x-real-ip") ?? "",
        cookie: c.req.header("cookie") ?? "",
      },
      body: { email },
      asResponse: true
    });
    if (!res.ok) {
      return c.redirect(`/login?error=${encodeURIComponent("Could not send link")}`);
    }
    // Forward Set-Cookie from the plugin response to the browser.
    for (const [k, v] of res.headers) {
      if (k.toLowerCase() === "set-cookie") c.header("Set-Cookie", v, { append: true });
    }
    const { id } = (await res.json()) as { id: string };
    return c.redirect(`/login/pending/${id}?email=${encodeURIComponent(email)}`);
  });

  r.get("/login/pending/:id", (c) => {
    const id = c.req.param("id");
    const email = c.req.query("email") ?? "";
    if (!z.uuid().safeParse(id).success) return c.redirect("/login");
    return c.html(<PendingPage email={email} pendingId={id} />);
  });

  r.get("/ui/login/poll/:id", async (c) => {
    const id = c.req.param("id");
    if (!z.uuid().safeParse(id).success) return c.text("expired", 200);

    const res = await deps.auth.api.crossDeviceStatus({
      method: "GET",
      headers: { cookie: c.req.header("cookie") ?? "" },
      asResponse: true
    });
    // Forward Set-Cookie from the plugin response (status=ready sets the session cookie).
    for (const [k, v] of res.headers) {
      if (k.toLowerCase() === "set-cookie") c.header("Set-Cookie", v, { append: true });
    }
    const body = (await res.json()) as { status: string; delivery?: string | null };
    if (body.status === "ready") {
      c.header("HX-Redirect", "/dashboard");
      return c.text("");
    }
    if (body.status === "expired" || body.status === "consumed" || body.status === "unbound") {
      c.header("HX-Redirect", "/login?error=Link%20expired");
      return c.text("");
    }
    if (body.delivery === "bounced") {
      // Hard bounce: the link will never arrive, so stop polling and tell the
      // user — parity with the app's bounced screen. delivery rides the pending
      // response; ZeptoMail sends no "delivered" event, so there is no success case.
      c.header(
        "HX-Redirect",
        `/login?error=${encodeURIComponent("We couldn't deliver the link — check the address and try again")}`
      );
      return c.text("");
    }
    // pending: re-render the same fragment so polling continues.
    return c.html(
      <div
        id="poll"
        class="text-xs text-base-content/50 font-mono"
        hx-get={`/ui/login/poll/${id}`}
        hx-trigger="every 3s"
        hx-swap="outerHTML"
      >
        Waiting for approval…
      </div>
    );
  });

  r.get("/login/approve", async (c) => {
    const id = c.req.query("id") ?? "";
    const token = c.req.query("t") ?? "";
    if (!z.uuid().safeParse(id).success || !token) {
      return c.redirect("/login?error=Invalid%20link");
    }
    const row = await findByIdWithHashes(deps.db, id);
    if (!row || row.expiresAt < new Date()) {
      return c.redirect("/login?error=Link%20expired");
    }
    if (!checkNonce(row.nonceHash, token, deps.env.BETTER_AUTH_SECRET)) {
      return c.redirect("/login?error=Invalid%20link");
    }
    // Re-opening an approved link — back button, a second tap, a mail client
    // prefetching URLs — is a success the user already earned, not a reused
    // link. Kept after the nonce check so the state isn't readable from the id.
    if (row.approvedAt) {
      return c.redirect("/login/approved");
    }
    // expiresAt = createdAt + 10m. Showing expiresAt as "requested at" is
    // imprecise but acceptable for the approver UI.
    return c.html(
      <ApproveSignInPage
        email={row.email}
        requesterUa={row.requesterUa}
        requesterIp={row.requesterIp}
        requestedAt={row.expiresAt}
        pendingId={row.id}
        token={token}
      />
    );
  });

  r.post("/ui/login/approve", async (c) => {
    if (!approveSignInLimiter(ipKey(c))) {
      return c.redirect("/login?error=Too%20many%20requests");
    }
    const form = await c.req.formData();
    const id = String(form.get("id") ?? "");
    const token = String(form.get("token") ?? "");
    try {
      await deps.auth.api.crossDeviceApprove({
        method: "POST",
        headers: { "content-type": "application/json" },
        body: { id, token },
      });
    } catch (err) {
      // A double-clicked button re-POSTs the same form. The first POST already
      // approved the row, so ALREADY_APPROVED means the approval landed — report
      // success rather than an error the approver cannot act on.
      if (isAPIError(err) && err.body?.message === ERR_ALREADY_APPROVED) {
        return c.redirect("/login/approved");
      }
      // Better-Auth APIError (bad token / expired / consumed) — surface a
      // generic message so we don't reveal which condition failed.
      return c.redirect("/login?error=Could%20not%20approve");
    }
    return c.redirect("/login/approved");
  });

  r.get("/login/approved", (c) => c.html(<ApprovedPage />));

  r.post("/ui/sign-out", async (c) => {
    const origin = new URL(c.req.url).origin;
    const res = await deps.auth.api.signOut({
      method: "POST",
      headers: {
        cookie: c.req.header("cookie") ?? "",
        origin,
        "content-type": "application/json",
      },
      asResponse: true,
    });
    for (const [k, v] of res.headers) {
      if (k.toLowerCase() === "set-cookie") c.header("Set-Cookie", v, { append: true });
    }
    if (!res.ok) return c.redirect("/dashboard?error=Could%20not%20sign%20out");
    return c.redirect("/login");
  });

  r.post("/ui/subscription/cancel", requireUserOrRedirect({ auth: deps.auth }), async (c) => {
    const userId = c.get("userId");
    await provisionProductAccountForUser(deps.db, userId);
    const sub = await activeSubscriptionForUser(deps.db, userId);
    if (!sub) return c.redirect("/dashboard?cancel=failed");

    const plan = await deps.db.plan.findUnique({ where: { id: sub.planId } });
    if (!plan?.recurring || sub.status !== "active" || isPendingCancellation(sub)) {
      return c.redirect("/dashboard?cancel=failed");
    }

    try {
      const { effective } = await cancelRecurringSubscription(deps.db, deps.relay, deps.env, {
        accountId: sub.accountId,
        subscription: { ...sub, plan },
      });
      if (effective === "immediately") return c.redirect("/dashboard?cancel=immediate");
      return c.redirect("/dashboard?cancel=pending");
    } catch {
      return c.redirect("/dashboard?cancel=failed");
    }
  });

  r.post("/ui/subscription/resume", requireUserOrRedirect({ auth: deps.auth }), async (c) => {
    const userId = c.get("userId");
    await provisionProductAccountForUser(deps.db, userId);
    const sub = await activeSubscriptionForUser(deps.db, userId);
    if (!sub) return c.redirect("/dashboard?resume=failed");

    const plan = await deps.db.plan.findUnique({ where: { id: sub.planId } });
    if (!plan?.recurring || !isPendingCancellation(sub)) {
      return c.redirect("/dashboard?resume=failed");
    }

    try {
      await resumeRecurringSubscription(deps.db, deps.env, {
        subscription: { ...sub, plan },
      });
      return c.redirect("/dashboard?resume=success");
    } catch {
      return c.redirect("/dashboard?resume=failed");
    }
  });

  r.get(
    "/internal/connections",
    requireUserOrRedirect({ auth: deps.auth }),
    async (c) => {
      const email = c.get("userEmail")?.toLowerCase() ?? "";
      if (!INTERNAL_OPERATOR_EMAILS.has(email)) {
        // Record denied probes too — for a surveillance endpoint, a non-operator
        // fishing for the route is exactly what the audit trail should capture.
        console.warn(
          JSON.stringify({
            evt: "internal.connections.denied",
            userId: c.get("userId"),
            email,
            at: new Date().toISOString(),
          }),
        );
        return c.notFound();
      }

      // Audit every access: a read of the live-connection map is a surveillance
      // capability the relay can't attribute (it only authenticates "web"), so
      // operator attribution must be logged here, at the gate.
      console.info(
        JSON.stringify({
          evt: "internal.connections.access",
          userId: c.get("userId"),
          email,
          at: new Date().toISOString(),
        }),
      );

      let connections: Awaited<ReturnType<typeof fetchConnections>> | null;
      try {
        connections = await fetchConnections(deps.relay);
      } catch (e) {
        console.warn("[internal.connections] relay fetch failed", e);
        connections = null;
      }
      return c.html(
        <ConnectionsPage
          user={{ email: c.get("userEmail") }}
          connections={connections}
          now={Date.now()}
        />,
      );
    },
  );

  r.get("/upgrade", (c) => c.redirect("/pricing"));

  r.get("/pricing", requireUserOrRedirect({ auth: deps.auth }), async (c) => {
    const userId = c.get("userId");
    await provisionProductAccountForUser(deps.db, userId);
    const plans = await listActivePlans(deps.db);
    // TEMP-PROMO: every plan renders as a disabled "Coming soon" card while
    // in-app purchases aren't live — grep "TEMP-PROMO" repo-wide for every
    // related spot (backend grant logic in web/src/models/subscription.ts
    // plus the matching disabled UI in web/src/ui/pricing.tsx).
    //
    // TO RESTORE ONCE PAYMENT INTEGRATION SHIPS: delete the `const plans =`
    // line above and the `c.html(...)` call below, then uncomment the two
    // blocks below (strip the leading "// ") — this re-adds the real
    // current-plan lookup that ui/pricing.tsx's restored version expects.
    //
    // const [plans, sub] = await Promise.all([
    //   listActivePlans(deps.db),
    //   activeSubscriptionForUser(deps.db, userId),
    // ]);
    // let currentPlanSlug: PlanId | null = null;
    // if (sub && sub.tier !== FREE_TIER) {
    //   const plan = await deps.db.plan.findUnique({ where: { id: sub.planId } });
    //   if (plan && isPlanId(plan.slug)) currentPlanSlug = plan.slug;
    // }
    return c.html(
      <PricingPage user={{ email: c.get("userEmail") }} plans={plans} env={deps.env} />
      // <PricingPage
      //   user={{ email: c.get("userEmail") }}
      //   plans={plans}
      //   env={deps.env}
      //   currentPlanSlug={currentPlanSlug}
      // />
    );
  });

  r.get("/checkout", requireUserOrRedirect({ auth: deps.auth }), async (c) => {
    const rawPlanId = c.req.query("planId") ?? "trial";
    const selectedPlanId = isPlanId(rawPlanId) ? rawPlanId : "trial";

    const userId = c.get("userId");
    const { id: accountId } = await provisionProductAccountForUser(deps.db, userId);
    let account = await ensureProductAccount(deps.db, userId);
    const planRows = await listActivePlans(deps.db);
    if (planRows.length === 0) return c.redirect("/pricing");

    const detected =
      account.country ??
      (await detectCountryFromIp(clientIpFromHeaders(c.req.raw.headers), deps.env.IPINFO_TOKEN));
    if (!account.country && detected) {
      account = await ensureProductAccountCountry(deps.db, accountId, detected, "ipinfo");
    }
    const country = account.country ?? detected;
    if (!isBillingProviderLocked(account) && country) {
      await lockBillingProvider(deps.db, accountId, country);
      account = await ensureProductAccount(deps.db, userId);
    }
    const gateway = previewBillingProvider(account, country);

    const planRow = planRows.find((row) => row.slug === selectedPlanId);
    if (!planRow || !isPlanId(planRow.slug)) return c.redirect("/pricing");

    const chargePrice = displayPriceCents(selectedPlanId, deps.env);
    const plan: CheckoutPlan = {
      id: planRow.slug,
      label: planRow.label,
      recurring: planRow.recurring,
      trial: planRow.trial,
      sessionLimit: planRow.sessionLimit,
      displayPrice: chargePrice,
      chargePrice,
    };

    const readiness = checkoutReadiness(deps.env, [selectedPlanId]);
    const checkoutAvailable = anyCheckoutReady(readiness);

    return c.html(
      <CheckoutPage
        user={{ email: c.get("userEmail") }}
        plan={plan}
        detectedCountry={country}
        gateway={gateway}
        readiness={readiness}
        checkoutAvailable={checkoutAvailable}
        isDev={deps.env.NODE_ENV === "development"}
      />
    );
  });

  r.get("/devices", requireUserOrRedirect({ auth: deps.auth }), async (c) => {
    const userId = c.get("userId");
    const devices = await listActiveDevices(deps.db, userId);
    return c.html(<DevicesPage user={{ email: c.get("userEmail") }} devices={devices} />);
  });

  r.get("/dashboard", requireUserOrRedirect({ auth: deps.auth }), async (c) => {
    const userId = c.get("userId");
    await provisionProductAccountForUser(deps.db, userId);
    const [sub, devices] = await Promise.all([
      activeSubscriptionForUser(deps.db, userId),
      listActiveDevices(deps.db, userId),
    ]);
    if (!sub) return c.redirect("/login");
    // resolveEntitlement only needs sub; compute tier now so we can prefetch sessions.
    const { tier, deviceLimit, sessionLimit } = resolveEntitlement(sub);
    // Run plan lookup and sessions fetch concurrently — they're independent.
    const [plan, sessions] = await Promise.all([
      deps.db.plan.findUnique({ where: { id: sub.planId } }),
      // Free tier shows an upsell — skip the relay round-trip; null means relay unreachable.
      tier === FREE_TIER ? Promise.resolve([] as UserSession[]) : listUserSessions(deps.relay, userId, devices),
    ]);
    if (!plan) return c.redirect("/login");
    const purchaseSuccess = c.req.query("purchase") === "success";
    const cancelRaw = c.req.query("cancel");
    const resumeRaw = c.req.query("resume");
    return c.html(
      <DashboardPage
        user={{ email: c.get("userEmail") }}
        subscription={sub}
        plan={plan}
        tier={tier}
        deviceLimit={deviceLimit}
        activeDevices={devices.length}
        sessions={sessions}
        sessionLimit={sessionLimit}
        now={Date.now()}
        purchaseSuccess={purchaseSuccess}
        cancelNotice={
          cancelRaw === "immediate" || cancelRaw === "pending" || cancelRaw === "failed"
            ? cancelRaw
            : null
        }
        resumeNotice={resumeRaw === "success" || resumeRaw === "failed" ? resumeRaw : null}
      />
    );
  });

  // HTMX removes the row on success (empty body + hx-swap="outerHTML").
  r.delete("/ui/devices/:id", requireUser({ auth: deps.auth }), async (c) => {
    const userId = c.get("userId");
    const id = c.req.param("id");
    if (!z.uuid().safeParse(id).success) return c.text("not found", 404);
    // Thread request headers so deleteDeviceOAuthClient can use the session.
    // This is a session-authed HTMX route, so headers are always available.
    await revokeUserDevice(deps.db, deps.relay, deps.auth, {
      userId,
      deviceUuid: id,
      headers: c.req.raw.headers,
    });
    return c.text("");
  });

  r.get("/account", requireUserOrRedirect({ auth: deps.auth }), async (c) => {
    const userId = c.get("userId");
    await provisionProductAccountForUser(deps.db, userId);
    // Same predicate the DELETE endpoint uses — one source of truth.
    const blocked = await hasRenewingPaidSubscription(deps.db, userId);
    return c.html(<AccountPage user={{ email: c.get("userEmail") }} blockedBySubscription={blocked} />);
  });

  r.post("/ui/account/delete", requireUserOrRedirect({ auth: deps.auth }), async (c) => {
    const userId = c.get("userId");
    // Re-verify the type-to-confirm word server-side. The page disables the
    // submit button until "DELETE" is typed, but that's client-only — a direct
    // POST, autofill, or Enter-submit could otherwise trip an irreversible
    // deletion without confirmation. Must stay in lockstep with the input's
    // name= and the confirm word in account.tsx.
    const body = await c.req.parseBody();
    if (body.confirm !== "DELETE") {
      return c.redirect("/account");
    }
    const result = await deleteUserAccount(deps.db, deps.relay, deps.auth, {
      userId,
      headers: c.req.raw.headers,
    });
    if (result === "blocked_subscription") return c.redirect("/account");
    // Sessions are already deleted by the service; clear the browser cookie too.
    // Best-effort: the account is already gone, so a signOut hiccup must not turn
    // the success path into a 500 — fall through to the deleted page regardless.
    try {
      const res = await deps.auth.api.signOut({ headers: c.req.raw.headers, asResponse: true });
      for (const sc of res.headers.getSetCookie()) c.header("set-cookie", sc, { append: true });
    } catch (err) {
      console.error("[account] signOut after deletion failed; cookie persists until TTL", err);
    }
    return c.redirect("/account/deleted");
  });

  r.get("/account/deleted", (c) => c.html(<AccountDeletedPage />));

  return r;
}
