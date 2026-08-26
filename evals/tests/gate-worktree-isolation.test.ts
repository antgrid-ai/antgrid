// Task 13 end-to-end gates for isolated (managed-worktree) sessions, over a
// real relay with a real bridge process.
//
// What these cover that the bridge unit tests cannot: the frames actually cross
// the E2E stream, so a checkout id that failed to survive sealing or stream
// muxing shows up here and nowhere else.
//
// The app-side capability gate is NOT one of them: this harness's app client
// always advertises `checkoutRouting`, so the refusal branch is unreachable
// from here. `bridge/tests/worktree-remote-security.test.ts` pins that.
import { expect, test } from "bun:test";
import { existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { setupTestEnv } from "../helpers/harness";
import { createMessage, type AbMessage, type SessionEntry } from "../../bridge/src/protocol";
import { bindFirstProject } from "../support/stream";

/** The slice of the harness's app client these rows drive. */
interface StreamApp {
  sendOnStream(id: string, m: AbMessage): void;
  waitFor(p: (m: any) => boolean, t?: number): Promise<any>;
}

async function git(cwd: string, args: string[]): Promise<void> {
  const proc = Bun.spawn(["git", ...args], { cwd, stdout: "ignore", stderr: "pipe" });
  if (await proc.exited !== 0) throw new Error(await new Response(proc.stderr).text());
}

/** The eval fixture project is a plain folder; isolation needs a repository. */
async function initRepo(dir: string): Promise<void> {
  await git(dir, ["init"]);
  await git(dir, ["config", "user.email", "eval@antgrid.local"]);
  await git(dir, ["config", "user.name", "Antgrid Eval"]);
  await git(dir, ["add", "."]);
  await git(dir, ["commit", "-m", "initial"]);
}

async function createIsolated(
  app: StreamApp,
  streamId: string,
  name: string,
  command?: string,
): Promise<SessionEntry> {
  const requestId = `create-${name}`;
  const replyP = app.waitFor(
    (m: any) => m.type === "session:result" && m.requestId === requestId,
    15_000,
  );
  app.sendOnStream(streamId, createMessage("session:create", {
    requestId, name, isolation: "worktree", command,
  }));
  const reply = await replyP;
  expect(reply.ok).toBe(true);
  expect(reply.session).toBeDefined();
  return reply.session as SessionEntry;
}

test("isolated sessions get distinct checkouts and route file reads to them", async () => {
  const env = await setupTestEnv({ fixtureName: "basic", prepareProject: initRepo });
  try {
    const { streamId } = await bindFirstProject(env.app, env.projectId);

    const one = await createIsolated(env.app, streamId, "one");
    const two = await createIsolated(env.app, streamId, "two");

    // Identity first: the app is told which checkout each session owns, and the
    // two are genuinely different working trees on different branches.
    expect(one.checkoutKind).toBe("managed-worktree");
    expect(two.checkoutKind).toBe("managed-worktree");
    expect(one.checkoutId).not.toBe(two.checkoutId);
    expect(one.checkoutBranch).toMatch(/^antgrid\//);
    expect(two.checkoutBranch).not.toBe(one.checkoutBranch);
    expect(one.checkoutState).toBe("ready");

    // The wire never carries a path — the app knows only the checkout id.
    expect(JSON.stringify(one)).not.toContain(env.projectDir);

    // Reading the same relative path on three checkouts must reach three
    // different files. README.md is committed, so all three start identical;
    // asserting on the routing means asserting each answer is stamped with the
    // checkout that was asked, and that an unknown id is refused outright.
    const read = async (checkoutId: string) => {
      const replyP = env.app.waitFor(
        (m: any) =>
          (m.type === "file:content" || m.type === "control:result")
          && m.checkoutId === checkoutId,
        15_000,
      );
      env.app.sendOnStream(streamId, createMessage("file:read", {
        projectId: env.projectId, path: "README.md", checkoutId,
      }));
      return replyP;
    };

    for (const checkoutId of ["main", one.checkoutId, two.checkoutId]) {
      const frame = await read(checkoutId);
      expect(frame.type).toBe("file:content");
      expect(frame.checkoutId).toBe(checkoutId);
      expect(frame.content).toContain("Eval Test Project");
    }

    const refused = await read("checkout-that-does-not-exist");
    expect(refused.type).toBe("control:result");
    expect(refused.ok).toBe(false);
    expect(refused.error?.code).toBe("UNKNOWN_CHECKOUT");

    await env.app.disconnect();
  } finally {
    await env.teardown();
  }
}, 120_000);

test("concurrent in-flight requests across checkouts stay correctly attributed", async () => {
  const env = await setupTestEnv({ fixtureName: "basic", prepareProject: initRepo });
  try {
    const { streamId } = await bindFirstProject(env.app, env.projectId);
    const one = await createIsolated(env.app, streamId, "one");
    const two = await createIsolated(env.app, streamId, "two");

    // Two clients focusing different checkouts show up on the wire as
    // interleaved requests on one project stream. Fire them all before reading
    // any answer, so nothing can pass by accident of request/response pairing.
    const checkouts = ["main", one.checkoutId, two.checkoutId, one.checkoutId, "main"];
    const pending = checkouts.map((checkoutId, i) => ({
      checkoutId,
      reply: env.app.waitFor(
        (m: any) =>
          m.type === "git:branches" && m.checkoutId === checkoutId && m._streamId === streamId,
        20_000,
      ),
    }));
    for (const { checkoutId } of pending) {
      env.app.sendOnStream(streamId, createMessage("git:list-branches", {
        projectId: env.projectId, checkoutId,
      }));
    }

    const branchByCheckout = new Map<string, string>();
    for (const { checkoutId, reply } of pending) {
      const frame = await reply;
      expect(frame.checkoutId).toBe(checkoutId);
      const seen = branchByCheckout.get(checkoutId);
      if (seen) expect(frame.current).toBe(seen);
      else branchByCheckout.set(checkoutId, frame.current);
    }

    // Each checkout is on its own branch, and main is on none of theirs — the
    // answers were routed, not echoed.
    expect(branchByCheckout.get(one.checkoutId)).toBe(one.checkoutBranch!);
    expect(branchByCheckout.get(two.checkoutId)).toBe(two.checkoutBranch!);
    expect(branchByCheckout.get("main")).not.toBe(one.checkoutBranch);
    expect(branchByCheckout.get("main")).not.toBe(two.checkoutBranch);

    await env.app.disconnect();
  } finally {
    await env.teardown();
  }
}, 120_000);

// --- worktree.setup: the start gate, end to end ---
//
// The bridge unit tests drive `CheckoutSetupRunner` against a stand-in terminal
// host. What only shows up here is the whole chain in one piece: a real PTY
// running the bridge's own hidden `worktree-setup` subcommand, its OSC step
// markers travelling back through `onTerminalTitle`, and the resulting `setup`
// block reaching the app on `session:list` over the sealed project stream.

/** How long the fixture's middle step holds the run open. Every assertion below
 *  waits for that step to be REPORTED before it starts spending the budget, so
 *  this is slack for a round trip, not a deadline the test races. */
const SETUP_HOLD_MS = 10_000;

/** Mirrors evals/fixtures/worktree-setup.yaml. */
const SETUP_STEP_COUNT = 3;
const SETUP_HOLD_STEP = "Hold the gate";

/** A bare executable with no arguments: bun-pty serializes argv POSIX-style and
 *  cmd.exe re-parses it, so a quoted launch line (`node -e "…"`) is not a
 *  portable way to ask for a long-lived PTY. A bare `node` REPL holds the
 *  terminal open on every platform. */
const IDLE_AGENT_COMMAND = "node";

/** Written AFTER the initial commit on purpose: untracked in main, absent from
 *  a fresh worktree, and therefore exactly the class of file `copy:` exists to
 *  carry across. */
const COPIED_ENV_FILE = ".env.eval";

async function prepareSetupProject(dir: string): Promise<void> {
  await initRepo(dir);
  writeFileSync(join(dir, COPIED_ENV_FILE), "EVAL_SETUP_COPIED=1\n");
}

/** The fixture's last step writes this into the MAIN project (via the
 *  `ANTGRID_PROJECT_PATH` contract), which is the one path both the setup child
 *  and this test can name. Its existence is the only on-disk witness that a run
 *  reached the end. */
function sentinelPath(projectDir: string, sessionId: string): string {
  return join(projectDir, `setup-done-${sessionId}`);
}

let nextSetupRequest = 1;

async function listSessions(app: StreamApp, streamId: string): Promise<SessionEntry[]> {
  const requestId = `setup-list-${nextSetupRequest++}`;
  const replyP = app.waitFor(
    (m: any) => m.type === "session:list:result" && m.requestId === requestId,
    10_000,
  );
  app.sendOnStream(streamId, createMessage("session:list", { requestId } as never));
  return (await replyP).sessions as SessionEntry[];
}

async function readSession(app: StreamApp, streamId: string, id: string): Promise<SessionEntry> {
  const entry = (await listSessions(app, streamId)).find((s) => s.id === id);
  if (!entry) throw new Error(`session ${id} is not in the list`);
  return entry;
}

/** Poll the list until `predicate` holds, and answer with the sample that
 *  satisfied it. Polled rather than driven off `session:updated`: these rows
 *  assert what was true at the instant the agent appeared, and a push that
 *  coalesced two transitions would move that instant. */
async function waitForSession(
  app: StreamApp,
  streamId: string,
  id: string,
  predicate: (entry: SessionEntry) => boolean,
  timeoutMs: number,
): Promise<SessionEntry> {
  const deadline = Date.now() + timeoutMs;
  let last: SessionEntry | undefined;
  while (Date.now() < deadline) {
    last = await readSession(app, streamId, id);
    if (predicate(last)) return last;
    await Bun.sleep(250);
  }
  throw new Error(
    `session ${id} never matched within ${timeoutMs}ms ` +
      `(running=${last?.running}, setup=${JSON.stringify(last?.setup)})`,
  );
}

async function startSession(app: StreamApp, streamId: string, sessionId: string): Promise<any> {
  const requestId = `setup-start-${nextSetupRequest++}`;
  const replyP = app.waitFor(
    (m: any) => m.type === "session:result" && m.requestId === requestId,
    15_000,
  );
  app.sendOnStream(streamId, createMessage("session:start", { requestId, sessionId }));
  return replyP;
}

async function setupAction(
  app: StreamApp,
  streamId: string,
  sessionId: string,
  action: "skip" | "cancel" | "rerun",
): Promise<any> {
  const requestId = `setup-${action}-${nextSetupRequest++}`;
  const replyP = app.waitFor(
    (m: any) => m.type === "session:result" && m.requestId === requestId,
    15_000,
  );
  app.sendOnStream(streamId, createMessage("session:setup", { requestId, sessionId, action }));
  return replyP;
}

async function readInCheckout(
  app: StreamApp,
  streamId: string,
  projectId: string,
  checkoutId: string,
  path: string,
): Promise<any> {
  const replyP = app.waitFor(
    (m: any) => m.type === "file:content" && m.checkoutId === checkoutId && m.path === path,
    15_000,
  );
  app.sendOnStream(streamId, createMessage("file:read", { projectId, path, checkoutId }));
  return replyP;
}

test("an isolated session's agent waits for worktree.setup to finish", async () => {
  const env = await setupTestEnv({
    fixtureName: "worktree-setup",
    replacements: { "__SETUP_HOLD_MS__": String(SETUP_HOLD_MS) },
    prepareProject: prepareSetupProject,
  });
  try {
    const { streamId } = await bindFirstProject(env.app, env.projectId);
    const session = await createIsolated(env.app, streamId, "gated", IDLE_AGENT_COMMAND);

    // The create reply already carries a live run: an isolated session must
    // never look provisioned for the frame before the first progress lands.
    expect(session.setup?.state).toBe("running");
    expect(session.running).toBe(false);

    const sentinel = sentinelPath(env.projectDir, session.id);
    expect(existsSync(sentinel)).toBe(false);

    // Queued, not refused. The reply is `ok` and the entry it carries says
    // `pendingStart` — that flag is the only thing telling the app "queued"
    // apart from "started".
    const queued = await startSession(env.app, streamId, session.id);
    expect(queued.ok).toBe(true);
    expect(queued.session?.running).toBe(false);
    expect(queued.session?.setup?.pendingStart).toBe(true);

    // Mid-run, on the step the fixture holds open. Naming the step at all
    // proves the OSC marker made it out of the child's PTY, through
    // `onTerminalTitle`, and onto the wire — that channel has no other witness.
    const holding = await waitForSession(env.app, streamId, session.id,
      (e) => e.setup?.stepName === SETUP_HOLD_STEP, 30_000);
    expect(holding.setup?.stepIndex).toBe(1);
    expect(holding.setup?.stepCount).toBe(SETUP_STEP_COUNT);
    expect(holding.setup?.terminalId).toBe(`${session.checkoutId}:setup`);
    // The gate itself: still queued, and the run has not reached its last step.
    expect(holding.running).toBe(false);
    expect(holding.setup?.pendingStart).toBe(true);
    expect(existsSync(sentinel)).toBe(false);

    // The queued start fires only once the run is over, so the first sample
    // that sees the agent must also see the sentinel the last step wrote.
    const started = await waitForSession(env.app, streamId, session.id,
      (e) => e.running, 60_000);
    expect(existsSync(sentinel)).toBe(true);
    expect(started.setup?.state).toBe("done");
    expect(started.setup?.exitCode).toBe(0);
    expect(started.setup?.pendingStart).toBe(false);
    // A `ready` checkout throughout: setup answers "has provisioning finished",
    // not "is this workspace usable".
    expect(started.checkoutState).toBe("ready");

    // The copy step read from the main project and wrote at the same relative
    // path inside the checkout. `.env.absent` alongside it is missing on
    // purpose and did not fail the run — see the `done` above.
    const copied = await readInCheckout(
      env.app, streamId, env.projectId, session.checkoutId, COPIED_ENV_FILE);
    expect(copied.error).toBeFalsy();
    expect(copied.content).toContain("EVAL_SETUP_COPIED=1");

    await env.app.disconnect();
  } finally {
    await env.teardown();
  }
}, 180_000);

test("Skip launches the queued agent before worktree.setup has finished", async () => {
  const env = await setupTestEnv({
    fixtureName: "worktree-setup",
    replacements: { "__SETUP_HOLD_MS__": String(SETUP_HOLD_MS) },
    prepareProject: prepareSetupProject,
  });
  try {
    const { streamId } = await bindFirstProject(env.app, env.projectId);
    const session = await createIsolated(env.app, streamId, "skipped", IDLE_AGENT_COMMAND);
    const sentinel = sentinelPath(env.projectDir, session.id);

    const queued = await startSession(env.app, streamId, session.id);
    expect(queued.ok).toBe(true);
    expect(queued.session?.setup?.pendingStart).toBe(true);

    // Skip from inside the hold, so the rest of the row has the whole remaining
    // hold as margin — the claim is an ordering one and must not rest on the
    // child being slow.
    await waitForSession(env.app, streamId, session.id,
      (e) => e.setup?.stepName === SETUP_HOLD_STEP, 30_000);
    expect(existsSync(sentinel)).toBe(false);

    const skipped = await setupAction(env.app, streamId, session.id, "skip");
    expect(skipped.ok).toBe(true);

    // The agent is up while the run it was queued behind is still going: skip
    // releases the gate and nothing else.
    const started = await waitForSession(env.app, streamId, session.id,
      (e) => e.running, 20_000);
    expect(existsSync(sentinel)).toBe(false);
    expect(started.setup?.state).toBe("running");
    expect(started.setup?.pendingStart).toBe(false);

    // Cancel rather than leaving the hold to outlive the test: the setup child
    // is a grandchild of the bridge, and killing the bridge does not reach it
    // on POSIX. It also pins the other half of the contract — a cancelled run
    // settles as `skipped`, never as a failure, and never reaches its last step.
    const cancelled = await setupAction(env.app, streamId, session.id, "cancel");
    expect(cancelled.ok).toBe(true);
    expect(cancelled.session?.setup?.state).toBe("skipped");
    expect(cancelled.session?.running).toBe(true);
    expect(existsSync(sentinel)).toBe(false);

    await env.app.disconnect();
  } finally {
    await env.teardown();
  }
}, 180_000);
