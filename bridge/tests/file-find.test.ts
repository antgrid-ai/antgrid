import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import {
  FileFinder,
  buildFindRipgrepArgs,
  buildFindGitArgs,
  walkFiles,
  deriveDirectories,
  matchFindEntries,
} from "../src/file-find";
import { loadIgnoreRules } from "../src/file-tree";
import type { AbMessage } from "../src/protocol";
import { mkdirSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { execSync } from "node:child_process";

const TEST_DIR = join(tmpdir(), "antgrid-find-test-" + Date.now());

function setupGitRepo() {
  mkdirSync(TEST_DIR, { recursive: true });
  execSync("git init", { cwd: TEST_DIR, stdio: "ignore" });
  execSync("git config user.email test@test.com", { cwd: TEST_DIR, stdio: "ignore" });
  execSync("git config user.name test", { cwd: TEST_DIR, stdio: "ignore" });
  writeFileSync(join(TEST_DIR, ".gitignore"), "ignored.txt\n");
  writeFileSync(join(TEST_DIR, "tracked.txt"), "hello\n");
  mkdirSync(join(TEST_DIR, "sub"), { recursive: true });
  writeFileSync(join(TEST_DIR, "sub", "nested.txt"), "world\n");
  mkdirSync(join(TEST_DIR, "emptydir"), { recursive: true });
  writeFileSync(join(TEST_DIR, "ignored.txt"), "noise\n");
  // Untracked and named by no `.gitignore` — `git ls-files -c -o` and
  // `rg --files --no-ignore` both emit it, `DEFAULT_IGNORES` does not. It is
  // the fixture that pins all three engines to the tree's answer.
  mkdirSync(join(TEST_DIR, "node_modules", "pkg"), { recursive: true });
  writeFileSync(join(TEST_DIR, "node_modules", "pkg", "index.js"), "x\n");
}

function cleanupTestDir() {
  rmSync(TEST_DIR, { recursive: true, force: true });
}

function findResults(messages: AbMessage[], requestId: string) {
  const m = messages.find((x) => x.type === "file:find-result" && x.requestId === requestId);
  if (!m || m.type !== "file:find-result") throw new Error(`no reply for ${requestId}`);
  return m;
}

describe("FileFinder", () => {
  let messages: AbMessage[];
  let finder: FileFinder;

  beforeEach(() => {
    setupGitRepo();
    messages = [];
    finder = new FileFinder(TEST_DIR, "test-project", (msg) => messages.push(msg), [], () => 0);
  });

  afterEach(() => {
    cleanupTestDir();
  });

  test("kinds:dirs derives directories from file paths and never reports an empty directory", async () => {
    await finder.find({
      projectId: "test-project",
      requestId: "req-dirs",
      query: "",
      includeIgnored: false,
      kinds: "dirs",
      limit: 100,
    });
    const result = findResults(messages, "req-dirs");
    const paths = result.entries.map((e) => e.path);
    expect(paths).toContain("sub");
    // git never tracks an empty directory, so "emptydir" has no file beneath
    // it to derive it from (D15) — the tree shows it, find cannot.
    expect(paths).not.toContain("emptydir");
    expect(result.entries.every((e) => e.isDir)).toBe(true);
  });

  test("includeIgnored:false hides a gitignored file; includeIgnored:true reveals it, and .git is never listed either way", async () => {
    await finder.find({
      projectId: "test-project",
      requestId: "req-hide",
      query: "",
      includeIgnored: false,
      kinds: "files",
      limit: 100,
    });
    const hidden = findResults(messages, "req-hide").entries.map((e) => e.path);
    expect(hidden).not.toContain("ignored.txt");
    expect(hidden.some((p) => p === ".git" || p.startsWith(".git/"))).toBe(false);

    await finder.find({
      projectId: "test-project",
      requestId: "req-reveal",
      query: "",
      includeIgnored: true,
      kinds: "files",
      limit: 100,
    });
    const revealed = findResults(messages, "req-reveal").entries.map((e) => e.path);
    expect(revealed).toContain("ignored.txt");
    expect(revealed.some((p) => p === ".git" || p.startsWith(".git/"))).toBe(false);
  });

  // The filter box replaces the tree on screen, so a result the tree would dim
  // has to arrive dimmable — see FindEntry.ignored.
  test("includeIgnored:true marks the ignored entry and leaves a tracked one unmarked; includeIgnored:false marks nothing", async () => {
    await finder.find({
      projectId: "test-project",
      requestId: "req-marked",
      query: "",
      includeIgnored: true,
      kinds: "files",
      limit: 100,
    });
    const marked = findResults(messages, "req-marked").entries;
    expect(marked.find((e) => e.path === "ignored.txt")?.ignored).toBe(true);
    expect(marked.find((e) => e.path === "tracked.txt")?.ignored).toBeUndefined();

    await finder.find({
      projectId: "test-project",
      requestId: "req-unmarked",
      query: "",
      includeIgnored: false,
      kinds: "files",
      limit: 100,
    });
    // Nothing ignored survived the engine, so there is nothing to mark and no
    // second rule set is built at all.
    const unmarked = findResults(messages, "req-unmarked").entries;
    expect(unmarked.every((e) => e.ignored === undefined)).toBe(true);
  });

  test("marks a directory result ignored by a trailing-slash pattern", async () => {
    writeFileSync(join(TEST_DIR, ".gitignore"), "ignored.txt\nbuilt/\n");
    mkdirSync(join(TEST_DIR, "built"), { recursive: true });
    writeFileSync(join(TEST_DIR, "built", "out.js"), "x\n");

    await finder.find({
      projectId: "test-project",
      requestId: "req-dir-mark",
      query: "built",
      includeIgnored: true,
      kinds: "dirs",
      limit: 100,
    });
    const entries = findResults(messages, "req-dir-mark").entries;
    expect(entries.find((e) => e.path === "built")?.ignored).toBe(true);
  });

  test("cache serves a stale list within the TTL even after seq moves, and re-lists once the TTL has elapsed", async () => {
    let seq = 1;
    let now = 0;
    const clocked = new FileFinder(
      TEST_DIR,
      "test-project",
      (msg) => messages.push(msg),
      [],
      () => seq,
      { now: () => now },
    );

    await clocked.find({
      projectId: "test-project",
      requestId: "req-a",
      query: "",
      includeIgnored: false,
      kinds: "files",
      limit: 100,
    });
    expect(findResults(messages, "req-a").entries.map((e) => e.path)).not.toContain("fresh.txt");

    writeFileSync(join(TEST_DIR, "fresh.txt"), "new\n");
    seq = 2; // a watcher flush landed
    now = 500; // still well inside FIND_CACHE_MIN_TTL_MS (2000)
    await clocked.find({
      projectId: "test-project",
      requestId: "req-b",
      query: "",
      includeIgnored: false,
      kinds: "files",
      limit: 100,
    });
    expect(findResults(messages, "req-b").entries.map((e) => e.path)).not.toContain("fresh.txt");

    now = 2500; // TTL elapsed, and seq has moved since the cached listing
    await clocked.find({
      projectId: "test-project",
      requestId: "req-c",
      query: "",
      includeIgnored: false,
      kinds: "files",
      limit: 100,
    });
    expect(findResults(messages, "req-c").entries.map((e) => e.path)).toContain("fresh.txt");
  });

  test("a superseding request still leaves both requests answered", async () => {
    const p1 = finder.find({
      projectId: "test-project",
      requestId: "req-first",
      query: "",
      includeIgnored: false,
      kinds: "files",
      limit: 100,
    });
    // Give the first call a real turn to reach its spawn before superseding it —
    // otherwise both calls race the same detectFindEngine() microtask and
    // neither ever holds a live process to kill.
    await new Promise<void>((r) => setImmediate(r));
    const p2 = finder.find({
      projectId: "test-project",
      requestId: "req-second",
      query: "",
      includeIgnored: false,
      kinds: "files",
      limit: 100,
    });
    await Promise.all([p1, p2]);

    // Same discipline as FileSearcher: there is no file:find-cancel, so a
    // superseded request's requestId still gets a reply — the app is the one
    // that drops a stale requestId, not the bridge.
    expect(() => findResults(messages, "req-first")).not.toThrow();
    expect(() => findResults(messages, "req-second")).not.toThrow();
  });

  test("the walk engine yields to the event loop instead of blocking through a large directory", async () => {
    const bigDir = join(TEST_DIR, "many");
    mkdirSync(bigDir, { recursive: true });
    for (let i = 0; i < 450; i++) {
      writeFileSync(join(bigDir, `f${i}.txt`), "x");
    }
    let yieldCalls = 0;
    const rules = loadIgnoreRules(TEST_DIR, [], { gitignore: true });
    const result = await walkFiles(TEST_DIR, rules, {
      yieldEvery: 200,
      yieldFn: async () => {
        yieldCalls++;
      },
    });
    // 450+ entries at a 200-entry cadence must yield at least twice — proof
    // the walk actually chunks rather than running to completion in one tick.
    expect(yieldCalls).toBeGreaterThanOrEqual(2);
    expect(result.paths.some((p) => p.endsWith("f0.txt"))).toBe(true);
  });

  test("buildFindRipgrepArgs anchors excludes with /** on BOTH rows — a bare trailing slash is inert on ripgrep 14", () => {
    // The show-all row is where the floor is load-bearing: `--no-ignore` is
    // precisely what makes rg descend into a real `.git/` (5,026 extra paths
    // in the main checkout, measured), so a refactor that moves the floor
    // inside the `if (includeIgnored)` branch has to fail here.
    for (const includeIgnored of [false, true]) {
      const args = buildFindRipgrepArgs(includeIgnored, ["state", "nested/dir"]);
      expect(args).toContain("--hidden");
      expect(args).toContain("!/.git/**");
      expect(args).toContain("!/state/**");
      expect(args).toContain("!/nested/dir/**");
      expect(args).not.toContain("!/state/");
      expect(args).not.toContain("!/nested/dir/");
      expect(args).not.toContain("!/.git/");
    }
    expect(buildFindRipgrepArgs(true, [])).toContain("--no-ignore");
    expect(buildFindRipgrepArgs(false, [])).not.toContain("--no-ignore");
  });


  test("includeIgnored:true means what it means in the tree: gitignore off, DEFAULT_IGNORES still on", async () => {
    // A1: the filter box sends includeIgnored:true so it agrees with the tree
    // it filters, and the tree's show-all variant keeps DEFAULT_IGNORES (see
    // IgnoreRulesOptions in file-tree.ts). Left to the engines this diverged
    // ~16x — `git ls-files -c -o` and `rg --files --no-ignore` emit
    // node_modules, the walk engine does not — so which answer the user got
    // depended on which binaries their machine happened to have, and a
    // node_modules row was a result the tree could never reveal.
    for (const includeIgnored of [false, true]) {
      await finder.find({
        projectId: "test-project",
        requestId: `req-nm-${includeIgnored}`,
        query: "",
        includeIgnored,
        kinds: "both",
        limit: 500,
      });
      const paths = findResults(messages, `req-nm-${includeIgnored}`).entries.map((e) => e.path);
      expect(paths).toContain("tracked.txt");
      expect(paths.some((p) => p === "node_modules" || p.startsWith("node_modules/"))).toBe(false);
    }
  });

  test("a timed-out listing answers with an error and is never cached as an empty result", async () => {
    // The regression: the timeout killed the engine but left activeRequestId
    // intact, so the killed run's empty listing passed the cache guard, was
    // stamped with an unchanged seq, and D12's `cached.seq === seq` clause
    // then served zero entries for as long as no file changed on disk.
    let fire: (() => void) | null = null;
    const timed = new FileFinder(
      TEST_DIR,
      "test-project",
      (msg) => messages.push(msg),
      [],
      () => 0,
      { armTimeout: (f) => { fire = f; return () => {}; } },
    );

    // Fired synchronously rather than raced against the spawn: where in the
    // listing the kill lands is not the invariant — that an aborted listing
    // is reported as an error and never written to the cache is.
    const pending = timed.find({
      projectId: "test-project",
      requestId: "req-timeout",
      query: "",
      includeIgnored: false,
      kinds: "files",
      limit: 100,
    });
    fire!();
    await pending;

    const timedOut = findResults(messages, "req-timeout");
    expect(timedOut.entries).toHaveLength(0);
    expect(timedOut.error).toBeTruthy();
    // `truncated` plus an error is what stops the app rendering an aborted
    // listing as a confident "No matching files".
    expect(timedOut.truncated).toBe(true);
    expect(timedOut.engine).toBe("none");

    await timed.find({
      projectId: "test-project",
      requestId: "req-after-timeout",
      query: "",
      includeIgnored: false,
      kinds: "files",
      limit: 100,
    });
    const after = findResults(messages, "req-after-timeout");
    expect(after.error).toBeUndefined();
    expect(after.entries.map((e) => e.path)).toContain("tracked.txt");
  });

  test("buildFindGitArgs is NUL-delimited and excludes the state dir on both flag values", () => {
    // `-z` is not cosmetic: core.quotePath defaults on, so without it a path
    // holding a byte above 0x7F comes back C-quoted and octal-escaped. This is
    // the engine that runs on any machine without ripgrep, so it is the
    // exclusion that runs in practice.
    for (const includeIgnored of [false, true]) {
      const args = buildFindGitArgs(includeIgnored, ["state", "nested/dir"]);
      expect(args).toContain("-z");
      expect(args).toContain(":(exclude,literal)state");
      expect(args).toContain(":(exclude,literal)nested/dir");
    }
    expect(buildFindGitArgs(false, [])).toContain("--exclude-standard");
    expect(buildFindGitArgs(true, [])).not.toContain("--exclude-standard");
  });

  test("the git engine returns a non-ASCII path verbatim rather than octal-escaped", async () => {
    writeFileSync(join(TEST_DIR, "café.txt"), "x\n");
    await finder.find({
      projectId: "test-project",
      requestId: "req-unicode",
      query: "caf",
      includeIgnored: false,
      kinds: "both",
      limit: 100,
    });
    const paths = findResults(messages, "req-unicode").entries.map((e) => e.path);
    expect(paths).toContain("café.txt");
    // The escaped form used to arrive as the literal `"caf/303/251.txt"`,
    // which also fabricated two directories that never existed.
    expect(paths.some((p) => p.includes("303"))).toBe(false);
    expect(paths.some((p) => p.includes(String.fromCharCode(34)))).toBe(false);
  });

  test("hostile input never throws and always replies", async () => {
    const hostile = {
      projectId: 42,
      requestId: { not: "a string" },
      query: ["array", "not", "string"],
      includeIgnored: "yes",
      kinds: "explode",
      limit: "a lot",
    };
    await expect(finder.find(hostile as never)).resolves.toBeUndefined();
    const results = messages.filter((m) => m.type === "file:find-result");
    expect(results.length).toBeGreaterThanOrEqual(1);
  });
});

describe("pure helpers", () => {
  test("deriveDirectories produces every ancestor prefix, not just the immediate parent", () => {
    const dirs = deriveDirectories(["a/b/c.txt", "a/b/d.txt", "top.txt"]);
    expect(dirs.has("a")).toBe(true);
    expect(dirs.has("a/b")).toBe(true);
    expect(dirs.has("a/b/c.txt")).toBe(false);
  });

  test("matchFindEntries ranks a basename hit above a path-only hit", () => {
    const entries = [
      { path: "deep/nested/needle.txt", isDir: false },
      { path: "needle/shallow.txt", isDir: false },
    ];
    const ranked = matchFindEntries(entries, "needle", 10);
    expect(ranked[0].path).toBe("deep/nested/needle.txt");
  });

  test("a tight basename match outranks a shallower scattered subsequence", () => {
    // Without a tightness tier the only tiebreak among basename hits was
    // depth, and `isSubsequence` is loose enough that i-n-d-e-x appears in
    // order inside a licence filename at depth 2 — which then beat the real
    // `index.ts` at depth 3.
    const entries = [
      { path: "LICENSES/LicenseRef-Third-Party-Trademark.txt", isDir: false },
      { path: "bridge/src/index.ts", isDir: false },
    ];
    expect(matchFindEntries(entries, "index", 10)[0].path).toBe("bridge/src/index.ts");
  });

  test("a matched directory stays reachable past the cap", () => {
    // The Dart ranker this replaced reserved slots for directories outright.
    // Depth ahead of the alphabetical tiebreak preserves the property — a
    // directory is always shallower than the files under it — and nothing
    // else pins it.
    const entries = [
      { path: "widgets", isDir: true },
      ...Array.from({ length: 50 }, (_, i) => ({ path: `widgets/w${i}.dart`, isDir: false })),
    ];
    const ranked = matchFindEntries(entries, "widgets", 3);
    expect(ranked.some((e) => e.isDir && e.path === "widgets")).toBe(true);
  });
});
