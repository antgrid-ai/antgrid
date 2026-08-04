import { describe, expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { parseWorktreeList } from "../src/worktrees/git-worktree-list";

describe("parseWorktreeList", () => {
  test("parses porcelain records with spaces, Unicode, and all flags", () => {
    const main = mkdtempSync(join(tmpdir(), "antgrid worktree "));
    const linked = mkdtempSync(join(tmpdir(), "antgrid-工作树-"));
    const raw = [
      `worktree ${main}`, "HEAD abc123", "branch refs/heads/main", "",
      `worktree ${linked}`, "HEAD def456", "detached", "locked maintenance", "prunable stale", "",
      "worktree /bare.git", "bare", "",
    ].join("\0");

    expect(parseWorktreeList(raw)).toEqual([
      { path: main, head: "abc123", branch: "refs/heads/main", bare: false, detached: false, locked: false, prunable: false },
      { path: linked, head: "def456", branch: null, bare: false, detached: true, locked: true, prunable: true },
      { path: expect.any(String), head: null, branch: null, bare: true, detached: false, locked: false, prunable: false },
    ]);
  });

  test("accepts records without empty separators", () => {
    const records = parseWorktreeList("worktree /one\0HEAD a\0worktree /two\0HEAD b\0");
    expect(records).toHaveLength(2);
    expect(records.map((record) => record.head)).toEqual(["a", "b"]);
  });
});
