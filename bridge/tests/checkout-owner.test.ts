import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { readCheckoutOwner, sameRepository } from "../src/worktrees/checkout-owner";

describe("readCheckoutOwner", () => {
  let dir: string;
  beforeEach(() => { dir = mkdtempSync(join(tmpdir(), "antgrid-owner-")); });
  afterEach(() => { rmSync(dir, { recursive: true, force: true }); });

  function checkout(pointer?: string): string {
    const path = join(dir, "checkout");
    mkdirSync(path, { recursive: true });
    if (pointer !== undefined) writeFileSync(join(path, ".git"), pointer);
    return path;
  }

  test("names the repository an absolute pointer belongs to", () => {
    // Spelled for the host, because "absolute" is what is under test: a
    // drive-letter path is absolute only on Windows, so on POSIX this fed the
    // relative branch and the two sides resolved against different bases.
    const repo = process.platform === "win32" ? "C:/dev/api" : "/dev/api";
    expect(readCheckoutOwner(checkout(`gitdir: ${repo}/.git/worktrees/one\n`)))
      .toEqual({ kind: "worktree", commonDir: resolve(`${repo}/.git`) });
  });

  test("resolves a relative pointer against the checkout", () => {
    // Git 2.48 writes these when `worktree.useRelativePaths` is set, and a user
    // with it on globally gets them for Antgrid's worktrees too.
    const path = checkout("gitdir: ../../repo/.git/worktrees/one");
    expect(readCheckoutOwner(path))
      .toEqual({ kind: "worktree", commonDir: resolve(path, "../../repo/.git") });
  });

  test("reads a `--separate-git-dir` layout as its own common dir", () => {
    // No `.git` component to strip; answering with the path itself is what
    // makes an unrecognised layout compare unequal rather than accidentally
    // matching ours.
    expect(readCheckoutOwner(checkout("gitdir: /srv/gitdirs/api/worktrees/one")))
      .toMatchObject({ kind: "worktree", commonDir: resolve("/srv/gitdirs/api") });
  });

  test("calls a full clone a repository, never a checkout of ours", () => {
    const path = join(dir, "clone");
    mkdirSync(join(path, ".git"), { recursive: true });
    expect(readCheckoutOwner(path)).toEqual({ kind: "repository" });
  });

  test("calls a directory holding no checkout at all nobody's", () => {
    expect(readCheckoutOwner(checkout())).toEqual({ kind: "none" });
    expect(readCheckoutOwner(checkout("not a pointer file"))).toEqual({ kind: "none" });
    expect(readCheckoutOwner(join(dir, "absent"))).toEqual({ kind: "none" });
  });
});

describe("sameRepository", () => {
  test("compares by the platform's own path rules", () => {
    const insensitive = process.platform === "win32" || process.platform === "darwin";
    expect(sameRepository("/dev/api/.git", "/dev/api/.git/")).toBe(true);
    expect(sameRepository("/dev/API/.git", "/dev/api/.git")).toBe(insensitive);
    expect(sameRepository("/dev/api/.git", "/dev/other/.git")).toBe(false);
  });
});
