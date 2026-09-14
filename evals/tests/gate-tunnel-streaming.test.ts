import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { randomBytes } from "node:crypto";
import type { Server } from "bun";
import { CHANNEL_WINDOW_BYTES, MAX_FRAME_PAYLOAD, SEAL_OVERHEAD_BYTES } from "antgrid-wire";
import { setupTestEnv, type TestEnv } from "../helpers/harness";
import { base64Length } from "../../bridge/src/tunnel-protocol";
import { firstProjectStream, streamSnapshot } from "../support/stream";

/**
 * The tunneled HTTP body on the preview credit window, end to end over a real
 * relay and a real agent. Streaming the body as start/chunk/end is only an
 * improvement if three things hold, and each is a row here: a body several
 * windows long must still cross under the app's credits while the control
 * channel keeps answering; a client that stops crediting must stop the sender
 * inside one window rather than let it flood; and a cancel must stop a stream
 * mid-body without wedging the bridge for the next request.
 *
 * Every request rides the project STREAM's preview channel — the machine
 * control plane drops tunnel messages (`onTunnelMessage: () => {}` in
 * host-server.ts).
 *
 * Known Windows test noise (NOT failures): fs.watch EPERM/EBUSY on teardown.
 */

// Several windows' worth once base64-expanded. Random bytes served as a binary
// type so gzip cannot collapse the body into a single slice.
const BIG = randomBytes(6 * 1024 * 1024);

/** The most the sender may write past what has been credited: the gate lets a
 *  frame through whenever nothing is outstanding, so one maximal frame past a
 *  full window is the ceiling. */
const WINDOW_CEILING = CHANNEL_WINDOW_BYTES + MAX_FRAME_PAYLOAD + SEAL_OVERHEAD_BYTES;

describe("gate: tunnel HTTP streaming under the preview window", () => {
  let env: TestEnv;
  let streamId: string;
  let origin: Server<unknown>;
  let originPort: number;

  const request = (requestId: string, path: string): void => {
    env.app.sendOnStream(
      streamId,
      { type: "tunnel:http-request", requestId, port: originPort, method: "GET", path, headers: {} },
      "preview",
    );
  };

  const framesFor = (requestId: string): number =>
    env.app.queuedCount((m: any) => typeof m?.type === "string" && m.type.startsWith("tunnel:") && m.requestId === requestId);

  const endsFor = (requestId: string): number =>
    env.app.queuedCount((m: any) => m?.type === "tunnel:http-end" && m.requestId === requestId);

  const chunksFor = (requestId: string): number =>
    env.app.queuedCount((m: any) => m?.type === "tunnel:http-chunk" && m.requestId === requestId);

  beforeAll(async () => {
    // Bind 127.0.0.1 explicitly: the bridge fetches http://localhost:<port>, and
    // a default Bun.serve can bind ::1 only, leaving the IPv4 loopback unreachable.
    origin = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(req) {
        const url = new URL(req.url);
        if (url.pathname === "/big") {
          return new Response(BIG, { headers: { "content-type": "application/octet-stream" } });
        }
        return new Response("small-ok", { status: 200, headers: { "content-type": "text/plain" } });
      },
    });
    originPort = origin.port!;

    env = await setupTestEnv({ fixtureName: "basic" });
    streamId = await firstProjectStream(env.app, env.projectId, 10_000);
  }, 60_000);

  afterAll(async () => {
    origin?.stop(true);
    await env?.teardown();
  });

  test("a body several windows long crosses under credits while a control verb is answered", async () => {
    const requestId = "gate-big-1";
    const before = env.app.consumedBytes("preview");

    request(requestId, "/big");
    const responseP = env.app.waitForTunnelResponse(requestId, 60_000);

    // Issued into a session already carrying a body several windows long. The
    // channels are separate windows but one socket and one E2E session, so a
    // stream that could only advance by starving the control plane would show
    // up here as a snapshot that never answers.
    const frames = await streamSnapshot(env.app, streamId, 20_000);
    expect(frames.length).toBeGreaterThan(0);

    const res = await responseP;
    expect(res.status).toBe(200);
    expect(res.body.equals(BIG)).toBe(true);
    expect(res.chunks).toBeGreaterThanOrEqual(1);
    expect(res.frames).toBe(res.chunks + 2);

    // Random bytes never gzip smaller, so every slice went out as plain base64
    // and the sealed payload is at least the body's base64 length — several
    // windows: the agent could only have written it after this client's
    // credits reopened the window it filled first.
    const consumed = env.app.consumedBytes("preview") - before;
    expect(consumed).toBeGreaterThan(CHANNEL_WINDOW_BYTES);
    expect(consumed).toBeGreaterThanOrEqual(base64Length(BIG.length));
  }, 90_000);

  test("a client that stops crediting stops the sender inside one window", async () => {
    const requestId = "gate-big-paused";
    env.app.setCreditsPaused(true);
    const before = env.app.consumedBytes("preview");

    request(requestId, "/big");

    // Long enough for the whole body to have landed on a healthy session.
    await Bun.sleep(1_500);

    const stalled = env.app.consumedBytes("preview") - before;
    expect(stalled).toBeGreaterThan(0);
    expect(stalled).toBeLessThanOrEqual(WINDOW_CEILING);

    // Sampled without consuming: a sender still writing would show a rising
    // frame count for this id, where a wedged one holds steady.
    const first = framesFor(requestId);
    await Bun.sleep(300);
    const second = framesFor(requestId);
    expect(second).toBe(first);
    expect(endsFor(requestId)).toBe(0);

    // The control channel has its own window, so the wedge is confined to preview.
    const frames = await streamSnapshot(env.app, streamId, 20_000);
    expect(frames.length).toBeGreaterThan(0);

    env.app.setCreditsPaused(false);

    const res = await env.app.waitForTunnelResponse(requestId, 60_000);
    expect(res.status).toBe(200);
    expect(res.body.equals(BIG)).toBe(true);
    // Everything held back during the stall was still queued, not dropped.
    expect(env.app.consumedBytes("preview") - before).toBeGreaterThan(stalled);
  }, 120_000);

  test("tunnel:http-cancel stops a stream mid-body and leaves the bridge usable", async () => {
    const requestId = "gate-big-cancel";
    // Paused credits park the run on a settle with chunks already delivered, so
    // the cancel lands against a stream that is genuinely mid-body rather than
    // one that finished before the frame crossed.
    env.app.setCreditsPaused(true);
    request(requestId, "/big");

    const deadline = Date.now() + 10_000;
    while (chunksFor(requestId) < 2 && Date.now() < deadline) await Bun.sleep(50);
    expect(chunksFor(requestId)).toBeGreaterThanOrEqual(2);
    expect(endsFor(requestId)).toBe(0);

    env.app.sendOnStream(streamId, { type: "tunnel:http-cancel", requestId }, "preview");
    env.app.setCreditsPaused(false);

    // The frame already handed to the send path may still cross; nothing after
    // it may, and a cancelled stream is never terminated with an `end`.
    await Bun.sleep(2_000);
    const settled = framesFor(requestId);
    expect(endsFor(requestId)).toBe(0);
    await Bun.sleep(300);
    expect(framesFor(requestId)).toBe(settled);
    expect(endsFor(requestId)).toBe(0);

    const followUpId = "gate-small-after-cancel";
    request(followUpId, "/small");
    const followUp = await env.app.waitForTunnelResponse(followUpId, 20_000);
    expect(followUp.status).toBe(200);
    expect(followUp.body.toString("utf8")).toBe("small-ok");
  }, 120_000);
});
