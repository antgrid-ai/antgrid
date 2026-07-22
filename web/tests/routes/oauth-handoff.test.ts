import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { APIError } from "better-auth/api";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { createTestUser, createTestSession } from "../helpers/fixtures.js";
import { oauthHandoffRoutes } from "../../src/routes/oauth-handoff.js";
import type { Auth } from "../../src/auth/better-auth.js";

/** Build the handoff route with a stub auth whose token mint throws `err`. */
function handoffWithMintError(err: unknown) {
  const auth = {
    api: {
      generateOneTimeToken: async () => {
        throw err;
      },
    },
  } as unknown as Auth;
  return oauthHandoffRoutes({ auth });
}

let pg: PgHandle;
beforeAll(async () => {
  pg = await startTestPg();
});
afterAll(async () => {
  await pg.stop();
});
beforeEach(async () => {
  await pg.truncate();
});

describe("/oauth/handoff", () => {
  test("mints a one-time token (not the raw session) that redeems to the user's session", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "alice@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);

    const res = await app.request("/oauth/handoff", { headers: { cookie } });
    expect(res.status).toBe(302);
    const loc = res.headers.get("location") ?? "";
    expect(loc.startsWith("antgrid://auth/callback?token=")).toBe(true);
    // The raw signed session cookie must NOT appear in the deep-link URL.
    expect(loc.includes("session=")).toBe(false);
    expect(res.headers.get("cache-control")).toBe("no-store");

    const token = new URL(loc).searchParams.get("token");
    expect(token).toBeTruthy();

    // Redeem the one-time token over the app's own HTTPS client.
    const verify = await app.request("/api/auth/one-time-token/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ token }),
    });
    expect(verify.status).toBe(200);
    const setCookie = verify.headers.get("set-cookie") ?? "";
    expect(setCookie.includes("better-auth.session_token=")).toBe(true);

    // Single-use: a second redemption of the same token fails.
    const replay = await app.request("/api/auth/one-time-token/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ token }),
    });
    expect(replay.status).not.toBe(200);
  });

  test("redirects to an error deep link when no session is present", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const res = await app.request("/oauth/handoff");
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe(
      "antgrid://auth/callback?error=no_session"
    );
  });

  test("an UNAUTHORIZED mint failure maps to ?error=no_session", async () => {
    const r = handoffWithMintError(new APIError("UNAUTHORIZED"));
    const res = await r.request("/oauth/handoff");
    expect(res.headers.get("location")).toBe(
      "antgrid://auth/callback?error=no_session"
    );
  });

  test("an unexpected mint failure maps to ?error=server_error (not no_session)", async () => {
    const r = handoffWithMintError(new Error("db unavailable"));
    const res = await r.request("/oauth/handoff");
    expect(res.headers.get("location")).toBe(
      "antgrid://auth/callback?error=server_error"
    );
  });
});
