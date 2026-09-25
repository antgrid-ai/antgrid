import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { randomBytes } from "node:crypto";
import type { Server } from "bun";
import { setupTestEnv, type TestEnv } from "../helpers/harness";
import { TUNNEL_BODY_SLICE_BYTES } from "../../bridge/src/tunnel-protocol";
import { firstProjectStream } from "../support/stream";

// Regression guard for the tunnel-http stream, end to end over a real relay
// and a real agent (Stage A wave A3, docs/iroh-reduction/stage-A-waves.md §3
// "A3"; the frozen contract is docs/iroh-reduction/stage-A-A3-contract.md).
// Every preview HTTP request gets its own native QUIC stream: the app writes
// the open frame, a `tunnel:http-head`-carrying head record, then the body as
// tagged records; the bridge answers with `tunnel:http-head`, `0x00`/`0x01`
// body records and a `tunnel:http-end`. The small case proves a body inside
// one upstream read is one body record and a clean end; the large
// case proves a paced, multi-record body reassembles byte for byte.
//
// Preview traffic is per-request now, not per-project: `openTunnelHttpStream`
// opens a stream directly on the native connection, bypassing the project
// stream entirely (D1/D3 of the contract — the legacy session-stream tunnel
// is deleted, not kept alongside).
const BIG = randomBytes(2 * 1024 * 1024);

describe("tunnel-http stream", () => {
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
        // Random bytes served as a binary type: gzip cannot collapse them, so
        // the record count reflects the real body size rather than its entropy.
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
    const client = await env.app.openTunnelHttpStream({
      projectId: env.projectId,
      head: { type: "tunnel:http-request", port: originPort, method: "GET", path: "/small", headers: {} },
    });

    const res = await client.response(10_000);
    expect(res.status).toBe(200);
    expect(res.body.toString("utf8")).toBe("small-ok");
    // A body inside one upstream read is exactly one body record; the end
    // record that follows it is unconditional, so a short body is never
    // mistaken for a truncated one.
    expect(res.records).toBe(1);
  }, 20_000);

  test("large response round-trips intact as paced records", async () => {
    const client = await env.app.openTunnelHttpStream({
      projectId: env.projectId,
      head: { type: "tunnel:http-request", port: originPort, method: "GET", path: "/big", headers: {} },
    });

    const res = await client.response(20_000);
    expect(res.status).toBe(200);
    expect(res.body.equals(BIG)).toBe(true);
    expect(res.records).toBeGreaterThanOrEqual(1);
    // Bounded, not exact: this is the production flush window, and one slow
    // upstream read on a loaded host legitimately ships a short slice.
    expect(res.records).toBeLessThanOrEqual(Math.ceil(BIG.length / TUNNEL_BODY_SLICE_BYTES));
  }, 40_000);
});
