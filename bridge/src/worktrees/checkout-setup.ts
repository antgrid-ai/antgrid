import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, parse, resolve } from "node:path";
import { z } from "zod";
import { resolveAbDir } from "../antgrid-dir";
import { findConfigFile, loadConfig, resolveVariables, type ResolveContext, type WorktreeSetup } from "../config";
import { logger } from "../logger";
import type { TerminalManager } from "../terminal-manager";
import type { CheckoutRecord, CheckoutSetupProgress } from "./checkout-types";
import { pathBelow } from "./path-guard";

const log = logger.child({ component: "checkout-setup" });

/** Budget for the WHOLE run, not per step. Ten minutes is what a cold
 *  `bun install` plus a Prisma generate costs on a slow laptop; anything past
 *  it is a wedged step, not a slow one. */
export const DEFAULT_SETUP_TIMEOUT_MS = 600_000;

/** How the child announces step boundaries, riding the PTY's OSC 2 title so it
 *  travels the same path the agent's own titles do. */
export const SETUP_OSC_PREFIX = "antgrid-setup:";

const SETUP_MARKER_RE = /^antgrid-setup:(\d+)\/(\d+):([\s\S]*)$/;

/** The setup transcript's terminal id. Namespaced exactly like a configured
 *  slot (`<checkoutId>:<name>`) so teardown's `configuredTerminalIds` sweep and
 *  the app's per-checkout routing both already understand it. */
export function setupTerminalId(checkoutId: string): string {
  return `${checkoutId}:setup`;
}

/** Control bytes would terminate the OSC string early and split the marker
 *  across two titles, so a step name carrying one is scrubbed rather than
 *  refused — the name is cosmetic and the progress line must survive it. */
function oscSafe(value: string): string {
  return value.replace(/[\u0000-\u001f\u007f]/g, " ");
}

export function formatSetupStepMarker(index: number, count: number, name: string): string {
  return `\x1b]2;${SETUP_OSC_PREFIX}${index}/${count}:${oscSafe(name)}\x07`;
}

export interface SetupStepMarker {
  index: number;
  count: number;
  name: string;
}

export function parseSetupStepMarker(title: string): SetupStepMarker | null {
  const m = SETUP_MARKER_RE.exec(title);
  if (!m) return null;
  return { index: Number(m[1]), count: Number(m[2]), name: m[3] };
}

/** One copy pair, both sides already absolute and already proven to sit inside
 *  their own root. `rel` exists only so the transcript can name the file the
 *  way the config did. */
export const SetupPlanCopySchema = z.object({
  rel: z.string(),
  from: z.string(),
  to: z.string(),
}).strict();

export const SetupPlanStepSchema = z.object({
  name: z.string(),
  copy: z.array(SetupPlanCopySchema).optional(),
  run: z.string().optional(),
  /** Absolute; the child never re-resolves it against its own cwd. */
  workingDir: z.string(),
  env: z.record(z.string(), z.string()).optional(),
}).strict();

/**
 * The fully resolved hand-off from runner to child. Every path in it is
 * absolute and every `${...}` is already interpolated: the child re-reads
 * nothing from `antgrid.yaml`, so the path guards below cannot be bypassed by
 * a config that changes between plan and run.
 */
export const SetupPlanFileSchema = z.object({
  version: z.literal(1),
  checkoutId: z.string(),
  checkoutPath: z.string(),
  projectPath: z.string(),
  sessionId: z.string(),
  /** Where the child writes its outcome. The PTY exit callback carries no exit
   *  code, so this file is the only channel for one. */
  resultPath: z.string(),
  /** The `ANTGRID_*` contract, applied to every `run` step's environment. */
  env: z.record(z.string(), z.string()),
  steps: z.array(SetupPlanStepSchema),
}).strict();

export type SetupPlanCopy = z.infer<typeof SetupPlanCopySchema>;
export type SetupPlanStep = z.infer<typeof SetupPlanStepSchema>;
export type SetupPlanFile = z.infer<typeof SetupPlanFileSchema>;

export const SetupResultFileSchema = z.object({
  exitCode: z.number().int(),
  stepIndex: z.number().int().nonnegative().optional(),
  stepName: z.string().optional(),
  message: z.string().optional(),
}).strict();

export type SetupResultFile = z.infer<typeof SetupResultFileSchema>;

/** A `worktree.setup` block that cannot be turned into a plan. Distinct from a
 *  step that fails at runtime: nothing is spawned and the transcript stays
 *  empty, so the message is all the user gets. */
export class SetupConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "SetupConfigError";
  }
}

/** Only what the runner asks of the terminal layer, so a test can stand in for
 *  it without building a PTY. */
export type SetupTerminalHost = Pick<TerminalManager, "spawn" | "killAndAwaitTree">;

export interface CheckoutSetupRunnerOptions {
  /** The MAIN project root. `copy` sources resolve against it and never
   *  against the checkout — the whole point is pulling in files the worktree
   *  does not have. */
  projectPath: string;
  terminals: SetupTerminalHost;
  /** Where plan/result files are staged. Outside the checkout on purpose: the
   *  worktree is the user's branch and a stray JSON file there shows up as an
   *  untracked change. */
  planDir?: string;
  /** Test seams for the self-spawn. Production reads `process.execPath` and
   *  the same `ANTGRID_BRIDGE_COMPILED` flag `resolveHookCommand` uses. */
  execPath?: string;
  entrypoint?: string;
  compiled?: boolean;
}

interface ActiveRun {
  checkoutId: string;
  terminalId: string;
  stepCount: number;
  stepIndex: number;
  stepName?: string;
  planPath: string;
  resultPath: string;
  timeoutMs: number;
  timer: ReturnType<typeof setTimeout> | null;
  /** Why WE killed the tree, when we did. Absent means the child exited on its
   *  own and its exit code decides the outcome. */
  killed: "cancelled" | "timeout" | null;
  finished: boolean;
  onProgress: (progress: CheckoutSetupProgress) => void;
}

/** Collapse to something that fits a one-line banner. */
function oneLine(value: string): string {
  const flat = value.replace(/\s+/g, " ").trim();
  return flat.length > 200 ? `${flat.slice(0, 199)}…` : flat;
}

/**
 * Runs a managed checkout's `worktree.setup` block in one PTY and reports
 * coarse transitions back to the session manager.
 *
 * The transcript is a real terminal rather than synthetic output because a
 * four-minute `bun install` is mostly colour and progress bars, and those only
 * exist when the child believes it has a TTY. What that PTY runs is the bridge
 * itself under a hidden subcommand — the shipped bridge is a compiled
 * single-file executable, so `process.execPath` plus a subcommand is the only
 * self-invocation that works, and it is the same shape `resolveHookCommand`
 * already relies on.
 */
export class CheckoutSetupRunner {
  private readonly runs = new Map<string, ActiveRun>();
  private readonly planDir: string;

  constructor(private readonly opts: CheckoutSetupRunnerOptions) {
    this.planDir = opts.planDir ?? join(resolveAbDir(), "setup");
  }

  /**
   * The checkout's own `worktree.setup`, or null when it has none.
   *
   * `findConfigFile` falls back to `<ANTGRID_DIR>/antgrid.yaml`, and a
   * machine-global setup block would then run for every project's worktrees
   * without anyone having asked — so a block is honoured only when the file it
   * came from physically lives in the checkout.
   *
   * @throws SetupConfigError when the checkout's antgrid.yaml does not parse.
   */
  resolveSetup(checkout: CheckoutRecord): WorktreeSetup | null {
    const found = findConfigFile(checkout.path);
    if (!found || resolve(found) !== resolve(join(checkout.path, "antgrid.yaml"))) return null;
    let setup: WorktreeSetup | undefined;
    try {
      setup = loadConfig(undefined, checkout.path).worktree?.setup;
    } catch (err) {
      throw new SetupConfigError(oneLine((err as Error).message));
    }
    return setup ?? null;
  }

  /** True while a setup run for this checkout is live. */
  isRunning(checkoutId: string): boolean {
    return this.runs.has(setupTerminalId(checkoutId));
  }

  /** True when this PTY is a live setup transcript, so its output and titles
   *  belong to the runner rather than to the session namer. */
  owns(terminalId: string): boolean {
    return this.runs.has(terminalId);
  }

  /**
   * Kick off setup. Returns immediately and never throws: `createWorktree` has
   * already replied to the client by the time this runs, so the only way a
   * failure can reach anyone is through `onProgress`.
   *
   * A checkout with no `worktree.setup` reports `done` with `stepCount: 0`
   * rather than staying silent — a caller that stamped `running` before
   * calling has to be released either way.
   */
  start(
    checkout: CheckoutRecord,
    sessionId: string,
    onProgress: (progress: CheckoutSetupProgress) => void,
  ): void {
    void this.begin(checkout, sessionId, onProgress).catch((err) => {
      log.warn(`setup for checkout ${checkout.id} could not start: ${(err as Error).message}`);
      onProgress({
        state: "failed",
        stepIndex: 0,
        stepCount: 0,
        message: oneLine((err as Error).message),
      });
    });
  }

  /**
   * Kill the run's process tree and wait for it to be gone. Awaited before
   * `git worktree remove`: on Windows a live `bun install` holding the checkout
   * as its cwd makes the remove fail.
   */
  async cancel(checkoutId: string): Promise<void> {
    const run = this.runs.get(setupTerminalId(checkoutId));
    if (!run) return;
    await this.killRun(run, "cancelled");
  }

  /**
   * Feed a PTY title. Returns true when the terminal is a setup transcript, in
   * which case the caller must NOT fall through to the session namer — every
   * title on this PTY is progress, not a conversation name.
   */
  handleTitle(terminalId: string, title: string): boolean {
    const run = this.runs.get(terminalId);
    if (!run) return false;
    const marker = parseSetupStepMarker(title);
    if (!marker) return true;
    run.stepIndex = marker.index;
    run.stepName = marker.name;
    run.onProgress({
      state: "running",
      stepIndex: run.stepIndex,
      stepCount: run.stepCount,
      stepName: run.stepName,
      terminalId,
    });
    return true;
  }

  /** Feed a PTY exit. Returns true when the runner owned the terminal. */
  handleExit(terminalId: string): boolean {
    const run = this.runs.get(terminalId);
    if (!run) return false;
    this.finish(run);
    return true;
  }

  private async begin(
    checkout: CheckoutRecord,
    sessionId: string,
    onProgress: (progress: CheckoutSetupProgress) => void,
  ): Promise<void> {
    const terminalId = setupTerminalId(checkout.id);
    // A rerun issued while the previous attempt is still alive would otherwise
    // leave two children writing the same result file.
    const previous = this.runs.get(terminalId);
    if (previous) await this.killRun(previous, "cancelled");

    const setup = this.resolveSetup(checkout);
    if (!setup || setup.steps.length === 0) {
      onProgress({ state: "done", stepIndex: 0, stepCount: 0 });
      return;
    }

    const env = setupEnv(this.opts.projectPath, checkout, sessionId);
    const planPath = join(this.planDir, `${checkout.id}.plan.json`);
    const resultPath = join(this.planDir, `${checkout.id}.result.json`);
    const plan = this.buildPlan(setup, checkout, sessionId, resultPath, env);

    mkdirSync(this.planDir, { recursive: true });
    rmSync(resultPath, { force: true });
    writeFileSync(planPath, JSON.stringify(plan, null, 2), "utf8");

    const run: ActiveRun = {
      checkoutId: checkout.id,
      terminalId,
      stepCount: plan.steps.length,
      stepIndex: 0,
      stepName: plan.steps[0]?.name,
      planPath,
      resultPath,
      timeoutMs: clampTimeout(setup.timeoutMs ?? DEFAULT_SETUP_TIMEOUT_MS),
      timer: null,
      killed: null,
      finished: false,
      onProgress,
    };
    // Registered before the spawn: a title can land on the very first chunk.
    this.runs.set(terminalId, run);
    // `.catch` for the same reason `start()` has one: bridge/src/index.ts turns
    // an unhandled rejection into a whole-host shutdown, and everything
    // `killRun` reaches — the PTY kill, `onProgress`, the push seal — can throw.
    run.timer = setTimeout(() => {
      void this.killRun(run, "timeout").catch((err) => {
        log.warn(`setup timeout handling for ${run.checkoutId} failed: ${(err as Error).message}`);
      });
    }, run.timeoutMs);
    onProgress({
      state: "running",
      stepIndex: 0,
      stepCount: run.stepCount,
      stepName: run.stepName,
      terminalId,
    });

    const command = this.selfCommand(planPath);
    try {
      this.opts.terminals.spawn({
        terminalId,
        name: "setup",
        command: command.binary,
        args: command.args,
        cwd: checkout.path,
        env,
        // No `type`: this is neither an agent nor a service, and typing it
        // `service` would put a provisioning log in the services list.
        //
        // `suppressOscTitle` is deliberately NOT set — that flag suppresses the
        // onTitle callback itself, which is the channel every step transition
        // travels on.
        suppressOscNotifications: true,
        // The log is read AFTER the run at least as often as during it: a
        // failed step's output is the only explanation the banner's one-liner
        // does not carry, and the user expands it once the banner turns red.
        retainScrollbackOnExit: true,
      });
    } catch (err) {
      this.runs.delete(terminalId);
      if (run.timer) clearTimeout(run.timer);
      this.cleanupFiles(run);
      throw err;
    }
  }

  private buildPlan(
    setup: WorktreeSetup,
    checkout: CheckoutRecord,
    sessionId: string,
    resultPath: string,
    env: Record<string, string>,
  ): SetupPlanFile {
    const projectPath = resolve(this.opts.projectPath);
    const checkoutPath = resolve(checkout.path);
    const ctx: ResolveContext = {
      projectPath,
      checkoutPath,
      checkoutBranch: checkout.branch ?? undefined,
      baseBranch: checkout.baseRef ?? undefined,
      sessionId,
    };

    const steps: SetupPlanStep[] = setup.steps.map((step) => {
      const workingDirRaw = step.workingDir ? resolveVariables(step.workingDir, ctx) : undefined;
      return {
        name: step.name,
        ...(step.copy ? { copy: step.copy.map((entry) => planCopy(entry, ctx, step.name, projectPath, checkoutPath)) } : {}),
        ...(step.run ? { run: resolveVariables(step.run, ctx) } : {}),
        workingDir: planWorkingDir(workingDirRaw, step.name, checkoutPath),
        ...(step.env
          ? { env: Object.fromEntries(Object.entries(step.env).map(([k, v]) => [k, resolveVariables(v, ctx)])) }
          : {}),
      };
    });

    return {
      version: 1,
      checkoutId: checkout.id,
      checkoutPath,
      projectPath,
      sessionId,
      resultPath,
      env,
      steps,
    };
  }

  private selfCommand(planPath: string): { binary: string; args: string[] } {
    const binary = this.opts.execPath ?? process.execPath;
    const compiled = this.opts.compiled ?? process.env.ANTGRID_BRIDGE_COMPILED === "1";
    // Uncompiled, `process.execPath` is bun itself, so the entrypoint has to be
    // named before the subcommand — same split `resolveHookCommand` makes.
    const preargs = compiled ? [] : [this.opts.entrypoint ?? Bun.main];
    return { binary, args: [...preargs, "worktree-setup", "--plan", planPath] };
  }

  private async killRun(run: ActiveRun, reason: "cancelled" | "timeout"): Promise<void> {
    if (run.finished) return;
    run.killed = reason;
    if (run.timer) { clearTimeout(run.timer); run.timer = null; }
    await this.opts.terminals.killAndAwaitTree(run.terminalId);
    // The PTY's exit normally lands on handleExit; finish here too so a
    // terminal layer that never reports one cannot leave the run pending.
    this.finish(run);
  }

  private finish(run: ActiveRun): void {
    if (run.finished) return;
    run.finished = true;
    if (run.timer) { clearTimeout(run.timer); run.timer = null; }
    this.runs.delete(run.terminalId);

    const result = readResult(run.resultPath);
    this.cleanupFiles(run);

    const stepIndex = result?.stepIndex ?? run.stepIndex;
    const stepName = result?.stepName ?? run.stepName;
    const base = {
      stepIndex,
      stepCount: run.stepCount,
      stepName,
      terminalId: run.terminalId,
    };

    if (run.killed === "cancelled") {
      run.onProgress({ ...base, state: "skipped", message: "Setup cancelled" });
      return;
    }
    if (run.killed === "timeout") {
      run.onProgress({
        ...base,
        state: "failed",
        message: `Setup timed out after ${Math.round(run.timeoutMs / 1000)}s`,
      });
      return;
    }
    // No result file means the child died before it could write one — a crash,
    // not a clean non-zero exit, so there is no code to report either.
    if (!result) {
      run.onProgress({ ...base, state: "failed", message: "Setup ended without reporting a result" });
      return;
    }
    if (result.exitCode === 0) {
      run.onProgress({ ...base, state: "done", exitCode: 0 });
      return;
    }
    run.onProgress({
      ...base,
      state: "failed",
      exitCode: result.exitCode,
      message: result.message ?? `Setup failed with exit code ${result.exitCode}`,
    });
  }

  private cleanupFiles(run: ActiveRun): void {
    try {
      rmSync(run.planPath, { force: true });
      rmSync(run.resultPath, { force: true });
    } catch {
      // Stale staging files are harmless; the next run overwrites them.
    }
  }
}

/** The `ANTGRID_*` contract every `run` step is promised. */
function setupEnv(projectPath: string, checkout: CheckoutRecord, sessionId: string): Record<string, string> {
  return {
    ANTGRID_PROJECT_PATH: resolve(projectPath),
    ANTGRID_CHECKOUT_PATH: resolve(checkout.path),
    ANTGRID_CHECKOUT_BRANCH: checkout.branch ?? "",
    ANTGRID_BASE_BRANCH: checkout.baseRef ?? "",
    ANTGRID_SESSION_ID: sessionId,
    ANTGRID_SETUP: "1",
  };
}

/**
 * Turn one `copy:` entry into an absolute source/destination pair.
 *
 * The source is read from the MAIN project and the destination keeps the same
 * relative path inside the checkout, so both sides must be proven to stay under
 * their own root: `copy: ["../../.ssh/id_ed25519"]` would otherwise read
 * outside the project and write outside the worktree, and a checkout's
 * `antgrid.yaml` is branch-supplied content. An escape is a config error and
 * refuses the whole run rather than skipping the entry — a setup that silently
 * dropped a step would be worse than one that says why it will not start.
 */
function planCopy(
  raw: string,
  ctx: ResolveContext,
  stepName: string,
  projectPath: string,
  checkoutPath: string,
): SetupPlanCopy {
  const rel = resolveVariables(raw, ctx);
  // `parse().root`, not `isAbsolute()`: the drive-RELATIVE spelling `C:foo` is
  // not absolute, yet `resolve()` anchors it to that drive's own cwd rather
  // than to the base handed in, so it lands somewhere unrelated to either root.
  if (parse(rel).root !== "") {
    throw new SetupConfigError(`step "${stepName}": copy path "${rel}" must be relative to the project root`);
  }
  const from = resolve(projectPath, rel);
  const to = resolve(checkoutPath, rel);
  if (!pathBelow(projectPath, from) || !pathBelow(checkoutPath, to)) {
    throw new SetupConfigError(`step "${stepName}": copy path "${rel}" escapes the project root`);
  }
  return { rel, from, to };
}

/**
 * A step's cwd, proven to stay inside the checkout it is provisioning.
 *
 * `resolve()` DISCARDS its base when the second argument is absolute, so an
 * unguarded `workingDir: "${project.path}"` would run the step in the main tree
 * and report a green banner over a worktree nothing was installed into. The
 * root itself is allowed here (unlike `copy`, where equality means "overwrite
 * the whole tree"): `workingDir: "."` is the default spelled out.
 */
function planWorkingDir(raw: string | undefined, stepName: string, checkoutPath: string): string {
  if (!raw) return checkoutPath;
  const dir = resolve(checkoutPath, raw);
  if (dir !== checkoutPath && !pathBelow(checkoutPath, dir)) {
    throw new SetupConfigError(`step "${stepName}": workingDir "${raw}" escapes the checkout`);
  }
  return dir;
}

/** `setTimeout` silently collapses a delay above the 32-bit signed ceiling to
 *  1 ms, so an over-large `timeoutMs` would kill the run on its first tick and
 *  report it as a timeout. Clamped rather than refused: the intent of a huge
 *  budget is "do not time out", and the ceiling is ~24.8 days. */
function clampTimeout(ms: number): number {
  return Math.min(ms, 0x7fffffff);
}

function readResult(path: string): SetupResultFile | null {
  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch {
    return null;
  }
  try {
    return SetupResultFileSchema.parse(JSON.parse(raw));
  } catch (err) {
    log.warn(`unreadable setup result at ${path}: ${(err as Error).message}`);
    return null;
  }
}

/** Exported for the child, which writes the file this runner reads. */
export function writeSetupResult(path: string, result: SetupResultFile): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, JSON.stringify(result), "utf8");
}
