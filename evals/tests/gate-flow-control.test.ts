import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { CHANNEL_WINDOW_BYTES, MAX_FRAME_PAYLOAD } from "antgrid-wire";
import { setupTestEnv, type TestEnv } from "../helpers/harness";
import { createMessage, type AbMessage } from "../../bridge/src/protocol";
import { firstProjectStream } from "../support/stream";

/**
 * Per-channel credit windows (docs/protocol/peer-session.md) gate only the
 * session stream: the control plane and its session frames. A project's
 * records ride that project's own QUIC stream, paced by QUIC flow control, so
 * a project body several windows long must cross without charging the session
 * window at all, and a client that withholds session credits must not stall
 * it. If project traffic ever fell back onto the session stream, one large
 * `file:content` would again hold every other project's control traffic
 * behind a window only this client's credits can reopen.
 *
 * The window's own stop-and-resume mechanics are pinned at the unit level by
 * bridge/tests/relay-client-credit-window.test.ts; the preview window is
 * exercised by gate-tunnel-streaming.test.ts.
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

    // Several windows of body crossed, and the session window was charged at
    // most the liveness traffic that shares it.
    expect(env.app.consumedBytes("control") - before).toBeLessThan(MAX_FRAME_PAYLOAD);
    expect(Buffer.from(flood!.content!, "base64").length).toBeGreaterThan(CHANNEL_WINDOW_BYTES);
  }, 60_000);

  test("withholding session credits does not stall a project stream", async () => {
    env.app.setCreditsPaused(true);
    try {
      env.app.sendOnStream(streamId, createMessage("file:read", {
        projectId: env.projectId,
        path: "flood.png",
      }));
      const flood = await env.app.waitForStreamAbType(streamId, "file:content", 40_000);
      expect(flood.path).toBe("flood.png");
      expect(flood.error).toBeUndefined();
      expect(Buffer.from(flood.content!, "base64").equals(png)).toBe(true);
    } finally {
      env.app.setCreditsPaused(false);
    }
  }, 60_000);
});
