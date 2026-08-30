// The Git view moved only on a 10s poll: nothing connected a file changing to
// git status being re-read, so a diff could sit invisible for up to ten
// seconds after the agent finished writing it. Worst on a phone or tablet,
// where the changes list is opened deliberately, right after the agent stops —
// which is exactly when it was most likely to be stale.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { MessageBus } from "../src/message-bus";
import { createMessage, type AbMessage } from "../src/protocol";
import { setLogLevel } from "../src/logger";

setLogLevel("error");

let root: string;
let previousAbDir: string | undefined;
let core: AgentCore | null;

beforeEach(() => {
  previousAbDir = process.env.ANTGRID_DIR;
  root = mkdtempSync(join(tmpdir(), "antgrid-git-fresh-"));
  process.env.ANTGRID_DIR = join(root, "state");
  writeFileSync(join(root, "antgrid.yaml"), "name: git-freshness\n");
});

afterEach(async () => {
  await core?.shutdown();
  core = null;
  if (previousAbDir === undefined) delete process.env.ANTGRID_DIR;
  else process.env.ANTGRID_DIR = previousAbDir;
  rmSync(root, { recursive: true, force: true });
});

async function git(args: string[]): Promise<void> {
  const proc = Bun.spawn(["git", ...args], { cwd: root, stdout: "ignore", stderr: "pipe" });
  const code = await proc.exited;
  if (code !== 0) throw new Error(await new Response(proc.stderr).text());
}

async function gitOut(args: string[]): Promise<string> {
  const proc = Bun.spawn(["git", ...args], { cwd: root, stdout: "pipe", stderr: "pipe" });
  const out = await new Response(proc.stdout).text();
  if ((await proc.exited) !== 0) throw new Error(await new Response(proc.stderr).text());
  return out.trim();
}

async function initRepo(): Promise<void> {
  await git(["init"]);
  await git(["config", "user.email", "test@antgrid.local"]);
  await git(["config", "user.name", "Antgrid Test"]);
  await git(["add", "."]);
  await git(["commit", "-m", "initial"]);
}

async function waitFor(
  predicate: () => boolean,
  what: string,
  // Well under the 10s poll: passing on the poll's back would prove nothing.
  timeoutMs = 4000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`timed out waiting for ${what}`);
}

async function bootCore(): Promise<{ bus: MessageBus; sent: AbMessage[] }> {
  core = await buildAgentCore({
    folder: root,
    mode: "local",
    identity: { deviceId: "agent", deviceName: "agent", createdAt: new Date().toISOString() },
  });
  const bus = new MessageBus();
  const sent: AbMessage[] = [];
  bus.subscribe({ deliver: (message) => sent.push(message) });
  core.attachTransport(bus);
  core.onHandshakeComplete();
  await waitFor(() => sent.some((m) => m.type === "agent:status"), "agent:status");
  return { bus, sent };
}

function lastGitStatus(sent: AbMessage[]) {
  const frames = sent.filter((m) => m.type === "git:status");
  const last = frames[frames.length - 1];
  return last && last.type === "git:status" ? last.files : [];
}

function stagedPaths(sent: AbMessage[]): string[] {
  return lastGitStatus(sent).filter((f) => f.staged).map((f) => f.path);
}

function gitStatusPaths(sent: AbMessage[]): string[] {
  const frames = sent.filter((m) => m.type === "git:status");
  const last = frames[frames.length - 1];
  if (!last || last.type !== "git:status") return [];
  return last.files.map((f) => f.path);
}

test("a file the agent writes reaches git:status without waiting for the poll", async () => {
  await initRepo();
  const { sent } = await bootCore();
  await waitFor(() => sent.some((m) => m.type === "git:status"), "the first git:status");

  writeFileSync(join(root, "written-by-the-agent.ts"), "export const x = 1;\n");

  await waitFor(
    () => gitStatusPaths(sent).includes("written-by-the-agent.ts"),
    "the new file in git:status",
  );
});

test("a tree snapshot request answers with git status too", async () => {
  await initRepo();
  const { bus, sent } = await bootCore();
  await waitFor(() => sent.some((m) => m.type === "git:status"), "the first git:status");

  writeFileSync(join(root, "changed-while-away.ts"), "export const y = 2;\n");
  await waitFor(
    () => gitStatusPaths(sent).includes("changed-while-away.ts"),
    "the new file in git:status",
  );
  // Let every watcher-driven refresh this write scheduled settle, so what the
  // request does below is the only thing left that could move the status.
  await new Promise((resolve) => setTimeout(resolve, 800));

  // Staging touches only `.git/`, which the watcher ignores by design (see
  // DEFAULT_IGNORES) — so this is a change nothing pushes, and an app that
  // reconnects into it has no way to know what it holds is out of date.
  await git(["add", "changed-while-away.ts"]);
  await new Promise((resolve) => setTimeout(resolve, 500));
  expect(stagedPaths(sent)).not.toContain("changed-while-away.ts");

  // The app asks for a tree snapshot on every reconnect and on a
  // pull-to-refresh — because it doubts what it holds. Answering with the tree
  // alone left the changes list on whatever the replay cache last had.
  bus.dispatchInbound(
    createMessage("file:tree:snapshot:request", {}),
    "control",
    "loopback",
  );

  await waitFor(
    () => sent.some((m) => m.type === "file:tree:snapshot"),
    "the tree snapshot",
  );
  await waitFor(
    () => stagedPaths(sent).includes("changed-while-away.ts"),
    "the staged file in git:status after the snapshot request",
  );
});

test("a FAILED discard still refreshes the Git view", async () => {
  writeFileSync(join(root, "tracked.ts"), "export const kept = 1;\n");
  await initRepo();
  const { bus, sent } = await bootCore();
  await waitFor(() => sent.some((m) => m.type === "git:status"), "the first git:status");

  // Break the discard's LATER invocations while leaving `git status` healthy:
  // drop the blob `tracked.ts` would be restored from. That ordering is the
  // whole point — a discard is several git invocations, and one that fails
  // after the index has already moved leaves the app holding a staged list the
  // tree no longer matches.
  //
  // Deliberately NOT the earlier `status.showUntrackedFiles=bogus` shape.
  // Breaking `git status` breaks the very read this asserts on: the refresh
  // behind the failure returns empty-handed, the re-send is byte-identical to
  // the cached frame and the bus dedups it away, so the only thing that could
  // ever satisfy the assertion was a watcher-driven refresh landing after the
  // config was put back — a 250ms debounce racing a `git config` spawn, which
  // under load lost and left the 10s poll as the only trigger.
  const blob = await gitOut(["rev-parse", "HEAD:tracked.ts"]);
  rmSync(join(root, ".git", "objects", blob.slice(0, 2), blob.slice(2)), { force: true });

  writeFileSync(join(root, "staged.ts"), "export const z = 3;\n");
  await git(["add", "staged.ts"]);
  rmSync(join(root, "tracked.ts"), { force: true });
  await waitFor(() => stagedPaths(sent).includes("staged.ts"), "the staged file");
  const before = sent.filter((m) => m.type === "git:status").length;

  bus.dispatchInbound(
    createMessage("git:discard", {
      projectId: core!.projectId,
      files: ["staged.ts", "tracked.ts"],
      includeStaged: true,
    }),
    "control",
    "loopback",
  );

  await waitFor(
    () => sent.some((m) => m.type === "git:discard-result" && m.success === false),
    "the failed discard result",
  );
  // Nothing in the failed discard touches the WORKTREE — the reset moves the
  // index and `restore` dies before writing — so no watcher event can produce
  // this frame. The handler's own refresh is the only thing that can, which is
  // what makes this an assertion about the mechanism rather than about timing.
  // Content-checked as well as counted, so a stray refresh cannot stand in for
  // the one that carries the reset.
  await waitFor(
    () =>
      sent.filter((m) => m.type === "git:status").length > before &&
      !stagedPaths(sent).includes("staged.ts"),
    "a git:status refresh, behind the failed discard, without the reset file staged",
  );
  expect(gitStatusPaths(sent)).toContain("staged.ts");
});
