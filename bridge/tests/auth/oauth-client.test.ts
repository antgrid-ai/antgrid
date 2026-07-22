import { describe, expect, it } from "bun:test";
import { OAuthClient } from "../../src/auth/oauth-client";

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
