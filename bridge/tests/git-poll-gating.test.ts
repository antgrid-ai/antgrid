import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { MessageBus } from "../src/message-bus";
import { createMessage, type AbMessage, type SessionEntry } from "../src/protocol";
import { CheckoutStore } from "../src/worktrees/checkout-store";
import { GIT_POLL_TIERS } from "../src/git-poll-cadence";

/** Base poll period these tests run the core on. The backoff ladder is
 *  expressed in multiples of it, so every window below is written in base
 *  periods rather than in milliseconds. Large enough that one cycle's git
 *  children settle well inside a tick on Windows, where each `git` costs two
 *  processes. */
const BASE_MS = 250;

let root: string;
let previousAbDir: string | undefined;
let core: AgentCore | null;

beforeEach(() => {
  previousAbDir = process.env.ANTGRID_DIR;
  root = mkdtempSync(join(tmpdir(), "antgrid-git-poll-"));
  process.env.ANTGRID_DIR = join(root, "state");
  writeFileSync(join(root, "antgrid.yaml"), "name: git-poll\nagent:\n  tool: claude-code\n");
  writeFileSync(join(root, "tracked.txt"), "one\n");
});

// 30s for the reason `agent-core-checkout-routing.test.ts` gives: `shutdown()`
// drains the in-flight `git` children still holding a checkout as their cwd,
// which is far outside Bun's 5s default hook budget.
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

async function git(args: string[], cwd = root): Promise<void> {
  const proc = Bun.spawn(["git", ...args], { cwd, stdout: "ignore", stderr: "pipe" });
  const code = await proc.exited;
  if (code !== 0) throw new Error(await new Response(proc.stderr).text());
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function waitFor(
  sent: AbMessage[],
  predicate: (message: AbMessage) => boolean,
  timeoutMs = 5000,
): Promise<AbMessage> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const found = sent.find(predicate);
    if (found) return found;
    await sleep(10);
  }
  throw new Error("timed out waiting for frame");
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
    gitPollBaseMs: BASE_MS,
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

async function createIsolatedSession(
  bus: MessageBus,
  sent: AbMessage[],
): Promise<SessionEntry> {
  const requestId = crypto.randomUUID();
  bus.dispatchInbound(createMessage("session:create", {
    requestId, name: "Isolated", isolation: "worktree",
  }), "control", "loopback");
  const result = await waitFor(sent, (message) =>
    message.type === "session:result" && message.requestId === requestId,
  );
  if (result.type !== "session:result" || !result.session) throw new Error("session missing");
  expect(result.ok).toBe(true);
  return result.session;
}

/** Every `git:status` this checkout has pushed since `from`. */
function statusesFor(sent: AbMessage[], checkoutId: string, from: number): AbMessage[] {
  return sent.slice(from).filter((m) => m.type === "git:status" && m.checkoutId === checkoutId);
}

/** Restart the checkout's cadence ladder at a known instant. The tree-snapshot
 *  request is a non-poll trigger, so it resets the cadence WITHOUT marking the
 *  checkout attended — which is exactly the phase reference these windows are
 *  measured from. */
function restartLadder(bus: MessageBus, checkoutId: string): void {
  bus.dispatchInbound(
    createMessage("file:tree:snapshot:request", { checkoutId }),
    "control",
    "loopback",
  );
}

// Ticks (counted from a cadence reset) at which the backstop actually runs.
// The first poll is one tick after the reset; each later one sits a full tier
// beyond its predecessor, where the tier is the one that poll's own result
// stepped the ladder to. Derived rather than written out, so a change to the
// ladder moves these windows with it.
const POLL_TICKS = GIT_POLL_TIERS.reduce<number[]>(
  (acc, tier, i) => [...acc, i === 0 ? 1 : acc[i - 1]! + tier],
  [],
);
/** The last poll before the cadence sits at its slowest tier. */
const SETTLED_TICK = POLL_TICKS[POLL_TICKS.length - 2]!;
/** The first poll of that slowest tier — nothing may run between the two. */
const NEXT_POLL_TICK = POLL_TICKS[POLL_TICKS.length - 1]!;

test(
  "an unattached checkout backs off, and focusing it delivers what the poll withheld",
  async () => {
    await initRepo();
    const { bus, sent } = await bootCore();
    const session = await createIsolatedSession(bus, sent);
    const checkoutId = session.checkoutId;
    const checkout = await new CheckoutStore(core!.abDir, core!.projectId).get(checkoutId);
    if (!checkout) throw new Error("checkout metadata missing");

    // A worktree change the WATCHER can see, so the baseline the poll compares
    // against already holds it. Everything after this point is index-only.
    writeFileSync(join(checkout.path, "tracked.txt"), "two\n");
    await waitFor(sent, (m) =>
      m.type === "git:status" && m.checkoutId === checkoutId
      && m.files.some((f) => f.path === "tracked.txt" && !f.staged),
    );

    // Phase reference: the ladder restarts here, so the last climbing poll has
    // run by tick SETTLED_TICK and the next one cannot come before
    // NEXT_POLL_TICK.
    restartLadder(bus, checkoutId);
    // Two ticks past the settling poll, and the silence window stops two short
    // of the next one: timer jitter over twenty-odd ticks is real, and the
    // assertion is about the eight ungated polls inside the window, not about
    // the exact instant either boundary poll lands.
    await sleep(BASE_MS * (SETTLED_TICK + 2));

    // `git add` writes the index alone — no file in the checkout moves, so the
    // watcher's ignore rules exclude it and the backstop poll is the ONLY thing
    // that could notice. That is what makes this a test of the poll.
    const mark = sent.length;
    await git(["add", "tracked.txt"], checkout.path);
    // Stop FOUR ticks short of the next poll, not two. The margin is the whole
    // point of the next assertion: it is what lets a bounded wait distinguish
    // the forced refresh from the backstop poll rather than accepting either.
    await sleep(BASE_MS * (NEXT_POLL_TICK - SETTLED_TICK - 6));
    expect(statusesFor(sent, checkoutId, mark)).toEqual([]);

    // The unfocus→focus edge is not a re-establish, so nothing else re-pulls:
    // without the forced refresh the user reads a snapshot up to a full slow
    // tier old.
    bus.dispatchInbound(
      createMessage("session:focus", { sessionId: session.id }),
      "control",
      "loopback",
    );
    // Bounded at two ticks, deliberately. The backstop poll is four ticks away,
    // so a push inside this window can only have come from the focus edge —
    // with the default timeout this assertion passed with `refreshFocusedCheckout`
    // deleted, which made it a test of the poll it was written to rule out.
    const staged = await waitFor(sent, (m) =>
      m.type === "git:status" && m.checkoutId === checkoutId
      && m.files.some((f) => f.path === "tracked.txt" && f.staged),
      BASE_MS * 2,
    );
    expect(staged.type).toBe("git:status");

    // Attended, so the cadence stays on the base period: the next index-only
    // change is picked up by the poll itself, well inside a couple of ticks.
    const afterFocus = sent.length;
    await git(["reset", "--", "tracked.txt"], checkout.path);
    const deadline = Date.now() + BASE_MS * 4;
    let unstaged: AbMessage | undefined;
    while (Date.now() < deadline && !unstaged) {
      // From the mark, never `sent.find`: the pre-`git add` snapshot already
      // reported this path unstaged, and matching that one would pass whether
      // or not the poll ever ran again.
      unstaged = statusesFor(sent, checkoutId, afterFocus).find((m) =>
        m.type === "git:status" && m.files.some((f) => f.path === "tracked.txt" && !f.staged),
      );
      if (!unstaged) await sleep(10);
    }
    expect(unstaged?.type).toBe("git:status");
  },
  60_000,
);

test("focusing a session whose checkout is gone refreshes nothing for it", async () => {
  await initRepo();
  const { bus, sent } = await bootCore();
  const session = await createIsolatedSession(bus, sent);
  const checkoutId = session.checkoutId;
  const gone = await new CheckoutStore(core!.abDir, core!.projectId).get(checkoutId);
  if (!gone) throw new Error("checkout metadata missing");

  const requestId = crypto.randomUUID();
  bus.dispatchInbound(createMessage("session:delete", {
    requestId, sessionId: session.id,
  }), "control", "loopback");
  const deleted = await waitFor(sent, (m) =>
    m.type === "session:result" && m.requestId === requestId, 20_000,
  );
  expect(deleted).toMatchObject({ type: "session:result", ok: true });

  // The focus-edge refresh is the ONE new site that spawns git, so it is the
  // one place the teardown wait can be widened: `awaitGitRefreshes` snapshots
  // the pending set, and a `git` child cwd'd inside a checkout Git is removing
  // is a Windows sharing violation that strands the session undeletable.
  const mark = sent.length;
  bus.dispatchInbound(
    createMessage("session:focus", { sessionId: session.id }),
    "control",
    "loopback",
  );
  await sleep(BASE_MS * 4);
  expect(statusesFor(sent, checkoutId, mark)).toEqual([]);

  // The silence above is necessary but on its own vacuous: once the sweep has
  // finished, the runtime is out of the registry and nothing could push whether
  // or not the disposed guard exists. THIS is the invariant with teeth — a git
  // child still cwd'd inside the checkout is a Windows sharing violation, and
  // the worktree it strands is one no later delete can remove.
  expect(existsSync(gone.path)).toBe(false);
}, 60_000);

test(
  "a background/foreground inside one connection leaves the checkout attended",
  async () => {
    await initRepo();
    const { bus, sent } = await bootCore();
    const session = await createIsolatedSession(bus, sent);
    const checkoutId = session.checkoutId;
    const checkout = await new CheckoutStore(core!.abDir, core!.projectId).get(checkoutId);
    if (!checkout) throw new Error("checkout metadata missing");

    writeFileSync(join(checkout.path, "tracked.txt"), "two\n");
    await waitFor(sent, (m) =>
      m.type === "git:status" && m.checkoutId === checkoutId
      && m.files.some((f) => f.path === "tracked.txt" && !f.staged),
    );

    // Phase reference, and the state the user is actually in: a session on
    // screen, so the cadence sits on the base period.
    bus.dispatchInbound(
      createMessage("session:focus", { sessionId: session.id }),
      "control",
      "loopback",
    );

    // The ONLY frame a background/foreground inside one live connection sends.
    // `resyncFocus` rides a stream re-establish, so no `session:focus` follows
    // the resume — if the pause edge drops the focus without the resume edge
    // putting it back, the checkout the user is sitting on reads as unattended
    // from here on.
    bus.dispatchInbound(
      createMessage("client:focus-state", { paused: true }),
      "control",
      "loopback",
    );
    // Long enough for the ladder to climb to its slowest tier while paused, so
    // the next backstop poll is a full slow tier away rather than a tick away.
    await sleep(BASE_MS * (SETTLED_TICK + 2));

    bus.dispatchInbound(
      createMessage("client:focus-state", { paused: false }),
      "control",
      "loopback",
    );

    // Index-only, so the watcher cannot see it and the window is far shorter
    // than the tier the poll would still be on: only a cadence put back on the
    // base period can report this in time.
    const mark = sent.length;
    await git(["add", "tracked.txt"], checkout.path);
    const deadline = Date.now() + BASE_MS * 4;
    let staged: AbMessage | undefined;
    while (Date.now() < deadline && !staged) {
      staged = statusesFor(sent, checkoutId, mark).find((m) =>
        m.type === "git:status" && m.files.some((f) => f.path === "tracked.txt" && f.staged),
      );
      if (!staged) await sleep(10);
    }
    expect(staged?.type).toBe("git:status");
  },
  60_000,
);
