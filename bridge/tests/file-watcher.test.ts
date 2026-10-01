import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { FileWatcher } from "../src/file-watcher";
import { createConnState } from "../src/conn-state";
import { PathStatCache } from "../src/terminal-links/stat-cache";
import type { AbMessage } from "../src/protocol";
import * as fsp from "node:fs/promises";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { setLogLevel } from "../src/logger";

setLogLevel("error");

describe("FileWatcher", () => {
  let tempDir: string;

  beforeEach(() => {
    tempDir = mkdtempSync(join(tmpdir(), "antgrid-watcher-test-"));
    // Create some initial files
    writeFileSync(join(tempDir, "index.ts"), "console.log('hello')");
    mkdirSync(join(tempDir, "src"));
    writeFileSync(join(tempDir, "src", "app.ts"), "export default {}");
  });

  afterEach(() => {
    rmSync(tempDir, { recursive: true, force: true });
  });

  it("detects file additions", async () => {
    const messages: AbMessage[] = [];
    const watcher = new FileWatcher(
      { id: "test", name: "Test", path: tempDir },
      (msg) => messages.push(msg),
      createConnState(),
    );

    watcher.startWatching();
    // Wait for watcher to be ready
    await new Promise((r) => setTimeout(r, 500));

    // Add a new file
    writeFileSync(join(tempDir, "new-file.txt"), "new content");

    // Wait for debounce + chokidar detection
    await new Promise((r) => setTimeout(r, 500));

    const updates = messages.filter((m) => m.type === "tree:update");
    expect(updates.length).toBeGreaterThanOrEqual(1);

    const lastUpdate = updates[updates.length - 1];
    if (lastUpdate.type === "tree:update") {
      expect(lastUpdate.added.length).toBeGreaterThanOrEqual(1);
      const addedFile = lastUpdate.added.find((n) => n.name === "new-file.txt");
      expect(addedFile).toBeDefined();
    }

    watcher.stop();
  });

  // Windows' (and reportedly macOS's) recursive fs.watch reports a `change`
  // event with filename === null when its internal notification buffer
  // overflows — measured: a burst of ~40 file creations under one new
  // directory was enough to drop every per-file event and report only this.
  // `flushBatch` must treat that as "something changed, scope unknown" and
  // resync the whole tree rather than silently doing nothing.
  it("falls back to a full tree resync when the watcher reports an unnamed change", async () => {
    const messages: AbMessage[] = [];
    const watcher = new FileWatcher(
      { id: "test", name: "Test", path: tempDir },
      (msg) => messages.push(msg),
      createConnState(),
    );

    // The real callback, not the private field it sets: assigning
    // `needsFullResync` by hand asserts only what the test just wrote, and
    // deleting the null branch from `handleNativeEvent` left it green.
    watcher.handleNativeEvent(null);

    await new Promise((r) => setTimeout(r, 200));

    expect(messages.some((m) => m.type === "file:tree:invalidated")).toBe(true);
    expect(messages.some((m) => m.type === "tree:update")).toBe(false);

    watcher.stop();
  });

  // The invalidation frame is what a lazy-tree app resyncs from — its seq must
  // move on every unnamed-change resync, or the bus's payload-equality dedup
  // swallows the second one and the app never learns the tree it holds is stale.
  it("bumps file:tree:invalidated's seq on every resync", async () => {
    const messages: AbMessage[] = [];
    const watcher = new FileWatcher(
      { id: "test", name: "Test", path: tempDir },
      (msg) => messages.push(msg),
      createConnState(),
    );

    watcher.handleNativeEvent(null);
    await new Promise((r) => setTimeout(r, 200));

    const invalidated = messages.find((m) => m.type === "file:tree:invalidated");
    if (invalidated?.type !== "file:tree:invalidated") {
      throw new Error("expected a file:tree:invalidated");
    }
    expect(invalidated.seq).toBeGreaterThan(0);

    // Consecutive resyncs must differ, or the bus's payload-equality dedup
    // swallows the second — the frame is sent unforced and leans on that.
    watcher.handleNativeEvent(null);
    await new Promise((r) => setTimeout(r, 200));
    const seqs = messages
      .filter((m) => m.type === "file:tree:invalidated")
      .map((m) => (m.type === "file:tree:invalidated" ? m.seq : -1));
    expect(seqs).toHaveLength(2);
    expect(seqs[1]).toBeGreaterThan(seqs[0]);

    watcher.stop();
  });

  // A resync requested while the app is backgrounded must OUTLIVE the drop.
  // `flushBatch` consumes the flag before it reaches the suppression gate, so
  // returning there without restoring it silently loses the one signal that
  // corrects a delta stream whose base is already wrong — and nothing ever
  // asks again.
  it("keeps a pending resync across a suppressed flush", async () => {
    const messages: AbMessage[] = [];
    const connState = createConnState();
    const watcher = new FileWatcher(
      { id: "test", name: "Test", path: tempDir },
      (msg) => messages.push(msg),
      connState,
    );

    connState.appFocusPaused = true;
    watcher.handleNativeEvent(null);
    await new Promise((r) => setTimeout(r, 200));
    expect(messages.length).toBe(0);

    connState.appFocusPaused = false;
    watcher.handleNativeEvent(null);
    await new Promise((r) => setTimeout(r, 200));
    expect(messages.some((m) => m.type === "file:tree:invalidated")).toBe(true);

    watcher.stop();
  });

  it("detects file modifications", async () => {
    const messages: AbMessage[] = [];
    const watcher = new FileWatcher(
      { id: "test", name: "Test", path: tempDir },
      (msg) => messages.push(msg),
      createConnState(),
    );

    watcher.startWatching();
    await new Promise((r) => setTimeout(r, 500));

    // Modify an existing file
    writeFileSync(join(tempDir, "index.ts"), "console.log('modified')");

    await new Promise((r) => setTimeout(r, 500));

    const updates = messages.filter((m) => m.type === "tree:update");
    expect(updates.length).toBeGreaterThanOrEqual(1);

    watcher.stop();
  });

  it("detects file deletions", async () => {
    const messages: AbMessage[] = [];
    const watcher = new FileWatcher(
      { id: "test", name: "Test", path: tempDir },
      (msg) => messages.push(msg),
      createConnState(),
    );

    watcher.startWatching();
    await new Promise((r) => setTimeout(r, 500));

    // Delete a file
    unlinkSync(join(tempDir, "index.ts"));

    await new Promise((r) => setTimeout(r, 500));

    const updates = messages.filter((m) => m.type === "tree:update");
    expect(updates.length).toBeGreaterThanOrEqual(1);

    const lastUpdate = updates[updates.length - 1];
    if (lastUpdate.type === "tree:update") {
      expect(lastUpdate.removed.length).toBeGreaterThanOrEqual(1);
    }

    watcher.stop();
  });

  it("handles file read requests", () => {
    const messages: AbMessage[] = [];
    const watcher = new FileWatcher(
      { id: "test", name: "Test", path: tempDir },
      (msg) => messages.push(msg),
      createConnState(),
    );

    watcher.handleFileReadRequest("index.ts");

    expect(messages.length).toBe(1);
    expect(messages[0].type).toBe("file:content");
    if (messages[0].type === "file:content") {
      expect(messages[0].content).toBe("console.log('hello')");
      expect(messages[0].path).toBe("index.ts");
    }

    watcher.stop();
  });

  function newWatcher(): FileWatcher {
    return new FileWatcher({ id: "test", name: "Test", path: tempDir }, () => {}, createConnState());
  }

  /** The paths a cache was asked to resolve at all, which is what the watcher's
   *  own refusals must keep empty: the cache refuses UNC shapes itself on
   *  Windows, so an empty `calls` alone cannot tell the two apart. */
  function askedCache(): { cache: PathStatCache; asked: string[]; calls: string[] } {
    const { cache, calls } = recordingCache();
    const asked: string[] = [];
    const resolveFresh = cache.resolveFresh.bind(cache);
    cache.resolveFresh = (abs, ms) => {
      asked.push(abs);
      return resolveFresh(abs, ms);
    };
    return { cache, asked, calls };
  }

  /** A cache over the real filesystem that records every path it is asked about. */
  function recordingCache(): { cache: PathStatCache; calls: string[] } {
    const calls: string[] = [];
    const cache = new PathStatCache({
      fs: {
        lstat: (p) => { calls.push(p); return fsp.lstat(p); },
        stat: (p) => { calls.push(p); return fsp.stat(p); },
        readlink: (p) => { calls.push(p); return fsp.readlink(p); },
      },
    });
    return { cache, calls };
  }

  it("resolves an absolute path printed by a terminal program to its checkout-relative form", async () => {
    const watcher = newWatcher();

    const reply = await watcher.resolvePath(join(tempDir, "src", "app.ts"), { requestId: "req-1" }, new PathStatCache());

    expect(reply.requestId).toBe("req-1");
    expect(reply.relPath).toBe("src/app.ts");
    expect(reply.isDirectory).toBe(false);
    expect(reply.externalImagePath).toBeNull();
    expect(reply.exists).toBe(true);

    watcher.stop();
  });

  it("resolves a directory path and reports isDirectory", async () => {
    const watcher = newWatcher();

    const reply = await watcher.resolvePath(join(tempDir, "src"), {}, new PathStatCache());

    expect(reply.relPath).toBe("src");
    expect(reply.isDirectory).toBe(true);
    expect(reply.exists).toBe(true);

    watcher.stop();
  });

  it("names the checkout root as an empty relative path", async () => {
    const watcher = newWatcher();

    const reply = await watcher.resolvePath(tempDir, {}, new PathStatCache());

    expect(reply.relPath).toBe("");
    expect(reply.isDirectory).toBe(true);
    expect(reply.exists).toBe(true);

    watcher.stop();
  });

  it("keeps the relative path of an inside path that does not exist, and says it is missing", async () => {
    const watcher = newWatcher();

    const reply = await watcher.resolvePath(join(tempDir, "src", "gone.ts"), {}, new PathStatCache());

    expect(reply.relPath).toBe("src/gone.ts");
    expect(reply.isDirectory).toBe(false);
    expect(reply.exists).toBe(false);

    watcher.stop();
  });

  it("refuses a path outside the checkout root", async () => {
    const watcher = newWatcher();

    // A sibling directory that merely shares the checkout root as a string
    // prefix — the traversal guard must compare path segments, not strings.
    const replies = [
      await watcher.resolvePath(`${tempDir}-sibling/secret.txt`, {}, new PathStatCache()),
      await watcher.resolvePath(join(tempDir, "..", "outside.txt"), {}, new PathStatCache()),
    ];

    for (const reply of replies) {
      expect(reply.relPath).toBeNull();
      // Non-image, so the narrow external-image exception doesn't apply
      // either — see the next test for the case where it does.
      expect(reply.externalImagePath).toBeNull();
      expect(reply.exists).toBe(false);
    }

    watcher.stop();
  });

  it("reports externalImagePath for a recognized image outside the checkout root", async () => {
    const watcher = newWatcher();

    const outsideDir = mkdtempSync(join(tmpdir(), "antgrid-watcher-external-"));
    const outsidePng = join(outsideDir, "generated.png");
    writeFileSync(outsidePng, Buffer.from([0x89, 0x50, 0x4e, 0x47]));

    try {
      const reply = await watcher.resolvePath(outsidePng, {}, new PathStatCache());

      expect(reply.relPath).toBeNull();
      expect(reply.externalImagePath).toBe(outsidePng);
      expect(reply.exists).toBe(true);
    } finally {
      rmSync(outsideDir, { recursive: true, force: true });
      watcher.stop();
    }
  });

  it("does not report externalImagePath for a recognized image that doesn't exist", async () => {
    const watcher = newWatcher();

    const outsideDir = mkdtempSync(join(tmpdir(), "antgrid-watcher-external-"));
    try {
      const reply = await watcher.resolvePath(join(outsideDir, "missing.png"), {}, new PathStatCache());

      expect(reply.relPath).toBeNull();
      expect(reply.externalImagePath).toBeNull();
      expect(reply.exists).toBe(false);
    } finally {
      rmSync(outsideDir, { recursive: true, force: true });
      watcher.stop();
    }
  });

  it("says an outside file that is not an image exists, without naming it", async () => {
    const watcher = newWatcher();

    const outsideDir = mkdtempSync(join(tmpdir(), "antgrid-watcher-external-"));
    const notes = join(outsideDir, "notes.txt");
    writeFileSync(notes, "text");
    try {
      const reply = await watcher.resolvePath(notes, {}, new PathStatCache());

      expect(reply.relPath).toBeNull();
      expect(reply.externalImagePath).toBeNull();
      expect(reply.exists).toBe(true);
    } finally {
      rmSync(outsideDir, { recursive: true, force: true });
      watcher.stop();
    }
  });

  it("resolves a path already given relative to the checkout", async () => {
    const watcher = newWatcher();

    const reply = await watcher.resolvePath("index.ts", {}, new PathStatCache());

    expect(reply.relPath).toBe("index.ts");
    expect(reply.isDirectory).toBe(false);
    expect(reply.exists).toBe(true);

    watcher.stop();
  });

  it("refuses a path that is not a string without throwing", async () => {
    const watcher = newWatcher();
    const { cache, calls } = recordingCache();

    for (const bad of [undefined, null, 42, {}, ["a"]]) {
      const reply = await watcher.resolvePath(bad, {}, cache);
      expect(reply.relPath).toBeNull();
      expect(reply.exists).toBe(false);
    }
    expect((await watcher.resolvePath("a".repeat(4097), {}, cache)).exists).toBe(false);
    expect(calls).toEqual([]);

    watcher.stop();
  });

  // The shape refusal is the whole defence on Windows, where merely stat-ing one
  // of these opens an SMB session; POSIX treats them as ordinary names.
  it.skipIf(process.platform !== "win32")("refuses UNC and device paths before the cache is asked", async () => {
    const watcher = newWatcher();
    const { cache, asked, calls } = askedCache();

    for (const shape of [
      "\\\\host\\share\\a.png", "//host/share/a.png", "/\\host\\share\\a.png",
      "\\\\?\\C:\\x.png", "\\\\.\\pipe\\x",
    ]) {
      for (const opts of [{}, { base: "a" as const }]) {
        const reply = await watcher.resolvePath(shape, opts, cache);
        expect(reply.relPath).toBeNull();
        expect(reply.externalImagePath).toBeNull();
        expect(reply.exists).toBe(false);
      }
    }
    expect(asked).toEqual([]);
    expect(calls).toEqual([]);

    watcher.stop();
  });

  it("refuses a path with control characters before the cache is asked", async () => {
    const watcher = newWatcher();
    const { cache, asked } = askedCache();

    for (const shape of ["src/app.ts" + String.fromCharCode(0), String.fromCharCode(10) + "src/app.ts", "src/" + String.fromCharCode(27) + "app.ts"]) {
      for (const opts of [{}, { base: "r" as const }]) {
        const reply = await watcher.resolvePath(shape, opts, cache);
        expect(reply.relPath).toBeNull();
        expect(reply.exists).toBe(false);
      }
    }
    expect(asked).toEqual([]);

    watcher.stop();
  });

  it("trusts the volume of its own checkout before resolving a path in it", async () => {
    const watcher = newWatcher();
    const trusted: string[] = [];
    const cache = new PathStatCache();
    const trust = cache.trustVolume.bind(cache);
    cache.trustVolume = (root) => {
      trusted.push(root);
      trust(root);
    };

    const reply = await watcher.resolvePath("index.ts", {}, cache);

    expect(reply.exists).toBe(true);
    expect(trusted).toEqual([tempDir]);

    watcher.stop();
  });

  it("resolves against the named base only", async () => {
    const watcher = newWatcher();
    writeFileSync(join(tempDir, "src", "only-here.ts"), "x");

    const reply = await watcher.resolvePath("only-here.ts", { base: "s", spawnCwd: join(tempDir, "src") }, new PathStatCache());

    expect(reply.relPath).toBe("src/only-here.ts");
    expect(reply.exists).toBe(true);

    watcher.stop();
  });

  it("does not fall through to the checkout root when the named base lacks the file", async () => {
    const watcher = newWatcher();

    // index.ts exists under the root but not under src/.
    const reply = await watcher.resolvePath("index.ts", { base: "s", spawnCwd: join(tempDir, "src") }, new PathStatCache());

    expect(reply.relPath).toBe("src/index.ts");
    expect(reply.exists).toBe(false);

    watcher.stop();
  });

  it("uses the live cwd for base l and the checkout root for base r", async () => {
    const watcher = newWatcher();

    const live = await watcher.resolvePath("app.ts", { base: "l", liveCwd: join(tempDir, "src") }, new PathStatCache());
    const root = await watcher.resolvePath("index.ts", { base: "r" }, new PathStatCache());

    expect(live.relPath).toBe("src/app.ts");
    expect(live.exists).toBe(true);
    expect(root.relPath).toBe("index.ts");
    expect(root.exists).toBe(true);

    watcher.stop();
  });

  it("refuses a base that is unavailable or whose cwd is outside the checkout", async () => {
    const watcher = newWatcher();
    const { cache, calls } = recordingCache();

    const none = await watcher.resolvePath("app.ts", { base: "s" }, cache);
    const outside = await watcher.resolvePath("app.ts", { base: "s", spawnCwd: join(tempDir, "..") }, cache);

    for (const reply of [none, outside]) {
      expect(reply.relPath).toBeNull();
      expect(reply.exists).toBe(false);
    }
    expect(calls).toEqual([]);

    watcher.stop();
  });

  it("refuses base a for a relative path", async () => {
    const watcher = newWatcher();
    const { cache, calls } = recordingCache();

    const reply = await watcher.resolvePath("src/app.ts", { base: "a" }, cache);

    expect(reply.relPath).toBeNull();
    expect(reply.exists).toBe(false);
    expect(calls).toEqual([]);

    watcher.stop();
  });

  it("resolves an absolute path under base a", async () => {
    const watcher = newWatcher();

    const reply = await watcher.resolvePath(join(tempDir, "src", "app.ts"), { base: "a" }, new PathStatCache());

    expect(reply.relPath).toBe("src/app.ts");
    expect(reply.exists).toBe(true);

    watcher.stop();
  });
});

describe("FileWatcher pause", () => {
  let tempDir: string;

  beforeEach(() => {
    tempDir = mkdtempSync(join(tmpdir(), "antgrid-watcher-pause-test-"));
    writeFileSync(join(tempDir, "index.ts"), "console.log('hello')");
  });

  afterEach(() => {
    rmSync(tempDir, { recursive: true, force: true });
  });

  it("does not emit tree:update while paused", async () => {
    const connState = createConnState();
    const emitted: AbMessage[] = [];
    const fw = new FileWatcher(
      { path: tempDir, id: "p1" },
      (m) => emitted.push(m),
      connState,
    );
    fw.startWatching();
    await new Promise((r) => setTimeout(r, 500));
    connState.appFocusPaused = true;

    writeFileSync(join(tempDir, "new-file.txt"), "x");
    await new Promise((r) => setTimeout(r, 500));

    const updates = emitted.filter((m) => m.type === "tree:update");
    expect(updates.length).toBe(0);
    expect(connState.fileSeq(tempDir)).toBeGreaterThan(0);
    fw.stop();
  });

  // The Git view used to move only on a 10s poll, so a change the agent had
  // just made could sit invisible for that long. The watcher is what tells the
  // core to re-read git status, and it must do so even while the heavy stream
  // is paused: git:status is not gated by suppression, and its cached frame is
  // what a reconnecting app is replayed from.
  it("reports file changes even while paused, for the git refresh", async () => {
    const connState = createConnState();
    let changes = 0;
    const fw = new FileWatcher(
      { path: tempDir, id: "p1" },
      () => {},
      connState,
      () => changes++,
    );
    fw.startWatching();
    await new Promise((r) => setTimeout(r, 500));
    connState.appFocusPaused = true;

    writeFileSync(join(tempDir, "new-file.txt"), "x");
    await new Promise((r) => setTimeout(r, 500));

    expect(changes).toBeGreaterThan(0);
    fw.stop();
  });

  // The gap the hook above cannot see through on its own: a file written
  // before the watch armed is reported by no event ever. `ignoreInitial`
  // suppresses it as part of the initial scan, and chokidar reads each
  // directory BEFORE attaching that directory's watch, so one landing in
  // between is missed by both halves permanently. Nothing then moves the Git
  // view until the 10s backstop poll — which is what made
  // `git-status-freshness.test.ts` flake on CI, where the core boots slowly
  // enough for a write to land in that window.
  it("asks for a git refresh once the watch is armed", async () => {
    let changes = 0;
    const fw = new FileWatcher(
      { path: tempDir, id: "p1" },
      () => {},
      createConnState(),
      () => changes++,
    );

    writeFileSync(join(tempDir, "written-before-the-watch.ts"), "x");
    fw.startWatching();

    const deadline = Date.now() + 4000;
    while (changes === 0 && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 20));
    }

    expect(changes).toBeGreaterThan(0);
    fw.stop();
  });

  // The throttle is what bounds a remote app's tree-delta bill: sustained churn
  // otherwise pins it at one frame per narrow window for as long as an agent
  // keeps writing. Asserted on RATE, not on a constant, so retuning the windows
  // does not rewrite the test.
  it("widens its coalescing window under sustained churn", async () => {
    const messages: AbMessage[] = [];
    const watcher = new FileWatcher(
      { id: "test", name: "Test", path: tempDir },
      (msg) => messages.push(msg),
      createConnState(),
    );

    const churn = setInterval(() => {
      writeFileSync(join(tempDir, "churn.ts"), `export const n = ${Date.now()}`);
      watcher.handleNativeEvent("churn.ts");
    }, 20);
    await new Promise((r) => setTimeout(r, 2_000));
    clearInterval(churn);

    const updates = messages.filter((m) => m.type === "tree:update").length;
    // 2s of continuous churn: ~20 frames on the narrow window alone, ~4 once
    // widened. Anything at or above 10 means the widening never engaged.
    expect(updates).toBeGreaterThan(0);
    expect(updates).toBeLessThan(10);

    watcher.stop();
  });

  // The narrow window is the one a user watches: a single save must not pay the
  // storm's latency because an unrelated burst happened to precede it.
  it("keeps the narrow window for an isolated change", async () => {
    const messages: AbMessage[] = [];
    const watcher = new FileWatcher(
      { id: "test", name: "Test", path: tempDir },
      (msg) => messages.push(msg),
      createConnState(),
    );

    writeFileSync(join(tempDir, "lone.ts"), "export const a = 1");
    watcher.handleNativeEvent("lone.ts");
    await new Promise((r) => setTimeout(r, 250));

    expect(messages.some((m) => m.type === "tree:update")).toBe(true);

    watcher.stop();
  });

  // The watcher's own ignore prune is unconditional and never consults
  // includeIgnored — a git-ignored path produces no delta at all, not a
  // delta the app then filters out. The refresh is collapse-then-expand,
  // never the watcher.
  it("produces no delta for a git-ignored path", async () => {
    writeFileSync(join(tempDir, ".gitignore"), "*.log\n");
    const messages: AbMessage[] = [];
    const watcher = new FileWatcher(
      { id: "test", name: "Test", path: tempDir },
      (msg) => messages.push(msg),
      createConnState(),
    );

    writeFileSync(join(tempDir, "debug.log"), "noise");
    watcher.handleNativeEvent("debug.log");
    await new Promise((r) => setTimeout(r, 250));

    expect(messages).toEqual([]);

    watcher.stop();
  });

  it("getRootListing returns the root's children at the current fileSeq", () => {
    const connState = createConnState();
    const fw = new FileWatcher(
      { path: tempDir, id: "p1" },
      () => {},
      connState,
    );
    expect(fw.getRootListing(true).children).toBeDefined();
    expect(fw.currentSeq()).toBe(connState.fileSeq(tempDir));
  });
});
