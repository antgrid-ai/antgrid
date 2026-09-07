import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { CHANNEL_WINDOW_BYTES, MAX_FRAME_PAYLOAD, SEAL_OVERHEAD_BYTES } from "antgrid-wire";
import { setupTestEnv, type TestEnv } from "../helpers/harness";
import { createMessage, type AbMessage } from "../../bridge/src/protocol";
import { firstProjectStream } from "../support/stream";

/**
 * Per-channel credit windows, end to end over a real relay and a real agent
 * (docs/protocol/e2e-handshake.md §8.8). The agent may hold at most
 * CHANNEL_WINDOW_BYTES of sealed payload in flight on a channel beyond what
 * this client has credited; the client counts what it takes off the wire and
 * returns cumulative `credit` session frames. Two things have to be true for
 * that to be an improvement rather than a new way to wedge: a body larger than
 * the window must still cross it, and a client that stops crediting must stop
 * the sender rather than let it flood.
 *
 * Both rows drive the `control` channel. The preview channel is not reachable
 * from this client — v3 serves the preview tunnel per-project and the machine
 * control plane drops preview traffic, so there is no stream-scoped sealed
 * preview send to aim at (see the header of sealed-preview-http.test.ts). The
 * shared channel makes the first row stricter, not weaker: the small verb's
 * reply queues behind the flood in the same FIFO rather than beside it.
 *
 * Known Windows test noise (NOT failures): fs.watch EPERM/EBUSY on teardown.
 */

// Over two windows once base64-expanded (~5.6 MB), and under the agent's 10 MB
// renderable-binary cap. Fragmented into ~1.4 MB frames, so several credits are
// needed before the last one can be written.
const BODY_BYTES = 4 * 1024 * 1024;

/** A binary PNG: the agent ships an oversize `file:content` only for a
 *  renderable binary type (the text path caps at 1 MB). */
function makeBinaryPng(size: number): Buffer {
  const buf = Buffer.alloc(size);
  buf.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], 0);
  for (let i = 8; i < size; i++) buf[i] = i % 251; // deterministic, non-trivial
  return buf;
}

type FileContent = Extract<AbMessage, { type: "file:content" }>;

describe("gate: per-channel flow control", () => {
  let env: TestEnv;
  let streamId: string;
  let png: Buffer;

  beforeAll(async () => {
    env = await setupTestEnv({ fixtureName: "basic" });
    streamId = await firstProjectStream(env.app, env.projectId, 10_000);
    png = makeBinaryPng(BODY_BYTES);
    writeFileSync(join(env.projectDir, "flood.png"), png);
  }, 60_000);

  afterAll(async () => {
    await env?.teardown();
  });

  test("a project verb is answered while a body several windows long is delivered", async () => {
    const before = env.app.consumedBytes("control");

    env.app.sendOnStream(streamId, createMessage("file:read", {
      projectId: env.projectId,
      path: "flood.png",
    }));
    // Issued into the same channel the flood is already filling. Whichever of
    // the two the agent finishes reading first, the other is behind a window
    // that only this client's credits can reopen.
    env.app.sendOnStream(streamId, createMessage("file:read", {
      projectId: env.projectId,
      path: "README.md",
    }));

    const replies: FileContent[] = [
      await env.app.waitForStreamAbType(streamId, "file:content", 40_000),
      await env.app.waitForStreamAbType(streamId, "file:content", 40_000),
    ];
    const byPath = new Map(replies.map((c) => [c.path, c]));

    const flood = byPath.get("flood.png");
    expect(flood).toBeDefined();
    expect(flood!.error).toBeUndefined();
    expect(flood!.size).toBe(BODY_BYTES);
    expect(Buffer.from(flood!.content!, "base64").equals(png)).toBe(true);

    const readme = byPath.get("README.md");
    expect(readme).toBeDefined();
    expect(readme!.content).toContain("Eval Test Project");

    // More than one window of sealed payload arrived on this channel, so the
    // agent could only have written it after credits released the window it
    // filled first.
    expect(env.app.consumedBytes("control") - before).toBeGreaterThan(CHANNEL_WINDOW_BYTES);
  }, 60_000);

  test("withholding credits stops the agent inside one window, and releasing them resumes it", async () => {
    env.app.setCreditsPaused(true);
    const before = env.app.consumedBytes("control");

    // Registered before the read so nothing is missed, and observed rather than
    // awaited: the point of the first half is that it does NOT arrive.
    let arrived = false;
    const content = env.app.waitForStreamAbType(streamId, "file:content", 40_000);
    content.then(() => { arrived = true; }, () => { arrived = true; });

    env.app.sendOnStream(streamId, createMessage("file:read", {
      projectId: env.projectId,
      path: "flood.png",
    }));

    // Long enough for the whole body to have landed on a healthy session, and
    // well inside the receive-side reassembler's per-transfer timeout, which
    // would otherwise discard the fragments already held.
    await Bun.sleep(3_000);

    const stalled = env.app.consumedBytes("control") - before;
    expect(arrived).toBe(false);
    expect(stalled).toBeGreaterThan(0);
    // The gate lets a frame through whenever nothing is outstanding, so one
    // maximal frame past a full window is the ceiling.
    expect(stalled).toBeLessThanOrEqual(CHANNEL_WINDOW_BYTES + MAX_FRAME_PAYLOAD + SEAL_OVERHEAD_BYTES);

    env.app.setCreditsPaused(false);

    const flood = await content;
    expect(flood.path).toBe("flood.png");
    expect(flood.error).toBeUndefined();
    expect(Buffer.from(flood.content!, "base64").equals(png)).toBe(true);
    // Everything held back during the stall was still in the queue, not dropped.
    expect(env.app.consumedBytes("control") - before).toBeGreaterThan(stalled);
  }, 60_000);
});
