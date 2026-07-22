import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { setupTestEnv, type TestEnv } from "../helpers/harness";
import { createMessage } from "../../bridge/src/protocol";
import { firstProjectStream } from "../support/stream";

const CHUNK = 512 * 1024;

function makePayload(size: number): Buffer {
  const buf = Buffer.alloc(size);
  for (let i = 0; i < size; i++) buf[i] = i % 251;
  return buf;
}

describe("file upload", () => {
  let env: TestEnv;
  let streamId: string;

  beforeAll(async () => {
    env = await setupTestEnv({ fixtureName: "basic" });
    // v3: file:upload verbs run on the firstProject stream, not the control plane.
    streamId = await firstProjectStream(env.app, env.projectId, 10_000);
  }, 60_000);

  afterAll(async () => {
    await env?.teardown();
  });

  test("multi-chunk upload lands byte-identical in .antgrid/uploads", async () => {
    const payload = makePayload(CHUNK + CHUNK / 2); // 1.5 chunks → 2 chunks

    env.app.sendOnStream(streamId, createMessage("file:upload-start", {
      projectId: env.projectId,
      requestId: "eval-r1",
      fileName: "eval upload.bin",
      size: payload.length,
    }));
    const ready = await env.app.waitForStreamAbType(streamId, "file:upload-ready", 10_000);
    expect(ready.requestId).toBe("eval-r1");
    const uploadId = ready.uploadId as string;

    for (let seq = 0, off = 0; off < payload.length; seq++, off += CHUNK) {
      env.app.sendOnStream(streamId, createMessage("file:upload-chunk", {
        uploadId, seq,
        data: payload.subarray(off, Math.min(off + CHUNK, payload.length)).toString("base64"),
      }));
      const ack = await env.app.waitForStreamAbType(streamId, "file:upload-ack", 10_000);
      expect(ack.seq).toBe(seq);
    }

    env.app.sendOnStream(streamId, createMessage("file:upload-done", { uploadId }));
    const result = await env.app.waitForStreamAbType(streamId, "file:upload-result", 10_000);
    expect(result.ok).toBe(true);
    expect(result.path).toBeDefined();
    expect(result.path!.startsWith(join(env.projectDir, ".antgrid", "uploads"))).toBe(true);
    expect(readFileSync(result.path!).equals(payload)).toBe(true);
    // Self-ignoring staging dir
    expect(existsSync(join(env.projectDir, ".antgrid", ".gitignore"))).toBe(true);
  }, 30_000);

  test("over-cap declared size is rejected with TOO_LARGE", async () => {
    env.app.sendOnStream(streamId, createMessage("file:upload-start", {
      projectId: env.projectId,
      requestId: "eval-r2",
      fileName: "big.bin",
      size: 21 * 1024 * 1024,
    }));
    const result = await env.app.waitForStreamAbType(streamId, "file:upload-result", 10_000);
    expect(result.requestId).toBe("eval-r2");
    expect(result.ok).toBe(false);
    expect(result.error).toBe("TOO_LARGE");
  }, 15_000);
});
