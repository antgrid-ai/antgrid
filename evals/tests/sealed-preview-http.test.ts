import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { randomBytes } from "node:crypto";
import type { Server } from "bun";
import { setupTestEnv, type TestEnv } from "../helpers/harness";
import { TUNNEL_CHUNK_BYTES } from "../../bridge/src/tunnel-protocol";
import { firstProjectStream } from "../support/stream";

// Regression guard for the sealed preview tunnel, end to end over a real relay
// and a real agent. An HTTP response rides the preview channel as
// `tunnel:http-start` (head + first body slice), `tunnel:http-chunk` and
// `tunnel:http-end`; the bridge reads the next slice only once the previous
// frame has left its send queue, so a body many slices long crosses the credit
// window under the app's credits alone. The small case proves a body that fits
// one slice is still exactly one frame; the large case proves a paced multi-
// slice body reassembles byte for byte.
//
// Preview traffic is per-project: it must ride the project STREAM's preview
// channel, because the machine control plane drops tunnel messages
// (`onTunnelMessage: () => {}` in host-server.ts).
const BIG = randomBytes(2 * 1024 * 1024);

describe("sealed preview HTTP tunnel", () => {
  let env: TestEnv;
  let streamId: string;
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
        // Random bytes served as a binary type: gzip cannot collapse them, so
        // the slice count reflects the real body size rather than its entropy.
        if (url.pathname === "/big") {
          return new Response(BIG, { headers: { "content-type": "application/octet-stream" } });
        }
        return new Response("small-ok", { status: 200, headers: { "content-type": "text/plain" } });
      },
    });
    // port is only undefined for unix-socket servers; this is a TCP listener.
    originPort = origin.port!;

    env = await setupTestEnv({ fixtureName: "basic" });
    streamId = await firstProjectStream(env.app, env.projectId, 10_000);
  }, 60_000);

  afterAll(async () => {
    origin?.stop(true);
    await env?.teardown();
  });

  test("small response round-trips sealed over the preview channel", async () => {
    const requestId = "req-small-1";
    env.app.sendOnStream(
      streamId,
      {
        type: "tunnel:http-request",
        requestId,
        port: originPort,
        method: "GET",
        path: "/small",
        headers: {},
      },
      "preview",
    );

    const res = await env.app.waitForTunnelResponse(requestId, 10_000);
    expect(res.status).toBe(200);
    expect(res.body.toString("utf8")).toBe("small-ok");
    // A body inside one slice folds into the start: no chunk, no end.
    expect(res.frames).toBe(1);
    expect(res.chunks).toBe(0);
  }, 20_000);

  test("large response round-trips intact as paced chunks", async () => {
    const requestId = "req-big-1";
    env.app.sendOnStream(
      streamId,
      {
        type: "tunnel:http-request",
        requestId,
        port: originPort,
        method: "GET",
        path: "/big",
        headers: {},
      },
      "preview",
    );

    const res = await env.app.waitForTunnelResponse(requestId, 20_000);
    expect(res.status).toBe(200);
    expect(res.body.equals(BIG)).toBe(true);
    expect(res.chunks).toBeGreaterThanOrEqual(1);
    expect(res.frames).toBe(res.chunks + 2);
    // Bounded, not exact: this is the production flush window, and one slow
    // upstream read on a loaded host legitimately ships a short slice.
    expect(res.chunks).toBeLessThanOrEqual(Math.ceil(BIG.length / TUNNEL_CHUNK_BYTES) - 1 + 2);
  }, 40_000);
});
