// Wave 1 of docs/file-tree-lazy-expansion-spec.md: the four listing frames'
// handler layer in agent-core.ts. file-tree.ts's own listDirectory/batch
// behavior (budgets, truncation, the path guard) is covered by
// file-tree.test.ts; this file is about the wire-facing handler — checkout
// scoping, the D-A hand-clamps (parseMessageFast validates the message TYPE
// alone, so a real inbound frame's Zod bounds/defaults never run), and the
// "always reply" contract a listing request has no backstop poll to fall
// back on if broken.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { MessageBus } from "../src/message-bus";
import { createMessage, type AbMessage, type SessionEntry } from "../src/protocol";
import { CheckoutStore } from "../src/worktrees/checkout-store";
import { setLogLevel } from "../src/logger";

setLogLevel("error");

let root: string;
let previousAbDir: string | undefined;
let core: AgentCore | null;

beforeEach(() => {
  previousAbDir = process.env.ANTGRID_DIR;
  root = mkdtempSync(join(tmpdir(), "antgrid-tree-listings-"));
  process.env.ANTGRID_DIR = join(root, "state");
  writeFileSync(join(root, "antgrid.yaml"), "name: tree-listings\n");
});

// Same 30s shape as agent-core-checkout-routing.test.ts and
// agent-core-resync-pushes.test.ts, for the same reason: shutdown() drains a
// graceful PTY kill (5s) plus in-flight git children, and a hook's own
// default budget is smaller than that.
afterEach(async () => {
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

async function waitFor(
  sent: AbMessage[],
  predicate: (message: AbMessage) => boolean,
  timeoutMs = 4000,
): Promise<AbMessage> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const found = sent.find(predicate);
    if (found) return found;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error("timed out waiting for a tree-listing frame");
}

async function git(args: string[]): Promise<void> {
  const proc = Bun.spawn(["git", ...args], { cwd: root, stdout: "ignore", stderr: "pipe" });
  const code = await proc.exited;
  if (code !== 0) throw new Error(await new Response(proc.stderr).text());
}

async function initRepo(): Promise<void> {
  await git(["init"]);
  await git(["config", "user.email", "test@antgrid.local"]);
  await git(["config", "user.name", "Antgrid Test"]);
  await git(["add", "."]);
  await git(["commit", "-m", "initial"]);
}

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

async function createSession(bus: MessageBus, sent: AbMessage[]): Promise<SessionEntry> {
  const requestId = crypto.randomUUID();
  bus.dispatchInbound(createMessage("session:create", {
    requestId, name: "Isolated", isolation: "worktree",
  }), "control", "loopback");
  const result = await waitFor(sent, (message) =>
    message.type === "session:result" && message.requestId === requestId,
  );
  if (result.type !== "session:result" || !result.session) throw new Error("session missing");
  return result.session;
}

async function checkoutPathOf(checkoutId: string): Promise<string> {
  const checkout = await new CheckoutStore(core!.abDir, core!.projectId).get(checkoutId);
  if (!checkout) throw new Error("checkout metadata missing");
  return checkout.path;
}

function childrenFrames(sent: AbMessage[], checkoutId: string): AbMessage[] {
  return sent.filter((m) => m.type === "file:tree:children" && m.checkoutId === checkoutId);
}

test("a root request answers only the asking checkout", async () => {
  await initRepo();
  const { bus, sent } = await bootCore();
  const session = await createSession(bus, sent);
  const checkoutPath = await checkoutPathOf(session.checkoutId);
  // Written AFTER the fork, each into only one working tree — a file
  // committed before the session exists in both and would prove nothing.
  writeFileSync(join(root, "main-only.txt"), "main\n");
  writeFileSync(join(checkoutPath, "isolated-only.txt"), "isolated\n");

  sent.length = 0;
  bus.dispatchInbound(createMessage("file:tree:root:request", { checkoutId: "main" }), "control", "loopback");
  bus.dispatchInbound(
    createMessage("file:tree:root:request", { checkoutId: session.checkoutId }),
    "control",
    "loopback",
  );

  const mainFrame = await waitFor(sent, (m) => m.type === "file:tree:children" && m.checkoutId === "main");
  const isolatedFrame = await waitFor(sent, (m) =>
    m.type === "file:tree:children" && m.checkoutId === session.checkoutId,
  );
  const namesOf = (m: AbMessage) =>
    m.type === "file:tree:children" ? m.listings[0]?.children.map((c) => c.name) ?? [] : [];
  expect(namesOf(mainFrame)).toContain("main-only.txt");
  expect(namesOf(mainFrame)).not.toContain("isolated-only.txt");
  expect(namesOf(isolatedFrame)).toContain("isolated-only.txt");
  expect(namesOf(isolatedFrame)).not.toContain("main-only.txt");
  // Each answer stayed on its own checkout — no cross-delivery in either
  // direction.
  expect(childrenFrames(sent, "main")).toHaveLength(1);
  expect(childrenFrames(sent, session.checkoutId)).toHaveLength(1);
});

test("a children request for 3 paths returns 3 listings", async () => {
  mkdirSync(join(root, "alpha"));
  mkdirSync(join(root, "beta"));
  mkdirSync(join(root, "gamma"));
  writeFileSync(join(root, "alpha", "a.txt"), "a\n");
  writeFileSync(join(root, "beta", "b.txt"), "b\n");
  writeFileSync(join(root, "gamma", "g.txt"), "g\n");
  const { bus, sent } = await bootCore();

  sent.length = 0;
  bus.dispatchInbound(createMessage("file:tree:children:request", {
    paths: ["alpha", "beta", "gamma"],
  }), "control", "loopback");

  const frame = await waitFor(sent, (m) => m.type === "file:tree:children");
  if (frame.type !== "file:tree:children") throw new Error("wrong frame");
  expect(frame.listings).toHaveLength(3);
  expect(frame.listings.map((l) => l.path).sort()).toEqual(["alpha", "beta", "gamma"]);
  const byPath = new Map(frame.listings.map((l) => [l.path, l]));
  expect(byPath.get("alpha")?.children.map((c) => c.name)).toEqual(["a.txt"]);
  expect(byPath.get("beta")?.children.map((c) => c.name)).toEqual(["b.txt"]);
  expect(byPath.get("gamma")?.children.map((c) => c.name)).toEqual(["g.txt"]);
});

test("an over-64 paths array is clamped, and the refused paths still answer", async () => {
  for (let i = 0; i < 80; i++) {
    mkdirSync(join(root, `dir-${i}`));
    writeFileSync(join(root, `dir-${i}`, "f.txt"), "f\n");
  }
  const { bus, sent } = await bootCore();
  const paths = Array.from({ length: 80 }, (_, i) => `dir-${i}`);

  sent.length = 0;
  // createMessage does not run Zod (D-A) — nothing before the handler would
  // ever clamp this array, so a live 80-path request is exactly what a real
  // wire frame could carry.
  bus.dispatchInbound(
    createMessage("file:tree:children:request", { paths }),
    "control",
    "loopback",
  );

  const frame = await waitFor(sent, (m) => m.type === "file:tree:children");
  if (frame.type !== "file:tree:children") throw new Error("wrong frame");
  // One listing per requested path, always: the reply carries no requestId, so
  // a path the clamp refused and never names is one the app cannot stop
  // waiting on.
  expect(frame.listings.map((l) => l.path).sort()).toEqual([...paths].sort());
  const listed = frame.listings.filter((l) => !l.missing);
  expect(listed).toHaveLength(64);
  expect(frame.listings.filter((l) => l.missing)).toHaveLength(16);
  expect(listed.every((l) => l.children.length === 1)).toBe(true);
});

test("a repeated path is listed once, not once per occurrence", async () => {
  mkdirSync(join(root, "hot"));
  writeFileSync(join(root, "hot", "a.txt"), "a\n");
  const { bus, sent } = await bootCore();

  sent.length = 0;
  bus.dispatchInbound(
    createMessage("file:tree:children:request", { paths: new Array(64).fill("hot") }),
    "control",
    "loopback",
  );

  const frame = await waitFor(sent, (m) => m.type === "file:tree:children");
  if (frame.type !== "file:tree:children") throw new Error("wrong frame");
  expect(frame.listings).toHaveLength(1);
  expect(frame.listings[0].children.map((c) => c.name)).toEqual(["a.txt"]);
});

test("a malformed paths value does not throw", async () => {
  const { bus, sent } = await bootCore();

  sent.length = 0;
  // Cast past the wire type on purpose: parseMessageFast checks the message
  // TYPE alone, so a hostile or out-of-date peer's `paths: "not-an-array"`
  // reaches the handler exactly like this.
  bus.dispatchInbound(
    createMessage("file:tree:children:request", { paths: "not-an-array" as unknown as string[] }),
    "control",
    "loopback",
  );
  const frame = await waitFor(sent, (m) => m.type === "file:tree:children");
  if (frame.type !== "file:tree:children") throw new Error("wrong frame");
  expect(frame.listings).toEqual([]);

  sent.length = 0;
  mkdirSync(join(root, "ok-dir"));
  writeFileSync(join(root, "ok-dir", "kept.txt"), "kept\n");
  bus.dispatchInbound(
    createMessage("file:tree:children:request", {
      paths: ["ok-dir", 42, null] as unknown as string[],
    }),
    "control",
    "loopback",
  );
  const second = await waitFor(sent, (m) => m.type === "file:tree:children");
  if (second.type !== "file:tree:children") throw new Error("wrong frame");
  // Non-string entries are dropped, not crashed on; the one real path is
  // genuinely listed rather than echoed back as missing.
  expect(second.listings.map((l) => l.path)).toEqual(["ok-dir"]);
  expect(second.listings[0].missing).toBeUndefined();
  expect(second.listings[0].children.map((c) => c.name)).toEqual(["kept.txt"]);
});

test("sinceSeq 0 re-lists rather than answering unchanged", async () => {
  writeFileSync(join(root, "top.txt"), "top\n");
  await initRepo();
  const { bus, sent } = await bootCore();

  sent.length = 0;
  // Nothing has been flushed on this watch root, so currentSeq() is genuinely
  // 0 — the same 0 the no-watcher fallback has to invent. A caller holding it
  // must be re-listed, or an app that pinned the fallback's empty root never
  // recovers.
  bus.dispatchInbound(
    createMessage("file:tree:root:request", { sinceSeq: 0 }),
    "control",
    "loopback",
  );

  const frame = await waitFor(sent, (m) => m.type === "file:tree:children");
  if (frame.type !== "file:tree:children") throw new Error("wrong frame");
  expect(frame.listings[0].children.map((c) => c.name)).toContain("top.txt");
  expect(sent.filter((m) => m.type === "file:tree:unchanged")).toEqual([]);
});

test("includeIgnored omitted behaves as true, explicit false as false", async () => {
  // No trailing slash: `ignore` reads `ignored-dir/` as directory-only and
  // never matches the bare name the listing tests it by, which would make this
  // pass whatever the flag did.
  writeFileSync(join(root, ".gitignore"), "ignored-dir\n");
  mkdirSync(join(root, "ignored-dir"));
  writeFileSync(join(root, "ignored-dir", "secret.txt"), "shh\n");
  await initRepo();
  const { bus, sent } = await bootCore();

  sent.length = 0;
  bus.dispatchInbound(createMessage("file:tree:root:request", {}), "control", "loopback");

  const frame = await waitFor(sent, (m) => m.type === "file:tree:children");
  if (frame.type !== "file:tree:children") throw new Error("wrong frame");
  // Omitted, not explicit false — the wire default (D10) is TRUE, so the
  // ignored directory must still be listed. `.default(true)` in the schema
  // would not have done this: parseMessageFast never runs Zod, so the handler
  // reads the absent field by hand.
  expect(frame.listings[0]?.children.map((c) => c.name) ?? []).toContain("ignored-dir");

  sent.length = 0;
  bus.dispatchInbound(
    createMessage("file:tree:root:request", { includeIgnored: false }),
    "control",
    "loopback",
  );
  const respecting = await waitFor(sent, (m) => m.type === "file:tree:children");
  if (respecting.type !== "file:tree:children") throw new Error("wrong frame");
  expect(respecting.listings[0]?.children.map((c) => c.name) ?? []).not.toContain("ignored-dir");
  // Nothing survives to be checked when the rules already respect git —
  // never a dimmed row on the includeIgnored: false path.
  expect(respecting.listings[0]?.children.every((c) => c.ignored === undefined)).toBe(true);
});

test("includeIgnored: true marks the ignored entry; its tracked sibling carries no ignored key", async () => {
  writeFileSync(join(root, ".gitignore"), "ignored-dir\n");
  mkdirSync(join(root, "ignored-dir"));
  writeFileSync(join(root, "ignored-dir", "secret.txt"), "shh\n");
  await initRepo();
  const { bus, sent } = await bootCore();

  sent.length = 0;
  bus.dispatchInbound(createMessage("file:tree:root:request", {}), "control", "loopback");

  const frame = await waitFor(sent, (m) => m.type === "file:tree:children");
  if (frame.type !== "file:tree:children") throw new Error("wrong frame");
  const children = frame.listings[0]?.children ?? [];
  const dirNode = children.find((c) => c.name === "ignored-dir");
  const yamlNode = children.find((c) => c.name === "antgrid.yaml");
  expect(dirNode?.ignored).toBe(true);
  expect(yamlNode?.ignored).toBeUndefined();
});

test(".git is absent from the tree under both includeIgnored flags, and never marked", async () => {
  await initRepo();
  const { bus, sent } = await bootCore();

  sent.length = 0;
  bus.dispatchInbound(createMessage("file:tree:root:request", {}), "control", "loopback");
  const showAll = await waitFor(sent, (m) => m.type === "file:tree:children");
  if (showAll.type !== "file:tree:children") throw new Error("wrong frame");
  expect(showAll.listings[0]?.children.map((c) => c.name) ?? []).not.toContain(".git");

  sent.length = 0;
  bus.dispatchInbound(
    createMessage("file:tree:root:request", { includeIgnored: false }),
    "control",
    "loopback",
  );
  const respecting = await waitFor(sent, (m) => m.type === "file:tree:children");
  if (respecting.type !== "file:tree:children") throw new Error("wrong frame");
  expect(respecting.listings[0]?.children.map((c) => c.name) ?? []).not.toContain(".git");
});

// includeIgnored is a per-install app setting, so two clients legitimately ask
// for different pictures of the same directory. The reply carries neither a
// requestId nor an echo of the flag, so a broadcast one is indistinguishable
// from a listing this client asked for and silently rewrites its tree.
test("a listing answers only the client that asked", async () => {
  writeFileSync(join(root, ".gitignore"), "ignored-dir\n");
  mkdirSync(join(root, "ignored-dir"));
  await initRepo();
  const { bus, sent } = await bootCore();

  const toRelay: AbMessage[] = [];
  bus.subscribe({ audience: "relay", deliver: (message) => toRelay.push(message) });

  sent.length = 0;
  bus.dispatchInbound(createMessage("file:tree:root:request", {}), "control", "loopback");
  await waitFor(sent, (m) => m.type === "file:tree:children");
  expect(toRelay.some((m) => m.type === "file:tree:children")).toBe(false);

  bus.dispatchInbound(
    createMessage("file:tree:children:request", { paths: ["ignored-dir"] }),
    "control",
    "relay",
  );
  await waitFor(toRelay, (m) => m.type === "file:tree:children");
});

test("a request for a bogus checkout id does not get main's answer", async () => {
  writeFileSync(join(root, "main-only.txt"), "main\n");
  await initRepo();
  const { bus, sent } = await bootCore();

  sent.length = 0;
  bus.dispatchInbound(createMessage("file:tree:root:request", {
    checkoutId: "does-not-exist",
  }), "control", "loopback");

  // Same pre-resolution refusal agent-core-checkout-routing.test.ts pins for
  // terminal:input: an explicit unknown checkoutId on a CHECKOUT_VARIABLE type
  // is refused before handleAbMessage ever runs, not silently served from
  // mainRuntime's fallback.
  const result = await waitFor(sent, (m) => m.type === "control:result");
  expect(result).toMatchObject({
    type: "control:result",
    checkoutId: "does-not-exist",
    ok: false,
    error: { code: "UNKNOWN_CHECKOUT" },
  });
  expect(sent.filter((m) => m.type === "file:tree:children")).toEqual([]);
});
