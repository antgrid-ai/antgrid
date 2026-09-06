import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { FileWatcher } from "../src/file-watcher";
import { createConnState } from "../src/conn-state";
import type { AbMessage } from "../src/protocol";
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

  it("sends full tree on sendFullTree()", () => {
    const messages: AbMessage[] = [];
    const watcher = new FileWatcher(
      { id: "test", name: "Test", path: tempDir },
      (msg) => messages.push(msg),
      createConnState(),
    );

    watcher.sendFullTree();

    expect(messages.length).toBe(1);
    expect(messages[0].type).toBe("tree:full");
    if (messages[0].type === "tree:full") {
      expect(messages[0].root.type).toBe("directory");
      expect(messages[0].root.children!.length).toBeGreaterThan(0);
    }

    watcher.stop();
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

    expect(messages.some((m) => m.type === "tree:full")).toBe(true);
    expect(messages.some((m) => m.type === "tree:update")).toBe(false);

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
    expect(messages.some((m) => m.type === "tree:full")).toBe(true);

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

  it("resolves an absolute path printed by a terminal program to its checkout-relative form", () => {
    const messages: AbMessage[] = [];
    const watcher = new FileWatcher(
      { id: "test", name: "Test", path: tempDir },
      (msg) => messages.push(msg),
      createConnState(),
    );

    watcher.handleResolvePathRequest("req-1", join(tempDir, "src", "app.ts"));

    expect(messages.length).toBe(1);
    expect(messages[0].type).toBe("file:resolve-path-result");
    if (messages[0].type === "file:resolve-path-result") {
      expect(messages[0].requestId).toBe("req-1");
      expect(messages[0].relPath).toBe("src/app.ts");
      expect(messages[0].isDirectory).toBe(false);
    }

    watcher.stop();
  });

  it("resolves a directory path and reports isDirectory", () => {
    const messages: AbMessage[] = [];
    const watcher = new FileWatcher(
      { id: "test", name: "Test", path: tempDir },
      (msg) => messages.push(msg),
      createConnState(),
    );

    watcher.handleResolvePathRequest("req-2", join(tempDir, "src"));

    expect(messages[0].type).toBe("file:resolve-path-result");
    if (messages[0].type === "file:resolve-path-result") {
      expect(messages[0].relPath).toBe("src");
      expect(messages[0].isDirectory).toBe(true);
    }

    watcher.stop();
  });

  it("refuses a path outside the checkout root", () => {
    const messages: AbMessage[] = [];
    const watcher = new FileWatcher(
      { id: "test", name: "Test", path: tempDir },
      (msg) => messages.push(msg),
      createConnState(),
    );

    // A sibling directory that merely shares the checkout root as a string
    // prefix — the traversal guard must compare path segments, not strings.
    watcher.handleResolvePathRequest("req-3", `${tempDir}-sibling/secret.txt`);
    watcher.handleResolvePathRequest("req-4", join(tempDir, "..", "outside.txt"));

    expect(messages.length).toBe(2);
    for (const msg of messages) {
      expect(msg.type).toBe("file:resolve-path-result");
      if (msg.type === "file:resolve-path-result") {
        expect(msg.relPath).toBeNull();
      }
    }

    watcher.stop();
  });

  it("resolves a path already given relative to the checkout", () => {
    const messages: AbMessage[] = [];
    const watcher = new FileWatcher(
      { id: "test", name: "Test", path: tempDir },
      (msg) => messages.push(msg),
      createConnState(),
    );

    watcher.handleResolvePathRequest("req-5", "index.ts");

    expect(messages[0].type).toBe("file:resolve-path-result");
    if (messages[0].type === "file:resolve-path-result") {
      expect(messages[0].relPath).toBe("index.ts");
      expect(messages[0].isDirectory).toBe(false);
    }

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
    expect(connState.fileSeq).toBeGreaterThan(0);
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

  it("getTreeSnapshot returns current tree + fileSeq", () => {
    const connState = createConnState();
    const fw = new FileWatcher(
      { path: tempDir, id: "p1" },
      () => {},
      connState,
    );
    const snap = fw.getTreeSnapshot();
    expect(snap.tree).toBeDefined();
    expect(snap.seq).toBe(connState.fileSeq);
  });
});
