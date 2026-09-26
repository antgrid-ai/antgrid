import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { createHash } from "node:crypto";
import { readFileSync, existsSync, readdirSync, mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { setupTestEnv, type TestEnv } from "../helpers/harness";
import { createMessage } from "../../bridge/src/protocol";
import { createTestProject } from "../helpers/fixtures";
import { computeProjectId } from "../../bridge/src/project-id";
import { readHostFile } from "../../bridge/src/host-discovery";
import { LocalTestClient, type LocalConnectInfo } from "../helpers/local-client";
import { firstProjectStream, resolveOnFreshAdvert } from "../support/stream";

// Remote uploads ride their own `upload` QUIC stream (docs/protocol/peer-session.md
// §1e). `file:upload-local` is the loopback-only counterpart: the desktop app on
// the same machine names an absolute local path and the bridge copies it into the
// same staging directory the `upload` stream uses.

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

  test("a relay-origin file:upload-local is dropped: no result follows and nothing is staged", async () => {
    const srcDir = mkdtempSync(join(tmpdir(), "antgrid-eval-upload-src-"));
    const sourcePath = join(srcDir, "dropped.bin");
    writeFileSync(sourcePath, makePayload(16));
    try {
      env.app.sendOnStream(streamId, createMessage("file:upload-local", {
        projectId: env.projectId,
        requestId: "eval-relay-origin-dropped",
        fileName: "dropped.bin",
        sourcePath,
      }));
      await expect(
        env.app.waitForStreamAbType(streamId, "file:upload-result", 2_000),
      ).rejects.toThrow();

      const uploadsDir = join(env.projectDir, ".antgrid", "uploads");
      const staged = existsSync(uploadsDir)
        ? readdirSync(uploadsDir).filter((name) => name.includes("dropped"))
        : [];
      expect(staged).toEqual([]);
    } finally {
      rmSync(srcDir, { recursive: true, force: true });
    }
  }, 10_000);
});

test("an upload with no open project stream on this peer is refused NOT_ALLOWED", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  const projBdir = createTestProject("basic", { "__RELAY_URL__": env.relay.url.replace(/\/ws$/, "") });
  try {
    const projB = computeProjectId(projBdir.dir);
    // Running (mode:"remote", never stopped) — a live entry exists, so the
    // refusal is the peer-scoped "no open project stream for THIS peer" check,
    // not the no-live-entry NOT_READY admission covers.
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

test("a loopback file:upload-local lands byte-identical", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  let local: LocalTestClient | null = null;
  const srcDir = mkdtempSync(join(tmpdir(), "antgrid-eval-upload-src-"));
  try {
    const conn: LocalConnectInfo = (await loopbackControl(env.abDir, {
      id: "file-upload-loopback", type: "project:start", projectId: env.projectId,
    })).connect;
    const messages: any[] = [];
    local = new LocalTestClient();
    local.on((m) => messages.push(m));
    await local.connect(conn);

    // Over 512 KiB and not aligned to any slice/chunk boundary. `.png` puts it
    // through the renderable-binary branch of `readFile` (bridge/src/file-tree.ts)
    // so the round trip below gets the bytes back as base64 rather than the
    // no-viewer "Binary file" refusal a plain `.bin` extension would hit.
    const payload = makePayload(600 * 1024 + 7);
    const sourcePath = join(srcDir, "loopback-upload.png");
    writeFileSync(sourcePath, payload);

    local.send(createMessage("file:upload-local", {
      projectId: env.projectId,
      requestId: "loopback-r1",
      fileName: "loopback-upload.png",
      sourcePath,
    }));
    const result = await waitForLocal(messages, (m) => m.type === "file:upload-result");
    expect(result.ok).toBe(true);

    local.send(createMessage("file:read", {
      projectId: env.projectId,
      path: result.relPath as string,
    }));
    const content = await waitForLocal(messages, (m) => m.type === "file:content");
    expect(content.encoding).toBe("base64");
    expect(Buffer.from(content.content as string, "base64").equals(payload)).toBe(true);
  } finally {
    local?.close();
    await env.teardown();
    rmSync(srcDir, { recursive: true, force: true });
  }
}, 30_000);
