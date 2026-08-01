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
      if (url.pathname === "/bundle.js") {
        return new Response(BUNDLE_JS, {
          headers: { "Content-Type": "application/javascript" },
        });
      }
      if (url.pathname === "/tiny.js") {
        return new Response("export const a = 1;", {
          headers: { "Content-Type": "application/javascript" },
        });
      }
      if (url.pathname === "/big.png") {
        return new Response(INCOMPRESSIBLE_RANDOM, {
          headers: { "Content-Type": "image/png" },
        });
      }
      if (url.pathname === "/blob.bin") {
        return new Response(INCOMPRESSIBLE_RANDOM, {
          headers: { "Content-Type": "application/octet-stream" },
        });
      }
      return new Response("Hello");
    },
  });
  return testServer;
}

// Well past GZIP_MIN_BYTES and compressible, like a real dev-server chunk.
const BUNDLE_JS = "export function hello(name) { return `hi ${name}`; }\n".repeat(400);
// Random bytes: gzip cannot shrink these. Served under image/* to exercise the
// content-type shortcut and under a type that shortcut misses to exercise the
// size check behind it.
const INCOMPRESSIBLE_RANDOM = crypto.getRandomValues(new Uint8Array(16 * 1024));

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

describe("fetchLocalhost body compression", () => {
  it("gzips a compressible body when the caller advertises the encoding", async () => {
    const server = startTestServer();
    const result = await fetchLocalhost({
      url: `http://localhost:${server.port}/bundle.js`,
      acceptEncodings: ["gzip-base64"],
    });

    expect(result.bodyEncoding).toBe("gzip-base64");
    const inflated = Buffer.from(Bun.gunzipSync(Buffer.from(result.body, "base64")));
    expect(inflated.toString("utf8")).toBe(BUNDLE_JS);
    // The point of the exercise: fewer bytes for the phone to decode than the
    // raw text would have been.
    expect(result.body.length).toBeLessThan(BUNDLE_JS.length / 2);
  });

  it("stays uncompressed for a caller that never advertised the encoding", async () => {
    const server = startTestServer();
    // An app predating acceptEncodings would render gzip bytes as text, so
    // silence must mean "send it plain".
    const result = await fetchLocalhost({ url: `http://localhost:${server.port}/bundle.js` });

    expect(result.bodyEncoding).toBe("utf8");
    expect(result.body).toBe(BUNDLE_JS);
  });

  it("ignores an advertisement it does not implement", async () => {
    const server = startTestServer();
    const result = await fetchLocalhost({
      url: `http://localhost:${server.port}/bundle.js`,
      acceptEncodings: ["br-base64"],
    });

    expect(result.bodyEncoding).toBe("utf8");
  });

  it("leaves a small body alone", async () => {
    const server = startTestServer();
    const result = await fetchLocalhost({
      url: `http://localhost:${server.port}/tiny.js`,
      acceptEncodings: ["gzip-base64"],
    });

    expect(result.bodyEncoding).toBe("utf8");
    expect(result.body).toBe("export const a = 1;");
  });

  it("leaves an already-compressed format alone", async () => {
    const server = startTestServer();
    const result = await fetchLocalhost({
      url: `http://localhost:${server.port}/big.png`,
      acceptEncodings: ["gzip-base64"],
    });

    expect(result.bodyEncoding).toBe("base64");
    expect(Buffer.from(result.body, "base64").equals(Buffer.from(INCOMPRESSIBLE_RANDOM))).toBe(
      true,
    );
  });

  // The content-type list can't know every incompressible format, so the size
  // check behind it is the real guard — and only a type that list MISSES
  // reaches it. Without this, inverting the comparison passes every test while
  // making incompressible bodies ~33% larger on the wire.
  it("discards a gzip that came out bigger than the plain encoding", async () => {
    const server = startTestServer();
    const result = await fetchLocalhost({
      url: `http://localhost:${server.port}/blob.bin`,
      acceptEncodings: ["gzip-base64"],
    });

    expect(result.bodyEncoding).toBe("base64");
    expect(Buffer.from(result.body, "base64").equals(Buffer.from(INCOMPRESSIBLE_RANDOM))).toBe(
      true,
    );
  });
});
