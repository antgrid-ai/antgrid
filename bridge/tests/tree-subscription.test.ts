import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { FileWatcher } from "../src/file-watcher";
import { createConnState } from "../src/conn-state";
import type { AbMessage } from "../src/protocol";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { setLogLevel } from "../src/logger";

setLogLevel("error");

// The delta filter in flushBatch is a union of every attached client's subscribed directories,
// applied only once every attached client has sent file:tree:subscribe at
// least once. These tests exercise the subscription store directly
// (setSubscription/dropSubscription/isSubscribed — fast, no filesystem) and,
// separately, the filter's effect on a real flushBatch (slower — a debounce
// window has to elapse, same style as file-watcher.test.ts).
describe("FileWatcher — subscription filter", () => {
  let tempDir: string;

  beforeEach(() => {
    tempDir = mkdtempSync(join(tmpdir(), "antgrid-subscription-test-"));
    mkdirSync(join(tempDir, "src"));
    mkdirSync(join(tempDir, "docs"));
    mkdirSync(join(tempDir, "other"));
  });

  afterEach(() => {
    rmSync(tempDir, { recursive: true, force: true });
  });

  function makeWatcher(attachedClients?: () => string[]) {
    const messages: AbMessage[] = [];
    const watcher = new FileWatcher(
      { id: "test", name: "Test", path: tempDir },
      (msg) => messages.push(msg),
      createConnState(),
      undefined,
      attachedClients,
    );
    return { messages, watcher };
  }

  async function settle(ms = 200): Promise<void> {
    await new Promise((r) => setTimeout(r, ms));
  }

  function lastUpdate(messages: AbMessage[]) {
    const updates = messages.filter((m) => m.type === "tree:update");
    const last = updates[updates.length - 1];
    if (last?.type !== "tree:update") throw new Error("expected a tree:update");
    return last;
  }

  // ── Subscription store — no filesystem, no debounce ──

  it("treats the root as always subscribed, even with no clients at all", () => {
    const { watcher } = makeWatcher();
    expect(watcher.isSubscribed("")).toBe(true);
    watcher.stop();
  });

  it("REPLACES a client's whole subscribed set rather than merging into it", () => {
    const { watcher } = makeWatcher();
    watcher.setSubscription("A", ["src"]);
    expect(watcher.isSubscribed("src")).toBe(true);

    watcher.setSubscription("A", ["docs"]);
    expect(watcher.isSubscribed("src")).toBe(false);
    expect(watcher.isSubscribed("docs")).toBe(true);
    watcher.stop();
  });

  it("unsubscribes on an empty array, with no separate verb", () => {
    const { watcher } = makeWatcher();
    watcher.setSubscription("A", ["src"]);
    expect(watcher.isSubscribed("src")).toBe(true);

    watcher.setSubscription("A", []);
    expect(watcher.isSubscribed("src")).toBe(false);
    watcher.stop();
  });

  it("dropSubscription removes only that client's contribution to the union", () => {
    const { watcher } = makeWatcher();
    watcher.setSubscription("A", ["src"]);
    watcher.setSubscription("B", ["docs"]);
    expect(watcher.isSubscribed("src")).toBe(true);
    expect(watcher.isSubscribed("docs")).toBe(true);

    watcher.dropSubscription("A");
    expect(watcher.isSubscribed("src")).toBe(false);
    expect(watcher.isSubscribed("docs")).toBe(true);
    watcher.stop();
  });

  it("stop() clears every subscription — the checkout-teardown half", () => {
    const { watcher } = makeWatcher();
    watcher.setSubscription("A", ["src"]);
    watcher.setSubscription("B", ["docs"]);
    expect(watcher.isSubscribed("src")).toBe(true);

    watcher.stop();
    expect(watcher.isSubscribed("src")).toBe(false);
    expect(watcher.isSubscribed("docs")).toBe(false);
    // Root stays subscribed unconditionally — it isn't stored in the map.
    expect(watcher.isSubscribed("")).toBe(true);
  });

  // parseMessageFast (protocol.ts) checks only the frame's `type`, so a
  // hostile `paths` reaches setSubscription exactly as sent — it must never
  // throw, since this runs on the bus dispatch path with no caller to catch it.
  it("never throws on hostile `paths` input", () => {
    const { watcher } = makeWatcher();
    expect(() => watcher.setSubscription("A", null)).not.toThrow();
    expect(watcher.isSubscribed("src")).toBe(false);

    expect(() => watcher.setSubscription("A", "not-an-array")).not.toThrow();
    expect(() => watcher.setSubscription("A", 42)).not.toThrow();
    expect(() => watcher.setSubscription("A", { paths: ["src"] })).not.toThrow();
    expect(watcher.isSubscribed("src")).toBe(false);
    watcher.stop();
  });

  // The direction matters and `isSubscribed` alone cannot see it: an empty
  // stored Set and no entry at all both read false there, while they are
  // OPPOSITES for everySubscribed. A frame that cannot be read leaves the
  // client unaccounted for, which turns the filter OFF (fail open).
  it("leaves a client whose `paths` could not be read unaccounted for, not subscribed to nothing", async () => {
    const { messages, watcher } = makeWatcher(() => ["A"]);
    watcher.setSubscription("A", ["src"]);
    watcher.setSubscription("A", null);

    writeFileSync(join(tempDir, "other", "c.txt"), "c");
    watcher.handleNativeEvent("other/c.txt");
    await settle();

    expect(lastUpdate(messages).added.map((n) => n.path)).toContain("other/c.txt");
    watcher.stop();
  });

  it("leaves a client whose entries were ALL unusable unaccounted for too", async () => {
    const { messages, watcher } = makeWatcher(() => ["A"]);
    watcher.setSubscription("A", [123, null, {}]);

    writeFileSync(join(tempDir, "other", "c.txt"), "c");
    watcher.handleNativeEvent("other/c.txt");
    await settle();

    expect(lastUpdate(messages).added.map((n) => n.path)).toContain("other/c.txt");
    watcher.stop();
  });

  // The one shape that IS an account with nothing in it — the wire contract's
  // unsubscribe. It must still count toward everySubscribed, or closing the
  // Files tab would switch the filter off for every other device.
  it("counts an empty ARRAY as an account, so the filter stays on for the others", async () => {
    const { messages, watcher } = makeWatcher(() => ["A", "B"]);
    watcher.setSubscription("A", ["src"]);
    watcher.setSubscription("B", []);

    writeFileSync(join(tempDir, "src", "a.ts"), "a");
    writeFileSync(join(tempDir, "other", "c.txt"), "c");
    watcher.handleNativeEvent("src/a.ts");
    watcher.handleNativeEvent("other/c.txt");
    await settle();

    const addedPaths = lastUpdate(messages).added.map((n) => n.path);
    expect(addedPaths).toContain("src/a.ts");
    expect(addedPaths).not.toContain("other/c.txt");
    watcher.stop();
  });

  it("skips non-string entries without throwing, keeping the valid ones", () => {
    const { watcher } = makeWatcher();
    expect(() =>
      watcher.setSubscription("A", [123, null, undefined, {}, ["nested"], "docs"]),
    ).not.toThrow();
    expect(watcher.isSubscribed("docs")).toBe(true);
    watcher.stop();
  });

  it("caps at 512 subscribed paths from a 50,000-entry array, without throwing", () => {
    const { watcher } = makeWatcher();
    const paths = Array.from({ length: 50_000 }, (_, i) => `dir-${i}`);
    expect(() => watcher.setSubscription("A", paths)).not.toThrow();

    // Entries are added in array order until the cap is hit.
    expect(watcher.isSubscribed("dir-0")).toBe(true);
    expect(watcher.isSubscribed("dir-511")).toBe(true);
    expect(watcher.isSubscribed("dir-49999")).toBe(false);
    watcher.stop();
  });

  it("drops a single entry over the per-path length limit, without throwing", () => {
    const { watcher } = makeWatcher();
    const huge = "d".repeat(10 * 1024 * 1024);
    expect(() => watcher.setSubscription("A", [huge, "docs"])).not.toThrow();
    expect(watcher.isSubscribed(huge)).toBe(false);
    expect(watcher.isSubscribed("docs")).toBe(true);
    watcher.stop();
  });

  // A hostile or stale client could send backslashes or a trailing slash;
  // flushBatch's delta paths are always forward-slash, trailing-slash-free
  // (toRelPath). Storage must normalize into the exact same form, or a
  // subscribed directory would never match its own deltas.
  it("normalizes backslashes and a trailing slash into flushBatch's key form", () => {
    const { watcher } = makeWatcher();
    watcher.setSubscription("A", ["src\\nested\\"]);
    expect(watcher.isSubscribed("src/nested")).toBe(true);
    // The raw, un-normalized form must not itself be a stored key.
    expect(watcher.isSubscribed("src\\nested\\")).toBe(false);
    watcher.stop();
  });

  it("normalizes '.' and '/' down to the root", () => {
    const { watcher } = makeWatcher();
    watcher.setSubscription("A", ["."]);
    // Root is already always-subscribed; the real assertion is that "."
    // does not linger as its own distinct (unmatchable) key.
    expect(watcher.isSubscribed(".")).toBe(false);
    watcher.stop();
  });

  it("folds a './' prefix away, so it matches the delta key it meant", () => {
    const { watcher } = makeWatcher();
    watcher.setSubscription("A", ["./src"]);
    expect(watcher.isSubscribed("src")).toBe(true);
    expect(watcher.isSubscribed("./src")).toBe(false);
    watcher.stop();
  });

  // ── Filter applied to a real flushBatch ──

  it("keeps entries from the union of two clients' subscribed directories, drops the rest", async () => {
    const { messages, watcher } = makeWatcher(() => ["A", "B"]);
    watcher.setSubscription("A", ["src"]);
    watcher.setSubscription("B", ["docs"]);

    writeFileSync(join(tempDir, "src", "a.ts"), "a");
    writeFileSync(join(tempDir, "docs", "b.md"), "b");
    writeFileSync(join(tempDir, "other", "c.txt"), "c");
    watcher.handleNativeEvent("src/a.ts");
    watcher.handleNativeEvent("docs/b.md");
    watcher.handleNativeEvent("other/c.txt");

    await settle();

    const update = lastUpdate(messages);
    const addedPaths = update.added.map((n) => n.path);
    expect(addedPaths).toContain("src/a.ts");
    expect(addedPaths).toContain("docs/b.md");
    expect(addedPaths).not.toContain("other/c.txt");

    watcher.stop();
  });

  // An app that never speaks file:tree:subscribe (or simply
  // hasn't yet) must never have deltas silently withheld from it.
  it("sends every delta unfiltered while any attached client has not subscribed", async () => {
    const { messages, watcher } = makeWatcher(() => ["A", "B"]);
    watcher.setSubscription("A", ["src"]);
    // B is attached (in the roster) but has never sent file:tree:subscribe.

    writeFileSync(join(tempDir, "other", "c.txt"), "c");
    watcher.handleNativeEvent("other/c.txt");
    await settle();

    const update = lastUpdate(messages);
    expect(update.added.map((n) => n.path)).toContain("other/c.txt");

    watcher.stop();
  });

  it("sends every delta unfiltered when no client is accounted for at all", async () => {
    const { messages, watcher } = makeWatcher(() => []);

    writeFileSync(join(tempDir, "other", "c.txt"), "c");
    watcher.handleNativeEvent("other/c.txt");
    await settle();

    const update = lastUpdate(messages);
    expect(update.added.map((n) => n.path)).toContain("other/c.txt");

    watcher.stop();
  });

  it("shrinks the union when a client disconnects — its directory stops surviving the filter", async () => {
    let roster = ["A", "B"];
    const { messages, watcher } = makeWatcher(() => roster);
    watcher.setSubscription("A", ["src"]);
    watcher.setSubscription("B", ["docs"]);

    // Simulate noteClientGone(B): both halves — roster shrinks and its
    // subscription is dropped — same as agent-core.ts does together.
    roster = ["A"];
    watcher.dropSubscription("B");

    writeFileSync(join(tempDir, "src", "a.ts"), "a");
    writeFileSync(join(tempDir, "docs", "b.md"), "b");
    watcher.handleNativeEvent("src/a.ts");
    watcher.handleNativeEvent("docs/b.md");
    await settle();

    const update = lastUpdate(messages);
    const addedPaths = update.added.map((n) => n.path);
    expect(addedPaths).toContain("src/a.ts");
    expect(addedPaths).not.toContain("docs/b.md");

    watcher.stop();
  });

  it("keeps a subscribed directory's own removal — closed under removal", async () => {
    writeFileSync(join(tempDir, "src", "existing.txt"), "x");
    const { messages, watcher } = makeWatcher(() => ["A"]);
    watcher.setSubscription("A", ["src"]);

    unlinkSync(join(tempDir, "src", "existing.txt"));
    watcher.handleNativeEvent("src/existing.txt");
    await settle();

    const update = lastUpdate(messages);
    expect(update.removed).toContain("src/existing.txt");

    watcher.stop();
  });

  // The case the parent-before-child reading cannot cover: the app's collapse
  // clears `childrenLoaded` on the collapsed node alone, so it legitimately
  // holds `src/nested` with no `src`. `dirnameKeyOf("src/nested")` is then
  // unsubscribed and the directory's own disappearance would be filtered out,
  // leaving a ghost row nothing re-lists.
  it("keeps the removal of a subscribed directory whose PARENT is not subscribed", async () => {
    mkdirSync(join(tempDir, "src", "nested"));
    const { messages, watcher } = makeWatcher(() => ["A"]);
    watcher.setSubscription("A", ["src/nested"]);

    rmSync(join(tempDir, "src", "nested"), { recursive: true, force: true });
    watcher.handleNativeEvent("src/nested");
    await settle();

    expect(lastUpdate(messages).removed).toContain("src/nested");
    watcher.stop();
  });

  // A relay socket close tears down no per-device session, so
  // `noteClientGone` does not fire for that device — the watcher reconciles
  // against the live roster itself rather than trusting the callback.
  it("drops a departed client's directories from the union on the next flush, with no callback", async () => {
    let roster = ["A", "B"];
    const { messages, watcher } = makeWatcher(() => roster);
    watcher.setSubscription("A", ["src"]);
    watcher.setSubscription("B", ["docs"]);

    // B vanishes with the socket: the roster shrinks and NOTHING else runs.
    roster = ["A"];

    writeFileSync(join(tempDir, "src", "a.ts"), "a");
    writeFileSync(join(tempDir, "docs", "b.md"), "b");
    watcher.handleNativeEvent("src/a.ts");
    watcher.handleNativeEvent("docs/b.md");
    await settle();

    const addedPaths = lastUpdate(messages).added.map((n) => n.path);
    expect(addedPaths).toContain("src/a.ts");
    expect(addedPaths).not.toContain("docs/b.md");
    watcher.stop();
  });

  it("always keeps a root-level entry, even when the filter is active and root was never named explicitly", async () => {
    const { messages, watcher } = makeWatcher(() => ["A"]);
    watcher.setSubscription("A", ["src"]);

    writeFileSync(join(tempDir, "root-file.txt"), "r");
    watcher.handleNativeEvent("root-file.txt");
    await settle();

    const update = lastUpdate(messages);
    expect(update.added.map((n) => n.path)).toContain("root-file.txt");

    watcher.stop();
  });
});
