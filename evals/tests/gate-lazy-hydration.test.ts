// D-B4 end to end: a client that pulls its own file tree
// (`file:tree:snapshot:request`) must not also receive the bridge's resync
// tree:full push, while everything else the resync re-sends still arrives; a
// client that does NOT advertise pulling it keeps getting the push (legacy
// path preserved).
//
// Only a LOOPBACK owner hello triggers `resyncState` (see D-B4's brief, §0a) —
// a relay stream attach or re-handshake runs no resync at all. So the trigger
// here is a `LocalTestClient` connected against the SAME project core the
// relay app (`env.app`) is bound to; the relay app's stream is one of the two
// surfaces asserted on (the other is the loopback socket itself), since a
// resync push reaches every bus subscriber.
//
// Known Windows test noise (NOT a failure): fs.watch EPERM/EBUSY on teardown
// (see drill-in.test.ts / gate-flow-control.test.ts).
import { expect, test } from "bun:test";
import { join } from "node:path";
import { setupTestEnv } from "../helpers/harness";
import { readHostFile } from "../../bridge/src/host-discovery";
import { createMessage, type AbMessage } from "../../bridge/src/protocol";
import { bindFirstProject } from "../support/stream";
import { LocalTestClient, type LocalConnectInfo } from "../helpers/local-client";

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

interface StreamApp {
  sendOnStream(id: string, m: AbMessage): void;
  waitFor(p: (m: any) => boolean, t?: number): Promise<any>;
}

async function createIsolated(app: StreamApp, streamId: string, name: string): Promise<{ checkoutId: string }> {
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
  return reply.session;
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

async function waitFor(predicate: () => boolean, what: string, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await Bun.sleep(50);
  }
  throw new Error(`timed out waiting for ${what}`);
}

test("a pulling client is not re-sent the tree on resync, but a non-pulling one still is", async () => {
  const env = await setupTestEnv({ fixtureName: "basic", prepareProject: initRepo });
  let local: LocalTestClient | null = null;
  let legacy: LocalTestClient | null = null;
  try {
    const { streamId } = await bindFirstProject(env.app, env.projectId);
    const one = await createIsolated(env.app, streamId, "one");
    const two = await createIsolated(env.app, streamId, "two");
    const three = await createIsolated(env.app, streamId, "three");
    const checkoutIds = ["main", one.checkoutId, two.checkoutId, three.checkoutId];

    const conn: LocalConnectInfo = (await loopbackControl(env.abDir, {
      id: "connect", type: "project:start", projectId: env.projectId,
    })).connect;

    // --- Row 1: a pulling owner connects, triggering resyncState. ---
    env.app.drainQueued("tree:full"); // nothing stale from setup should count below.
    const seen: AbMessage[] = [];
    local = new LocalTestClient();
    local.on((m) => seen.push(m));
    await local.connect(conn); // pullsTree defaults on.

    // Wait for the resync's POSITIVE evidence (git:sync-state is forced per
    // runtime, ahead of the tree loop in program order) before trusting the
    // negative tree:full assertion below.
    await waitFor(
      () => new Set(
        seen.filter((m) => m.type === "git:sync-state").map((m: any) => m.checkoutId),
      ).size >= checkoutIds.length,
      "git:sync-state for every checkout",
      20_000,
    );

    expect(seen.filter((m) => m.type === "tree:full")).toHaveLength(0);
    // The relay app's stream is the other surface a push would have reached.
    expect(env.app.queuedCount((m: any) => m.type === "tree:full" && m._streamId === streamId)).toBe(0);

    // --- Row 2: a pull is answered once, and a reply right behind it on the ---
    // --- same stream is not stuck behind a tree push. ---
    const listId = "lazy-list-1";
    env.app.sendOnStream(streamId, createMessage("file:tree:snapshot:request", {
      checkoutId: one.checkoutId,
    }));
    const t0 = Date.now();
    env.app.sendOnStream(streamId, createMessage("session:list", { requestId: listId } as never));
    const reply = await env.app.waitFor(
      (m: any) => m._streamId === streamId && m.type === "session:list:result" && m.requestId === listId,
      20_000,
    );
    const elapsed = Date.now() - t0;
    expect(reply.sessions).toBeDefined();
    // The product bar is one second; asserted generously here (5s) so a loaded
    // Windows box with three real worktrees and a real relay never flakes on
    // scheduling noise unrelated to the fix. The eval's link is loopback-fast,
    // so a pass here is weak evidence by construction — it would have failed
    // with four tree:full pushes ahead of it in the same FIFO, but does not
    // prove a slow link stays under the real one-second bar.
    expect(elapsed).toBeLessThan(5_000);

    const snaps = env.app.queuedCount((m: any) =>
      (m.type === "file:tree:snapshot" || m.type === "file:tree:unchanged")
      && m.checkoutId === one.checkoutId && m._streamId === streamId);
    expect(snaps).toBe(1);

    // Widen row 1's negative window cheaply now that more time has passed.
    expect(seen.filter((m) => m.type === "tree:full")).toHaveLength(0);

    // --- Row 3: a client that does NOT advertise pullsTree still gets the ---
    // --- legacy push (this owner supersedes `local`, firing a fresh resync). ---
    const legacySeen: AbMessage[] = [];
    legacy = new LocalTestClient();
    legacy.on((m) => legacySeen.push(m));
    await legacy.connect(conn, { pullsTree: false });

    await waitFor(
      () => new Set(
        legacySeen.filter((m) => m.type === "tree:full").map((m: any) => m.checkoutId),
      ).size >= checkoutIds.length,
      "a tree:full per checkout",
      30_000,
    );
    // A concurrent filesystem change could add an extra tree:full for a
    // checkout at any moment, so this asserts the SET of checkouts covered,
    // never an exact frame count.
    expect(new Set(legacySeen.filter((m) => m.type === "tree:full").map((m: any) => m.checkoutId)))
      .toEqual(new Set(checkoutIds));
  } finally {
    local?.close();
    legacy?.close();
    await env.teardown();
  }
}, 180_000);
