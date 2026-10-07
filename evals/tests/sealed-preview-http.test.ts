import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { randomBytes } from "node:crypto";
import type { Server } from "bun";
import { setupTestEnv, type TestEnv } from "../helpers/harness";
import { firstProjectStream } from "../support/stream";
import { buildRequest, fetchOverTunnel } from "../support/raw-http";

// Regression guard for the tunnel-tcp stream, end to end over a real relay
// and a real agent. The phone's preview forwarder gives every accepted
// connection its own native QUIC stream: the app writes the open frame and a
// `tunnel:tcp-open` head record, the bridge answers `tunnel:tcp-ready`, and
// from then on both directions are raw TCP bytes ending in a clean FIN. The
// small case proves a body that arrives inside one upstream read still ends
// cleanly; the large case proves a large body reassembles byte for byte.
//
// Preview traffic is per-connection, not per-project: `openTunnelTcpStream`
// opens a stream directly on the native connection, bypassing the project
// stream entirely.
const BIG = randomBytes(2 * 1024 * 1024);

describe("tunnel-tcp stream", () => {
  let env: TestEnv;
  let origin: Server<unknown>;
  let originPort: number;

  beforeAll(async () => {
    // Bind 127.0.0.1 explicitly: the bridge dials localhost:<port>, and a
    // default Bun.serve can bind ::1 only, leaving the IPv4 loopback unreachable.
    origin = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(req) {
        const url = new URL(req.url);
        // Random bytes served as a binary type: gzip cannot collapse them, so
        // the body crosses the tunnel at its real size rather than its entropy.
        if (url.pathname === "/big") {
          return new Response(BIG, { headers: { "content-type": "application/octet-stream" } });
        }
        return new Response("small-ok", { status: 200, headers: { "content-type": "text/plain" } });
      },
    });
    // port is only undefined for unix-socket servers; this is a TCP listener.
    originPort = origin.port!;

    env = await setupTestEnv({ fixtureName: "basic" });
    // Proves a project stream still exists beside the tunnel stream, though
    // no row here drives verbs on it.
    await firstProjectStream(env.app, env.projectId, 10_000);
  }, 60_000);

  afterAll(async () => {
    origin?.stop(true);
    await env?.teardown();
  });

  test("small response round-trips over its own stream", async () => {
    const client = await env.app.openTunnelTcpStream({ projectId: env.projectId, port: originPort });
    const res = await fetchOverTunnel(client, buildRequest({ method: "GET", path: "/small", port: originPort }), 10_000);
    expect(res.status).toBe(200);
    expect(res.body.toString("utf8")).toBe("small-ok");
  }, 20_000);

  test("large response round-trips intact", async () => {
    const client = await env.app.openTunnelTcpStream({ projectId: env.projectId, port: originPort });
    const res = await fetchOverTunnel(client, buildRequest({ method: "GET", path: "/big", port: originPort }), 20_000);
    expect(res.status).toBe(200);
    expect(res.body.equals(BIG)).toBe(true);
  }, 40_000);
});
