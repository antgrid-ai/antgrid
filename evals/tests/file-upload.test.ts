import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { createHash } from "node:crypto";
import { readFileSync, existsSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { setupTestEnv, type TestEnv } from "../helpers/harness";
import { createMessage } from "../../bridge/src/protocol";
import { createTestProject } from "../helpers/fixtures";
import { computeProjectId } from "../../bridge/src/project-id";
import { readHostFile } from "../../bridge/src/host-discovery";
import { LocalTestClient, type LocalConnectInfo } from "../helpers/local-client";
import { firstProjectStream, resolveOnFreshAdvert } from "../support/stream";

// Remote uploads ride their own `upload` QUIC stream
// (docs/protocol/peer-session.md §1e); the file:upload-start/ready/chunk/ack/
// done/result exchange over the project stream is loopback-only, for the
// desktop app on the same machine.

const CHUNK = 512 * 1024;

function makePayload(size: number): Buffer {
  const buf = Buffer.alloc(size);
  for (let i = 0; i < size; i++) buf[i] = i % 251;
  return buf;
}

function sha256(bytes: Buffer): string {
  return createHash("sha256").update(bytes).digest("hex");
}

async function loopbackControl(abDir: string, body: object): Promise<any> {
  const hf = readHostFile(join(abDir, "host.json"));
  if (!hf) throw new Error("no host.json for loopback control");
  const res = await fetch(`http://127.0.0.1:${hf.controlPort}/control`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${hf.token}` },
    body: JSON.stringify(body),
  });
  return res.json();
}

/** Polls `messages` for a predicate match, mirroring the sibling frame-mode
 *  suite's approach to a `LocalTestClient` feed, which exposes no waiter of
 *  its own. */
async function waitForLocal(
  messages: any[],
  predicate: (m: any) => boolean,
  timeoutMs = 10_000,
): Promise<any> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const found = messages.find(predicate);
    if (found) return found;
    if (Date.now() >= deadline) throw new Error(`Timed out waiting for a loopback message (${timeoutMs}ms)`);
    await Bun.sleep(20);
  }
}

describe("upload stream (native)", () => {
  let env: TestEnv;
  let streamId: string;

  beforeAll(async () => {
    env = await setupTestEnv({ fixtureName: "basic" });
    streamId = await firstProjectStream(env.app, env.projectId, 10_000);
  }, 60_000);

  afterAll(async () => {
    await env?.teardown();
  });

  test("a 9 MiB + 13 byte upload lands byte-identical under .antgrid/uploads", async () => {
    const payload = makePayload(9 * 1024 * 1024 + 13); // spans many raw slices, not slice-aligned
    const wantHash = sha256(payload);

    const client = await env.app.openUploadStream({
      projectId: env.projectId,
      fileName: "eval upload.bin",
      bytes: payload,
    });
    const result = await client.result(30_000);
    expect(await client.ended).toBe("result");
    expect(result.ok).toBe(true);
    expect(result.path).toBeDefined();
    expect((result.path as string).startsWith(join(env.projectDir, ".antgrid", "uploads"))).toBe(true);
    expect(sha256(readFileSync(result.path as string))).toBe(wantHash);
    // Self-ignoring staging dir.
    expect(existsSync(join(env.projectDir, ".antgrid", ".gitignore"))).toBe(true);
  }, 40_000);

  test("a declared size over the cap is rejected with TOO_LARGE", async () => {
    const client = await env.app.openUploadStream({
      projectId: env.projectId,
      fileName: "big.bin",
      size: 21 * 1024 * 1024,
      bytes: new Uint8Array(0),
    });
    const result = await client.result(10_000);
    expect(result.ok).toBe(false);
    expect(result.error).toBe("TOO_LARGE");
  }, 15_000);

  test("cancelling mid-body leaves neither a final file nor a .part file", async () => {
    const fileName = "cancel-me.bin";
    const client = await env.app.openUploadStream({
      projectId: env.projectId,
      fileName,
      size: 4 * 1024 * 1024,
      bytes: makePayload(1024),
      finish: false,
    });
    client.cancel();
    await client.ended;

    const uploadsDir = join(env.projectDir, ".antgrid", "uploads");
    const deadline = Date.now() + 5_000;
    let leftover: string[] = [];
    for (;;) {
      leftover = existsSync(uploadsDir)
        ? readdirSync(uploadsDir).filter((name) => name.includes(fileName))
        : [];
      if (leftover.length === 0 || Date.now() >= deadline) break;
      await Bun.sleep(100);
    }
    expect(leftover).toEqual([]);
  }, 15_000);

  test("a relay-origin file:upload-start is dropped: no file:upload-ready follows it", async () => {
    env.app.sendOnStream(streamId, createMessage("file:upload-start", {
      projectId: env.projectId,
      requestId: "eval-relay-origin-dropped",
      fileName: "dropped.bin",
      size: 16,
    }));
    await expect(
      env.app.waitForStreamAbType(streamId, "file:upload-ready", 2_000),
    ).rejects.toThrow();
  }, 10_000);
});

test("an upload with no open project stream on this peer is refused NOT_ALLOWED", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  const projBdir = createTestProject("basic", { "__RELAY_URL__": env.relay.url.replace(/\/ws$/, "") });
  try {
    const projB = computeProjectId(projBdir.dir);
    // Running (mode:"remote", never stopped) — a live entry exists, so the
    // refusal is the peer-scoped "no open project stream for THIS peer" check
    // (§2.3 step 5), not the no-live-entry NOT_READY admission covers.
    expect((await loopbackControl(env.abDir, {
      id: "file-upload-admission-b", type: "project:open", projectId: projB, projectPath: projBdir.dir, mode: "remote",
    })).ok).toBe(true);
    await resolveOnFreshAdvert(env.app, projB, {
      resolve: (app) => app.waitFor(
        (m: any) => m.type === "agent:projects" && m.projects.some((p: any) => p.projectId === projB && p.running),
        3_000,
      ),
    });

    const client = await env.app.openUploadStream({
      projectId: projB,
      fileName: "no-stream.bin",
      bytes: makePayload(16),
    });
    expect(await client.ended).toBe("refused");
    expect(client.refusal?.code).toBe("NOT_ALLOWED");
  } finally {
    await env.teardown();
    try { projBdir.cleanup(); } catch { /* Windows EBUSY teardown race */ }
  }
}, 30_000);

test("a multi-chunk loopback upload still lands byte-identical", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  let local: LocalTestClient | null = null;
  try {
    const conn: LocalConnectInfo = (await loopbackControl(env.abDir, {
      id: "file-upload-loopback", type: "project:start", projectId: env.projectId,
    })).connect;
    const messages: any[] = [];
    local = new LocalTestClient();
    local.on((m) => messages.push(m));
    await local.connect(conn);

    const payload = makePayload(CHUNK + CHUNK / 2); // 1.5 chunks → 2 chunks
    local.send(createMessage("file:upload-start", {
      projectId: env.projectId,
      requestId: "loopback-r1",
      fileName: "loopback upload.bin",
      size: payload.length,
    }));
    const ready = await waitForLocal(messages, (m) => m.type === "file:upload-ready");
    const uploadId = ready.uploadId as string;

    for (let seq = 0, off = 0; off < payload.length; seq++, off += CHUNK) {
      local.send(createMessage("file:upload-chunk", {
        uploadId, seq,
        data: payload.subarray(off, Math.min(off + CHUNK, payload.length)).toString("base64"),
      }));
      await waitForLocal(messages, (m) => m.type === "file:upload-ack" && m.seq === seq);
    }
    local.send(createMessage("file:upload-done", { uploadId }));
    const result = await waitForLocal(messages, (m) => m.type === "file:upload-result");
    expect(result.ok).toBe(true);
    expect(readFileSync(result.path as string).equals(payload)).toBe(true);
  } finally {
    local?.close();
    await env.teardown();
  }
}, 30_000);
