// bridge/tests/handler/snapshot.test.ts
import { test, expect, describe } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, sep } from "node:path";
import {
  planSnapshots, takeSnapshots, undoSnapshot, sessionTrashDir, clearSessionTrash, describeSnapshot,
  releaseSnapshots, SNAPSHOT_PATTERNS, NO_SNAPSHOT_PATTERNS,
  type GitRun, type SnapshotEntry, type StashSnapshot, type PrePushSnapshot, type TrashSnapshot,
  type SnapshotOutcome,
} from "../../src/handler/snapshot";
import { classifyDestructive } from "../../src/handler/destructive-floor";

// ---------------------------------------------------------------------------
// Real-repo scaffolding. Filesystem correctness is the whole point of this
// module, so the git and copy paths are exercised against real repos rather
// than a fake that would happily agree with a wrong implementation.
// ---------------------------------------------------------------------------

function git(cwd: string, ...args: string[]): string {
  const r = Bun.spawnSync(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  if (r.exitCode !== 0) throw new Error(`git ${args.join(" ")} failed: ${r.stderr.toString()}`);
  return r.stdout.toString().trim();
}

// realpath: macOS /tmp is a symlink, and the inside-project check compares text.
const temp = (prefix: string) => realpathSync(mkdtempSync(join(tmpdir(), prefix)));

interface Fixture {
  project: string;
  abDir: string;
  sessionId: string;
}

const fixtures: string[] = [];

function makeRepo(): Fixture {
  const project = temp("ab-snap-repo-");
  const abDir = temp("ab-snap-home-");
  fixtures.push(project, abDir);
  git(project, "init", "-q", "-b", "main");
  git(project, "config", "user.email", "test@antgrid.local");
  git(project, "config", "user.name", "Antgrid Test");
  // These tests assert exact file BYTES across a checkout. Git for Windows
  // installs core.autocrlf=true globally, which would rewrite every restored
  // "\n" to "\r\n" and fail assertions that have nothing to do with newlines.
  git(project, "config", "core.autocrlf", "false");
  writeFileSync(join(project, "tracked.txt"), "committed\n");
  git(project, "add", "-A");
  git(project, "commit", "-qm", "first");
  return { project, abDir, sessionId: "proj:term-1" };
}

function cleanup(): void {
  for (const d of fixtures.splice(0)) rmSync(d, { recursive: true, force: true });
}

const snapshotted = (o: SnapshotOutcome): SnapshotEntry => {
  if (o.status !== "snapshotted") throw new Error(`expected snapshotted, got ${o.status}: ${JSON.stringify(o)}`);
  return o.entry;
};

const take = (f: Fixture, text: string, extra: Partial<Parameters<typeof takeSnapshots>[0]> = {}) =>
  takeSnapshots({ text, projectPath: f.project, sessionId: f.sessionId, abDir: f.abDir, ...extra });

// ---------------------------------------------------------------------------
// Planning (pure)
// ---------------------------------------------------------------------------

describe("planSnapshots", () => {
  test("recognizes the four §5.2 rows", () => {
    expect(planSnapshots("git reset --hard HEAD~1")).toEqual([
      { action: "reset_hard", trigger: "git reset --hard HEAD~1", targetRef: "HEAD~1" },
    ]);
    expect(planSnapshots("git push --force origin feat/x")).toEqual([
      { action: "force_push", trigger: "git push --force origin feat/x", remote: "origin", refspecs: ["feat/x"], mirror: false },
    ]);
    expect(planSnapshots("rm -rf build dist")).toEqual([
      { action: "rm_rf", trigger: "rm -rf build dist", operands: ["build", "dist"] },
    ]);
    expect(planSnapshots("git clean -fdx")).toEqual([
      { action: "git_clean", trigger: "git clean -fdx", dryRunArgs: ["clean", "-n", "-dx"] },
    ]);
  });

  test("ignores commands that are not preparable", () => {
    expect(planSnapshots("bun run test")).toEqual([]);
    expect(planSnapshots("rm stale.log")).toEqual([]); // no -r/-f: the floor does not flag it either
    expect(planSnapshots("git push origin main")).toEqual([]);
    expect(planSnapshots("git clean -n")).toEqual([]);
    expect(planSnapshots("git reset --soft HEAD~1")).toEqual([]);
  });

  test("sees through sudo, env assignments and && chains", () => {
    const plans = planSnapshots("FOO=1 sudo rm -rf tmp && git reset --hard");
    expect(plans.map((p) => p.action)).toEqual(["rm_rf", "reset_hard"]);
  });

  // The judge's reply is prose ("(when handle) text to send the agent"), so the
  // verb is routinely not the first token. The floor matches it wherever it sits;
  // a plan that did not would leave the action flagged, injected and unprotected
  // with no row saying so.
  test("finds the command inside prose, not only at token 0", () => {
    expect(planSnapshots("Yes, go ahead — run rm -rf node_modules and reinstall")[0]).toMatchObject({
      action: "rm_rf", operands: ["node_modules", "and", "reinstall"],
    });
    expect(planSnapshots("Sure. git push --force origin main")[0]?.action).toBe("force_push");
    expect(planSnapshots("Please confirm: git reset --hard origin/main")[0]?.action).toBe("reset_hard");
  });

  test("one command's operands stop where the next command starts", () => {
    const plans = planSnapshots("first rm -rf build then git reset --hard HEAD~1");
    expect(plans[0]).toMatchObject({ action: "rm_rf", operands: ["build", "then"] });
    expect(plans[1]).toMatchObject({ action: "reset_hard", targetRef: "HEAD~1" });
  });

  test("every planned shape is one the floor also flags", () => {
    // The two parsers are independent and drift silently: a shape only the
    // planner knows is never snapshotted (the engine never enters the pass), and
    // a shape only the floor knows is flagged with no protection.
    for (const cmd of [
      "rm -rf build", "rm --recursive --force dist", "git reset --hard HEAD~1",
      "git push --force origin main", "git push -f", "git push origin +main",
      "git push --mirror origin", "git push --delete origin old",
      "git clean -fd", "git clean --force -d", "git clean -d --force",
    ]) {
      expect(planSnapshots(cmd)).not.toEqual([]);
      expect(classifyDestructive(cmd, "/proj").warnings).not.toEqual([]);
    }
  });

  test("a push carries every refspec it names", () => {
    expect(planSnapshots("git push --force origin main dev")[0]).toMatchObject({
      remote: "origin", refspecs: ["main", "dev"], mirror: false,
    });
    expect(planSnapshots("git push --mirror origin")[0]).toMatchObject({ mirror: true });
  });

  test("keeps quoted operands whole", () => {
    expect(planSnapshots(`rm -rf "my dir/sub" 'other one'`)).toEqual([
      { action: "rm_rf", trigger: `rm -rf "my dir/sub" 'other one'`, operands: ["my dir/sub", "other one"] },
    ]);
  });

  test("honors -- and drops flags from rm operands", () => {
    expect(planSnapshots("rm -rf --no-preserve-root -- -weird-name")).toEqual([
      {
        action: "rm_rf",
        trigger: "rm -rf --no-preserve-root -- -weird-name",
        operands: ["-weird-name"],
      },
    ]);
  });

  test("force push is recognized in every spelling the floor flags", () => {
    for (const cmd of [
      "git push -f origin main",
      "git push --force-with-lease origin main",
      "git push --mirror origin",
      "git push --delete origin old",
      "git push origin +main",
    ]) {
      expect(planSnapshots(cmd)[0]?.action).toBe("force_push");
    }
  });

  test("clean dry-run args mirror the real flags minus force", () => {
    expect(planSnapshots("git clean -f -d -- vendor")[0]).toEqual({
      action: "git_clean",
      trigger: "git clean -f -d -- vendor",
      dryRunArgs: ["clean", "-n", "-d", "--", "vendor"],
    });
  });
});

// ---------------------------------------------------------------------------
// git reset --hard  →  stash + backup ref
// ---------------------------------------------------------------------------

describe("reset_hard", () => {
  test("stashes uncommitted work and restores it on undo", async () => {
    const f = makeRepo();
    try {
      writeFileSync(join(f.project, "tracked.txt"), "live session work\n");

      const entry = snapshotted((await take(f, "git reset --hard"))[0]!) as StashSnapshot;
      expect(entry.kind).toBe("git_stash");
      expect(entry.stashSha).toMatch(/^[0-9a-f]{40}$/);
      expect(git(f.project, "rev-parse", entry.backupRef)).toBe(entry.stashSha!);

      git(f.project, "reset", "--hard");
      expect(readFileSync(join(f.project, "tracked.txt"), "utf8")).toBe("committed\n");

      const undone = await undoSnapshot(entry);
      expect(undone.ok).toBe(true);
      expect(readFileSync(join(f.project, "tracked.txt"), "utf8")).toBe("live session work\n");
    } finally {
      cleanup();
    }
  });

  test("a clean tree with no target ref has nothing at risk", async () => {
    const f = makeRepo();
    try {
      const out = (await take(f, "git reset --hard"))[0]!;
      expect(out.status).toBe("nothing");
    } finally {
      cleanup();
    }
  });

  test("restores commits when the reset moved HEAD, saving the newer state first", async () => {
    const f = makeRepo();
    try {
      writeFileSync(join(f.project, "second.txt"), "second commit\n");
      git(f.project, "add", "-A");
      git(f.project, "commit", "-qm", "second");
      const originalHead = git(f.project, "rev-parse", "HEAD");

      const entry = snapshotted((await take(f, "git reset --hard HEAD~1"))[0]!) as StashSnapshot;
      expect(entry.headSha).toBe(originalHead);
      expect(entry.stashSha).toBeUndefined();

      git(f.project, "reset", "--hard", "HEAD~1");
      expect(existsSync(join(f.project, "second.txt"))).toBe(false);

      // Work done after the reset must survive the undo as its own entry.
      writeFileSync(join(f.project, "tracked.txt"), "post-reset edit\n");

      const undone = await undoSnapshot(entry);
      expect(undone.ok).toBe(true);
      expect(git(f.project, "rev-parse", "HEAD")).toBe(originalHead);
      expect(existsSync(join(f.project, "second.txt"))).toBe(true);

      expect(undone.safety).toBeDefined();
      const back = await undoSnapshot(undone.safety!);
      expect(back.ok).toBe(true);
      expect(readFileSync(join(f.project, "tracked.txt"), "utf8")).toBe("post-reset edit\n");
    } finally {
      cleanup();
    }
  });

  test("commits made after the reset survive the undo via the safety entry", async () => {
    const f = makeRepo();
    try {
      writeFileSync(join(f.project, "second.txt"), "second\n");
      git(f.project, "add", "-A");
      git(f.project, "commit", "-qm", "second");
      const originalHead = git(f.project, "rev-parse", "HEAD");

      const entry = snapshotted((await take(f, "git reset --hard HEAD~1"))[0]!) as StashSnapshot;
      git(f.project, "reset", "--hard", "HEAD~1");

      writeFileSync(join(f.project, "later.txt"), "written after the reset\n");
      git(f.project, "add", "-A");
      git(f.project, "commit", "-qm", "later");
      const laterHead = git(f.project, "rev-parse", "HEAD");

      const undone = await undoSnapshot(entry);
      expect(undone.ok).toBe(true);
      expect(git(f.project, "rev-parse", "HEAD")).toBe(originalHead);
      expect(existsSync(join(f.project, "later.txt"))).toBe(false);

      // The safety entry pins the abandoned commit, so it is not reflog-only.
      expect((undone.safety as StashSnapshot).headSha).toBe(laterHead);
      expect(git(f.project, "rev-parse", undone.safety!.backupRef)).toBe(laterHead);
      expect((await undoSnapshot(undone.safety!)).ok).toBe(true);
      expect(git(f.project, "rev-parse", "HEAD")).toBe(laterHead);
      expect(readFileSync(join(f.project, "later.txt"), "utf8")).toBe("written after the reset\n");
    } finally {
      cleanup();
    }
  });

  test("undo refuses when the backup ref is gone rather than reporting success", async () => {
    const f = makeRepo();
    try {
      writeFileSync(join(f.project, "tracked.txt"), "dirty\n");
      const entry = snapshotted((await take(f, "git reset --hard"))[0]!) as StashSnapshot;
      git(f.project, "update-ref", "-d", entry.backupRef);
      git(f.project, "reflog", "expire", "--expire=now", "--all");
      git(f.project, "gc", "--prune=now", "-q");

      const undone = await undoSnapshot({ ...entry, backupRef: "refs/antgrid/handler-snapshot/missing" });
      expect(undone.ok).toBe(false);
      expect(undone.detail).toContain("gone");
    } finally {
      cleanup();
    }
  });
});

// ---------------------------------------------------------------------------
// rm -rf / git clean  →  session trash
// ---------------------------------------------------------------------------

describe("trash copy", () => {
  test("rm -rf is restorable file-for-file", async () => {
    const f = makeRepo();
    try {
      mkdirSync(join(f.project, "build", "nested"), { recursive: true });
      writeFileSync(join(f.project, "build", "a.txt"), "A\n");
      writeFileSync(join(f.project, "build", "nested", "b.txt"), "B\n");

      const entry = snapshotted((await take(f, "rm -rf build"))[0]!) as TrashSnapshot;
      expect(entry.kind).toBe("trash_copy");
      expect(entry.files).toEqual([{ relPath: "build", trashPath: join(sessionTrashDir(f.sessionId, f.abDir), entry.id, "build") }]);
      expect(entry.bytes).toBe(4);
      expect(readFileSync(join(entry.files[0]!.trashPath, "nested", "b.txt"), "utf8")).toBe("B\n");

      rmSync(join(f.project, "build"), { recursive: true, force: true });
      const undone = await undoSnapshot(entry, { abDir: f.abDir });
      expect(undone.ok).toBe(true);
      expect(readFileSync(join(f.project, "build", "a.txt"), "utf8")).toBe("A\n");
      expect(readFileSync(join(f.project, "build", "nested", "b.txt"), "utf8")).toBe("B\n");
    } finally {
      cleanup();
    }
  });

  test("git clean asks git what it would remove, then restores exactly that", async () => {
    const f = makeRepo();
    try {
      writeFileSync(join(f.project, "untracked.txt"), "U\n");
      mkdirSync(join(f.project, "junk"), { recursive: true });
      writeFileSync(join(f.project, "junk", "c.txt"), "C\n");
      writeFileSync(join(f.project, ".gitignore"), "ignored.txt\n");
      writeFileSync(join(f.project, "ignored.txt"), "I\n");
      git(f.project, "add", ".gitignore");
      git(f.project, "commit", "-qm", "ignore");

      const entry = snapshotted((await take(f, "git clean -fd"))[0]!) as TrashSnapshot;
      const rels = entry.files.map((x) => x.relPath).sort();
      expect(rels).toEqual(["junk", "untracked.txt"]);
      // -x was not asked for, so the ignored file is not at risk and is not copied.
      expect(rels).not.toContain("ignored.txt");

      git(f.project, "clean", "-fd");
      expect(existsSync(join(f.project, "untracked.txt"))).toBe(false);

      const undone = await undoSnapshot(entry, { abDir: f.abDir });
      expect(undone.ok).toBe(true);
      expect(readFileSync(join(f.project, "untracked.txt"), "utf8")).toBe("U\n");
      expect(readFileSync(join(f.project, "junk", "c.txt"), "utf8")).toBe("C\n");
    } finally {
      cleanup();
    }
  });

  test("git clean with nothing to remove reports nothing, not a snapshot", async () => {
    const f = makeRepo();
    try {
      expect((await take(f, "git clean -fd"))[0]!.status).toBe("nothing");
    } finally {
      cleanup();
    }
  });

  test("a path outside the project is refused out loud, not skipped", async () => {
    const f = makeRepo();
    try {
      const out = (await take(f, "rm -rf /etc/nginx"))[0]!;
      expect(out.status).toBe("failed");
      if (out.status !== "failed") return;
      expect(out.reason).toBe("outside_project");
      // Resolved, not literal: the operand is absolutized against the platform's
      // rules, so on Windows a rooted POSIX path picks up the current drive.
      expect(out.detail).toContain(resolve("/etc/nginx"));
    } finally {
      cleanup();
    }
  });

  test("a sibling directory sharing the project prefix is still outside", async () => {
    const f = makeRepo();
    try {
      const out = (await take(f, `rm -rf ${f.project}-evil`))[0]!;
      expect(out.status).toBe("failed");
      if (out.status === "failed") expect(out.reason).toBe("outside_project");
    } finally {
      cleanup();
    }
  });

  test("the project root and glob operands are refused as unsupported", async () => {
    const f = makeRepo();
    try {
      const root = (await take(f, `rm -rf ${f.project}`))[0]!;
      expect(root.status === "failed" && root.reason).toBe("unsupported");
      const glob = (await take(f, "rm -rf build/*"))[0]!;
      expect(glob.status === "failed" && glob.reason).toBe("unsupported");
    } finally {
      cleanup();
    }
  });

  test("a missing target has nothing to copy", async () => {
    const f = makeRepo();
    try {
      expect((await take(f, "rm -rf never-existed"))[0]!.status).toBe("nothing");
    } finally {
      cleanup();
    }
  });

  // "nothing was at risk" is a claim about a path that was resolved and found
  // absent. A shell expands ~ and $VAR before rm sees them, so the string here
  // resolves to <project>/~/Downloads — absent, while the real home directory is
  // what gets deleted.
  test("an operand the shell will expand is unsupported, never 'nothing'", async () => {
    const f = makeRepo();
    try {
      for (const cmd of ["rm -rf ~/Downloads", "rm -rf $HOME/.config", "rm -rf ${TMP}/x"]) {
        const out = (await take(f, cmd))[0]!;
        expect(out.status).toBe("failed");
        if (out.status === "failed") expect(out.reason).toBe("unsupported");
      }
    } finally {
      cleanup();
    }
  });

  // Octal escapes, the quoting every platform can reach: core.quotepath renders
  // any non-ASCII byte as \NNN, and one character is several of them.
  test("a C-quoted git clean path is unquoted, not dropped from the copy", async () => {
    const f = makeRepo();
    try {
      writeFileSync(join(f.project, "quoté.txt"), "Q\n");
      writeFileSync(join(f.project, "plain.txt"), "P\n");

      const entry = snapshotted((await take(f, "git clean -fd"))[0]!) as TrashSnapshot;
      expect(entry.files.map((x) => x.relPath).sort()).toEqual(["plain.txt", "quoté.txt"]);

      git(f.project, "clean", "-fd");
      expect((await undoSnapshot(entry, { abDir: f.abDir })).ok).toBe(true);
      expect(readFileSync(join(f.project, "quoté.txt"), "utf8")).toBe("Q\n");
    } finally {
      cleanup();
    }
  });

  // The backslash-escape branch, which needs a name Windows cannot hold: `"` is
  // a reserved character there, so the fixture cannot even be written.
  test.skipIf(process.platform === "win32")(
    "an escaped quote in a git clean path survives the copy",
    async () => {
      const f = makeRepo();
      try {
        writeFileSync(join(f.project, `quo"te.txt`), "Q\n");

        const entry = snapshotted((await take(f, "git clean -fd"))[0]!) as TrashSnapshot;
        expect(entry.files.map((x) => x.relPath)).toEqual([`quo"te.txt`]);

        git(f.project, "clean", "-fd");
        expect((await undoSnapshot(entry, { abDir: f.abDir })).ok).toBe(true);
        expect(readFileSync(join(f.project, `quo"te.txt`), "utf8")).toBe("Q\n");
      } finally {
        cleanup();
      }
    },
  );

  test("over the ceiling reports failed, so the caller cannot claim protection", async () => {
    const f = makeRepo();
    try {
      mkdirSync(join(f.project, "big"), { recursive: true });
      writeFileSync(join(f.project, "big", "blob.bin"), "x".repeat(4096));

      const byBytes = (await take(f, "rm -rf big", { maxBytes: 1024 }))[0]!;
      expect(byBytes.status).toBe("failed");
      if (byBytes.status === "failed") {
        expect(byBytes.reason).toBe("too_large");
        expect(byBytes.detail).toContain("NOT protected");
      }

      const byFiles = (await take(f, "rm -rf big", { maxFiles: 1 }))[0]!;
      expect(byFiles.status === "failed" && byFiles.reason).toBe("too_large");
      // Nothing half-copied is left behind for a later restore to trust.
      expect(existsSync(sessionTrashDir(f.sessionId, f.abDir))).toBe(false);
    } finally {
      cleanup();
    }
  });

  test("undo reports partial failure instead of claiming success", async () => {
    const f = makeRepo();
    try {
      mkdirSync(join(f.project, "build"), { recursive: true });
      writeFileSync(join(f.project, "build", "a.txt"), "A\n");
      const entry = snapshotted((await take(f, "rm -rf build"))[0]!) as TrashSnapshot;
      rmSync(entry.files[0]!.trashPath, { recursive: true, force: true });

      const undone = await undoSnapshot(entry, { abDir: f.abDir });
      expect(undone.ok).toBe(false);
      expect(undone.detail).toContain("build");
    } finally {
      cleanup();
    }
  });
});

// ---------------------------------------------------------------------------
// git push --force  →  pre-push remote SHA
// ---------------------------------------------------------------------------

describe("force_push", () => {
  test("records the pre-push remote SHA and pushes it back on undo", async () => {
    const f = makeRepo();
    const remote = temp("ab-snap-remote-");
    fixtures.push(remote);
    try {
      git(remote, "init", "-q", "--bare", "-b", "main");
      git(f.project, "remote", "add", "origin", remote);
      git(f.project, "push", "-q", "-u", "origin", "main");
      const published = git(f.project, "rev-parse", "HEAD");

      const entry = snapshotted((await take(f, "git push --force origin main"))[0]!) as PrePushSnapshot;
      expect(entry.remoteSha).toBe(published);
      expect(entry.ref).toBe("refs/heads/main");
      expect(git(f.project, "rev-parse", entry.backupRef)).toBe(published);

      writeFileSync(join(f.project, "tracked.txt"), "rewritten\n");
      git(f.project, "commit", "-qam", "rewrite");
      git(f.project, "push", "-q", "--force", "origin", "main");
      expect(git(remote, "rev-parse", "refs/heads/main")).not.toBe(published);

      const undone = await undoSnapshot(entry);
      expect(undone.ok).toBe(true);
      expect(git(remote, "rev-parse", "refs/heads/main")).toBe(published);
    } finally {
      cleanup();
    }
  });

  test("resolves the target from the upstream when the push names neither", async () => {
    const f = makeRepo();
    const remote = temp("ab-snap-remote-");
    fixtures.push(remote);
    try {
      git(remote, "init", "-q", "--bare", "-b", "main");
      git(f.project, "remote", "add", "origin", remote);
      git(f.project, "push", "-q", "-u", "origin", "main");

      const entry = snapshotted((await take(f, "git push -f"))[0]!) as PrePushSnapshot;
      expect(entry.remote).toBe("origin");
      expect(entry.ref).toBe("refs/heads/main");
    } finally {
      cleanup();
    }
  });

  test("a remote ref that does not exist yet overwrites nothing", async () => {
    const f = makeRepo();
    const remote = temp("ab-snap-remote-");
    fixtures.push(remote);
    try {
      git(remote, "init", "-q", "--bare", "-b", "main");
      git(f.project, "remote", "add", "origin", remote);
      git(f.project, "push", "-q", "-u", "origin", "main");

      const out = (await take(f, "git push --force origin feat/new"))[0]!;
      expect(out.status).toBe("nothing");
    } finally {
      cleanup();
    }
  });

  test("every refspec the push names gets its own snapshot", async () => {
    const f = makeRepo();
    const remote = temp("ab-snap-remote-");
    fixtures.push(remote);
    try {
      git(remote, "init", "-q", "--bare", "-b", "main");
      git(f.project, "remote", "add", "origin", remote);
      git(f.project, "push", "-q", "-u", "origin", "main");
      git(f.project, "branch", "release");
      git(f.project, "push", "-q", "origin", "release");

      const out = await take(f, "git push --force origin main release");
      expect(out).toHaveLength(2);
      const refs = out.map((o) => (snapshotted(o) as PrePushSnapshot).ref).sort();
      expect(refs).toEqual(["refs/heads/main", "refs/heads/release"]);
    } finally {
      cleanup();
    }
  });

  // A mirror push rewrites AND deletes every ref the remote has, including ones
  // this repo has never fetched. Recording one of them and calling the action
  // protected would offer an undo that restores that one and silently leaves the
  // rest destroyed.
  test("a mirror push is reported unprotected rather than falsely protected", async () => {
    const f = makeRepo();
    const remote = temp("ab-snap-remote-");
    fixtures.push(remote);
    try {
      git(remote, "init", "-q", "--bare", "-b", "main");
      git(f.project, "remote", "add", "origin", remote);
      git(f.project, "push", "-q", "-u", "origin", "main");

      const out = (await take(f, "git push --mirror origin"))[0]!;
      expect(out.status).toBe("failed");
      if (out.status === "failed") expect(out.reason).toBe("unsupported");
    } finally {
      cleanup();
    }
  });

  // A hosted remote exposes no reflog, so a blind force back to the recorded SHA
  // is a loss nothing can walk back — the same reason undoStash stashes before it
  // moves HEAD.
  test("an undo taken after the remote moved pins what it overwrites", async () => {
    const f = makeRepo();
    const remote = temp("ab-snap-remote-");
    fixtures.push(remote);
    try {
      git(remote, "init", "-q", "--bare", "-b", "main");
      git(f.project, "remote", "add", "origin", remote);
      git(f.project, "push", "-q", "-u", "origin", "main");
      const published = git(f.project, "rev-parse", "HEAD");

      const entry = snapshotted((await take(f, "git push --force origin main"))[0]!) as PrePushSnapshot;

      writeFileSync(join(f.project, "tracked.txt"), "teammate's work\n");
      git(f.project, "commit", "-qam", "later");
      git(f.project, "push", "-q", "--force", "origin", "main");
      const laterTip = git(f.project, "rev-parse", "HEAD");

      const undone = await undoSnapshot(entry);
      expect(undone.ok).toBe(true);
      expect(git(remote, "rev-parse", "refs/heads/main")).toBe(published);

      // The overwritten tip is an undoable entry of its own, not reflog-only.
      const safety = undone.safety as PrePushSnapshot;
      expect(safety.kind).toBe("pre_push_sha");
      expect(safety.remoteSha).toBe(laterTip);
      expect(git(f.project, "rev-parse", safety.backupRef)).toBe(laterTip);
      expect((await undoSnapshot(safety)).ok).toBe(true);
      expect(git(remote, "rev-parse", "refs/heads/main")).toBe(laterTip);
    } finally {
      cleanup();
    }
  });

  test("an unreachable remote fails rather than recording an unusable SHA", async () => {
    const f = makeRepo();
    try {
      git(f.project, "remote", "add", "origin", join(f.project, "no-such-remote.git"));
      const out = (await take(f, "git push --force origin main"))[0]!;
      expect(out.status).toBe("failed");
      if (out.status === "failed") expect(out.reason).toBe("git_failed");
    } finally {
      cleanup();
    }
  });
});

// ---------------------------------------------------------------------------
// Injectable exec, trash scoping, rendering
// ---------------------------------------------------------------------------

describe("module surface", () => {
  test("git paths run through the injected runner, so no repo is required", async () => {
    const calls: string[][] = [];
    const runGit = async (_cwd: string, args: string[]): Promise<GitRun> => {
      calls.push(args);
      if (args[0] === "rev-parse") return { exitCode: 0, stdout: "a".repeat(40), stderr: "" };
      if (args[0] === "stash") return { exitCode: 0, stdout: `${"b".repeat(40)}\n`, stderr: "" };
      return { exitCode: 0, stdout: "", stderr: "" };
    };

    const out = await takeSnapshots({
      text: "git reset --hard",
      projectPath: "/nowhere/proj",
      sessionId: "s1",
      abDir: "/nowhere/ab",
      runGit,
      now: () => 1234,
      newId: () => "fixed-id",
    });
    const entry = snapshotted(out[0]!) as StashSnapshot;
    expect(entry).toEqual({
      id: "fixed-id",
      at: 1234,
      sessionId: "s1",
      projectPath: "/nowhere/proj",
      trigger: "git reset --hard",
      kind: "git_stash",
      headSha: "a".repeat(40),
      stashSha: "b".repeat(40),
      backupRef: "refs/antgrid/handler-snapshot/fixed-id",
    });
    expect(calls).toContainEqual(["update-ref", "refs/antgrid/handler-snapshot/fixed-id", "b".repeat(40)]);
  });

  test("a git failure surfaces the stderr rather than a bare entry", async () => {
    const runGit = async (): Promise<GitRun> => ({ exitCode: 128, stdout: "", stderr: "fatal: not a git repository\n" });
    const out = await takeSnapshots({
      text: "git reset --hard", projectPath: "/nowhere", sessionId: "s1", abDir: "/nowhere", runGit,
    });
    expect(out[0]!.status).toBe("failed");
    if (out[0]!.status === "failed") expect(out[0]!.detail).toContain("not a git repository");
  });

  test("one text can carry several actions, each reported independently", async () => {
    const f = makeRepo();
    try {
      writeFileSync(join(f.project, "tracked.txt"), "dirty\n");
      mkdirSync(join(f.project, "out"), { recursive: true });
      writeFileSync(join(f.project, "out", "x"), "X\n");

      const outcomes = await take(f, "rm -rf out && git reset --hard && rm -rf /etc/hosts");
      expect(outcomes.map((o) => [o.action, o.status])).toEqual([
        ["rm_rf", "snapshotted"],
        ["reset_hard", "snapshotted"],
        ["rm_rf", "failed"],
      ]);
    } finally {
      cleanup();
    }
  });

  test("a prose operand still snapshots the directory the agent will delete", async () => {
    const f = makeRepo();
    try {
      mkdirSync(join(f.project, "node_modules"), { recursive: true });
      writeFileSync(join(f.project, "node_modules", "dep.js"), "X\n");

      const [out] = await take(f, "run rm -rf node_modules, then reinstall");
      expect(snapshotted(out!).kind).toBe("trash_copy");
    } finally {
      cleanup();
    }
  });

  test("a directory whose name really ends in punctuation is not trimmed away", async () => {
    const f = makeRepo();
    try {
      // Trimming unconditionally would resolve `build (old)` to `build (old`,
      // find nothing, and report "nothing at risk" about a directory that was.
      mkdirSync(join(f.project, "build (old)"), { recursive: true });
      writeFileSync(join(f.project, "build (old)", "x"), "X\n");

      const [out] = await take(f, `rm -rf "build (old)"`);
      expect(snapshotted(out!).kind).toBe("trash_copy");
    } finally {
      cleanup();
    }
  });

  test("trash is session-scoped and clearable", async () => {
    const f = makeRepo();
    try {
      const other = sessionTrashDir("proj:term-2", f.abDir);
      expect(sessionTrashDir(f.sessionId, f.abDir)).not.toBe(other);

      mkdirSync(join(f.project, "build"), { recursive: true });
      writeFileSync(join(f.project, "build", "a.txt"), "A\n");
      snapshotted((await take(f, "rm -rf build"))[0]!);
      expect(existsSync(sessionTrashDir(f.sessionId, f.abDir))).toBe(true);

      await clearSessionTrash(f.sessionId, f.abDir);
      expect(existsSync(sessionTrashDir(f.sessionId, f.abDir))).toBe(false);
    } finally {
      cleanup();
    }
  });

  test("a session id with path separators cannot escape the trash root", () => {
    const root = join("/ab", "handler-trash");
    const dir = sessionTrashDir("../../etc/evil", "/ab");
    // One flat segment under the root: separators are gone, so there is no
    // traversal left to resolve.
    expect(dir.startsWith(`${root}${sep}`)).toBe(true);
    expect(dir.slice(root.length + 1)).not.toMatch(/[\\/]/);
    expect(resolve(dir).startsWith(resolve(root))).toBe(true);
  });

  // A backup ref keeps its stash commit — and everything reachable from it —
  // alive against `git gc` for as long as it exists, so an entry dropped from the
  // store without this leaves a pin nobody can ever name again.
  test("releasing an entry drops its backup ref and its trash copy", async () => {
    const f = makeRepo();
    try {
      writeFileSync(join(f.project, "tracked.txt"), "dirty\n");
      const stash = snapshotted((await take(f, "git reset --hard"))[0]!) as StashSnapshot;
      mkdirSync(join(f.project, "build"), { recursive: true });
      writeFileSync(join(f.project, "build", "a.txt"), "A\n");
      const trash = snapshotted((await take(f, "rm -rf build"))[0]!) as TrashSnapshot;

      expect(git(f.project, "rev-parse", "--verify", stash.backupRef)).toBeTruthy();
      expect(existsSync(trash.files[0]!.trashPath)).toBe(true);

      await releaseSnapshots([stash, trash], { abDir: f.abDir });

      expect(Bun.spawnSync(["git", "rev-parse", "--verify", stash.backupRef], { cwd: f.project }).exitCode)
        .not.toBe(0);
      expect(existsSync(trash.files[0]!.trashPath)).toBe(false);
    } finally {
      cleanup();
    }
  });

  test("SNAPSHOT_PATTERNS maps a live floor pattern for each §5.2 action", () => {
    expect([...new Set(SNAPSHOT_PATTERNS.values())].sort())
      .toEqual(["force_push", "git_clean", "reset_hard", "rm_rf"]);
    for (const [pattern, action] of SNAPSHOT_PATTERNS) {
      const cmd = { reset_hard: "git reset --hard HEAD", force_push: "git push --force origin main",
        rm_rf: "rm -rf build", git_clean: "git clean -fd" }[action];
      expect(classifyDestructive(cmd, "/proj").warnings.map((w) => w.pattern)).toContain(pattern);
    }
  });

  test("NO_SNAPSHOT_PATTERNS names only shapes §5.2 can never cover", () => {
    const outward = [
      "gh pr merge 1", "gh pr close 1", "gh release delete v1", "gh repo delete owner/name",
      "git branch -D topic", "git tag -d v1", "npm publish",
    ];
    expect(NO_SNAPSHOT_PATTERNS.size).toBeGreaterThan(0);
    for (const pattern of NO_SNAPSHOT_PATTERNS) expect(SNAPSHOT_PATTERNS.has(pattern)).toBe(false);
    for (const cmd of outward) {
      const flagged = classifyDestructive(cmd, "/proj").warnings
        .filter((w) => w.tier === "DESTRUCTIVE").map((w) => w.pattern);
      expect(flagged.some((p) => NO_SNAPSHOT_PATTERNS.has(p))).toBe(true);
      // Planning nothing is the correct answer, not a parser gap: the state these
      // move is outside the project, so there is nothing local to hold.
      expect(planSnapshots(cmd)).toEqual([]);
    }
  });

  test("describeSnapshot renders one line per mechanism", () => {
    const b = { id: "i", at: 0, sessionId: "s", projectPath: "/p", trigger: "t" };
    expect(describeSnapshot({ ...b, kind: "git_stash", headSha: "a".repeat(40), stashSha: "b".repeat(40), backupRef: "r" }))
      .toBe("saved working tree (bbbbbbb) and HEAD aaaaaaa");
    expect(describeSnapshot({ ...b, kind: "pre_push_sha", remote: "origin", ref: "refs/heads/main", remoteSha: "c".repeat(40), backupRef: "r" }))
      .toBe("recorded origin refs/heads/main at ccccccc");
    expect(describeSnapshot({ ...b, kind: "trash_copy", files: [{ relPath: "a", trashPath: "/t/a" }], bytes: 12 }))
      .toBe("copied 1 path(s), 12 bytes, to session trash");
  });
});
