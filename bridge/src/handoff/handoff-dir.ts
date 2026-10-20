import { lstat, mkdir, readFile, readdir, realpath, rename, rm, stat, writeFile, cp } from "node:fs/promises";
import { join, sep } from "node:path";
import { z } from "zod";
import type { AgentSpec as RegistryAgentSpec } from "antgrid-agents/contracts";
import {
  ByteBudget,
  HANDOFF_STAGE_DEADLINE_MS,
  HandoffSnapshotError,
  safeJoin,
  writeText,
  type HandoffFile,
  type HandoffMethod,
  type HandoffSnapshot,
  type HandoffSnapshotOpts,
} from "antgrid-agents/handoff";
import { logger } from "../logger";
import { ensureHandoffExcluded } from "./git-exclude";

const log = logger.child({ component: "handoff-dir" });

export const HANDOFF_REL_DIR = ".antgrid/handoff";
export const SCROLLBACK_FILE = "terminal-scrollback.txt";
export const NO_TRANSCRIPT_COPY = "This session has no captured transcript to fork yet.";
export const SNAPSHOT_TOO_LARGE_COPY = "This conversation's transcript is over 256 MB, too large to copy for a handoff.";

const SESSION_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// A `.partial` older than the process cannot belong to a staging pass in flight.
const PROCESS_START_MS = Date.now();

const HandoffFileSchema = z.object({
  name: z.string(),
  role: z.enum(["transcript", "segment", "sidecar"]),
  originalName: z.string().optional(),
  sourcePath: z.string().optional(),
  sourceRange: z.object({ start: z.number(), end: z.number() }).optional(),
  bytes: z.number(),
  sha256: z.string(),
});

const ManifestSchema = z.object({
  version: z.literal(1),
  agent: z.string(),
  agentSessionId: z.string().optional(),
  method: z.enum(["copy", "decompress", "db-serialize", "scrollback"]),
  primary: z.string(),
  files: z.array(HandoffFileSchema),
  references: z.array(z.object({ path: z.string(), note: z.string() })),
  redactions: z.array(z.string()),
  warnings: z.array(z.string()),
  capturedAt: z.string(),
  projectId: z.string(),
  sourceSessionId: z.string(),
  sourceAgentLabel: z.string(),
});

export interface HandoffManifest extends Omit<HandoffSnapshot, "method"> {
  version: 1;
  method: HandoffMethod | "scrollback";
  capturedAt: string;
  projectId: string;
  sourceSessionId: string;
  sourceAgentLabel: string;
}

/** The only part of a session row the handoff lifecycle reads. */
export interface HandoffRow {
  forkHandoff?: { state: "staged" | "materialized"; root?: string };
}

export function assertSessionUuid(id: string): void {
  if (!SESSION_UUID.test(id)) throw new Error(`Refusing a handoff for a non-UUID session id ${JSON.stringify(id)}.`);
}

/** Where a snapshot waits between the fork and the session's first launch. */
export function stagingDir(sessionsDir: string, id: string): string {
  assertSessionUuid(id);
  return join(sessionsDir, "handoff", id);
}

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** A disk-side failure is surfaced rather than papered over with the scrollback,
 * which would be written to the same disk. */
function snapshotFailure(error: unknown): Error {
  if (error instanceof HandoffSnapshotError) return new Error(`Could not snapshot the conversation: ${error.errno ?? error.code}`);
  const code = (error as NodeJS.ErrnoException | undefined)?.code;
  return new Error(`Could not snapshot the conversation: ${code ?? errorText(error)}`);
}

function isUnder(child: string, parent: string): boolean {
  return child === parent || child.startsWith(parent.endsWith(sep) ? parent : parent + sep);
}

async function removeTree(path: string): Promise<void> {
  await rm(path, { recursive: true, force: true, maxRetries: 3, retryDelay: 100 });
}

async function readManifest(dir: string): Promise<HandoffManifest | undefined> {
  try {
    const parsed = ManifestSchema.safeParse(JSON.parse(await readFile(join(dir, "manifest.json"), "utf8")));
    return parsed.success ? parsed.data : undefined;
  } catch {
    return undefined;
  }
}

/**
 * Calls the source agent's snapshot into a staging dir, falls back to (and
 * always adds) the terminal scrollback, and writes `manifest.json` last. The dir
 * only appears under its final name once complete, so a crash leaves at most a
 * `.partial` for the sweep.
 */
export async function stageHandoff(args: {
  sessionsDir: string;
  projectId: string;
  newSessionId: string;
  source: { id: string; name: string; tool: string; agentSessionId?: string };
  adapter: RegistryAgentSpec;
  snapshotOpts: Omit<HandoffSnapshotOpts, "outDir" | "signal">;
  scrollback?: string;
  deadlineMs?: number;
}): Promise<HandoffManifest> {
  const finalDir = stagingDir(args.sessionsDir, args.newSessionId);
  const partial = `${finalDir}.partial`;
  await removeTree(partial);
  await mkdir(partial, { recursive: true });
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), args.deadlineMs ?? HANDOFF_STAGE_DEADLINE_MS);
  try {
    const manifest = await capture(args, partial, controller.signal);
    try {
      await writeFile(join(partial, "manifest.json"), JSON.stringify(manifest, null, 2));
      await rename(partial, finalDir);
    } catch (error) {
      throw snapshotFailure(error);
    }
    return manifest;
  } catch (error) {
    await removeTree(partial).catch(() => {});
    throw error;
  } finally {
    clearTimeout(timer);
  }
}

async function capture(
  args: Parameters<typeof stageHandoff>[0],
  outDir: string,
  signal: AbortSignal,
): Promise<HandoffManifest> {
  const warnings: string[] = [];
  let snapshot: HandoffSnapshot | undefined;
  try {
    snapshot = await args.adapter.fork.snapshot({ ...args.snapshotOpts, outDir, signal });
    if (snapshot) for (const file of snapshot.files) safeJoin(outDir, file.name);
  } catch (error) {
    if (error instanceof HandoffSnapshotError && error.code === "TOO_LARGE") throw new Error(SNAPSHOT_TOO_LARGE_COPY);
    if (error instanceof HandoffSnapshotError && error.code === "WRITE") throw snapshotFailure(error);
    if (!(error instanceof HandoffSnapshotError) && !signal.aborted) throw snapshotFailure(error);
    warnings.push(`The agent's own transcript could not be read (${errorText(error)}); the terminal scrollback was used instead.`);
    snapshot = undefined;
    // Whatever the adapter had written is not a usable snapshot.
    await removeTree(outDir);
    await mkdir(outDir, { recursive: true });
  }
  if (!snapshot && warnings.length === 0) {
    warnings.push("No transcript of the agent's own was found; the terminal scrollback was used instead.");
  }

  const scrollbackText = args.scrollback ?? "";
  let scrollbackFile: HandoffFile | undefined;
  if (scrollbackText.trim().length > 0) {
    try {
      scrollbackFile = await writeText(outDir, SCROLLBACK_FILE, scrollbackText, snapshot ? "sidecar" : "transcript", new ByteBudget());
    } catch (error) {
      throw error instanceof HandoffSnapshotError && error.code === "TOO_LARGE" ? new Error(SNAPSHOT_TOO_LARGE_COPY) : snapshotFailure(error);
    }
  }
  if (!snapshot && !scrollbackFile) throw new Error(NO_TRANSCRIPT_COPY);

  const common = {
    version: 1 as const,
    capturedAt: new Date().toISOString(),
    projectId: args.projectId,
    sourceSessionId: args.source.id,
    sourceAgentLabel: args.adapter.label,
  };
  if (snapshot) {
    return {
      ...common,
      ...snapshot,
      files: scrollbackFile ? [...snapshot.files, scrollbackFile] : snapshot.files,
      warnings: [...snapshot.warnings, ...warnings],
    };
  }
  return {
    ...common,
    agent: args.source.tool,
    agentSessionId: args.source.agentSessionId,
    method: "scrollback",
    primary: SCROLLBACK_FILE,
    files: [scrollbackFile!],
    references: [],
    redactions: [],
    warnings,
  };
}

/** The directory the handoff lands under: the agent's launch cwd when it is
 *  really inside the checkout, otherwise the checkout itself. */
async function resolveHandoffRoot(checkoutPath: string, launchCwd: string): Promise<{ root: string; checkoutReal: string }> {
  const checkoutReal = await realpath(checkoutPath);
  try {
    const launchReal = await realpath(launchCwd);
    if (isUnder(launchReal, checkoutReal)) return { root: launchReal, checkoutReal };
  } catch { /* a launch cwd that does not exist yet falls back to the checkout */ }
  return { root: checkoutReal, checkoutReal };
}

/** Refuses a link at any component. A cloned repository can commit `.antgrid`
 *  as a symlink or junction that points outside the checkout. */
async function assertNoLinks(root: string, parts: string[]): Promise<void> {
  let current = root;
  for (const part of parts) {
    current = join(current, part);
    let info;
    try { info = await lstat(current); } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return;
      throw error;
    }
    if (info.isSymbolicLink()) throw new Error(`${current} is a link; refusing to write a handoff through it.`);
  }
}

async function moveDir(from: string, to: string, io: { rename: typeof rename }): Promise<void> {
  try {
    await io.rename(from, to);
    return;
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    // The project can live on another drive; a held handle on Windows also
    // fails a rename that a copy then survives.
    if (code !== "EXDEV" && code !== "EPERM" && code !== "EACCES" && code !== "EBUSY") throw error;
  }
  const moving = `${to}.moving`;
  await removeTree(moving);
  await cp(from, moving, { recursive: true, errorOnExist: true });
  await rename(moving, to);
  await removeTree(from);
}

/**
 * Moves a staged snapshot into the checkout. The git exclude goes in first so
 * the files are never visible as untracked. Safe to repeat: staging already gone
 * and a valid manifest at the target counts as done.
 */
export async function materializeHandoff(
  sessionsDir: string,
  checkoutPath: string,
  launchCwd: string,
  id: string,
  io: { rename: typeof rename } = { rename },
): Promise<{ root: string; dir: string; manifest: HandoffManifest }> {
  const staging = stagingDir(sessionsDir, id);
  const { root, checkoutReal } = await resolveHandoffRoot(checkoutPath, launchCwd);
  await assertNoLinks(root, [".antgrid", "handoff", id]);
  const parent = join(root, ".antgrid", "handoff");
  await mkdir(parent, { recursive: true });
  const parentReal = await realpath(parent);
  if (!isUnder(parentReal, checkoutReal)) throw new Error("The handoff directory resolves outside the checkout.");
  const dir = join(parent, id);

  const placed = await readManifest(dir);
  const stagedManifest = await readManifest(staging);
  if (!stagedManifest) {
    if (placed) return { root, dir, manifest: placed };
    throw new Error("The staged handoff is missing.");
  }
  try {
    await ensureHandoffExcluded(root, id);
    if (placed) {
      await removeTree(staging);
      return { root, dir, manifest: placed };
    }
    // A target with no manifest is a copy that died partway.
    await removeTree(dir);
    await moveDir(staging, dir, io);
    return { root, dir, manifest: stagedManifest };
  } catch (error) {
    // The move may have landed before it failed; the caller has to be able to
    // name where, or a later delete cannot find the files.
    if (error instanceof Error) Object.assign(error, { handoffRoot: root });
    throw error;
  }
}

/** Removes a session's staging dir and its copy in the checkout. Best-effort and
 *  never throws: nothing a delete does may be blocked by leftover files. */
export async function removeHandoff(sessionsDir: string | undefined, handoffRoot: string | undefined, id: string): Promise<void> {
  try {
    assertSessionUuid(id);
  } catch (error) {
    log.warn("%s", errorText(error));
    return;
  }
  if (sessionsDir) {
    const staging = stagingDir(sessionsDir, id);
    for (const path of [staging, `${staging}.partial`]) {
      await removeTree(path).catch((error) => log.warn("could not remove %s: %s", path, errorText(error)));
    }
  }
  if (handoffRoot) {
    try {
      await assertNoLinks(handoffRoot, [".antgrid", "handoff", id]);
      const target = join(handoffRoot, ".antgrid", "handoff", id);
      await removeTree(target);
      await removeTree(`${target}.moving`);
    } catch (error) {
      log.warn("could not remove the handoff in %s: %s", handoffRoot, errorText(error));
    }
  }
}

/**
 * The backstop for every delete path: a crash between a move and a row delete,
 * or a copy-and-remove that a virus scanner stopped partway, leaves files no
 * row names.
 */
export async function sweepHandoffs(args: {
  sessionsDir: string;
  projectPath: string;
  projectId: string;
  rows: ReadonlyMap<string, HandoffRow>;
  inFlight: ReadonlySet<string>;
  /** Checkouts other than the project folder that may hold a placed handoff. */
  extraRoots?: readonly string[];
}): Promise<void> {
  const stagingRoot = join(args.sessionsDir, "handoff");
  let names: string[] = [];
  try { names = await readdir(stagingRoot); } catch { /* nothing staged */ }
  for (const name of names) {
    try {
      const partial = name.endsWith(".partial");
      const id = partial ? name.slice(0, -".partial".length) : name;
      if (!SESSION_UUID.test(id) || args.inFlight.has(id)) continue;
      if (partial) {
        if ((await stat(join(stagingRoot, name))).mtimeMs >= PROCESS_START_MS) continue;
      } else if (args.rows.get(id)?.forkHandoff?.state !== "materialized" && args.rows.has(id)) {
        // Whatever its forkHandoff parsed to: a row that lost the field to a
        // schema mismatch must not lose the only copy of its context too.
        continue;
      }
      await removeTree(join(stagingRoot, name));
    } catch (error) {
      log.warn("handoff sweep skipped %s: %s", name, errorText(error));
    }
  }

  // A launch cwd below the project, or a managed worktree, holds its own copy;
  // a removal that failed there is retried only if that root is visited here.
  const roots = new Set([args.projectPath, ...(args.extraRoots ?? [])]);
  for (const row of args.rows.values()) if (row.forkHandoff?.root) roots.add(row.forkHandoff.root);
  for (const root of roots) await sweepCheckoutRoot(root, args);
}

async function sweepCheckoutRoot(root: string, args: Parameters<typeof sweepHandoffs>[0]): Promise<void> {
  const checkoutHandoffs = join(root, ".antgrid", "handoff");
  let names: string[];
  try {
    await assertNoLinks(root, [".antgrid", "handoff"]);
    names = await readdir(checkoutHandoffs);
  } catch { return; }
  for (const entry of names) {
    // An interrupted cross-volume move leaves `<id>.moving`.
    const name = entry.endsWith(".moving") ? entry.slice(0, -".moving".length) : entry;
    if (!SESSION_UUID.test(name) || args.rows.has(name) || args.inFlight.has(name)) continue;
    try {
      const dir = join(checkoutHandoffs, entry);
      // Only what this project's own manifest claims: another project can share
      // the folder.
      const manifest = await readManifest(dir);
      // A copy that died partway may not have reached its manifest yet.
      const unfinishedMove = entry !== name && !manifest;
      if (!unfinishedMove && manifest?.projectId !== args.projectId) continue;
      await removeTree(dir);
    } catch (error) {
      log.warn("handoff sweep skipped %s: %s", entry, errorText(error));
    }
  }
}
