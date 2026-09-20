// The merge-gate suite for docs/file-tree-lazy-expansion-spec.md: opening a
// project (or resyncing an already-open one) must never pull a whole file
// tree. The whole-tree push and the `pullsTree`-keyed fork in behaviour it
// used to guard directly are gone — there is no longer a "legacy path" that
// still gets a push, for any client. What replaces it is asserted here three
// ways: (1) a resync, run across several checkouts and observed by two
// differently-configured clients, produces no tree data at all unless asked;
// (2) the listing protocol itself is genuinely shallow — requesting the root
// returns depth-1 entries only (a subdirectory comes back with no `children`),
// and a subdirectory's contents arrive only once it is asked for by path;
// (3) `file:tree:snapshot:request` — the whole-tree pull, now retired — is
// INERT: sending one produces no answer at all.
//
// (3) is asserted over a hand-built envelope rather than `createMessage`,
// because the type no longer exists in the protocol to construct. That is the
// point: a bridge that re-grows a whole-tree reply fails here, and nothing
// else would catch it now that neither frame type has a schema.
//
// Only a LOOPBACK owner (re)connect triggers `resyncState` — a relay stream
// attach or re-handshake runs no resync at all. So the trigger here is a
// `LocalTestClient` connected against the SAME project core the relay app
// (`env.app`) is bound to; the relay app's stream is one of the surfaces
// asserted on, since a push (if one existed) would reach every bus
// subscriber, not just the loopback socket that triggered it.
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

/** True once `frames` carries a `git:sync-state` for every id in `checkoutIds`
 *  — the resync's positive evidence, forced per runtime ahead of anything
 *  tree-related in program order, so seeing it all here is what makes the
 *  negative tree assertions below trustworthy rather than merely "nothing
 *  arrived yet". */
function hasSyncStateForEveryCheckout(frames: AbMessage[], checkoutIds: string[]): boolean {
  const covered = new Set(
    frames.filter((m) => m.type === "git:sync-state").map((m: any) => m.checkoutId),
  );
  return checkoutIds.every((id) => covered.has(id));
}

test("a project resync never pushes a whole tree, and the listing protocol stays shallow", async () => {
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

    // --- A pulling owner connects, triggering resyncState. ---
    env.app.drainQueued("tree:full");
    const seen: AbMessage[] = [];
    local = new LocalTestClient();
    local.on((m) => seen.push(m));
    await local.connect(conn); // pullsTree defaults on, and is now ignored either way.

    await waitFor(
      () => hasSyncStateForEveryCheckout(seen, checkoutIds),
      "git:sync-state for every checkout",
      20_000,
    );

    // No `tree:full` — the whole-tree push this gate used to name — from the
    // resync. (`tree:update`, the live delta channel, is a different
    // mechanism a resync never drove even before this wave, and freshly
    // creating a worktree can legitimately fire one of its own as the new
    // checkout's watcher catches up — asserting its absence here would be
    // asserting something this test never guaranteed.)
    expect(seen.filter((m) => m.type === "tree:full")).toHaveLength(0);
    // The relay app's stream is the other surface a push would have reached.
    expect(env.app.queuedCount((m: any) => m.type === "tree:full" && m._streamId === streamId)).toBe(0);

    // --- A second, differently-configured client connects (superseding ---
    // --- `local`), firing a fresh resync. `pullsTree: false` used to select ---
    // --- the OTHER behaviour (a forced tree:full per checkout); today the ---
    // --- capability is parsed-and-ignored (spec Deferred) and both clients ---
    // --- get the identical, tree-free resync. ---
    const legacySeen: AbMessage[] = [];
    legacy = new LocalTestClient();
    legacy.on((m) => legacySeen.push(m));
    await legacy.connect(conn, { pullsTree: false });

    await waitFor(
      () => hasSyncStateForEveryCheckout(legacySeen, checkoutIds),
      "git:sync-state for every checkout (legacy)",
      20_000,
    );
    expect(legacySeen.filter((m) => m.type === "tree:full")).toHaveLength(0);

    // Widen the first client's negative window cheaply now that more time has
    // passed and a second resync has run.
    expect(seen.filter((m) => m.type === "tree:full")).toHaveLength(0);

    // --- The listing protocol itself is shallow: the root reply's directory ---
    // --- entries carry no `children` — proving the request walked ONE level, ---
    // --- not the whole checkout — and a nested file is invisible until its ---
    // --- own directory is asked for by path. ---
    const rootReply = await requestListing(env.app, streamId, one.checkoutId);
    const rootListing = rootReply.listings.find((l: any) => l.path === "");
    expect(rootListing).toBeDefined();
    expect(rootListing.missing).toBeUndefined();
    const rootNames = rootListing.children.map((n: any) => n.name);
    expect(rootNames).toContain("README.md");
    expect(rootNames).toContain("src");
    const srcEntry = rootListing.children.find((n: any) => n.name === "src");
    expect(srcEntry.type).toBe("directory");
    // The whole-tree walk this replaces would have nested src's contents
    // right here; the lazy listing leaves it unexpanded.
    expect(srcEntry.children).toBeUndefined();
    expect(rootNames).not.toContain("index.ts");
    expect(rootNames).not.toContain("utils.ts");

    const srcReply = await requestListing(env.app, streamId, one.checkoutId, ["src"]);
    const srcListing = srcReply.listings.find((l: any) => l.path === "src");
    expect(srcListing).toBeDefined();
    const srcNames = srcListing.children.map((n: any) => n.name);
    expect(srcNames).toContain("index.ts");
    expect(srcNames).toContain("utils.ts");

    // --- the retired whole-tree pull is inert ---
    // Hand-built: the type has no schema any more, so `createMessage` cannot
    // name it. The bridge must neither answer it nor fall back to any other
    // whole-tree frame.
    env.app.sendOnStream(streamId, {
      id: crypto.randomUUID(),
      timestamp: Date.now(),
      type: "file:tree:snapshot:request",
      checkoutId: one.checkoutId,
    } as any);
    await Bun.sleep(1000);
    expect(env.app.queuedCount(
      (m: any) => m.type === "file:tree:snapshot" && m._streamId === streamId,
    )).toBe(0);
    expect(env.app.queuedCount(
      (m: any) => m.type === "tree:full" && m._streamId === streamId,
    )).toBe(0);
  } finally {
    local?.close();
    legacy?.close();
    await env.teardown();
  }
}, 180_000);

/** Send a root (no `paths`) or children (`paths`) listing request for
 *  `checkoutId` and return the `file:tree:children` reply. */
async function requestListing(
  app: StreamApp,
  streamId: string,
  checkoutId: string,
  paths?: string[],
): Promise<any> {
  const replyP = app.waitFor(
    (m: any) => m._streamId === streamId && m.type === "file:tree:children" && m.checkoutId === checkoutId,
    10_000,
  );
  if (paths) {
    app.sendOnStream(streamId, createMessage("file:tree:children:request", { paths, checkoutId }));
  } else {
    app.sendOnStream(streamId, createMessage("file:tree:root:request", { checkoutId }));
  }
  return replyP;
}
