import { describe, expect, test } from "bun:test";
import type { Auth } from "../../src/auth/better-auth.js";
import { uiRoutes } from "../../src/routes/ui.js";

// Better-Auth's signOut can clear more than one cookie (session token plus, when
// cookie-cache / dont-remember are in play, `session_data` / `dont_remember`).
// The /logout handler must forward EACH Set-Cookie as its own header — the
// clearing cookies carry `Expires=Thu, 01 Jan 1970 ...` whose comma makes a
// single comma-joined header unparseable. This stubs auth so we can assert the
// multi-cookie case without depending on Better-Auth's exact emission.
function appWithSignOutCookies(cookies: string[]) {
  const auth = {
    api: {
      signOut: async () => {
        const h = new Headers();
        for (const c of cookies) h.append("set-cookie", c);
        return new Response(null, { headers: h });
      },
    },
  } as unknown as Auth;
  // db/relay/clientIp are unused by the /logout handler; BETTER_AUTH_URL is
  // not — the router derives its same-origin check from it at construction.
  return uiRoutes({
    db: {} as never,
    auth,
    env: { BETTER_AUTH_URL: "http://localhost" } as never,
    relay: {} as never,
    clientIp: () => null,
  });
}

describe("POST /logout — Set-Cookie forwarding", () => {
  test("forwards every clearing cookie as its own header", async () => {
    const r = appWithSignOutCookies([
      "better-auth.session_token=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT",
      "better-auth.session_data=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT",
    ]);

    const res = await r.fetch(
      new Request("http://localhost/logout", {
        method: "POST",
        redirect: "manual",
      })
    );

    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe("/");

    const setCookies = res.headers.getSetCookie();
    expect(setCookies).toHaveLength(2);
    expect(setCookies.some((c) => c.startsWith("better-auth.session_token="))).toBe(true);
    expect(setCookies.some((c) => c.startsWith("better-auth.session_data="))).toBe(true);
  });
});
