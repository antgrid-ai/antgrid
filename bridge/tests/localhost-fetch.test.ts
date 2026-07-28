import { describe, it, expect, afterAll } from "bun:test";
import { fetchLocalhost } from "../src/localhost-fetch";

let testServer: ReturnType<typeof Bun.serve> | null = null;

function startTestServer() {
  testServer = Bun.serve({
    port: 0, // random available port
    fetch(req) {
      const url = new URL(req.url);
      if (url.pathname === "/json") {
        return new Response(JSON.stringify({ ok: true }), {
          headers: { "Content-Type": "application/json" },
        });
      }
      if (url.pathname === "/binary") {
        const buf = new Uint8Array([0x89, 0x50, 0x4e, 0x47]); // PNG header
        return new Response(buf, {
          headers: { "Content-Type": "image/png" },
        });
      }
      if (url.pathname === "/slow") {
        return new Promise((resolve) => {
          setTimeout(() => resolve(new Response("slow")), 15_000);
        });
      }
      if (url.pathname === "/redirect") {
        return new Response(null, {
          status: 302,
          headers: { Location: "/landed", "Set-Cookie": "sid=abc; Path=/" },
        });
      }
      if (url.pathname === "/multicookie") {
        const h = new Headers();
        h.append("Set-Cookie", "session=xyz; Path=/; HttpOnly");
        h.append("Set-Cookie", "csrf=123; Path=/");
        return new Response("ok", { headers: h });
      }
      if (url.pathname === "/gzipped.css") {
        // Pre-gzipped body + content-encoding, like a dev server compressing
        // assets. fetch() must decompress it AND the stale framing headers
        // must not survive into the forwarded response.
        const gz = Bun.gzipSync(Buffer.from("body { color: red; }"));
        return new Response(gz, {
          headers: {
            "Content-Type": "text/css",
            "Content-Encoding": "gzip",
            "Content-Length": String(gz.byteLength),
          },
        });
      }
      return new Response("Hello");
    },
  });
  return testServer;
}

afterAll(() => {
  testServer?.stop(true);
});

describe("fetchLocalhost", () => {
  it("rejects non-localhost URLs", async () => {
    const result = await fetchLocalhost({ url: "http://example.com/test" });
    expect(result.status).toBe(403);
    expect(result.body).toContain("Forbidden");
  });

  it("decompresses gzipped bodies and strips stale framing headers", async () => {
    const server = startTestServer();
    const result = await fetchLocalhost({
      url: `http://localhost:${server.port}/gzipped.css`,
    });
    expect(result.status).toBe(200);
    expect(result.bodyEncoding).toBe("utf8");
    expect(result.body).toBe("body { color: red; }");
    expect(result.headers["content-encoding"]).toBeUndefined();
    expect(result.headers["content-length"]).toBeUndefined();
    expect(result.headers["transfer-encoding"]).toBeUndefined();
  });

  it("fetches JSON from localhost", async () => {
    const server = startTestServer();
    const result = await fetchLocalhost({
      url: `http://localhost:${server.port}/json`,
    });
    expect(result.status).toBe(200);
    expect(result.bodyEncoding).toBe("utf8");
    const parsed = JSON.parse(result.body);
    expect(parsed.ok).toBe(true);
  });

  it("returns base64 for binary content", async () => {
    const server = startTestServer();
    const result = await fetchLocalhost({
      url: `http://localhost:${server.port}/binary`,
    });
    expect(result.status).toBe(200);
    expect(result.bodyEncoding).toBe("base64");
    const buf = Buffer.from(result.body, "base64");
    expect(buf[0]).toBe(0x89);
    expect(buf[1]).toBe(0x50);
  });

  it("includes response headers", async () => {
    const server = startTestServer();
    const result = await fetchLocalhost({
      url: `http://localhost:${server.port}/json`,
    });
    expect(result.headers["content-type"]).toContain("application/json");
  });

  it("does not follow redirects, preserving Set-Cookie on the 3xx", async () => {
    const server = startTestServer();
    const result = await fetchLocalhost({
      url: `http://localhost:${server.port}/redirect`,
    });
    // The WebView must see the redirect itself; following it here would swallow
    // the Set-Cookie that auth flows place on the 302.
    expect(result.status).toBe(302);
    expect(result.headers["location"]).toBe("/landed");
    expect(result.setCookies).toContain("sid=abc; Path=/");
  });

  it("captures every Set-Cookie on a multi-cookie response", async () => {
    const server = startTestServer();
    const result = await fetchLocalhost({
      url: `http://localhost:${server.port}/multicookie`,
    });
    expect(result.setCookies).toEqual([
      "session=xyz; Path=/; HttpOnly",
      "csrf=123; Path=/",
    ]);
    // The flattened map must not also carry it, or the proxy would emit a
    // duplicate (last-only) copy alongside the out-of-band list.
    expect(result.headers["set-cookie"]).toBeUndefined();
  });
});
