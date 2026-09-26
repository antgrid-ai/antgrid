// `file:upload-local` is loopback-only — a remote app uploads over its own
// `upload` stream, never this bus verb, because it names an absolute path on
// THIS machine. These tests drive the admission chokepoint from every native
// source a relay peer could reach it from, and prove copyLocal is never
// reached from any of them.
import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test";
import { mkdtempSync, readdirSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { MessageBus } from "../src/message-bus";
import { createMessage, type AbMessage } from "../src/protocol";
import { FileUploadManager } from "../src/file-upload";
import { __setRootForTest } from "../src/logger";
import {
  TerminalStreamRegistry,
  type TerminalStreamRegistryOptions,
} from "../src/peer/terminal-streams";
import type { TerminalProjectBinding, PeerSessionView } from "../src/project-streams";
import type { StreamRefusal } from "../src/peer/stream-dispatch";

/** Capture pino JSONL lines written during `fn` — the same technique
 *  `agent-core-checkout-routing.test.ts` uses to distinguish "dropped" from
 *  "not yet answered". */
async function capturingWarnings(fn: () => Promise<void>): Promise<string> {
  const lines: string[] = [];
  __setRootForTest({ write: (m: string) => { lines.push(m); } }, "warn");
  try { await fn(); } finally { __setRootForTest(process.stdout, "info"); }
  return lines.join("");
}

async function waitFor(
  sent: AbMessage[],
  predicate: (message: AbMessage) => boolean,
  timeoutMs = 3000,
): Promise<AbMessage> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const found = sent.find(predicate);
    if (found) return found;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error("timed out waiting for a frame");
}

function stagingDirOf(root: string): string {
  return join(root, ".antgrid", "uploads");
}

let root: string;
let previousAbDir: string | undefined;
let core: AgentCore | null;
let sourceDir: string;
let sourceFile: string;

beforeEach(() => {
  previousAbDir = process.env.ANTGRID_DIR;
  root = mkdtempSync(join(tmpdir(), "antgrid-upload-local-"));
  process.env.ANTGRID_DIR = join(root, "state");
  writeFileSync(join(root, "antgrid.yaml"), "name: upload-local\nagent:\n  tool: claude-code\n");
  sourceDir = mkdtempSync(join(tmpdir(), "antgrid-upload-local-source-"));
  sourceFile = join(sourceDir, "a.bin");
  writeFileSync(sourceFile, "abc");
});

afterEach(async () => {
  const dying = core;
  const dir = root;
  const srcDir = sourceDir;
  const restore = previousAbDir;
  core = null;
  if (restore === undefined) delete process.env.ANTGRID_DIR;
  else process.env.ANTGRID_DIR = restore;
  try {
    await dying?.shutdown();
  } finally {
    rmSync(dir, { recursive: true, force: true });
    rmSync(srcDir, { recursive: true, force: true });
  }
}, 30_000);

async function bootRemoteCore(): Promise<{ bus: MessageBus; sent: AbMessage[] }> {
  core = await buildAgentCore({
    folder: root,
    mode: "remote",
    remoteAccessEnabled: () => true,
    worktreeSessionsSupported: true,
    identity: { deviceId: "agent", deviceName: "agent", createdAt: new Date().toISOString() },
  });
  const bus = new MessageBus();
  const sent: AbMessage[] = [];
  bus.subscribe({ deliver: (message) => sent.push(message) });
  core.attachTransport(bus);
  core.onHandshakeComplete();
  await waitFor(sent, (message) => message.type === "agent:status");
  return { bus, sent };
}

describe("file:upload-local admission", () => {
  test("a relay-origin frame is dropped before copyLocal ever runs, and nothing is staged", async () => {
    const { bus, sent } = await bootRemoteCore();
    const copyLocal = spyOn(FileUploadManager.prototype, "copyLocal");

    const relayLog = await capturingWarnings(async () => {
      bus.dispatchInbound(createMessage("file:upload-local", {
        projectId: core!.projectId, requestId: "relay-r1", fileName: "a.bin", sourcePath: sourceFile,
      }), "control", "relay", "some-peer");
      await new Promise((resolve) => setTimeout(resolve, 200));
    });

    expect(relayLog).toContain("Dropping inbound");
    expect(sent.find((m) => m.type === "file:upload-result" && m.requestId === "relay-r1")).toBeUndefined();
    expect(sent.find((m) => m.type === "control:result" && "requestId" in m && m.requestId === "relay-r1")).toBeUndefined();
    expect(copyLocal).not.toHaveBeenCalled();
    expect(existsSync(stagingDirOf(root)) ? readdirSync(stagingDirOf(root)) : []).toEqual([]);
    copyLocal.mockRestore();
  });

  // Only session:* records ever reach a session frame — `receiveSessionRecord`
  // (peer-session-owner.ts) hands anything else to `onControlMessage`, which
  // funnels into the exact same `bus.dispatchInbound(msg, "control", "relay",
  // peerId)` call the project stream uses above, so a `file:upload-local`
  // arriving there is refused by the same chokepoint and never reaches a core.
  test("the same funnel the session stream reduces to for a non-session:* record never reaches a core", async () => {
    const { bus, sent } = await bootRemoteCore();
    const copyLocal = spyOn(FileUploadManager.prototype, "copyLocal");

    bus.dispatchInbound(createMessage("file:upload-local", {
      projectId: core!.projectId, requestId: "session-r1", fileName: "a.bin", sourcePath: sourceFile,
    }), "control", "relay", "some-peer");
    await new Promise((resolve) => setTimeout(resolve, 200));

    expect(sent.find((m) => m.type === "file:upload-result" && m.requestId === "session-r1")).toBeUndefined();
    expect(copyLocal).not.toHaveBeenCalled();
    copyLocal.mockRestore();
  });

  test("a projectId that does not match the core's own project is refused NOT_ALLOWED", async () => {
    const { bus, sent } = await bootRemoteCore();
    bus.dispatchInbound(createMessage("file:upload-local", {
      projectId: "not-this-project", requestId: "mismatch-r1", fileName: "a.bin", sourcePath: sourceFile,
    }), "control", "loopback");
    const result = await waitFor(sent, (m) => m.type === "file:upload-result" && m.requestId === "mismatch-r1");
    expect(result).toMatchObject({ type: "file:upload-result", ok: false, error: "NOT_ALLOWED" });
  });
});

describe("file:upload-local on a terminal stream", () => {
  // Mirrors terminal-streams.test.ts's fake harness, trimmed to what this one
  // needs: proving the type-specific case, not re-testing the registry itself
  // (that generic "any non-subscribe first record breaches" coverage already
  // lives there).
  const PROJECT = "proj1";
  const PEER = "peer1";

  function lengthPrefixed(body: Buffer): number[][] {
    const prefix = Buffer.alloc(4);
    prefix.writeUInt32BE(body.length);
    return [Array.from(prefix), Array.from(body)];
  }

  function createFakeStream() {
    const resetCalls: bigint[] = [];
    const stopCalls: bigint[] = [];
    const recvQueue: number[][] = [];
    const waiters: Array<{ resolve: (v: number[]) => void; reject: (e: unknown) => void }> = [];
    function pump(): void {
      while (waiters.length && recvQueue.length) waiters.shift()!.resolve(recvQueue.shift()!);
    }
    const send = {
      writeAll: async () => {},
      setPriority: async () => {},
      reset: async (code: bigint) => { resetCalls.push(code); },
      finish: async () => {},
    };
    const recv = {
      readExact: () => new Promise<number[]>((resolve, reject) => { waiters.push({ resolve, reject }); pump(); }),
      read: () => new Promise<number[]>((resolve, reject) => { waiters.push({ resolve, reject }); pump(); }),
      stop: async (code: bigint) => { stopCalls.push(code); },
    };
    return {
      stream: { send, recv }, resetCalls, stopCalls,
      pushRecord(msg: AbMessage | Record<string, unknown>): void {
        for (const chunk of lengthPrefixed(Buffer.from(JSON.stringify(msg), "utf8"))) recvQueue.push(chunk);
        pump();
      },
    };
  }

  function fakeBinding() {
    const dispatched: Array<{ msg: AbMessage; peerId: string }> = [];
    const binding: TerminalProjectBinding = {
      hasOpenStream: () => true,
      refusalFor: () => null,
      dispatch: (msg, peerId) => { dispatched.push({ msg, peerId }); return true; },
    };
    return { binding, dispatched };
  }

  function makeRegistry(bindings: Map<string, TerminalProjectBinding>, cataloged: Set<string>) {
    const opts: TerminalStreamRegistryOptions = {
      projectCataloged: (id) => cataloged.has(id),
      projectBinding: (id) => bindings.get(id) ?? null,
      peerSession: () => null as PeerSessionView | null,
      retirePeer: () => {},
    };
    return new TerminalStreamRegistry(opts);
  }

  function flush(): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, 0));
  }

  test("file:upload-local as the first record is refused by the terminal-stream allowlist, and never reaches the project binding", async () => {
    const bindings = new Map<string, TerminalProjectBinding>();
    const cataloged = new Set<string>([PROJECT]);
    const { binding, dispatched } = fakeBinding();
    bindings.set(PROJECT, binding);
    const registry = makeRegistry(bindings, cataloged);

    const fake = createFakeStream();
    const open = { kind: "terminal" as const, projectId: PROJECT, checkoutId: "main", requestId: crypto.randomUUID() };
    const admission = { peerId: PEER, open, stream: fake.stream, authorized: () => true };
    registry.handler(admission);

    fake.pushRecord(createMessage("file:upload-local", {
      projectId: PROJECT, requestId: "r1", fileName: "a.bin", sourcePath: "/tmp/a.bin",
    }));
    await flush();

    expect(dispatched).toEqual([]); // never reached the project binding, so never reaches copyLocal
    expect(fake.resetCalls.length).toBe(1);
    expect(fake.stopCalls.length).toBe(1);
  });
});
