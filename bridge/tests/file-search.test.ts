import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { FileSearcher } from "../src/file-search";
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
