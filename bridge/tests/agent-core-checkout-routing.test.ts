import { afterEach, beforeEach, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, relative } from "node:path";
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

// 30s, not the 5s Bun gives a hook by default: `shutdown()` waits out a
// graceful PTY kill whose own budget IS 5s (`killAllGracefully`) and then
// drains the in-flight `git` children holding a checkout as their cwd. The
// default is therefore exactly the wrong size, and `test(..., 20000)` does not
// raise it — a hook budget is separate from the test's.
afterEach(async () => {
  // Bound before the await, never read after it. Bun does not CANCEL a hook
  // that overruns its budget, it just stops waiting: the body resumes inside
  // the next test, where the module-level `core`/`root`/`previousAbDir` have
  // already been reassigned. Read at resume, a late teardown drops that test's
  // core on the floor, deletes its checkout mid-run and restores its env —
  // which is how one slow shutdown used to fail three unrelated tests.
  const dying = core;
  const dir = root;
  const restore = previousAbDir;
  core = null;
  if (restore === undefined) delete process.env.ANTGRID_DIR;
  else process.env.ANTGRID_DIR = restore;
  try {
    await dying?.shutdown();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}, 30_000);

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

/** Drive a whole upload through one checkout and return the file it produced. */
async function uploadThrough(
  bus: MessageBus,
  sent: AbMessage[],
  checkoutId: string,
  content: string,
): Promise<string> {
  const requestId = `upload-${checkoutId}`;
  bus.dispatchInbound(createMessage("file:upload-start", {
    projectId: core!.projectId, requestId, fileName: "note.txt",
    size: Buffer.byteLength(content), checkoutId,
  }), "control", "loopback");
  const ready = await waitFor(sent, (m) =>
    m.type === "file:upload-ready" && m.requestId === requestId,
  );
  if (ready.type !== "file:upload-ready") throw new Error("upload was never ready");
  bus.dispatchInbound(createMessage("file:upload-chunk", {
    uploadId: ready.uploadId, seq: 0, data: Buffer.from(content).toString("base64"), checkoutId,
  }), "control", "loopback");
  await waitFor(sent, (m) => m.type === "file:upload-ack" && m.uploadId === ready.uploadId);
  bus.dispatchInbound(createMessage("file:upload-done", {
    uploadId: ready.uploadId, checkoutId,
  }), "control", "loopback");
  const result = await waitFor(sent, (m) =>
    m.type === "file:upload-result" && m.requestId === requestId,
  );
  expect(result).toMatchObject({ ok: true, checkoutId });
  if (result.type !== "file:upload-result" || !result.path) throw new Error("upload produced no path");
  return result.path;
}

test("a write through one checkout's runtime is invisible to the other", async () => {
  // The read tests above all write with the filesystem. This is the other
  // direction: each runtime owns its own upload manager, so a write the bridge
  // performs must land in the tree that asked for it and nowhere else.
  writeFileSync(join(root, "same.txt"), "main\n");
  await initRepo();
  const { bus, sent, checkoutId, checkoutPath } = await startWithIsolatedSession();

  const isolatedFile = await uploadThrough(bus, sent, checkoutId, "isolated\n");
  const mainFile = await uploadThrough(bus, sent, "main", "main\n");
  expect(readFileSync(isolatedFile, "utf8")).toBe("isolated\n");
  expect(readFileSync(mainFile, "utf8")).toBe("main\n");

  const isolatedRelative = relative(checkoutPath, isolatedFile);
  const mainRelative = relative(root, mainFile);
  expect(isolatedRelative.startsWith("..")).toBe(false);
  expect(mainRelative.startsWith("..")).toBe(false);
  expect(existsSync(join(root, isolatedRelative))).toBe(false);
  expect(existsSync(join(checkoutPath, mainRelative))).toBe(false);
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
  // The only test that awaits a full `shutdown()` in its BODY, so it needs the
  // same headroom the teardown hook does — the default 5s is `killAllGracefully`'s
  // own budget, leaving nothing for the git drain behind it.
}, 30_000);

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

test("a terminal snapshot request is answered by the asking checkout alone", async () => {
  await initRepo();
  const { bus, sent } = await startWithIsolatedSession();
  // cwd deliberately outside the project: on Windows a live PTY holds its own
  // cwd open and the fixture's teardown rm would hit EBUSY.
  bus.dispatchInbound(
    createMessage("terminal:start", { terminalId: "adhoc", cwd: tmpdir() }),
    "control",
    "loopback",
  );
  await waitFor(sent, (message) =>
    message.type === "terminal:started" && message.terminalId === "adhoc",
  );
  sent.length = 0;

  bus.dispatchInbound(
    createMessage("terminal:snapshot:request", { terminalId: "adhoc" }),
    "control",
    "loopback",
  );
  await waitFor(sent, (message) => message.type === "terminal:snapshot");
  // Serializing a screen is real work and every runtime sees the frame, so the
  // guard has to short-circuit before the isolated runtime does any of it —
  // otherwise the app applies whichever reply lands last.
  await new Promise((resolve) => setTimeout(resolve, 400));
  expect(sent.filter((message) => message.type === "terminal:snapshot").length).toBe(1);
});

/** Dispatch `fire` from inside the very delivery of the first `session:updated`
 *  that carries `deleting: true`, then run the isolated session's delete to
 *  completion. Dispatching from the subscriber removes the scheduler gap, so the
 *  in-flight window is hit deterministically instead of racing a real
 *  `git worktree remove`. */
async function duringIsolatedDelete(
  fixture: IsolatedFixture,
  fire: () => void,
): Promise<void> {
  const { bus, sent, checkoutId } = fixture;
  let fired = false;
  const unsubscribe = bus.subscribe({
    deliver: (message) => {
      if (fired) return;
      if (message.type !== "session:updated") return;
      if (!message.sessions.some((s) => s.checkoutId === checkoutId && s.deleting)) return;
      fired = true;
      fire();
    },
  });
  const requestId = crypto.randomUUID();
  const session = await waitFor(sent, (m) =>
    m.type === "session:updated" && m.sessions.some((s) => s.checkoutId === checkoutId),
  );
  if (session.type !== "session:updated") throw new Error("no session list");
  const sessionId = session.sessions.find((s) => s.checkoutId === checkoutId)!.id;
  sent.length = 0;
  bus.dispatchInbound(createMessage("session:delete", { requestId, sessionId }), "control", "loopback");
  const result = await waitFor(sent, (m) => m.type === "session:result" && m.requestId === requestId, 20000);
  expect(result).toMatchObject({ type: "session:result", ok: true });
  expect(fired).toBe(true);
  unsubscribe();
}

test("a checkout-variable message for a checkout whose delete is in flight is refused, not served from main", async () => {
  writeFileSync(join(root, "same.txt"), "main\n");
  await initRepo();
  const fixture = await startWithIsolatedSession();
  const { bus, sent, checkoutId } = fixture;

  await duringIsolatedDelete(fixture, () => {
    bus.dispatchInbound(createMessage("file:read", {
      projectId: core!.projectId, path: "same.txt", checkoutId,
    }), "control", "loopback");
  });

  expect(sent.find((m) => m.type === "control:result" && m.checkoutId === checkoutId)).toMatchObject({
    ok: false,
    verb: "file:read",
    error: { code: "CHECKOUT_DELETING" },
  });
  // The trap this second assertion pins: `runtimeFor` falls back to
  // `mainRuntime`, so a guard that merely skipped the prepare would have
  // answered out of MAIN's working tree — the wrong repository, silently.
  expect(sent.filter((m) => m.type === "file:content" && m.checkoutId === checkoutId)).toEqual([]);
});

test("main is unaffected while another checkout's delete is in flight", async () => {
  writeFileSync(join(root, "same.txt"), "main\n");
  await initRepo();
  const fixture = await startWithIsolatedSession();
  const { bus, sent } = fixture;

  await duringIsolatedDelete(fixture, () => {
    bus.dispatchInbound(createMessage("file:read", {
      projectId: core!.projectId, path: "same.txt", checkoutId: "main",
    }), "control", "loopback");
  });

  // The guard is per-checkout, never a stop-the-world.
  const frame = await waitFor(sent, (m) => m.type === "file:content" && m.checkoutId === "main");
  expect(frame).toMatchObject({ type: "file:content", content: "main\n" });
  expect(sent.filter((m) => m.type === "control:result" && m.checkoutId === "main")).toEqual([]);
});

/** A committed antgrid.yaml the managed checkout will read as its own. */
function commitConfig(body: string): Promise<void> {
  writeFileSync(join(root, "antgrid.yaml"), body);
  return initRepo();
}

function frameIndex(sent: AbMessage[], predicate: (message: AbMessage) => boolean): number {
  const index = sent.findIndex(predicate);
  if (index < 0) throw new Error("frame never arrived");
  return index;
}

test("a managed checkout's services wait for worktree.setup to finish", async () => {
  // Auto-starting a service against a worktree whose node_modules has not been
  // provisioned yet is a guaranteed failure the user then has to read past, so
  // the block is held from `prepareCheckoutRuntime` until setup reaches ANY
  // terminal state — `onFailure: warn` means a failed run still gets its
  // dev server.
  await commitConfig([
    "name: checkout-routing",
    "agent:",
    "  tool: claude-code",
    "services:",
    "  - name: svc",
    "    command: git --version",
    "worktree:",
    "  setup:",
    "    steps:",
    "      - name: Install dependencies",
    "        run: git --version",
  ].join("\n"));
  const { bus, sent } = await bootCore();
  const session = await createSession(bus, sent, "Isolated", "worktree");
  const checkoutId = session.checkoutId;
  // The create reply is what the app waits 15 s for, and it already carries the
  // truth: this workspace is still being provisioned.
  expect(session.setup).toMatchObject({ state: "running", pendingStart: false });

  const isServiceFrame = (message: AbMessage) =>
    "terminalId" in message && message.terminalId === "svc"
    && "checkoutId" in message && message.checkoutId === checkoutId;
  const isSettled = (message: AbMessage) =>
    message.type === "session:updated"
    && message.sessions.some((entry) =>
      entry.id === session.id && entry.setup !== undefined && entry.setup.state !== "running");

  await waitFor(sent, isServiceFrame, 20000);
  // Ordering rather than a snapshot: an undeferred block spawns inside
  // prepareCheckoutRuntime, which runs BEFORE the entry is committed — so a
  // regression puts the service ahead of the create reply, not merely early.
  const createReply = frameIndex(sent, (message) =>
    message.type === "session:result" && message.session?.id === session.id);
  expect(frameIndex(sent, isServiceFrame)).toBeGreaterThan(createReply);
  expect(frameIndex(sent, isServiceFrame)).toBeGreaterThan(frameIndex(sent, isSettled));
  // Main's own slot is untouched by the deferral: only the checkout being
  // provisioned waits.
  expect(sent.some((message) =>
    "terminalId" in message && message.terminalId === "svc"
    && "checkoutId" in message && message.checkoutId === "main")).toBe(true);
  // Releasing the services is only half the job: `agent:status` is what carries
  // services[].running to the app, and this checkout's last push happened while
  // they were still held back.
  await waitFor(sent, (message) =>
    message.type === "agent:status"
    && "checkoutId" in message && message.checkoutId === checkoutId
    && (message.services ?? []).some((service) => service.name === "svc" && service.running), 20000);
}, 20000);

/** Point the setup child at a stub that emits one step marker and lingers.
 *
 *  The runner spawns `process.execPath` under a hidden subcommand, which is the
 *  only self-invocation a compiled single-file bridge supports — so a stub in
 *  that slot is the only way to put a REAL OSC 2 title on a real setup PTY.
 *  POSIX-only: the equivalent needs a `.cmd` that can emit a bare ESC, which
 *  `cmd.exe` has no portable spelling for. The parsing itself is covered
 *  platform-independently in checkout-setup.test.ts.
 */
function withSetupStub<T>(marker: string, fn: () => Promise<T>): Promise<T> {
  const stub = join(root, "setup-stub.sh");
  writeFileSync(stub, `#!/bin/sh\nprintf '\\033]2;${marker}\\007'\nsleep 1\n`);
  chmodSync(stub, 0o755);
  const real = process.execPath;
  process.execPath = stub;
  return fn().finally(() => { process.execPath = real; });
}

test.skipIf(process.platform === "win32")(
  "a setup terminal's OSC title becomes step progress and never a session name",
  async () => {
    await commitConfig([
      "name: checkout-routing",
      "agent:",
      "  tool: claude-code",
      "worktree:",
      "  setup:",
      "    steps:",
      "      - name: Copy env files",
      "        copy: [\"antgrid.yaml\"]",
      "      - name: Install dependencies",
      "        run: git --version",
    ].join("\n"));
    const { bus, sent } = await bootCore();
    const session = await withSetupStub(
      "antgrid-setup:1/2:Install dependencies",
      () => createSession(bus, sent, "Isolated", "worktree"),
    );

    // The runner seeds step 0 before the child says anything; the marker is what
    // moves it. `suppressOscTitle` on that spawn would suppress the onTitle
    // callback itself and this transition would never arrive.
    expect(session.setup).toMatchObject({
      state: "running", stepIndex: 0, stepCount: 2, terminalId: `${session.checkoutId}:setup`,
    });
    const advanced = await waitFor(sent, (message) =>
      message.type === "session:updated"
      && message.sessions.some((entry) => entry.id === session.id && entry.setup?.stepIndex === 1),
      20000,
    );
    if (advanced.type !== "session:updated") throw new Error("no session list");
    const entry = advanced.sessions.find((candidate) => candidate.id === session.id)!;
    expect(entry.setup).toMatchObject({
      state: "running", stepIndex: 1, stepCount: 2, stepName: "Install dependencies",
    });
    // The interception happens BEFORE the namer fallback: a step marker read as
    // a conversation title would rename the session to "Install dependencies".
    expect(entry.name).toBe("Isolated");
  },
  20000,
);
