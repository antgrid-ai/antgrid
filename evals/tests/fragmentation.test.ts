import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { setupTestEnv, type TestEnv } from "../helpers/harness";
import { createMessage } from "../../bridge/src/protocol";
import { firstProjectStream } from "../support/stream";

const THREE_MB = 3 * 1024 * 1024;

/**
 * A >1.5MB sealed `file:content` exceeds the relay's MAX_FRAME_PAYLOAD (1.5MB)
 * and would trigger a 1009 WS close (cascade-disconnecting paired phones) without
 * fragmentation. The bridge SEND seam splits it into sealed `__frag` envelopes;
 * the app/bridge RECEIVE seam reassembles them. This eval drives a REAL relay and
 * agent, proving the round-trip is intact once the test relay client mirrors the
 * production receive-side reassembler (see helpers/relay-client.ts).
 *
 * The agent only ships an oversize `file:content` for a RENDERABLE binary type
 * (the text path caps at 1MB; see bridge/src/file-tree.ts), so the oversize
 * fixture is a 3MB `.png` with binary content — base64-encoded (~4MB) on the
 * wire, comfortably over the 1.5MB frame limit.
 */
function makeBinaryPng(size: number): Buffer {
  const buf = Buffer.alloc(size);
  // PNG magic so the .png extension is honoured; an early NUL marks it binary
  // (bridge isBinaryBuffer scans the head for a zero byte).
  buf.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], 0);
  for (let i = 8; i < size; i++) buf[i] = i % 251; // deterministic, non-trivial
  return buf;
}

describe("fragmentation", () => {
  let env: TestEnv;
  let streamId: string;

  beforeAll(async () => {
    env = await setupTestEnv({ fixtureName: "basic" });
    // v3: project traffic runs on the firstProject stream, not the control plane.
    streamId = await firstProjectStream(env.app, env.projectId, 10_000);
  }, 60_000);

  afterAll(async () => {
    await env?.teardown();
  });

  test("large file:content round-trips intact over the relay via fragmentation", async () => {
    const png = makeBinaryPng(THREE_MB);
    writeFileSync(join(env.projectDir, "large.png"), png);

    env.app.sendOnStream(streamId, createMessage("file:read", {
      projectId: env.projectId,
      path: "large.png",
    }));

    const content = await env.app.waitForStreamAbType(streamId, "file:content", 10_000);
    expect(content.path).toBe("large.png");
    expect(content.error).toBeUndefined();
    expect(content.encoding).toBe("base64");
    expect(content.size).toBe(THREE_MB);
    expect(content.content).not.toBeNull();

    // The stream envelope `{ s: streamId, m }` is fragmented as a whole, so `s`
    // must survive reassembly: matching via waitForStreamAbType (which keys on
    // `_streamId === streamId`) is that proof — a lost `s` would land the
    // reassembled frame on the control plane and never match here.
    expect((content as { _streamId?: string })._streamId).toBe(streamId);

    const decoded = Buffer.from(content.content!, "base64");
    expect(decoded.length).toBe(THREE_MB);
    expect(decoded.equals(png)).toBe(true);
  }, 20_000);

  test("sub-threshold file:content uses the single-frame common path", async () => {
    // README.md is seeded by createTestProject (a few dozen bytes) — well under
    // the fragmentation threshold, so it arrives as one un-fragmented frame. This
    // guards against the reassembler accidentally swallowing normal messages.
    env.app.sendOnStream(streamId, createMessage("file:read", {
      projectId: env.projectId,
      path: "README.md",
    }));

    const content = await env.app.waitForStreamAbType(streamId, "file:content", 10_000);
    expect(content.path).toBe("README.md");
    expect(content.encoding).toBe("utf8");
    expect(content.content).toContain("Eval Test Project");
  }, 15_000);

  // NOTE: dropped-fragment heal / abort behaviour is not exercised here — the
  // eval harness has no frame-drop fault injection. That path is covered by the
  // bridge & Dart reassembler unit tests (Tasks 3/7).
});
