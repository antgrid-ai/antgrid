import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { FileSearcher, SearchOutputParser, buildRipgrepArgs, type SearchMatchData } from "../src/file-search";
import type { AbMessage } from "../src/protocol";
import { mkdirSync, writeFileSync, rmSync, existsSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { execSync } from "node:child_process";

const TEST_DIR = join(tmpdir(), "antgrid-search-test-" + Date.now());

function setupTestDir() {
  mkdirSync(TEST_DIR, { recursive: true });
  // Init a git repo so git-grep works with --untracked
  execSync("git init", { cwd: TEST_DIR, stdio: "ignore" });
  writeFileSync(join(TEST_DIR, "hello.txt"), "Hello World\nfoo bar baz\nHello again\n");
  writeFileSync(join(TEST_DIR, "code.ts"), "const x = 42;\nfunction hello() {\n  return 'world';\n}\n");
  writeFileSync(join(TEST_DIR, "empty.txt"), "");
}

function cleanupTestDir() {
  rmSync(TEST_DIR, { recursive: true, force: true });
}

describe("FileSearcher", () => {
  let messages: AbMessage[];
  let searcher: FileSearcher;

  beforeEach(() => {
    setupTestDir();
    messages = [];
    searcher = new FileSearcher(TEST_DIR, "test-project", (msg) => {
      messages.push(msg);
    });
  });

  afterEach(() => {
    cleanupTestDir();
  });

  test("search finds matching text across files", async () => {
    await searcher.search({
      projectId: "test-project",
      query: "Hello",
      caseSensitive: false,
      regex: false,
      wholeWord: false,
      requestId: "req-1",
    });

    const done = messages.find((m) => m.type === "file:search-done");
    expect(done).toBeDefined();
    expect(done!.type).toBe("file:search-done");
    if (done!.type === "file:search-done") {
      expect(done!.totalMatches).toBeGreaterThanOrEqual(2);
      expect(done!.totalFiles).toBeGreaterThanOrEqual(1);
      expect(done!.error).toBeUndefined();
    }

    const results = messages.filter((m) => m.type === "file:search-result");
    expect(results.length).toBeGreaterThanOrEqual(1);
  });

  test("case-sensitive search respects flag", async () => {
    await searcher.search({
      projectId: "test-project",
      query: "hello",
      caseSensitive: true,
      regex: false,
      wholeWord: false,
      requestId: "req-2",
    });

    const done = messages.find((m) => m.type === "file:search-done");
    expect(done).toBeDefined();
    if (done!.type === "file:search-done") {
      expect(done!.totalMatches).toBeGreaterThanOrEqual(1);
    }
  });

  test("search with no results sends done with zero matches", async () => {
    await searcher.search({
      projectId: "test-project",
      query: "zzz_nonexistent_pattern_zzz",
      caseSensitive: false,
      regex: false,
      wholeWord: false,
      requestId: "req-3",
    });

    const done = messages.find((m) => m.type === "file:search-done");
    expect(done).toBeDefined();
    if (done!.type === "file:search-done") {
      expect(done!.totalMatches).toBe(0);
      expect(done!.totalFiles).toBe(0);
    }
  });

  test("cancel kills the search process", async () => {
    const searchPromise = searcher.search({
      projectId: "test-project",
      query: "Hello",
      caseSensitive: false,
      regex: false,
      wholeWord: false,
      requestId: "req-4",
    });
    searcher.cancel("req-4");
    await searchPromise;

    const done = messages.find((m) => m.type === "file:search-done");
    expect(done).toBeDefined();
  });

  test("an excluded dir inside the root is not searched, a same-named one elsewhere still is", async () => {
    // The Antgrid state dir holds every managed worktree, so a main-scoped
    // search that walks into it reports the isolated checkouts' content as
    // main's. Only the root-level directory is off limits — a project of its
    // own that happens to share the name is still project content.
    mkdirSync(join(TEST_DIR, "state", "wt"), { recursive: true });
    writeFileSync(join(TEST_DIR, "state", "wt", "isolated.txt"), "needle\n");
    mkdirSync(join(TEST_DIR, "src", "state"), { recursive: true });
    writeFileSync(join(TEST_DIR, "src", "state", "own.txt"), "needle\n");

    const scoped = new FileSearcher(TEST_DIR, "test-project", (msg) => messages.push(msg), [
      join(TEST_DIR, "state"),
    ]);
    await scoped.search({
      projectId: "test-project",
      query: "needle",
      caseSensitive: false,
      regex: false,
      wholeWord: false,
      requestId: "req-exclude",
    });

    const paths = messages
      .filter((m) => m.type === "file:search-result")
      .flatMap((m) => (m.type === "file:search-result" ? m.matches.map((x) => x.path) : []));
    expect(paths.some((p) => p.includes("isolated.txt"))).toBe(false);
    expect(paths.some((p) => p.includes("own.txt"))).toBe(true);
  });

  test("the ripgrep exclude glob is anchored with /** — a bare trailing slash is inert on ripgrep 14", () => {
    // This is a shape assertion, not a presence assertion: a test that only
    // checked "--glob" was passed at all would have let the original `!/x/`
    // form (which ripgrep 14 silently ignores — measured, see the comment on
    // buildRipgrepArgs) ship green. This machine has no `rg` reachable by
    // Bun.spawn (see F3 in the wave-3 codemap), so the shape is all a local
    // run can verify; the exclude actually working is covered by the git-grep
    // path in the tests above.
    const args = buildRipgrepArgs(
      {
        projectId: "p",
        query: "needle",
        caseSensitive: false,
        regex: false,
        wholeWord: false,
        requestId: "req",
      },
      ["state", "nested/dir"],
    );
    const globIndex = (rel: string) => args.indexOf(`!/${rel}/**`);
    expect(globIndex("state")).toBeGreaterThan(-1);
    expect(globIndex("nested/dir")).toBeGreaterThan(-1);
    expect(args).not.toContain("!/state/");
    expect(args).not.toContain("!/nested/dir/");
  });

  test("an exclude outside the search root leaves the search intact", async () => {
    // A searcher rooted at a managed worktree sits UNDER the state dir it is
    // handed; anchoring that exclude would blank its own results.
    const nested = new FileSearcher(TEST_DIR, "test-project", (msg) => messages.push(msg), [
      join(TEST_DIR, "..", "somewhere-else"),
    ]);
    await nested.search({
      projectId: "test-project",
      query: "Hello",
      caseSensitive: false,
      regex: false,
      wholeWord: false,
      requestId: "req-outside",
    });

    const done = messages.find((m) => m.type === "file:search-done");
    expect(done!.type === "file:search-done" && done!.totalMatches).toBeGreaterThanOrEqual(2);
  });

  test("whole word search only matches complete words", async () => {
    writeFileSync(join(TEST_DIR, "words.txt"), "cat\ncatalog\nthe cat sat\n");

    await searcher.search({
      projectId: "test-project",
      query: "cat",
      caseSensitive: false,
      regex: false,
      wholeWord: true,
      requestId: "req-5",
    });

    const results = messages.filter((m) => m.type === "file:search-result");
    const allMatches = results.flatMap((m) =>
      m.type === "file:search-result" ? m.matches : []
    );
    for (const match of allMatches) {
      if (match.path.endsWith("words.txt")) {
        expect(match.lineContent).not.toContain("catalog");
      }
    }
  });
});

describe("FileSearcher outside a git repository", () => {
  const dir = join(tmpdir(), "antgrid-search-norepo-" + Date.now());
  let messages: AbMessage[];
  const run = (query: string, regex = false) =>
    new FileSearcher(dir, "p", (m) => messages.push(m)).search({
      projectId: "p",
      query,
      caseSensitive: false,
      regex,
      wholeWord: false,
      requestId: "r",
    });

  beforeEach(() => {
    messages = [];
    mkdirSync(join(dir, "sub"), { recursive: true });
    writeFileSync(join(dir, "sub", "a.txt"), "needle here\n");
  });
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  test("finds matches in a folder that is not a repository", async () => {
    await run("needle");
    const paths = messages.flatMap((m) => (m.type === "file:search-result" ? m.matches.map((x) => x.path) : []));
    expect(paths).toEqual(["sub/a.txt"]);
  });

  test("reports an invalid regex instead of an empty result", async () => {
    await run("(", true);
    const done = messages.find((m) => m.type === "file:search-done");
    expect(done?.type === "file:search-done" && done.error).toBeTruthy();
  });
});

describe("SearchOutputParser", () => {
  const collect = (engine: "ripgrep" | "git-grep", chunks: string[]) => {
    const out: SearchMatchData[] = [];
    const parser = new SearchOutputParser(engine, "/root", (m) => out.push(m));
    for (const c of chunks) parser.push(c);
    parser.end();
    return out;
  };

  // Git for Windows checks out CRLF by default, and git grep prints the file's
  // `\r` on every line. The regexes cannot match across it, so every match on
  // such a checkout used to be dropped without a word.
  test("git-grep: CRLF-terminated lines still parse, without the \r in the content", () => {
    const out = collect("git-grep", [
      "a.dart-1-before\r\na.dart:2:3:CarbonButton x\r\na.dart-3-after\r\n--\r\nb.dart:9:1:CarbonButton\r\n",
    ]);
    expect(out).toHaveLength(2);
    expect(out[0]).toEqual({
      path: "a.dart",
      line: 2,
      column: 3,
      lineContent: "CarbonButton x",
      contextBefore: ["before"],
      contextAfter: ["after"],
    });
    expect(out[1]!.path).toBe("b.dart");
    expect(out[1]!.lineContent).toBe("CarbonButton");
  });

  test("git-grep: a chunk boundary between \r and \n loses nothing", () => {
    const out = collect("git-grep", ["a.dart:2:3:hit\r", "\nb.dart:4:1:hit\r", "\n"]);
    expect(out.map((m) => [m.path, m.lineContent])).toEqual([
      ["a.dart", "hit"],
      ["b.dart", "hit"],
    ]);
  });

  test("git-grep: a final line with no terminator is still parsed", () => {
    expect(collect("git-grep", ["a.dart:1:1:last\r"]).map((m) => m.lineContent)).toEqual(["last"]);
  });

  test("ripgrep: CRLF line text arrives without its \r", () => {
    const line = (o: unknown) => JSON.stringify(o) + "\n";
    const out = collect("ripgrep", [
      line({ type: "begin", data: { path: { text: "./a.dart" } } }),
      line({ type: "context", data: { lines: { text: "before\r\n" } } }),
      line({
        type: "match",
        data: { path: { text: "./a.dart" }, line_number: 2, lines: { text: "hit\r\n" }, submatches: [{ start: 0 }] },
      }),
      line({ type: "context", data: { lines: { text: "after\r\n" } } }),
      line({ type: "end", data: {} }),
    ]);
    expect(out).toHaveLength(1);
    expect(out[0]).toMatchObject({
      path: "a.dart",
      line: 2,
      column: 1,
      lineContent: "hit",
      contextBefore: ["before"],
      contextAfter: ["after"],
    });
  });
});

describe("FileSearcher end to end", () => {
  const dir = join(tmpdir(), "antgrid-search-e2e-" + Date.now());
  let messages: AbMessage[];

  beforeEach(() => {
    messages = [];
    mkdirSync(dir, { recursive: true });
    execSync("git init", { cwd: dir, stdio: "ignore" });
    writeFileSync(join(dir, "crlf.dart"), "one\r\nCarbonButton here\r\nthree\r\n");
  });
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  const opts = (requestId: string) => ({
    projectId: "p",
    query: "CarbonButton",
    caseSensitive: false,
    regex: false,
    wholeWord: false,
    requestId,
  });

  test("finds a match in a CRLF file", async () => {
    await new FileSearcher(dir, "p", (m) => messages.push(m)).search(opts("r-crlf"));
    const matches = messages.flatMap((m) => (m.type === "file:search-result" ? m.matches : []));
    expect(matches).toHaveLength(1);
    expect(matches[0]!.path).toBe("crlf.dart");
    expect(matches[0]!.lineContent).toBe("CarbonButton here");
    expect(matches[0]!.contextBefore).toEqual(["one"]);
    expect(matches[0]!.contextAfter).toEqual(["three"]);
  });

  test("a timed-out search reports a failure, not zero results", async () => {
    // A zero timeout fires long before any engine can spawn and answer.
    await new FileSearcher(dir, "p", (m) => messages.push(m), [], { timeoutMs: 0 }).search(opts("r-timeout"));
    const done = messages.find((m) => m.type === "file:search-done");
    expect(done?.type === "file:search-done" && done.error).toMatch(/timed out/);
  });

  test("a superseded search is answered as cancelled, and the newer one completes", async () => {
    const searcher = new FileSearcher(dir, "p", (m) => messages.push(m));
    const first = searcher.search(opts("r-old"));
    const second = searcher.search(opts("r-new"));
    await Promise.all([first, second]);
    const doneFor = (id: string) =>
      messages.find((m) => m.type === "file:search-done" && m.requestId === id);
    const old = doneFor("r-old");
    expect(old?.type === "file:search-done" && old.error).toBe("Search cancelled");
    const fresh = doneFor("r-new");
    expect(fresh?.type === "file:search-done" && fresh.totalMatches).toBe(1);
    expect(fresh?.type === "file:search-done" && fresh.error).toBeUndefined();
  });
});
