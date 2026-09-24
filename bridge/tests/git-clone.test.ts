import { test, expect, beforeEach, afterEach } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { GitCloneError, cloneRepository, defaultCloneDirName, isCloneableUrl } from "../src/git-clone";
import { ControlRequestSchema } from "../src/control-protocol";

async function git(cwd: string, args: string[]) {
  const proc = Bun.spawn(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  await proc.exited;
}

let root: string;

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "antgrid-clone-"));
});

afterEach(() => {
  rmSync(root, { recursive: true, force: true });
});

test("only network transports are cloneable", () => {
  expect(isCloneableUrl("https://github.com/o/r.git")).toBe(true);
  expect(isCloneableUrl("git@github.com:o/r.git")).toBe(true);
  expect(isCloneableUrl("ssh://git@host/o/r")).toBe(true);
  expect(isCloneableUrl("file:///etc")).toBe(false);
  expect(isCloneableUrl("ext::sh -c id")).toBe(false);
  expect(isCloneableUrl("--upload-pack=x")).toBe(false);
  expect(isCloneableUrl("/local/path")).toBe(false);
});

test("default folder name is the repo name without .git", () => {
  expect(defaultCloneDirName("https://github.com/o/repo.git")).toBe("repo");
  expect(defaultCloneDirName("git@github.com:o/repo")).toBe("repo");
  expect(defaultCloneDirName("https://github.com/o/repo/")).toBe("repo");
});

test("refuses a bad url before touching the filesystem", async () => {
  const err = await cloneRepository({ url: "file:///tmp/x", parentDir: root }).catch((e) => e);
  expect(err).toBeInstanceOf(GitCloneError);
  expect(err.code).toBe("BAD_URL");
});

test("refuses a missing parent and an existing target", async () => {
  const missing = await cloneRepository({ url: "https://h/o/r.git", parentDir: join(root, "nope") }).catch((e) => e);
  expect(missing.code).toBe("BAD_TARGET");

  mkdirSync(join(root, "r"));
  writeFileSync(join(root, "r", "keep.txt"), "mine");
  const exists = await cloneRepository({ url: "https://h/o/r.git", parentDir: root }).catch((e) => e);
  expect(exists.code).toBe("TARGET_EXISTS");
  expect(existsSync(join(root, "r", "keep.txt"))).toBe(true);
});

test("a failing clone reports CLONE_FAILED", async () => {
  const err = await cloneRepository({ url: "https://127.0.0.1:1/o/r.git", parentDir: root }).catch((e) => e);
  expect(err.code).toBe("CLONE_FAILED");
});

test("git:clone request schema", () => {
  expect(
    ControlRequestSchema.safeParse({ id: "1", type: "git:clone", url: "https://h/o/r.git", parentDir: "/p" }).success,
  ).toBe(true);
  expect(ControlRequestSchema.safeParse({ id: "1", type: "git:clone", parentDir: "/p" }).success).toBe(false);
});
