import { afterEach, describe, expect, it } from "bun:test";
import {
  existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, symlinkSync, utimesSync, writeFileSync,
} from "node:fs";
import { rename } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AgentSpec } from "antgrid-agents/contracts";
import { HandoffSnapshotError, writeText, ByteBudget, type HandoffSnapshot, type HandoffSnapshotOpts } from "antgrid-agents/handoff";
import {
  assertSessionUuid, materializeHandoff, removeHandoff, stageHandoff, stagingDir, sweepHandoffs,
} from "../src/handoff/handoff-dir";

const ID = "11111111-2222-4333-8444-555555555555";
const OTHER = "99999999-2222-4333-8444-555555555555";
const dirs: string[] = [];
afterEach(() => { for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true }); });

function tmp(): string {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "antgrid-handoff-")));
  dirs.push(dir);
  return dir;
}

type Snapshotter = (opts: HandoffSnapshotOpts) => Promise<HandoffSnapshot | undefined>;

function adapter(snapshot: Snapshotter): AgentSpec {
  return { label: "Fixture", fork: { snapshot } } as unknown as AgentSpec;
}

function git(cwd: string, ...args: string[]): string {
  const run = Bun.spawnSync(["git", "-c", "user.name=t", "-c", "user.email=t@example.com", ...args], { cwd });
  if (run.exitCode !== 0) throw new Error(`git ${args.join(" ")}: ${run.stderr.toString()}`);
  return run.stdout.toString();
}

function initRepo(dir: string): void {
  git(dir, "init", "-q");
  writeFileSync(join(dir, "a.txt"), "a");
  git(dir, "add", "a.txt");
  git(dir, "commit", "-q", "-m", "init");
}

const baseOpts = { projectPath: "/p", maxMsgs: 1, sourceCwd: "/p" };

async function writingSnapshot(opts: HandoffSnapshotOpts): Promise<HandoffSnapshot> {
  const file = await writeText(opts.outDir, "fixture.jsonl", '{"a":1}\n', "transcript", new ByteBudget());
  return { agent: "fixture", method: "copy", primary: "fixture.jsonl", files: [file], references: [], redactions: [], warnings: [] };
}

function stage(sessionsDir: string, snapshot: Snapshotter, scrollback?: string, id = ID, deadlineMs?: number) {
  return stageHandoff({
    sessionsDir, projectId: "p1", newSessionId: id,
    source: { id: "src", name: "Source", tool: "fixture" },
    adapter: adapter(snapshot), snapshotOpts: baseOpts, scrollback, deadlineMs,
  });
}

describe("stageHandoff", () => {
  it("writes the snapshot, adds the scrollback and the manifest last", async () => {
    const store = tmp();
    const manifest = await stage(store, writingSnapshot, "scroll");
    expect(manifest.method).toBe("copy");
    expect(manifest.files.map((f) => f.name)).toEqual(["fixture.jsonl", "terminal-scrollback.txt"]);
    expect(readdirSync(stagingDir(store, ID)).sort()).toEqual(["fixture.jsonl", "manifest.json", "terminal-scrollback.txt"]);
    expect(existsSync(`${stagingDir(store, ID)}.partial`)).toBe(false);
  });

  it("uses the scrollback as the snapshot when the agent has no store", async () => {
    const store = tmp();
    const manifest = await stage(store, async () => undefined, "scroll");
    expect(manifest.method).toBe("scrollback");
    expect(manifest.primary).toBe("terminal-scrollback.txt");
    expect(manifest.warnings).toHaveLength(1);
  });

  it("falls back to the scrollback when the snapshot is unreadable, discarding its partial files", async () => {
    const store = tmp();
    const manifest = await stage(store, async (opts) => {
      await writingSnapshot(opts);
      throw new HandoffSnapshotError("UNREADABLE", "locked");
    }, "scroll");
    expect(manifest.method).toBe("scrollback");
    expect(readdirSync(stagingDir(store, ID)).sort()).toEqual(["manifest.json", "terminal-scrollback.txt"]);
  });

  it("falls back to the scrollback when the deadline passes", async () => {
    const store = tmp();
    const manifest = await stage(store, (opts) => new Promise((_, reject) => {
      opts.signal.addEventListener("abort", () => reject(new HandoffSnapshotError("UNREADABLE", "deadline")));
    }), "scroll", ID, 20);
    expect(manifest.method).toBe("scrollback");
  });

  it("refuses with the existing copy when there is neither a store nor scrollback", async () => {
    const store = tmp();
    await expect(stage(store, async () => undefined, "  ")).rejects.toThrow("This session has no captured transcript to fork yet.");
    expect(existsSync(join(store, "handoff", `${ID}.partial`))).toBe(false);
    expect(existsSync(stagingDir(store, ID))).toBe(false);
  });

  it("refuses an oversized snapshot and leaves nothing staged", async () => {
    const store = tmp();
    await expect(stage(store, async () => { throw new HandoffSnapshotError("TOO_LARGE", "big"); }, "scroll"))
      .rejects.toThrow("over 256 MB");
    expect(readdirSync(join(store, "handoff"))).toEqual([]);
  });

  it("reports a write failure without falling back", async () => {
    const store = tmp();
    await expect(stage(store, async () => { throw Object.assign(new Error("disk"), { code: "ENOSPC" }); }, "scroll"))
      .rejects.toThrow("Could not snapshot the conversation: ENOSPC");
    expect(readdirSync(join(store, "handoff"))).toEqual([]);
  });

  it("reports an output-side failure without falling back to the scrollback", async () => {
    const store = tmp();
    await expect(stage(store, async () => { throw new HandoffSnapshotError("WRITE", "write handoff output (ENOSPC): full", "ENOSPC"); }, "scroll"))
      .rejects.toThrow("Could not snapshot the conversation: ENOSPC");
    expect(readdirSync(join(store, "handoff"))).toEqual([]);
  });

  it("falls back when the adapter names a file that is not a safe flat name", async () => {
    const store = tmp();
    const manifest = await stage(store, async (opts) => {
      const snap = await writingSnapshot(opts);
      return { ...snap, files: [{ ...snap.files[0]!, name: "../escape.jsonl" }] };
    }, "scroll");
    expect(manifest.method).toBe("scrollback");
  });
});

describe("materializeHandoff", () => {
  it("rejects a non-uuid id", async () => {
    expect(() => assertSessionUuid("../x")).toThrow();
    await expect(materializeHandoff(tmp(), tmp(), tmp(), "../x")).rejects.toThrow();
  });

  it("moves the staged dir into the checkout and is idempotent", async () => {
    const store = tmp();
    const checkout = tmp();
    await stage(store, writingSnapshot, "scroll");
    const first = await materializeHandoff(store, checkout, checkout, ID);
    expect(first.dir).toBe(join(checkout, ".antgrid", "handoff", ID));
    expect(readFileSync(join(first.dir, "fixture.jsonl"), "utf8")).toBe('{"a":1}\n');
    expect(existsSync(stagingDir(store, ID))).toBe(false);
    const again = await materializeHandoff(store, checkout, checkout, ID);
    expect(again.manifest.sourceSessionId).toBe("src");
  });

  it("places the handoff under the launch cwd when it is inside the checkout", async () => {
    const store = tmp();
    const checkout = tmp();
    mkdirSync(join(checkout, "app"));
    await stage(store, writingSnapshot);
    const placed = await materializeHandoff(store, checkout, join(checkout, "app"), ID);
    expect(placed.root).toBe(join(checkout, "app"));
    const escaped = tmp();
    await stage(store, writingSnapshot, undefined, OTHER);
    expect((await materializeHandoff(store, checkout, escaped, OTHER)).root).toBe(checkout);
  });

  it("crosses volumes by copying when a rename is refused with EXDEV", async () => {
    const store = tmp();
    const checkout = tmp();
    await stage(store, writingSnapshot);
    const placed = await materializeHandoff(store, checkout, checkout, ID, {
      rename: (async (from: string, to: string) => {
        if (from === stagingDir(store, ID)) throw Object.assign(new Error("x"), { code: "EXDEV" });
        return rename(from, to);
      }) as typeof rename,
    });
    expect(existsSync(join(placed.dir, "manifest.json"))).toBe(true);
    expect(existsSync(stagingDir(store, ID))).toBe(false);
    expect(existsSync(`${placed.dir}.moving`)).toBe(false);
  });

  it("counts a missing staging dir with a valid target manifest as placed", async () => {
    const store = tmp();
    const checkout = tmp();
    await stage(store, writingSnapshot);
    await materializeHandoff(store, checkout, checkout, ID);
    expect((await materializeHandoff(store, checkout, checkout, ID)).dir).toBe(join(checkout, ".antgrid", "handoff", ID));
    await expect(materializeHandoff(store, checkout, checkout, OTHER)).rejects.toThrow("missing");
  });

  it("refuses a symlinked .antgrid", async () => {
    const store = tmp();
    const checkout = tmp();
    const outside = tmp();
    symlinkSync(outside, join(checkout, ".antgrid"), "junction");
    await stage(store, writingSnapshot);
    await expect(materializeHandoff(store, checkout, checkout, ID)).rejects.toThrow("link");
    expect(readdirSync(outside)).toEqual([]);
    expect(existsSync(stagingDir(store, ID))).toBe(true);
  });
});

describe("materializeHandoff in a git checkout", () => {
  it("excludes the placed files, so status stays clean and a worktree removal is not refused", async () => {
    const store = tmp();
    const repo = tmp();
    initRepo(repo);
    const worktree = join(tmp(), "wt");
    git(repo, "worktree", "add", "-q", "-b", "feature", worktree);
    await stage(store, writingSnapshot, "scroll");
    const placed = await materializeHandoff(store, worktree, worktree, ID);
    expect(existsSync(join(placed.dir, "manifest.json"))).toBe(true);
    expect(git(worktree, "status", "--porcelain")).toBe("");
    git(repo, "worktree", "remove", worktree);
    expect(existsSync(worktree)).toBe(false);
  });

  it("names the root when the move fails after the checkout was resolved", async () => {
    const store = tmp();
    const checkout = tmp();
    await stage(store, writingSnapshot);
    const failing = { rename: async () => { throw new Error("nope"); } } as unknown as { rename: typeof rename };
    const error = await materializeHandoff(store, checkout, checkout, ID, failing).catch((e) => e);
    expect((error as { handoffRoot?: string }).handoffRoot).toBe(checkout);
  });
});

describe("removeHandoff", () => {
  it("also removes the copy an interrupted cross-volume move left behind", async () => {
    const checkout = tmp();
    const moving = join(checkout, ".antgrid", "handoff", `${ID}.moving`);
    mkdirSync(moving, { recursive: true });
    writeFileSync(join(moving, "fixture.jsonl"), "partial");
    await removeHandoff(undefined, checkout, ID);
    expect(existsSync(moving)).toBe(false);
  });

  it("removes staging and the checkout copy, and never throws", async () => {
    const store = tmp();
    const checkout = tmp();
    await stage(store, writingSnapshot);
    const placed = await materializeHandoff(store, checkout, checkout, ID);
    await stage(store, writingSnapshot, undefined, OTHER);
    await removeHandoff(store, placed.root, ID);
    await removeHandoff(store, undefined, OTHER);
    expect(existsSync(placed.dir)).toBe(false);
    expect(existsSync(stagingDir(store, OTHER))).toBe(false);
    await removeHandoff(store, checkout, "not-a-uuid");
  });

  it("does not follow a linked .antgrid out of the checkout", async () => {
    const outside = tmp();
    mkdirSync(join(outside, "handoff", ID), { recursive: true });
    const checkout = tmp();
    symlinkSync(outside, join(checkout, ".antgrid"), "junction");
    await removeHandoff(undefined, checkout, ID);
    expect(existsSync(join(outside, "handoff", ID))).toBe(true);
  });
});

describe("sweepHandoffs", () => {
  it("removes old partials, row-less and materialized staging, and this project's row-less checkout dirs only", async () => {
    const store = tmp();
    const project = tmp();
    const ids = {
      partial: "aaaaaaaa-0000-4000-8000-000000000001",
      orphan: "aaaaaaaa-0000-4000-8000-000000000002",
      materialized: "aaaaaaaa-0000-4000-8000-000000000003",
      staged: "aaaaaaaa-0000-4000-8000-000000000004",
      mine: "aaaaaaaa-0000-4000-8000-000000000005",
      theirs: "aaaaaaaa-0000-4000-8000-000000000006",
      kept: "aaaaaaaa-0000-4000-8000-000000000007",
    };
    for (const id of [ids.orphan, ids.materialized, ids.staged]) await stage(store, writingSnapshot, undefined, id);
    const partial = `${stagingDir(store, ids.partial)}.partial`;
    mkdirSync(partial, { recursive: true });
    const old = new Date(Date.now() - 3_600_000);
    utimesSync(partial, old, old);
    for (const [id, projectId] of [[ids.mine, "p1"], [ids.theirs, "other"], [ids.kept, "p1"]] as const) {
      await stage(store, writingSnapshot, undefined, id);
      const placed = join(project, ".antgrid", "handoff", id);
      mkdirSync(join(project, ".antgrid", "handoff"), { recursive: true });
      await rename(stagingDir(store, id), placed);
      const manifest = JSON.parse(readFileSync(join(placed, "manifest.json"), "utf8"));
      writeFileSync(join(placed, "manifest.json"), JSON.stringify({ ...manifest, projectId }));
    }
    await sweepHandoffs({
      sessionsDir: store, projectPath: project, projectId: "p1", inFlight: new Set(),
      rows: new Map([
        [ids.materialized, { forkHandoff: { state: "materialized" as const } }],
        [ids.staged, { forkHandoff: { state: "staged" as const } }],
        [ids.kept, { forkHandoff: { state: "materialized" as const } }],
      ]),
    });
    expect(existsSync(partial)).toBe(false);
    expect(existsSync(stagingDir(store, ids.orphan))).toBe(false);
    expect(existsSync(stagingDir(store, ids.materialized))).toBe(false);
    expect(existsSync(stagingDir(store, ids.staged))).toBe(true);
    expect(existsSync(join(project, ".antgrid", "handoff", ids.mine))).toBe(false);
    expect(existsSync(join(project, ".antgrid", "handoff", ids.theirs))).toBe(true);
    expect(existsSync(join(project, ".antgrid", "handoff", ids.kept))).toBe(true);
  });

  it("keeps the staging dir of any row whose handoff has not been placed, however the marker parsed", async () => {
    const store = tmp();
    await stage(store, writingSnapshot, undefined, ID);
    await sweepHandoffs({ sessionsDir: store, projectPath: tmp(), projectId: "p1", inFlight: new Set(), rows: new Map([[ID, {}]]) });
    expect(existsSync(stagingDir(store, ID))).toBe(true);
  });

  it("visits roots recorded on rows and extra roots, and clears unfinished moves", async () => {
    const store = tmp();
    const project = tmp();
    const nested = tmp();
    const worktree = tmp();
    const ids = [
      "bbbbbbbb-0000-4000-8000-000000000001",
      "bbbbbbbb-0000-4000-8000-000000000002",
      "bbbbbbbb-0000-4000-8000-000000000003",
    ] as const;
    const placeAt = async (root: string, id: string, suffix = "") => {
      await stage(store, writingSnapshot, undefined, id);
      mkdirSync(join(root, ".antgrid", "handoff"), { recursive: true });
      await rename(stagingDir(store, id), join(root, ".antgrid", "handoff", id + suffix));
      return join(root, ".antgrid", "handoff", id + suffix);
    };
    const inNested = await placeAt(nested, ids[0]);
    const inWorktree = await placeAt(worktree, ids[1]);
    const moving = await placeAt(project, ids[2], ".moving");
    rmSync(join(moving, "manifest.json"));
    await sweepHandoffs({
      sessionsDir: store, projectPath: project, projectId: "p1", inFlight: new Set(),
      rows: new Map([["cccccccc-0000-4000-8000-000000000001", { forkHandoff: { state: "materialized" as const, root: nested } }]]),
      extraRoots: [worktree],
    });
    expect(existsSync(inNested)).toBe(false);
    expect(existsSync(inWorktree)).toBe(false);
    expect(existsSync(moving)).toBe(false);
  });

  it("never removes a partial dir or staged dir that is in flight", async () => {
    const store = tmp();
    const partial = `${stagingDir(store, ID)}.partial`;
    mkdirSync(partial, { recursive: true });
    const old = new Date(Date.now() - 3_600_000);
    utimesSync(partial, old, old);
    await stage(store, writingSnapshot, undefined, OTHER);
    await sweepHandoffs({ sessionsDir: store, projectPath: tmp(), projectId: "p1", rows: new Map(), inFlight: new Set([ID, OTHER]) });
    expect(existsSync(partial)).toBe(true);
    expect(existsSync(stagingDir(store, OTHER))).toBe(true);
  });
});
