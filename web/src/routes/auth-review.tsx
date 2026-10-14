// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { createHash, randomBytes } from "node:crypto";
import { Hono } from "hono";
import { getCookie, setCookie } from "hono/cookie";
import type { Auth } from "../auth/better-auth.js";
import { Layout } from "../ui/layout.js";

export function authReviewRoutes(deps: { auth: Auth; baseURL: string }) {
  const r = new Hono();
  const cookieName = (token: string) => "antgrid.verify_csrf."+createHash("sha256").update(token).digest("hex").slice(0,24);
  r.get("/api/auth/verify-email", (c) => {
    const token = c.req.query("token") ?? "";
    if (!token || token.length > 4096) return c.text("Invalid verification link", 400);
    const csrf = randomBytes(32).toString("base64url");
    setCookie(c, cookieName(token), csrf, { httpOnly: true, secure: deps.baseURL.startsWith("https:"), sameSite: "strict", path: "/", maxAge: 3600 });
    return c.html(<Layout title="Review email verification" analytics={false}>
      <main class="max-w-md mx-auto mt-16 card bg-panel border border-edge"><div class="card-body">
        <h1 class="card-title">Review email verification</h1><p>Continue only if you created an Antgrid account with this address.</p>
        <form method="post" action="/ui/verify-email/confirm"><input type="hidden" name="token" value={token} />
          <input type="hidden" name="csrf" value={csrf} /><button class="btn btn-primary" type="submit">Verify email</button></form>
      </div></main></Layout>);
  });
  r.post("/ui/verify-email/confirm", async (c) => {
    const origin = c.req.header("origin");
    if (origin !== new URL(deps.baseURL).origin && !(origin === "null" && c.req.header("sec-fetch-site") === "same-origin")) return c.text("Forbidden", 403);
    const form = await c.req.formData();
    const token = String(form.get("token") ?? "");
    const csrf = getCookie(c, cookieName(token));
    if (!csrf || csrf !== form.get("csrf")) return c.text("Forbidden", 403);
    if (!token || token.length > 4096) return c.text("Invalid verification link", 400);
    const response = await deps.auth.api.verifyEmail({ query: { token, callbackURL: "/login/verified" }, headers: c.req.raw.headers, asResponse: true });
    setCookie(c, cookieName(token), "", { path: "/", maxAge: 0 });
    return c.redirect(response.ok || response.status === 302 ? response.headers.get("location") ?? "/login/verified" : "/login/verified?error=INVALID_TOKEN");
  });
  return r;
}
