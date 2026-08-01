import { describe, expect, it } from "bun:test";
import { OAuthClient, startTokenMaintenance, type MintedToken } from "../../src/auth/oauth-client";

function makeServer(handler: (req: Request) => Response | Promise<Response>): {
  url: string;
  close: () => void;
} {
  const srv = Bun.serve({ port: 0, fetch: handler });
  return { url: `http://localhost:${srv.port}`, close: () => srv.stop() };
}

function fakeJwt(expSec: number): string {
  const header = Buffer.from(JSON.stringify({ alg: "EdDSA", typ: "JWT" })).toString("base64url");
  const payload = Buffer.from(
    JSON.stringify({ exp: Math.floor(Date.now() / 1000) + expSec }),
  ).toString("base64url");
  return `${header}.${payload}.sig`;
}

describe("OAuthClient", () => {
  it("mints a token via client_credentials with resource=<licenseApiUrl>/api/auth", async () => {
    const srv = makeServer(async (req) => {
      const u = new URL(req.url);
      expect(u.pathname).toBe("/api/auth/oauth2/token");
      expect(req.headers.get("authorization")).toMatch(/^Basic /);
      const body = new URLSearchParams(await req.text());
      expect(body.get("grant_type")).toBe("client_credentials");
      expect(body.get("scope")).toBe("agent");
      // Resource MUST point at <licenseApiUrl>/api/auth — without it Better-Auth returns an opaque token.
      const resource = body.get("resource");
      expect(resource).toBeTruthy();
      expect(resource!).toMatch(/\/api\/auth$/);
      return Response.json({ access_token: fakeJwt(3600), expires_in: 3600, token_type: "bearer" });
    });
    try {
      const c = new OAuthClient({
        licenseApiUrl: srv.url,
        clientId: "id",
        clientSecret: "secret",
      });
      const t = await c.mint();
      expect(t.accessToken).toMatch(/^ey/);
      expect(t.expiresAt).toBeGreaterThan(Date.now());
    } finally {
      srv.close();
    }
  });

  it("calls onAuthRevoked and throws on 401 invalid_client", async () => {
    const srv = makeServer(() => Response.json({ error: "invalid_client" }, { status: 401 }));
    try {
      let revoked = false;
      const c = new OAuthClient({
        licenseApiUrl: srv.url,
        clientId: "id",
        clientSecret: "bad",
        onAuthRevoked: () => { revoked = true; },
      });
      await expect(c.mint()).rejects.toThrow();
      expect(revoked).toBe(true);
    } finally {
      srv.close();
    }
  });

  // Better-Auth answers a deleted OAuth client with 400, not 401 — signing out
  // rotates the account device and drops its client row. Treating that as a
  // generic error left the host retrying a client the web no longer has, so the
  // machine never reached the relay and phones saw it as offline forever.
  it("calls onAuthRevoked and throws on 400 invalid_client (client deleted)", async () => {
    const srv = makeServer(() =>
      Response.json({ error: "invalid_client", error_description: "missing client" }, { status: 400 }),
    );
    try {
      let revoked = false;
      const c = new OAuthClient({
        licenseApiUrl: srv.url,
        clientId: "stale",
        clientSecret: "stale",
        onAuthRevoked: () => { revoked = true; },
      });
      await expect(c.mint()).rejects.toThrow(/invalid_client/);
      expect(revoked).toBe(true);
    } finally {
      srv.close();
    }
  });

  it("does NOT call onAuthRevoked on a 400 that isn't invalid_client", async () => {
    const srv = makeServer(() => Response.json({ error: "invalid_scope" }, { status: 400 }));
    try {
      let revoked = false;
      const c = new OAuthClient({
        licenseApiUrl: srv.url,
        clientId: "id",
        clientSecret: "secret",
        onAuthRevoked: () => { revoked = true; },
      });
      await expect(c.mint()).rejects.toThrow();
      expect(revoked).toBe(false);
    } finally {
      srv.close();
    }
  });

  it("does NOT call onAuthRevoked on 5xx", async () => {
    const srv = makeServer(() => new Response("oops", { status: 500 }));
    try {
      let revoked = false;
      const c = new OAuthClient({
        licenseApiUrl: srv.url,
        clientId: "id",
        clientSecret: "secret",
        onAuthRevoked: () => { revoked = true; },
      });
      await expect(c.mint()).rejects.toThrow();
      expect(revoked).toBe(false);
    } finally {
      srv.close();
    }
  });

  it("handles trailing slash on licenseApiUrl", async () => {
    const srv = makeServer(async (req) => {
      const u = new URL(req.url);
      expect(u.pathname).toBe("/api/auth/oauth2/token");
      return Response.json({ access_token: fakeJwt(3600), expires_in: 3600 });
    });
    try {
      const c = new OAuthClient({
        licenseApiUrl: srv.url + "/",
        clientId: "id",
        clientSecret: "secret",
      });
      await c.mint();
    } finally {
      srv.close();
    }
  });
});

describe("startTokenMaintenance", () => {
  it("onMinted fires after each successful re-mint, not the initial", async () => {
    // The real refresh timer waits 0.8×60s (the ttl floor) — far too long for a
    // unit test — so capture the scheduled callback and drive re-mints by hand.
    // A microtask flush after each invocation lets the async mint + re-schedule
    // settle before the next drive.
    //
    // Unlike `captureSchedule` in relay-client-backoff.test.ts, this patch has
    // to stay installed across those awaits — and `bun test` runs every file in
    // ONE process, so an unrelated file's ambient timer would otherwise land in
    // `pending` and be driven in place of the maintenance callback. Discriminate
    // by delay: maintenance asks for minutes (0.8×ttl, floored at 60s, or the
    // 30s retry), ambient work asks for milliseconds. Foreign timers are handed
    // to the real implementation rather than swallowed, so nothing else in the
    // process silently loses its timer for the duration of this test.
    const realSetTimeout = globalThis.setTimeout;
    const MIN_MAINTENANCE_DELAY_MS = 30_000;
    let pending: (() => void) | null = null;
    (globalThis as any).setTimeout = ((fn: () => void, ms?: number, ...rest: unknown[]) => {
      if ((ms ?? 0) >= MIN_MAINTENANCE_DELAY_MS) {
        pending = fn;
        return 0;
      }
      return (realSetTimeout as any)(fn, ms, ...rest);
    });
    const flush = () => new Promise((r) => realSetTimeout(r, 0));

    let mintCalls = 0;
    const client = {
      mint: async (): Promise<MintedToken> => {
        mintCalls++;
        return { accessToken: `t${mintCalls}`, expiresAt: Date.now() + 3_600_000 };
      },
    } as unknown as OAuthClient;
    const initial: MintedToken = { accessToken: "t0", expiresAt: Date.now() + 3_600_000 };

    try {
      let minted = 0;
      const maint = startTokenMaintenance(client, initial, { onMinted: () => minted++ });

      // The initial token is provided by the caller, not minted here → no fire.
      expect(minted).toBe(0);
      expect(maint.getToken()).toBe("t0");

      pending!(); await flush();               // first re-mint
      expect(minted).toBe(1);
      expect(maint.getToken()).toBe("t1");

      pending!(); await flush();               // second re-mint
      expect(minted).toBe(2);
      expect(maint.getToken()).toBe("t2");

      maint.stop(); // cancel the outstanding timer — no leaked maintenance loop
    } finally {
      (globalThis as any).setTimeout = realSetTimeout;
    }
  });
});
