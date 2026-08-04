// Task 13 end-to-end gates for isolated (managed-worktree) sessions, over a
// real relay with a real bridge process.
//
// What these cover that the bridge unit tests cannot: the frames actually cross
// the E2E stream, so a checkout id that failed to survive sealing, stream
// muxing or the app-side capability gate shows up here and nowhere else.
import { expect, test } from "bun:test";
import { setupTestEnv } from "../helpers/harness";
import { createMessage, type AbMessage, type SessionEntry } from "../../bridge/src/protocol";
import { bindFirstProject } from "../support/stream";

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
  app: { sendOnStream(id: string, m: AbMessage): void; waitFor(p: (m: any) => boolean, t?: number): Promise<any> },
  streamId: string,
  name: string,
): Promise<SessionEntry> {
  const requestId = `create-${name}`;
  const replyP = app.waitFor(
    (m: any) => m.type === "session:result" && m.requestId === requestId,
    15_000,
  );
  app.sendOnStream(streamId, createMessage("session:create", {
    requestId, name, isolation: "worktree",
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
