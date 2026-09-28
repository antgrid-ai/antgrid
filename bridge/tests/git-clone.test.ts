import { test, expect, beforeEach, afterEach } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { GitCloneError, cloneRepository, cloneSshEnv, defaultCloneDirName, isCloneableUrl } from "../src/git-clone";
import { ControlRequestSchema } from "../src/control-protocol";

async function git(cwd: string, args: string[]) {
  const proc = Bun.spawn(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  await proc.exited;
}

let root: string;

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "antgrid-clone-"));
});

afterEach(async () => {
  // A killed (not exited) git subprocess can hold a Windows file handle open
  // for a moment past its own reported kill, so a plain rmSync can lose a race
  // against the OS releasing it — retry rather than flake the whole file.
  for (let i = 0; i < 20; i++) {
    try {
      rmSync(root, { recursive: true, force: true });
      break;
    } catch {
      await new Promise((r) => setTimeout(r, 25));
    }
  }
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

test("refuses a non-absolute parentDir", async () => {
  const err = await cloneRepository({ url: "https://h/o/r.git", parentDir: "relative/dir" }).catch((e) => e);
  expect(err).toBeInstanceOf(GitCloneError);
  expect(err.code).toBe("BAD_TARGET");
});

test("cloneSshEnv sets BatchMode so ssh never blocks on a prompt, but leaves an operator's own GIT_SSH_COMMAND alone", () => {
  const prev = process.env.GIT_SSH_COMMAND;
  try {
    delete process.env.GIT_SSH_COMMAND;
    expect(cloneSshEnv()).toEqual({ GIT_SSH_COMMAND: "ssh -o BatchMode=yes" });

    process.env.GIT_SSH_COMMAND = "custom-ssh-wrapper";
    expect(cloneSshEnv()).toBeUndefined();
  } finally {
    if (prev === undefined) delete process.env.GIT_SSH_COMMAND;
    else process.env.GIT_SSH_COMMAND = prev;
  }
});

test("a killed (timed-out) clone removes the partial target it created, so a retry never fails TARGET_EXISTS", async () => {
  // Accept the TCP connection but never answer, forcing the clone past our
  // short deadline into git-spawn.ts's kill (TerminateProcess on Windows) —
  // the ungraceful kill that leaves a partial directory behind in production,
  // unlike an ordinary connection failure (which git cleans up after itself).
  const server = createServer((socket) => socket.on("error", () => {}));
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", () => resolve()));
  const port = (server.address() as { port: number }).port;
  try {
    const err = await cloneRepository({
      url: `https://127.0.0.1:${port}/o/r.git`,
      parentDir: root,
      timeoutMs: 300,
    }).catch((e) => e);
    expect(err).toBeInstanceOf(GitCloneError);
    expect(err.code).toBe("CLONE_FAILED");
    expect(existsSync(join(root, "r"))).toBe(false);
  } finally {
    server.close();
  }
}, 15_000);

test("git:clone request schema", () => {
  expect(
    ControlRequestSchema.safeParse({ id: "1", type: "git:clone", url: "https://h/o/r.git", parentDir: "/p" }).success,
  ).toBe(true);
  expect(ControlRequestSchema.safeParse({ id: "1", type: "git:clone", parentDir: "/p" }).success).toBe(false);
});
