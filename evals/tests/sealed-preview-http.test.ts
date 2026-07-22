import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import type { Server } from "bun";
import { setupTestEnv, type TestEnv } from "../helpers/harness";

// Regression guard for the sealed preview tunnel. Preview HTTP responses are now
// sealed on the `preview` channel and fragmented via frag1 (the bespoke app-side
// `tunnel:http-response-chunk` reassembler that previously handled large bodies was
// deleted). A >1.5MB body exceeds the relay's MAX_FRAME_PAYLOAD, so the large case
// proves the sealed preview send fragments and the app client reassembles it.
const BIG = "A".repeat(2 * 1024 * 1024);

// TODO(evals): v3 serves the preview tunnel PER-PROJECT on the project stream's
// `preview` channel — the machine control plane drops preview traffic
// (`onTunnelMessage: () => {}` in host-server.ts). The frozen RelayClient helper
// only exposes control-plane `sendEncryptedTunnel` (streamId = CONTROL), with no
// stream-scoped sealed preview send, so this sealed-preview fragmentation guard
// can't be driven from evals without a helper addition (sendAppEnvelope over a
// project streamId on the "preview" channel). Skipped until the harness grows a
// stream-preview send; the fragmentation receive path is still covered by
// fragmentation.test.ts.
describe.skip("sealed preview HTTP tunnel", () => {
  let env: TestEnv;
  let origin: Server<unknown>;
  let originPort: number;

  beforeAll(async () => {
    // Bind 127.0.0.1 explicitly: the bridge fetches http://localhost:<port>, and
    // a default Bun.serve can bind ::1 only, leaving the IPv4 loopback unreachable.
    origin = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(req) {
        const url = new URL(req.url);
        if (url.pathname === "/big") return new Response(BIG, { headers: { "content-type": "text/plain" } });
        return new Response("small-ok", { status: 200, headers: { "content-type": "text/plain" } });
      },
    });
    // port is only undefined for unix-socket servers; this is a TCP listener.
    originPort = origin.port!;

    env = await setupTestEnv({ fixtureName: "basic" });
    await env.app.waitForAbType("agent:status", 10_000);
  }, 60_000);

  afterAll(async () => {
    origin?.stop(true);
    await env?.teardown();
  });

  test("small response round-trips sealed over the preview channel", async () => {
    const requestId = "req-small-1";
    env.app.sendEncryptedTunnel({
      type: "tunnel:http-request",
      requestId,
      port: originPort,
      method: "GET",
      path: "/small",
      headers: {},
    });

    const res = await env.app.waitForTunnelResponse(requestId, 10_000);
    expect(res.status).toBe(200);
    const body = res.bodyEncoding === "base64"
      ? Buffer.from(res.body, "base64").toString("utf8")
      : res.body;
    expect(body).toBe("small-ok");
  }, 20_000);

  test("large response round-trips intact via fragmentation", async () => {
    const requestId = "req-big-1";
    env.app.sendEncryptedTunnel({
      type: "tunnel:http-request",
      requestId,
      port: originPort,
      method: "GET",
      path: "/big",
      headers: {},
    });

    const res = await env.app.waitForTunnelResponse(requestId, 15_000);
    expect(res.status).toBe(200);
    const body = res.bodyEncoding === "base64"
      ? Buffer.from(res.body, "base64").toString("utf8")
      : res.body;
    expect(body.length).toBe(BIG.length);
    expect(body).toBe(BIG);
  }, 30_000);
});
