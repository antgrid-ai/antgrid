import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { FileWatcher } from "../src/file-watcher";
import { createConnState } from "../src/conn-state";
import type { AbMessage } from "../src/protocol";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { setLogLevel } from "../src/logger";

setLogLevel("error");

// A recursive fs.watch is lossy by contract on Windows, and the overflow
// report that exists to say so was measured going missing too — a host that
// lost every event below the checkout root and reported nothing. Nothing
// pull-based recovers from that, because a lost event never moves `seq` and
// the bridge then answers `file:tree:unchanged` to the app's own re-pull. The
// sweep asks the disk instead. These tests drive it directly rather than
// provoking the OS: a watcher that was never started delivers no events at
// all, which is the same silence, deterministically.
describe("FileWatcher — subscribed-directory revalidation", () => {
  let tempDir: string;

  beforeEach(() => {
    tempDir = mkdtempSync(join(tmpdir(), "antgrid-revalidation-test-"));
    mkdirSync(join(tempDir, "src"));
    mkdirSync(join(tempDir, "node_modules"));
  });

  afterEach(() => {
    rmSync(tempDir, { recursive: true, force: true });
  });

  function makeWatcher(clients: string[] = ["A"]) {
    const messages: AbMessage[] = [];
    const watcher = new FileWatcher(
      { id: "test", name: "Test", path: tempDir },
      (msg) => messages.push(msg),
      createConnState(),
      undefined,
      () => clients,
    );
    return { messages, watcher };
  }

  async function settle(ms = 200): Promise<void> {
    await new Promise((r) => setTimeout(r, ms));
  }

  const invalidations = (messages: AbMessage[]) =>
    messages.filter((m) => m.type === "file:tree:invalidated");

  it("reports a change no watcher event ever arrived for", async () => {
    const { messages, watcher } = makeWatcher();
    watcher.setSubscription("A", ["src"]);
    watcher.revalidateSubscribedDirs();

    // The loss: the file lands, and nothing tells the watcher.
    writeFileSync(join(tempDir, "src", "appeared.ts"), "x");
    watcher.revalidateSubscribedDirs();
    await settle();

    const frames = invalidations(messages);
    expect(frames.length).toBe(1);
    const frame = frames[0];
    if (frame?.type !== "file:tree:invalidated") throw new Error("expected an invalidation");
    expect(frame.seq).toBeGreaterThan(0);
    await watcher.stop();
  });

  it("stays silent after a change the watcher DID deliver", async () => {
    const { messages, watcher } = makeWatcher();
    watcher.setSubscription("A", ["src"]);
    watcher.revalidateSubscribedDirs();

    // Delivered, so the app already has it — and the directory's mtime moved
    // all the same. Reporting it would re-list every open directory on every
    // ordinary save, which is the traffic the on-demand tree exists to avoid.
    writeFileSync(join(tempDir, "src", "delivered.ts"), "x");
    watcher.handleNativeEvent("src/delivered.ts");
    await settle();
    expect(messages.some((m) => m.type === "tree:update")).toBe(true);

    watcher.revalidateSubscribedDirs();
    await settle();
    expect(invalidations(messages)).toEqual([]);
    await watcher.stop();
  });

  it("records a directory on first sighting instead of reporting it", async () => {
    const { messages, watcher } = makeWatcher();
    watcher.setSubscription("A", ["src"]);

    // The sweep that follows a client expanding a tree must not invalidate it.
    watcher.revalidateSubscribedDirs();
    await settle();

    expect(invalidations(messages)).toEqual([]);
    await watcher.stop();
  });

  it("never sweeps a directory the watcher's own ignore rules prune", async () => {
    const { messages, watcher } = makeWatcher();
    // Show-everything browsing lets a client expand — and subscribe to —
    // node_modules. Sweeping it would invalidate on every install write.
    watcher.setSubscription("A", ["node_modules"]);
    watcher.revalidateSubscribedDirs();

    writeFileSync(join(tempDir, "node_modules", "installed.js"), "x");
    watcher.revalidateSubscribedDirs();
    await settle();

    expect(invalidations(messages)).toEqual([]);
    await watcher.stop();
  });

  it("reports a subscribed directory that disappears", async () => {
    const { messages, watcher } = makeWatcher();
    watcher.setSubscription("A", ["src"]);
    watcher.revalidateSubscribedDirs();

    rmSync(join(tempDir, "src"), { recursive: true, force: true });
    watcher.revalidateSubscribedDirs();
    await settle();

    expect(invalidations(messages).length).toBe(1);
    await watcher.stop();
  });

  it("does nothing at all when no client is attached", async () => {
    const { messages, watcher } = makeWatcher([]);
    watcher.setSubscription("A", ["src"]);
    watcher.revalidateSubscribedDirs();

    writeFileSync(join(tempDir, "src", "unwatched.ts"), "x");
    watcher.revalidateSubscribedDirs();
    await settle();

    expect(invalidations(messages)).toEqual([]);
    await watcher.stop();
  });
});
