import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { MessageBus } from "../src/message-bus";
import { createMessage, type AbMessage, type SessionEntry } from "../src/protocol";
import { CheckoutStore } from "../src/worktrees/checkout-store";

let root: string;
let previousAbDir: string | undefined;
let core: AgentCore | null;

beforeEach(() => {
  previousAbDir = process.env.ANTGRID_DIR;
  root = mkdtempSync(join(tmpdir(), "antgrid-checkout-routing-"));
  process.env.ANTGRID_DIR = join(root, "state");
  writeFileSync(join(root, "antgrid.yaml"), "name: checkout-routing\nagent:\n  tool: claude-code\n");
});

afterEach(async () => {
  await core?.shutdown();
  core = null;
  if (previousAbDir === undefined) delete process.env.ANTGRID_DIR;
  else process.env.ANTGRID_DIR = previousAbDir;
  rmSync(root, { recursive: true, force: true });
});

test("explicit unknown checkout is rejected without falling back to main", async () => {
  core = await buildAgentCore({
    folder: root,
    mode: "local",
    identity: { deviceId: "agent", deviceName: "agent", createdAt: new Date().toISOString() },
  });
  const bus = new MessageBus();
  const sent: AbMessage[] = [];
  bus.subscribe({ deliver: (message) => sent.push(message) });
  core.attachTransport(bus);
  bus.dispatchInbound(createMessage("terminal:input", {
    terminalId: "any",
    data: "x",
    checkoutId: "does-not-exist",
  }), "control", "loopback");

  for (let i = 0; i < 100 && !sent.some((m) => m.type === "control:result"); i++) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  const result = sent.find((m) => m.type === "control:result");
  expect(result).toMatchObject({
    type: "control:result",
    checkoutId: "does-not-exist",
    ok: false,
    error: { code: "UNKNOWN_CHECKOUT" },
  });
});

async function git(args: string[]): Promise<void> {
  const proc = Bun.spawn(["git", ...args], { cwd: root, stdout: "ignore", stderr: "pipe" });
  const code = await proc.exited;
  if (code !== 0) throw new Error(await new Response(proc.stderr).text());
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
  throw new Error("timed out waiting for checkout frame");
}

async function initRepo(): Promise<void> {
  await git(["init"]);
  await git(["config", "user.email", "test@antgrid.local"]);
  await git(["config", "user.name", "Antgrid Test"]);
  await git(["add", "."]);
  await git(["commit", "-m", "initial"]);
}

interface IsolatedFixture {
  bus: MessageBus;
  sent: AbMessage[];
  checkoutId: string;
  checkoutPath: string;
}

/** Boot a core over the committed repo, attached to a fresh bus. */
async function bootCore(): Promise<{ bus: MessageBus; sent: AbMessage[] }> {
  core = await buildAgentCore({
    folder: root,
    mode: "local",
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

async function createSession(
  bus: MessageBus,
  sent: AbMessage[],
  name: string,
  isolation?: "worktree",
): Promise<SessionEntry> {
  const requestId = crypto.randomUUID();
  bus.dispatchInbound(createMessage("session:create", {
    requestId, name, ...(isolation ? { isolation } : {}),
  }), "control", "loopback");
  const result = await waitFor(sent, (message) =>
    message.type === "session:result" && message.requestId === requestId,
  );
  expect(result).toMatchObject({ type: "session:result", ok: true });
  if (result.type !== "session:result" || !result.session) throw new Error("session missing");
  return result.session;
}

async function checkoutPathOf(checkoutId: string): Promise<string> {
  const checkout = await new CheckoutStore(core!.abDir, core!.projectId).get(checkoutId);
  if (!checkout) throw new Error("checkout metadata missing");
  return checkout.path;
}

/** Boot a core over the committed repo and create one isolated session. */
async function startWithIsolatedSession(): Promise<IsolatedFixture> {
  const { bus, sent } = await bootCore();
  const session = await createSession(bus, sent, "Isolated", "worktree");
  return {
    bus, sent,
    checkoutId: session.checkoutId,
    checkoutPath: await checkoutPathOf(session.checkoutId),
  };
}

test("main and managed runtimes read the same relative file independently", async () => {
  writeFileSync(join(root, "same.txt"), "main\n");
  await initRepo();
  const { bus, sent, checkoutId, checkoutPath } = await startWithIsolatedSession();
  writeFileSync(join(checkoutPath, "same.txt"), "isolated\n");

  sent.length = 0;
  bus.dispatchInbound(createMessage("file:read", {
    projectId: core!.projectId, path: "same.txt", checkoutId: "main",
  }), "control", "loopback");
  bus.dispatchInbound(createMessage("file:read", {
    projectId: core!.projectId, path: "same.txt", checkoutId,
  }), "control", "loopback");
  const main = await waitFor(sent, (message) =>
    message.type === "file:content" && message.checkoutId === "main",
  );
  const isolated = await waitFor(sent, (message) =>
    message.type === "file:content" && message.checkoutId === checkoutId,
  );
  expect(main).toMatchObject({ type: "file:content", content: "main\n" });
  expect(isolated).toMatchObject({ type: "file:content", content: "isolated\n" });
});

test("two isolated sessions edit the same relative file without seeing each other", async () => {
  writeFileSync(join(root, "same.txt"), "main\n");
  await initRepo();
  const { bus, sent } = await bootCore();
  const one = await createSession(bus, sent, "One", "worktree");
  const two = await createSession(bus, sent, "Two", "worktree");
  expect(one.checkoutId).not.toBe(two.checkoutId);

  const pathOne = await checkoutPathOf(one.checkoutId);
  const pathTwo = await checkoutPathOf(two.checkoutId);
  expect(pathOne).not.toBe(pathTwo);
  writeFileSync(join(pathOne, "same.txt"), "one\n");
  writeFileSync(join(pathTwo, "same.txt"), "two\n");

  sent.length = 0;
  for (const checkoutId of [one.checkoutId, two.checkoutId, "main"]) {
    bus.dispatchInbound(createMessage("file:read", {
      projectId: core!.projectId, path: "same.txt", checkoutId,
    }), "control", "loopback");
  }
  const read = async (checkoutId: string) => {
    const frame = await waitFor(sent, (m) =>
      m.type === "file:content" && m.checkoutId === checkoutId,
    );
    return frame.type === "file:content" ? frame.content : null;
  };
  expect(await read(one.checkoutId)).toBe("one\n");
  expect(await read(two.checkoutId)).toBe("two\n");
  expect(await read("main")).toBe("main\n");
});

test("git branches and search follow the focused checkout, not main", async () => {
  writeFileSync(join(root, "same.txt"), "main\n");
  await initRepo();
  const { bus, sent, checkoutId, checkoutPath } = await startWithIsolatedSession();
  // Only the isolated checkout holds the needle.
  writeFileSync(join(checkoutPath, "isolated-only.txt"), "needle\n");

  sent.length = 0;
  for (const id of [checkoutId, "main"]) {
    bus.dispatchInbound(createMessage("git:list-branches", {
      projectId: core!.projectId, checkoutId: id,
    }), "control", "loopback");
    bus.dispatchInbound(createMessage("file:search", {
      projectId: core!.projectId, requestId: `q-${id}`, query: "needle", caseSensitive: false, regex: false, wholeWord: false, checkoutId: id,
    }), "control", "loopback");
  }

  const currentBranchOf = async (id: string) => {
    const frame = await waitFor(sent, (m) =>
      m.type === "git:branches" && m.checkoutId === id,
    );
    return frame.type === "git:branches" ? frame.current : null;
  };
  // Each checkout is on its own branch — that IS the isolation.
  expect(await currentBranchOf(checkoutId)).toMatch(/^antgrid\//);
  expect(await currentBranchOf("main")).not.toMatch(/^antgrid\//);

  const hitsFor = async (id: string) => {
    await waitFor(sent, (m) => m.type === "file:search-done" && m.requestId === `q-${id}`);
    return sent.filter((m) => m.type === "file:search-result" && m.requestId === `q-${id}`);
  };
  expect(await hitsFor(checkoutId)).not.toHaveLength(0);
  expect(await hitsFor("main")).toHaveLength(0);
});

test("a bridge restart restores checkout bindings and their file routing", async () => {
  writeFileSync(join(root, "same.txt"), "main\n");
  await initRepo();
  const first = await startWithIsolatedSession();
  writeFileSync(join(first.checkoutPath, "same.txt"), "isolated\n");
  await core!.shutdown();
  core = null;

  // Same folder, same ANTGRID_DIR: the checkout store and session store are the
  // only things carrying the binding across the restart.
  const { bus, sent } = await bootCore();
  const listRequestId = crypto.randomUUID();
  bus.dispatchInbound(
    createMessage("session:list", { requestId: listRequestId }),
    "control",
    "loopback",
  );
  const restored = await waitFor(sent, (m) =>
    m.type === "session:list:result" && m.requestId === listRequestId,
  );
  const entries = restored.type === "session:list:result" ? restored.sessions : [];
  expect(entries).toHaveLength(1);
  expect(entries[0]).toMatchObject({
    checkoutId: first.checkoutId,
    checkoutKind: "managed-worktree",
    checkoutState: "ready",
  });

  sent.length = 0;
  bus.dispatchInbound(createMessage("file:read", {
    projectId: core!.projectId, path: "same.txt", checkoutId: first.checkoutId,
  }), "control", "loopback");
  const frame = await waitFor(sent, (m) =>
    m.type === "file:content" && m.checkoutId === first.checkoutId,
  );
  expect(frame).toMatchObject({ type: "file:content", content: "isolated\n" });
});

test("a configured terminal in a managed checkout is attributed to that checkout", async () => {
  // The service must be committed: the managed checkout reads its own copy of
  // antgrid.yaml, so both runtimes end up with a `svc` slot of the same name.
  writeFileSync(
    join(root, "antgrid.yaml"),
    "name: checkout-routing\nagent:\n  tool: claude-code\nservices:\n  - name: svc\n    command: git --version\n",
  );
  await initRepo();
  const { sent, checkoutId } = await startWithIsolatedSession();

  const framesFor = (id: string) =>
    sent.filter((message) => "terminalId" in message && message.terminalId === id);
  await waitFor(sent, (message) =>
    "terminalId" in message
    && message.terminalId === "svc"
    && "checkoutId" in message
    && message.checkoutId === checkoutId,
  );
  // The namespaced id is bridge-internal plumbing; it must never reach the wire.
  expect(framesFor(`${checkoutId}:svc`)).toEqual([]);
  // ...and main's own slot keeps its own attribution.
  expect(framesFor("svc").some((message) =>
    "checkoutId" in message && message.checkoutId === "main",
  )).toBe(true);
});
