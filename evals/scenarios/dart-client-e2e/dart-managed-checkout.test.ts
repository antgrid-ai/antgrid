import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { setupDartTestEnv, type DartTestEnv } from "../../helpers/harness";
import { createMessage } from "../../../bridge/src/protocol";

async function git(cwd: string, args: string[]): Promise<void> {
  const child = Bun.spawn(["git", ...args], { cwd, stdout: "ignore", stderr: "pipe" });
  const code = await child.exited;
  if (code !== 0) throw new Error(`git ${args.join(" ")} failed: ${await new Response(child.stderr).text()}`);
}

async function initRepo(dir: string): Promise<void> {
  await git(dir, ["init"]);
  await git(dir, ["config", "user.email", "eval@antgrid.local"]);
  await git(dir, ["config", "user.name", "Antgrid Eval"]);
  await git(dir, ["add", "."]);
  await git(dir, ["commit", "-m", "initial"]);
}

/**
 * Managed-checkout creation and Git verbs, over the real Dart binding. These
 * ride the same project stream as file:read/terminal:* (already proven via
 * Dart elsewhere), but a message shape neither of those exercises is still a
 * real cross-language decode this suite has not otherwise checked.
 */
describe("dart-managed-checkout", () => {
  let env: DartTestEnv;

  beforeAll(async () => {
    env = await setupDartTestEnv({
      fixtureName: "basic",
      clientName: "eval-dart-checkout",
      prepareProject: initRepo,
    });
    await env.app.waitForAgentStatus(env.streamId, 10_000);
  }, 60_000);

  afterAll(async () => {
    await env?.teardown();
  });

  test("creates a managed-worktree checkout and lists its branch via Dart client", async () => {
    const requestId = crypto.randomUUID();
    env.app.sendOnStream(env.streamId, createMessage("session:create", {
      requestId, name: "dart-checkout", isolation: "worktree",
    }));
    const created = await env.app.waitForStreamAbMessage(env.streamId, "session:result", 15_000);
    expect(created.data.ok).toBe(true);
    expect(created.data.session.checkoutKind).toBe("managed-worktree");

    env.app.sendOnStream(env.streamId, createMessage("git:list-branches", {
      projectId: env.projectId, checkoutId: created.data.session.checkoutId,
    }));
    const branches = await env.app.waitForStreamAbMessage(env.streamId, "git:branches", 10_000);
    expect(branches.data.current).toBe(created.data.session.checkoutBranch);
  }, 25_000);
});
