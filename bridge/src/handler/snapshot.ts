// bridge/src/handler/snapshot.ts

// Snapshot-before-act (spec §5.2). The advisory floor stopped being a gate, and
// what buys that back is reversibility: for a flagged action that is destructive
// but *preparable*, Handler takes a cheap snapshot and proceeds without waking
// anyone. Being wrong then costs one tap instead of a lost afternoon.
//
// Scope: this reads the text Handler is about to INJECT, never the commands the
// agent goes on to run. A snapshot covers "Handler told the agent to force push",
// not "the agent decided to force push on its own".
//
// The outcome type distinguishes "snapshotted" / "nothing" / "failed" because the
// UI turns that difference into a promise to the user. An entry nobody can undo
// from is worse than no entry at all, so every path that cannot guarantee the undo
// reports `failed` rather than recording a hopeful entry.

import { cp, lstat, mkdir, readdir, rm } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { dirname, join, relative, resolve } from "node:path";
import { resolveAbDir } from "../antgrid-dir";
import { classifyDestructive } from "./destructive-floor";

// ---------------------------------------------------------------------------
// git invocation
// ---------------------------------------------------------------------------

export interface GitRun {
  exitCode: number;
  stdout: string;
  stderr: string;
}

/** Injectable so tests can drive the parse/record paths without a real repo. */
export type GitRunner = (cwd: string, args: string[]) => Promise<GitRun>;

// A snapshot runs inline on the act path, so a git call that blocks forever
// blocks the supervised session. `ls-remote` can sit on a credential prompt or a
// dead network, hence both the kill timer and GIT_TERMINAL_PROMPT.
const GIT_TIMEOUT_MS = 20_000;

/**
 * Mirrors `src/git.ts`'s runner (same spawn shape, same `core.quotepath=false`
 * so non-ASCII paths stay verbatim rather than C-quoted). It is a separate copy
 * only because this one must not hang and must parse English git prose:
 * `git clean -n` output is localized, so LC_ALL pins it.
 */
async function defaultRunGit(cwd: string, args: string[]): Promise<GitRun> {
  const proc = Bun.spawn(["git", "-c", "core.quotepath=false", ...args], {
    cwd,
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env, LC_ALL: "C", GIT_TERMINAL_PROMPT: "0" },
  });
  const kill = setTimeout(() => proc.kill(), GIT_TIMEOUT_MS);
  try {
    const [stdout, stderr] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
    ]);
    return { exitCode: await proc.exited, stdout, stderr };
  } finally {
    clearTimeout(kill);
  }
}

// ---------------------------------------------------------------------------
// Plans — what the injected text asks for
// ---------------------------------------------------------------------------

/** The four §5.2 rows, named after the action rather than the mechanism. */
export type SnapshotAction = "reset_hard" | "force_push" | "rm_rf" | "git_clean";

export type SnapshotPlan =
  | { action: "reset_hard"; trigger: string; targetRef?: string }
  /** Every refspec operand, because one push can rewrite many remote refs. */
  | { action: "force_push"; trigger: string; remote?: string; refspecs: string[]; mirror: boolean }
  | { action: "rm_rf"; trigger: string; operands: string[] }
  /** Args for the dry run that answers "what would this remove", flags mirrored. */
  | { action: "git_clean"; trigger: string; dryRunArgs: string[] };

// ---------------------------------------------------------------------------
// Entries — what an undo needs
// ---------------------------------------------------------------------------

interface SnapshotBase {
  id: string;
  at: number;
  sessionId: string;
  projectPath: string;
  /** The command segment that triggered it, bounded — this reaches the UI. */
  trigger: string;
}

export interface StashSnapshot extends SnapshotBase {
  kind: "git_stash";
  /** HEAD before the reset. `git reset --hard <ref>` moves it; undo moves it back. */
  headSha: string;
  /** `git stash create` commit, absent when the working tree was already clean. */
  stashSha?: string;
  /**
   * `refs/antgrid/handler-snapshot/<id>`, pinning the stash (or HEAD) so the
   * objects survive GC. The reflog is not enough: it does not save uncommitted
   * work, which is what a live session consists of.
   */
  backupRef: string;
}

export interface PrePushSnapshot extends SnapshotBase {
  kind: "pre_push_sha";
  remote: string;
  /** Fully-qualified remote ref as `ls-remote` reported it. */
  ref: string;
  /** Remote tip before the force push. */
  remoteSha: string;
  /** Local pin proving `remoteSha` is present locally, i.e. that undo can push it back. */
  backupRef: string;
}

export interface TrashedPath {
  /** Project-relative, so a moved project still restores to the right place. */
  relPath: string;
  trashPath: string;
}

export interface TrashSnapshot extends SnapshotBase {
  kind: "trash_copy";
  files: TrashedPath[];
  bytes: number;
}

export type SnapshotEntry = StashSnapshot | PrePushSnapshot | TrashSnapshot;

// ---------------------------------------------------------------------------
// Outcomes
// ---------------------------------------------------------------------------

export type SnapshotFailure =
  | "outside_project"
  | "too_large"
  | "git_failed"
  | "unsupported"
  | "io_error";

export type SnapshotOutcome =
  | { status: "snapshotted"; action: SnapshotAction; entry: SnapshotEntry }
  /** Nothing was at risk — the action is already reversible or a no-op. */
  | { status: "nothing"; action: SnapshotAction; trigger: string; detail: string }
  /** At risk and NOT protected. The caller must not tell the user it can be undone. */
  | { status: "failed"; action: SnapshotAction; trigger: string; reason: SnapshotFailure; detail: string };

export interface UndoResult {
  ok: boolean;
  detail: string;
  /**
   * Present when the undo had to discard live state to get back (the tree — or
   * the remote ref — moved on after the snapshot). Undo must not be the second
   * destructive act, so that state is pinned first and handed back as its own
   * undoable entry.
   */
  safety?: StashSnapshot | PrePushSnapshot;
}

export interface SnapshotOptions {
  /** The text Handler is about to inject. */
  text: string;
  projectPath: string;
  /** Scopes the trash dir. Dies with the session it names. */
  sessionId: string;
  abDir?: string;
  runGit?: GitRunner;
  now?: () => number;
  newId?: () => string;
  maxBytes?: number;
  maxFiles?: number;
}

export interface UndoOptions {
  abDir?: string;
  runGit?: GitRunner;
  now?: () => number;
  newId?: () => string;
}

// A snapshot is only worth taking if it is cheap: it runs inline before an
// inject, so its cost is latency the supervised session pays. 256 MiB is ~1s on a
// commodity SSD, and it sits above the working sets people actually delete by
// hand (build/, dist/, a coverage dir) and below the ones that make this a hang
// rather than a safety feature (node_modules is routinely 0.3–4 GB). The file
// ceiling exists because many tiny files, not bytes, is what makes a copy crawl.
const MAX_SNAPSHOT_BYTES = 256 * 1024 * 1024;
const MAX_SNAPSHOT_FILES = 20_000;

const MAX_TRIGGER_CHARS = 200;

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

/** Command separators. Injected text is single-line (the engine rejects control
 *  chars), but `&&` chains are ordinary. */
function segmentsOf(text: string): string[] {
  return text
    .split(/&&|\|\||[;|\n]/g)
    .map((s) => s.trim())
    .filter(Boolean);
}

/**
 * Quote-aware word split. Not a shell: it recognizes quoting and nothing else.
 *
 * Backticks are dropped from unquoted tokens because a judge reply is markdown, and
 * "run `rm -rf node_modules`" is its ordinary spelling of a command. The floor matches
 * straight through the fence — its patterns anchor with `\b` and a backtick is a
 * non-word character — so a planner that kept the fence disagreed with the floor on the
 * COMMON case and left it flagged, injected and unprotected, which is the same failure
 * commandRanges below already guards the other half of.
 */
function tokenize(segment: string): string[] {
  const out: string[] = [];
  for (const m of segment.matchAll(/"([^"]*)"|'([^']*)'|(\S+)/g)) {
    const quoted = m[1] ?? m[2];
    if (quoted !== undefined) { out.push(quoted); continue; }
    const bare = m[3]!.replace(/`/g, "");
    if (bare) out.push(bare);
  }
  return out;
}

const COMMAND_HEADS = new Set(["rm", "git"]);

/**
 * Token ranges, one per §5.2 command found anywhere in the segment.
 *
 * The verb is deliberately NOT required at token 0. The judge's reply is prose
 * ("Yes, go ahead — run rm -rf node_modules and reinstall"), and the floor
 * matches the command wherever it sits; a planner that only read the head left
 * exactly those replies flagged, injected and unprotected. Each range stops at
 * the next command so one command's operands do not swallow the next.
 */
function commandRanges(tokens: string[]): { from: number; to: number }[] {
  const starts: number[] = [];
  for (let i = 0; i < tokens.length; i++) if (COMMAND_HEADS.has(tokens[i]!)) starts.push(i);
  return starts.map((from, n) => ({ from, to: starts[n + 1] ?? tokens.length }));
}

const isFlag = (t: string) => t.startsWith("-") && t !== "-" && t !== "--";
const hasShortFlag = (t: string, letter: string) =>
  /^-[a-zA-Z]+$/.test(t) && t.slice(1).includes(letter);

function operandsAfter(tokens: string[], from: number, to: number = tokens.length): string[] {
  const out: string[] = [];
  let literal = false;
  for (let i = from; i < to; i++) {
    const t = tokens[i]!;
    if (!literal && t === "--") { literal = true; continue; }
    if (!literal && isFlag(t)) continue;
    out.push(t);
  }
  return out;
}

/**
 * Which §5.2 rows the injected text asks for. Pure: it never touches git or the
 * filesystem, so the engine can decide whether a snapshot is even worth running.
 */
function planCommand(tokens: string[], from: number, to: number, trigger: string): SnapshotPlan | null {
  const head = tokens[from]!;
  const args = tokens.slice(from + 1, to);

  if (head === "rm") {
    const forced = args.some(
      (t) => hasShortFlag(t, "r") || hasShortFlag(t, "R") || hasShortFlag(t, "f") ||
        t === "--recursive" || t === "--force" || t === "--no-preserve-root",
    );
    return forced ? { action: "rm_rf", trigger, operands: operandsAfter(args, 0) } : null;
  }

  const verb = args[0];
  const rest = args.slice(1);

  if (verb === "reset" && rest.includes("--hard")) {
    return { action: "reset_hard", trigger, targetRef: operandsAfter(rest, 0)[0] };
  }

  if (verb === "push") {
    const mirror = rest.includes("--mirror");
    const forced = mirror || rest.some(
      (t) => t === "-f" || hasShortFlag(t, "f") || t === "--force" || t.startsWith("--force-with-lease") ||
        t === "--delete" || t.startsWith("+"),
    );
    if (!forced) return null;
    const operands = operandsAfter(rest, 0);
    return { action: "force_push", trigger, remote: operands[0], refspecs: operands.slice(1), mirror };
  }

  if (verb === "clean") {
    if (!rest.some((t) => hasShortFlag(t, "f") || t === "--force")) return null;
    // Mirror the real flags minus force, so the dry run answers for THIS
    // command: -d/-x/-X and any pathspec change what would be removed.
    //
    // Only ONE f comes off: `-ff` is what reaches into a nested git repository, and
    // dropping both left the dry run listing the plain directories while the real
    // clean took the nested repo too — an entry reporting "snapshotted" over files no
    // copy was ever made of.
    const dryRunArgs = ["clean", "-n"];
    for (const t of rest) {
      if (t === "--force") continue;
      if (/^-[a-zA-Z]+$/.test(t)) {
        const kept = t.slice(1).replace(/f/, "");
        if (kept) dryRunArgs.push(`-${kept}`);
        continue;
      }
      dryRunArgs.push(t);
    }
    return { action: "git_clean", trigger, dryRunArgs };
  }

  return null;
}

export function planSnapshots(text: string): SnapshotPlan[] {
  const plans: SnapshotPlan[] = [];
  for (const segment of segmentsOf(text)) {
    const trigger = segment.slice(0, MAX_TRIGGER_CHARS);
    const tokens = tokenize(segment);
    for (const { from, to } of commandRanges(tokens)) {
      const plan = planCommand(tokens, from, to, trigger);
      if (plan) plans.push(plan);
    }
  }
  return plans;
}

/**
 * Floor pattern source → the §5.2 action that would protect what it flags.
 *
 * The backstop for the two parsers drifting apart: the floor decides what is
 * flagged, this planner decides what is protected, and a shape only the first
 * recognizes is the one case where silence would read to the user exactly like a
 * fully snapshotted action. Derived by running the floor over one canonical
 * command per row rather than transcribed, so a floor edit cannot leave a stale
 * key here.
 */
export const SNAPSHOT_PATTERNS: ReadonlyMap<string, SnapshotAction> = new Map(
  ([
    ["git reset --hard HEAD", "reset_hard"],
    ["git push --force origin main", "force_push"],
    ["rm -rf build", "rm_rf"],
    ["git clean -fd", "git_clean"],
  ] as const).flatMap(([command, action]) =>
    classifyDestructive(command, "").warnings
      .filter((w) => w.tier === "DESTRUCTIVE")
      .map((w) => [w.pattern, action] as [string, SnapshotAction]),
  ),
);

/**
 * Floor patterns for which no §5.2 action exists BY CONSTRUCTION.
 *
 * A separate set rather than more rows in the map above, because it answers a
 * different question: these move state that is not in the project at all — a
 * remote's default branch, a deleted ref, a published version — so there is
 * nothing local a snapshot could hold. That is not the same as the patterns which
 * merely have no plan yet, and the engine says so out loud instead of passing over
 * them in the silence that reads like a fully protected action.
 *
 * Derived by running the floor over one canonical command per row, the same way
 * the map above is, so a floor edit cannot leave a stale key here.
 */
export const NO_SNAPSHOT_PATTERNS: ReadonlySet<string> = new Set(
  ([
    "gh pr merge 1",
    "gh pr close 1",
    "gh release delete v1",
    "gh repo delete owner/name",
    "git branch -D topic",
    "git tag -d v1",
    "npm publish",
  ] as const).flatMap((command) =>
    classifyDestructive(command, "").warnings
      .filter((w) => w.tier === "DESTRUCTIVE")
      .map((w) => w.pattern),
  ),
);

// ---------------------------------------------------------------------------
// Trash dir
// ---------------------------------------------------------------------------

function safeSegment(s: string): string {
  const cleaned = s.replace(/[^A-Za-z0-9._-]/g, "_").replace(/^\.+/, "_");
  return cleaned || "unknown";
}

/** Session-scoped: `<ANTGRID_DIR>/handler-trash/<sessionId>/`. */
export function sessionTrashDir(sessionId: string, abDir: string = resolveAbDir()): string {
  return join(abDir, "handler-trash", safeSegment(sessionId));
}

/** Drops everything this session trashed. The trash outlives no session. */
export async function clearSessionTrash(sessionId: string, abDir: string = resolveAbDir()): Promise<void> {
  await rm(sessionTrashDir(sessionId, abDir), { recursive: true, force: true });
}

/**
 * Give back what an entry was holding once it stops being an undo offer.
 *
 * A backup ref keeps its stash commit — and every object reachable from it —
 * alive against `git gc` for as long as it exists, so an entry dropped from the
 * store without this leaves a pin nobody can ever name again. Same for the trash
 * copy, which can be up to the snapshot ceiling in bytes.
 *
 * Best-effort by design: the entries are already unreachable through the store,
 * so a failure here costs disk, never correctness.
 */
export async function releaseSnapshots(entries: SnapshotEntry[], opts: UndoOptions = {}): Promise<void> {
  const git = opts.runGit ?? defaultRunGit;
  const abDir = opts.abDir ?? resolveAbDir();
  for (const entry of entries) {
    try {
      if (entry.kind === "trash_copy") {
        await rm(join(sessionTrashDir(entry.sessionId, abDir), entry.id), { recursive: true, force: true });
      } else {
        await git(entry.projectPath, ["update-ref", "-d", entry.backupRef]);
      }
    } catch { /* best effort */ }
  }
}

// ---------------------------------------------------------------------------
// Filesystem helpers
// ---------------------------------------------------------------------------

// Separator-aware so "/proj" does not swallow "/proj-evil". Windows backslashes
// and drive-letter case are normalized: the judge writes forward slashes even
// where the project path is backslashed.
function insideProject(target: string, projectPath: string): boolean {
  const norm = (s: string) =>
    s.replace(/\\/g, "/").replace(/^([A-Za-z]):/, (_m, d: string) => `${d.toLowerCase()}:`).replace(/\/+$/, "");
  const base = norm(projectPath);
  const p = norm(target);
  return p === base || p.startsWith(`${base}/`);
}

async function statOf(path: string) {
  try {
    return await lstat(path);
  } catch {
    return null;
  }
}

interface Measured {
  bytes: number;
  files: number;
  /** True once a ceiling is passed; the walk stops there, so cost stays bounded. */
  overflow: boolean;
}

async function measureTree(root: string, maxBytes: number, maxFiles: number): Promise<Measured> {
  const stack = [root];
  let bytes = 0;
  let files = 0;
  while (stack.length) {
    const current = stack.pop()!;
    const st = await statOf(current);
    if (!st) continue;
    files++;
    // Symlinks are copied as links, never followed: following them both escapes
    // the project and can cycle forever.
    if (st.isDirectory()) {
      let names: string[];
      try {
        names = await readdir(current);
      } catch {
        continue;
      }
      for (const n of names) stack.push(join(current, n));
    } else if (st.isFile()) {
      bytes += st.size;
    }
    if (bytes > maxBytes || files > maxFiles) return { bytes, files, overflow: true };
  }
  return { bytes, files, overflow: false };
}

// ---------------------------------------------------------------------------
// Taking snapshots
// ---------------------------------------------------------------------------

interface Ctx {
  projectPath: string;
  sessionId: string;
  abDir: string;
  git: GitRunner;
  now: () => number;
  newId: () => string;
  maxBytes: number;
  maxFiles: number;
}

const BACKUP_REF_PREFIX = "refs/antgrid/handler-snapshot";

function base(ctx: Ctx, trigger: string): SnapshotBase {
  return { id: ctx.newId(), at: ctx.now(), sessionId: ctx.sessionId, projectPath: ctx.projectPath, trigger };
}

const failed = (
  action: SnapshotAction, trigger: string, reason: SnapshotFailure, detail: string,
): SnapshotOutcome => ({ status: "failed", action, trigger, reason, detail });

const nothing = (action: SnapshotAction, trigger: string, detail: string): SnapshotOutcome =>
  ({ status: "nothing", action, trigger, detail });

function gitError(r: GitRun, fallback: string): string {
  return r.stderr.trim() || r.stdout.trim() || fallback;
}

async function snapshotReset(plan: Extract<SnapshotPlan, { action: "reset_hard" }>, ctx: Ctx): Promise<SnapshotOutcome> {
  const head = await ctx.git(ctx.projectPath, ["rev-parse", "HEAD"]);
  if (head.exitCode !== 0) return failed("reset_hard", plan.trigger, "git_failed", gitError(head, "no HEAD to snapshot"));
  const headSha = head.stdout.trim();

  // `git stash create` saves tracked modifications and the index without
  // touching the working tree — same blast radius `git reset --hard` has, which
  // also leaves untracked files alone.
  const created = await ctx.git(ctx.projectPath, ["stash", "create"]);
  if (created.exitCode !== 0) {
    return failed("reset_hard", plan.trigger, "git_failed", gitError(created, "git stash create failed"));
  }
  const stashSha = created.stdout.trim() || undefined;

  if (!stashSha && !plan.targetRef) {
    return nothing("reset_hard", plan.trigger, "working tree is clean and the reset names no other commit");
  }

  const b = base(ctx, plan.trigger);
  const entry: StashSnapshot = {
    ...b,
    kind: "git_stash",
    headSha,
    stashSha,
    backupRef: `${BACKUP_REF_PREFIX}/${b.id}`,
  };
  const pinned = await ctx.git(ctx.projectPath, ["update-ref", entry.backupRef, stashSha ?? headSha]);
  if (pinned.exitCode !== 0) {
    return failed("reset_hard", plan.trigger, "git_failed", gitError(pinned, "could not pin the backup ref"));
  }
  return { status: "snapshotted", action: "reset_hard", entry };
}

async function resolvePushTarget(
  refspec: string | undefined, remote: string | undefined, ctx: Ctx,
): Promise<{ remote: string; ref: string } | string> {
  let ref = refspec;

  if (ref) {
    ref = ref.replace(/^\+/, "");
    // A `src:dst` refspec names the REMOTE ref on the right; the left is local.
    const colon = ref.indexOf(":");
    if (colon >= 0) ref = ref.slice(colon + 1);
    if (ref === "HEAD" || ref === "") ref = undefined;
  }

  if (!remote || !ref) {
    const upstream = await ctx.git(ctx.projectPath, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"]);
    if (upstream.exitCode === 0) {
      const [up, ...restParts] = upstream.stdout.trim().split("/");
      remote ??= up;
      ref ??= restParts.join("/");
    }
  }
  if (!ref) {
    const branch = await ctx.git(ctx.projectPath, ["symbolic-ref", "--short", "HEAD"]);
    if (branch.exitCode === 0) ref = branch.stdout.trim();
  }
  if (!remote || !ref) return "could not tell which remote ref this push targets";
  return { remote, ref };
}

/** "<sha>\t<fullref>" per line; a short ref can match both a head and a tag. */
function lsRemoteRow(stdout: string, ref: string): { sha: string; fullRef: string } | null {
  const rows = stdout.trim().split("\n").map((l) => l.split("\t")).filter((c) => c.length === 2);
  const row = rows.find((c) => c[1] === `refs/heads/${ref}`) ?? rows.find((c) => c[1] === ref) ?? rows[0];
  return row ? { sha: row[0]!.trim(), fullRef: row[1]!.trim() } : null;
}

async function snapshotOneRef(
  trigger: string, refspec: string | undefined, remoteArg: string | undefined, ctx: Ctx,
): Promise<SnapshotOutcome> {
  const target = await resolvePushTarget(refspec, remoteArg, ctx);
  if (typeof target === "string") return failed("force_push", trigger, "git_failed", target);

  const ls = await ctx.git(ctx.projectPath, ["ls-remote", target.remote, target.ref]);
  if (ls.exitCode !== 0) {
    return failed("force_push", trigger, "git_failed", gitError(ls, "could not read the remote ref"));
  }
  const row = lsRemoteRow(ls.stdout, target.ref);
  if (!row) {
    return nothing("force_push", trigger, `${target.remote}/${target.ref} does not exist yet, so the push overwrites nothing`);
  }

  const b = base(ctx, trigger);
  const entry: PrePushSnapshot = {
    ...b,
    kind: "pre_push_sha",
    remote: target.remote,
    ref: row.fullRef,
    remoteSha: row.sha,
    backupRef: `${BACKUP_REF_PREFIX}/${b.id}`,
  };
  // The pin doubles as the proof that undo is possible at all: update-ref fails
  // when the object is missing locally, and a SHA we cannot push back is a
  // promise we cannot keep.
  const pinned = await ctx.git(ctx.projectPath, ["update-ref", entry.backupRef, row.sha]);
  if (pinned.exitCode !== 0) {
    return failed(
      "force_push", trigger, "git_failed",
      `remote commit ${row.sha.slice(0, 12)} is not available locally, so it could not be pushed back`,
    );
  }
  return { status: "snapshotted", action: "force_push", entry };
}

/**
 * One outcome per remote ref the push rewrites — a `git push --force origin a b`
 * rewrites two, and recording only the first would advertise an undo that
 * restores one and silently leaves the rest destroyed.
 *
 * `--mirror` is refused outright: it rewrites and DELETES every ref the remote
 * has, including ones this repo has never fetched, so nothing here can enumerate
 * what would be lost. Reporting it unprotected is the honest answer.
 */
async function snapshotForcePush(
  plan: Extract<SnapshotPlan, { action: "force_push" }>, ctx: Ctx,
): Promise<SnapshotOutcome[]> {
  if (plan.mirror) {
    return [failed(
      "force_push", plan.trigger, "unsupported",
      "a mirror push rewrites and deletes every ref on the remote; its scope cannot be captured",
    )];
  }
  if (plan.refspecs.length <= 1) {
    return [await snapshotOneRef(plan.trigger, plan.refspecs[0], plan.remote, ctx)];
  }
  const out: SnapshotOutcome[] = [];
  for (const refspec of plan.refspecs) out.push(await snapshotOneRef(plan.trigger, refspec, plan.remote, ctx));
  return out;
}

// `~` at a path boundary and `$VAR` are expanded by the shell, not by rm, so the
// string we can resolve is not the path that gets deleted: `rm -rf ~/Downloads`
// resolves to <project>/~/Downloads, which is absent, and reporting "nothing was
// at risk" would be a lie about the real home directory.
const UNEXPANDED_OPERAND = /(?:^|\/)~(?:$|\/)|\$/;

// The judge answers in PROSE, so an operand routinely arrives with the
// sentence's punctuation still attached ("rm -rf node_modules, then reinstall").
// The agent reads that as English and deletes `node_modules`, while a snapshot
// resolving `node_modules,` finds nothing on disk and reports "nothing was at
// risk" — the one answer this must never give about a path that was. Only
// applied to shell-expanded (rm) operands: `git clean -n` reports real paths,
// where a trailing dot is part of the name.
const PROSE_TAIL = /[.,;:!?)\]]+$/;

// Stripping is a fallback, never a rewrite: a directory whose name really ends
// in punctuation (`build (old)`) would otherwise be stripped to a path that is
// not there, and land on the same silent "nothing at risk" this exists to
// prevent. Only substitute when the operand as written is absent and the
// trimmed form is present.
async function resolveOperand(raw: string, ctx: Ctx): Promise<string> {
  const trimmed = raw.replace(PROSE_TAIL, "");
  if (!trimmed || trimmed === raw) return raw;
  if (await statOf(resolve(ctx.projectPath, raw))) return raw;
  return (await statOf(resolve(ctx.projectPath, trimmed))) ? trimmed : raw;
}

async function copyToTrash(
  action: SnapshotAction, trigger: string, absPaths: string[], ctx: Ctx,
  { shellExpands = false }: { shellExpands?: boolean } = {},
): Promise<SnapshotOutcome> {
  const targets: string[] = [];
  for (const raw of absPaths) {
    const p = shellExpands ? await resolveOperand(raw, ctx) : raw;
    // Both guards are about text a SHELL would have expanded, so both belong behind the
    // same flag. snapshotClean's operands come back from `git clean -n`, which reports
    // paths that exist — a repo holding `app/[id]/page.tsx` was aborting its whole clean
    // snapshot over a real filename.
    if (shellExpands) {
      if (/[*?[\]]/.test(p)) {
        return failed(action, trigger, "unsupported", `cannot snapshot a glob operand: ${p}`);
      }
      if (UNEXPANDED_OPERAND.test(p)) {
        return failed(action, trigger, "unsupported", `cannot resolve a shell-expanded operand: ${p}`);
      }
    }
    const abs = resolve(ctx.projectPath, p);
    if (!insideProject(abs, ctx.projectPath)) {
      return failed(action, trigger, "outside_project", `refusing to snapshot a path outside the project: ${abs}`);
    }
    if (relative(ctx.projectPath, abs) === "") {
      return failed(action, trigger, "unsupported", "refusing to snapshot the project root");
    }
    if (await statOf(abs)) targets.push(abs);
  }
  if (targets.length === 0) return nothing(action, trigger, "nothing on disk to copy");

  let bytes = 0;
  let files = 0;
  for (const t of targets) {
    const m = await measureTree(t, ctx.maxBytes - bytes, ctx.maxFiles - files);
    bytes += m.bytes;
    files += m.files;
    if (m.overflow) {
      return failed(
        action, trigger, "too_large",
        `over the snapshot ceiling (${ctx.maxBytes} bytes / ${ctx.maxFiles} files) at ${t} — NOT protected`,
      );
    }
  }

  const entry: TrashSnapshot = { ...base(ctx, trigger), kind: "trash_copy", files: [], bytes };
  const root = join(sessionTrashDir(ctx.sessionId, ctx.abDir), entry.id);
  try {
    for (const abs of targets) {
      const relPath = relative(ctx.projectPath, abs);
      const trashPath = join(root, relPath);
      await mkdir(dirname(trashPath), { recursive: true });
      await cp(abs, trashPath, { recursive: true, force: true });
      entry.files.push({ relPath, trashPath });
    }
  } catch (e) {
    // Half a copy protects nothing, and leaving it behind would let a later
    // restore write a partial tree over the real one.
    await rm(root, { recursive: true, force: true });
    return failed(action, trigger, "io_error", `copy to trash failed: ${String(e)}`);
  }
  return { status: "snapshotted", action, entry };
}

// `git clean -n` has no -z, so a path holding a quote, a backslash or a control
// character comes back C-quoted whatever `core.quotepath` says. Taking the quoted
// spelling verbatim resolves to a path that does not exist, which would drop the
// file from the copy while still reporting the action snapshotted.
const C_ESCAPES: Record<string, string> = { a: "\x07", b: "\b", f: "\f", n: "\n", r: "\r", t: "\t", v: "\v" };

function unquoteGitPath(raw: string): string {
  if (raw.length < 2 || !raw.startsWith(`"`) || !raw.endsWith(`"`)) return raw;
  const body = raw.slice(1, -1);
  // Assembled as BYTES: an octal escape names one byte, and a multi-byte UTF-8
  // character arrives as several of them.
  const bytes: number[] = [];
  const push = (s: string) => { for (const b of Buffer.from(s, "utf8")) bytes.push(b); };
  for (let i = 0; i < body.length; i++) {
    const ch = body[i]!;
    if (ch !== "\\") { push(ch); continue; }
    const c = body[++i];
    if (c === undefined) break;
    const octal = body.slice(i, i + 3);
    if (/^[0-7]{3}$/.test(octal)) {
      bytes.push(parseInt(octal, 8));
      i += 2;
      continue;
    }
    push(C_ESCAPES[c] ?? c);
  }
  return Buffer.from(bytes).toString("utf8");
}

async function snapshotClean(
  plan: Extract<SnapshotPlan, { action: "git_clean" }>, ctx: Ctx,
): Promise<SnapshotOutcome> {
  // Ask git rather than guess: `clean -f` skips untracked directories that `-d`
  // would take, and -x/-X and pathspecs move the answer again.
  const dry = await ctx.git(ctx.projectPath, plan.dryRunArgs);
  if (dry.exitCode !== 0) {
    return failed("git_clean", plan.trigger, "git_failed", gitError(dry, "git clean dry run failed"));
  }
  const paths = dry.stdout
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l.startsWith("Would remove "))
    .map((l) => unquoteGitPath(l.slice("Would remove ".length)).replace(/\/$/, ""))
    .filter(Boolean);
  if (paths.length === 0) return nothing("git_clean", plan.trigger, "git clean would remove nothing");
  return copyToTrash("git_clean", plan.trigger, paths, ctx);
}

function contextFrom(opts: SnapshotOptions): Ctx {
  return {
    projectPath: opts.projectPath,
    sessionId: opts.sessionId,
    abDir: opts.abDir ?? resolveAbDir(),
    git: opts.runGit ?? defaultRunGit,
    now: opts.now ?? Date.now,
    newId: opts.newId ?? randomUUID,
    maxBytes: opts.maxBytes ?? MAX_SNAPSHOT_BYTES,
    maxFiles: opts.maxFiles ?? MAX_SNAPSHOT_FILES,
  };
}

/**
 * Snapshot every §5.2 action the injected text asks for, in the order it asks.
 * At least one outcome per plan, so a text that both resets and deletes reports
 * each independently — one of them failing does not silently downgrade the
 * other. A push naming several refspecs reports one outcome per ref.
 */
export async function takeSnapshots(opts: SnapshotOptions): Promise<SnapshotOutcome[]> {
  const ctx = contextFrom(opts);
  const out: SnapshotOutcome[] = [];
  for (const plan of planSnapshots(opts.text)) {
    switch (plan.action) {
      case "reset_hard": out.push(await snapshotReset(plan, ctx)); break;
      case "force_push": out.push(...await snapshotForcePush(plan, ctx)); break;
      case "rm_rf":
        out.push(await copyToTrash("rm_rf", plan.trigger, plan.operands, ctx, { shellExpands: true }));
        break;
      case "git_clean": out.push(await snapshotClean(plan, ctx)); break;
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Undo
// ---------------------------------------------------------------------------

function undoCtx(entry: SnapshotEntry, opts: UndoOptions): Ctx {
  return {
    projectPath: entry.projectPath,
    sessionId: entry.sessionId,
    abDir: opts.abDir ?? resolveAbDir(),
    git: opts.runGit ?? defaultRunGit,
    now: opts.now ?? Date.now,
    newId: opts.newId ?? randomUUID,
    maxBytes: MAX_SNAPSHOT_BYTES,
    maxFiles: MAX_SNAPSHOT_FILES,
  };
}

async function undoStash(entry: StashSnapshot, ctx: Ctx): Promise<UndoResult> {
  const pin = await ctx.git(ctx.projectPath, ["rev-parse", "--verify", `${entry.backupRef}^{commit}`]);
  if (pin.exitCode !== 0) {
    return { ok: false, detail: `backup ref ${entry.backupRef} is gone; nothing to restore from` };
  }

  let safety: StashSnapshot | undefined;
  const head = await ctx.git(ctx.projectPath, ["rev-parse", "HEAD"]);
  if (head.exitCode !== 0) return { ok: false, detail: gitError(head, "could not read HEAD") };

  if (head.stdout.trim() !== entry.headSha) {
    // The reset moved commits, so getting back means moving them again — which
    // discards whatever the tree holds now. Save that first: an undo that
    // destroys is just a second destructive act. The target ref is named so the
    // save also pins the CURRENT head; commits made after the reset are
    // otherwise reachable only through a reflog this undo is about to bury.
    const saved = await snapshotReset(
      { action: "reset_hard", trigger: `undo of ${entry.id}`, targetRef: entry.headSha },
      ctx,
    );
    if (saved.status === "failed") return { ok: false, detail: `could not protect current state: ${saved.detail}` };
    if (saved.status === "snapshotted") safety = saved.entry as StashSnapshot;

    const back = await ctx.git(ctx.projectPath, ["reset", "--hard", entry.headSha]);
    if (back.exitCode !== 0) return { ok: false, detail: gitError(back, "could not move HEAD back"), safety };
  }

  if (entry.stashSha) {
    const applied = await ctx.git(ctx.projectPath, ["stash", "apply", entry.stashSha]);
    if (applied.exitCode !== 0) return { ok: false, detail: gitError(applied, "git stash apply failed"), safety };
    return { ok: true, detail: `restored working tree from ${entry.stashSha.slice(0, 12)}`, safety };
  }
  return { ok: true, detail: `restored HEAD to ${entry.headSha.slice(0, 12)}`, safety };
}

/**
 * Push the recorded pre-push tip back, protecting whatever the remote holds NOW.
 *
 * The undo can land hours after the snapshot, by which time a teammate (or a
 * later session) may have pushed on top. A hosted remote exposes no reflog, so a
 * blind `--force` back to the recorded SHA is the one loss nothing can walk back
 * — the same reason `undoStash` stashes before it moves HEAD. The observed tip is
 * therefore fetched, pinned locally and returned as its own undoable entry, and
 * the push carries a lease on exactly that tip so a race cannot slip through.
 */
async function undoPrePush(entry: PrePushSnapshot, ctx: Ctx): Promise<UndoResult> {
  const ls = await ctx.git(ctx.projectPath, ["ls-remote", entry.remote, entry.ref]);
  if (ls.exitCode !== 0) return { ok: false, detail: gitError(ls, "could not read the remote ref") };
  const observed = lsRemoteRow(ls.stdout, entry.ref);

  let safety: PrePushSnapshot | undefined;
  if (observed && observed.sha !== entry.remoteSha) {
    const fetched = await ctx.git(ctx.projectPath, ["fetch", entry.remote, observed.sha]);
    if (fetched.exitCode !== 0) {
      return { ok: false, detail: `${entry.remote} ${entry.ref} has moved to ${observed.sha.slice(0, 12)} and it could not be fetched, so the undo would destroy it` };
    }
    const b = base(ctx, `undo of ${entry.id}`);
    const pin: PrePushSnapshot = {
      ...b,
      kind: "pre_push_sha",
      remote: entry.remote,
      ref: observed.fullRef,
      remoteSha: observed.sha,
      backupRef: `${BACKUP_REF_PREFIX}/${b.id}`,
    };
    const pinned = await ctx.git(ctx.projectPath, ["update-ref", pin.backupRef, observed.sha]);
    if (pinned.exitCode !== 0) {
      return { ok: false, detail: `could not pin ${entry.remote} ${entry.ref} at ${observed.sha.slice(0, 12)} before overwriting it` };
    }
    safety = pin;
  }

  // The lease is the ONLY force flag when there is a tip to lease against: git lets
  // `--force` override `--force-with-lease` on the same command line, so sending both
  // made the lease inert — a teammate pushing between the ls-remote above and this
  // push lost that commit, unfetched and unpinned. No lease when the ref is gone from
  // the remote: there is nothing to lose, and a lease naming a tip that does not exist
  // would reject the restore.
  const args = observed
    ? ["push", `--force-with-lease=${entry.ref}:${observed.sha}`]
    : ["push", "--force"];
  args.push(entry.remote, `${entry.remoteSha}:${entry.ref}`);

  const pushed = await ctx.git(ctx.projectPath, args);
  if (pushed.exitCode !== 0) return { ok: false, detail: gitError(pushed, "push back failed"), safety };
  return { ok: true, detail: `${entry.remote} ${entry.ref} restored to ${entry.remoteSha.slice(0, 12)}`, safety };
}

async function undoTrash(entry: TrashSnapshot, ctx: Ctx): Promise<UndoResult> {
  const missing: string[] = [];
  let restored = 0;
  for (const f of entry.files) {
    if (!(await statOf(f.trashPath))) {
      missing.push(f.relPath);
      continue;
    }
    const dest = join(ctx.projectPath, f.relPath);
    try {
      await mkdir(dirname(dest), { recursive: true });
      await cp(f.trashPath, dest, { recursive: true, force: true });
      restored++;
    } catch (e) {
      missing.push(`${f.relPath} (${String(e)})`);
    }
  }
  if (missing.length) {
    return { ok: false, detail: `restored ${restored}/${entry.files.length}; could not restore: ${missing.join(", ")}` };
  }
  return { ok: true, detail: `restored ${restored} path(s) from session trash` };
}

/** Perform the undo an entry promised. Pure of engine concerns: it needs the
 *  entry and a git runner, nothing else. */
export async function undoSnapshot(entry: SnapshotEntry, opts: UndoOptions = {}): Promise<UndoResult> {
  const ctx = undoCtx(entry, opts);
  switch (entry.kind) {
    case "git_stash": return undoStash(entry, ctx);
    case "pre_push_sha": return undoPrePush(entry, ctx);
    case "trash_copy": return undoTrash(entry, ctx);
  }
}

/** One-line rendering for the activity row and the wrap-up summary. */
export function describeSnapshot(entry: SnapshotEntry): string {
  switch (entry.kind) {
    case "git_stash":
      return entry.stashSha
        ? `saved working tree (${entry.stashSha.slice(0, 7)}) and HEAD ${entry.headSha.slice(0, 7)}`
        : `saved HEAD ${entry.headSha.slice(0, 7)}`;
    case "pre_push_sha":
      return `recorded ${entry.remote} ${entry.ref} at ${entry.remoteSha.slice(0, 7)}`;
    case "trash_copy":
      return `copied ${entry.files.length} path(s), ${entry.bytes} bytes, to session trash`;
  }
}
