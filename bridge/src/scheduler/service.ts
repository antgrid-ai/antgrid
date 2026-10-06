import { randomUUID } from "node:crypto";
import { nextOccurrences, validateCron, validateTimezone } from "./cron";
import { ScheduleInputSchema, SchedulePatchSchema, isActiveRun, type Schedule, type ScheduleInput, type SchedulePatch,
  type SchedulerCapabilities, type SchedulerRun, type RunStatus } from "./models";
import { SchedulerStore } from "./store";

const LAUNCH_FAILURE_REASONS = {
  PROJECT_UNAVAILABLE: "Project is unavailable. Open it from the desktop before running this schedule.",
  WORKTREE_MISSING: "Schedule workspace is missing. Restore it or create a new schedule.",
  WORKTREE_CONFLICT: "Schedule workspace ownership or Git state is inconsistent. Review the workspace or create a new schedule.",
  WORKTREE_CREATE_FAILED: "Could not create the schedule workspace. Check Git and the selected base branch, then run again.",
  WORKTREE_WORKING_DIR_UNSAFE: "The configured agent working directory escapes the schedule workspace. Fix agent.workingDir in antgrid.yaml.",
  UNKNOWN_BASE_BRANCH: "The schedule base branch is unavailable. Restore the branch or edit the schedule before its first workspace is created.",
  NOT_GIT_REPOSITORY: "This project is no longer a Git repository. Restore it or create a schedule using the shared workspace.",
  SETUP_FAILED: "Schedule workspace setup failed. Open the session setup log and recover setup before running again.",
  CHECKOUT_STORE_UNAVAILABLE: "Checkout metadata is unavailable. Restore it before running this schedule again.",
  AGENT_COMPLETION_UNAVAILABLE: "Agent completion monitoring could not be installed. Repair the agent integration before running again.",
} as const;
export class SchedulerLaunchError extends Error {
  constructor(readonly code: keyof typeof LAUNCH_FAILURE_REASONS) { super(LAUNCH_FAILURE_REASONS[code]); }
}
function launchFailureReason(error: unknown): string {
  const code = error && typeof error === "object" && "code" in error ? error.code : undefined;
  return typeof code === "string" && Object.hasOwn(LAUNCH_FAILURE_REASONS, code)
    ? LAUNCH_FAILURE_REASONS[code as keyof typeof LAUNCH_FAILURE_REASONS]
    : "Could not prepare or deliver the scheduled prompt; check the project, workspace, agent, and setup log";
}
const OWNERSHIP_CLEANUP_ERROR = "A deleted schedule still owns its workspace. Restore checkout metadata and reopen the desktop app to retry ownership release.";

export interface ScheduledSessionIdentity { sessionId: string; runtimeGeneration: string; checkoutId?: string }
export interface SchedulerObservation extends ScheduledSessionIdentity {
  projectId: string;
  status: Exclude<RunStatus, "preparing" | "skipped">;
  reason?: string;
}
export interface SchedulerOptions {
  abDir: string;
  desktopOwned: boolean;
  timezone?: string;
  now?: () => number;
  supportedAgents: () => SchedulerCapabilities["agents"] | Promise<SchedulerCapabilities["agents"]>;
  authorize: (schedule: Schedule) => string | null | Promise<string | null>;
  prepare: (schedule: Schedule, run: SchedulerRun, bind: (identity: ScheduledSessionIdentity) => void) => Promise<
    ScheduledSessionIdentity & { deliverPrompt: () => Promise<void> }>;
  stop: (run: SchedulerRun) => Promise<void>;
  releaseWorkspace?: (schedule: Schedule) => Promise<void>;
}

export class SchedulerService {
  readonly store: SchedulerStore;
  readonly timezone: string;
  private readonly now: () => number;
  private timer?: ReturnType<typeof setInterval>;
  private ticking = false;
  private fault?: string;
  private readonly cleanupFailures = new Set<string>();
  private readonly cancelling = new Set<string>();
  private closed = false;

  constructor(private readonly options: SchedulerOptions) {
    this.now = options.now ?? Date.now;
    this.timezone = validateTimezone(options.timezone ?? Intl.DateTimeFormat().resolvedOptions().timeZone);
    this.store = new SchedulerStore(options.abDir);
    try {
      for (const run of this.store.runs().filter(isActiveRun)) {
        this.store.updateRun(run.id, (r) => ({ ...r, status: "interrupted", finishedAt: this.now(),
          reason: "Desktop host restarted; uncertain prompt delivery will not be replayed" }));
      }
      this.skipMissed();
    } catch (error) { this.store.close(); throw error; }
  }

  start(): void {
    if (this.timer || this.closed) return;
    void this.cleanupDeleted().catch(() => {});
    this.timer = setInterval(() => { void this.tick().catch(() => {}); }, 1_000);
    this.timer.unref?.();
  }
  private guarded<T>(fn: () => T): T {
    if (this.closed) throw new Error("Scheduler is closed");
    if (this.fault) throw new Error(this.fault);
    try { return fn(); }
    catch (error) {
      this.fault = "Scheduler storage failed; execution is disabled until the desktop host restarts";
      throw new Error(this.fault);
    }
  }
  private executable(): void {
    if (!this.options.desktopOwned) throw new Error("Scheduled execution requires the target desktop app to remain open");
    if (this.closed || this.fault) throw new Error(this.fault ?? "Scheduler is closed");
  }
  async capabilities(): Promise<SchedulerCapabilities> {
    const error = this.fault ?? (this.cleanupFailures.size ? OWNERSHIP_CLEANUP_ERROR : undefined);
    return { supported: this.options.desktopOwned && !this.closed && !this.fault, timezone: this.timezone, supportsBaseBranchClear: true,
      agents: await this.options.supportedAgents(), ...(error ? { error } : {}) };
  }
  schedules(): Schedule[] { return this.guarded(() => this.store.schedules()); }
  runs(scheduleId?: string): SchedulerRun[] { return this.guarded(() => this.store.runs(scheduleId)); }
  preview(cron: string, timezone = this.timezone): number[] { return nextOccurrences(cron, timezone, this.now()); }
  private find(id: string): Schedule {
    const schedule = this.schedules().find((s) => s.id === id);
    if (!schedule) throw new Error("Schedule no longer exists");
    return schedule;
  }
  private async validated(input: unknown): Promise<ScheduleInput> {
    const parsed = ScheduleInputSchema.parse(input);
    parsed.cron = validateCron(parsed.cron, parsed.timezone);
    const agents = await this.options.supportedAgents();
    if (!agents.some((agent) => agent.agentId === parsed.agentId && agent.modes.includes(parsed.mode))) {
      throw new Error("This installed agent and mode do not support opening prompts and observable turn completion");
    }
    return parsed;
  }
  async create(input: unknown, authorDeviceId: string | null = null): Promise<Schedule> {
    this.executable();
    const parsed = await this.validated(input);
    const now = this.now();
    const schedule: Schedule = { ...parsed, id: randomUUID(), authorDeviceId, workspaceCreated: false,
      createdAt: now, updatedAt: now, nextOccurrence: nextOccurrences(parsed.cron, parsed.timezone, now, 1)[0]! };
    this.guarded(() => this.store.saveSchedule(schedule));
    return schedule;
  }
  async update(id: string, patch: unknown, authorDeviceId: string | null = null): Promise<Schedule> {
    this.executable();
    const parsed: SchedulePatch = SchedulePatchSchema.parse(patch);
    const changes = { ...parsed, ...(parsed.baseBranch === null ? { baseBranch: undefined } : {}) };
    const agents = await this.options.supportedAgents();
    const original = this.find(id);
    if ((original.workspaceCreated || this.runs(id).some(isActiveRun)) && (["projectId", "workspace", "baseBranch"] as const)
      .some((key) => key in changes && changes[key] !== original[key])) {
      throw new Error("Project, workspace, and base branch cannot change after the schedule workspace is created");
    }
    const originalInput = Object.fromEntries(Object.keys(ScheduleInputSchema.shape).map((key) => [key, original[key as keyof Schedule]]));
    const input = ScheduleInputSchema.parse({ ...originalInput, ...changes });
    input.cron = validateCron(input.cron, input.timezone);
    if (!agents.some((agent) => agent.agentId === input.agentId && agent.modes.includes(input.mode))) {
      throw new Error("This installed agent and mode do not support opening prompts and observable turn completion");
    }
    const now = this.now();
    let nextOccurrence = original.nextOccurrence;
    if (input.cron !== original.cron || input.timezone !== original.timezone) nextOccurrence = nextOccurrences(input.cron, input.timezone, now, 1)[0]!;
    if (!original.enabled && input.enabled && nextOccurrence <= now) {
      this.recordMissed(original, now);
      nextOccurrence = nextOccurrences(input.cron, input.timezone, now, 1)[0]!;
    }
    const executionChanged = (["projectId", "agentId", "mode", "prompt", "approvalPolicy", "workspace", "baseBranch", "cron", "timezone", "enabled"] as const)
      .some((key) => input[key] !== original[key]);
    const next = { ...original, ...input, authorDeviceId: executionChanged ? authorDeviceId : original.authorDeviceId, updatedAt: now, nextOccurrence };
    this.guarded(() => this.store.saveSchedule(next));
    return next;
  }
  async delete(id: string): Promise<void> {
    this.executable();
    const schedule = this.guarded(() => this.store.schedules(true)).find((s) => s.id === id);
    if (!schedule) throw new Error("Schedule no longer exists");
    const deleted = schedule.deletedAt === undefined ? { ...schedule, enabled: false, deletedAt: this.now(), updatedAt: this.now() } : schedule;
    if (schedule.deletedAt === undefined) this.guarded(() => this.store.saveSchedule(deleted));
    await this.releaseDeleted(deleted);
  }
  private async releaseDeleted(schedule: Schedule): Promise<void> {
    try {
      await this.options.releaseWorkspace?.(schedule);
      this.cleanupFailures.delete(schedule.id);
    } catch {
      this.cleanupFailures.add(schedule.id);
      throw new Error(OWNERSHIP_CLEANUP_ERROR);
    }
  }
  private async cleanupDeleted(): Promise<void> {
    for (const schedule of this.guarded(() => this.store.schedules(true)).filter((s) => s.deletedAt !== undefined)) {
      if (this.closed || this.fault) return;
      try { await this.releaseDeleted(schedule); } catch { /* One unavailable checkout store must not block other ownership releases. */ }
    }
  }
  private newRun(schedule: Schedule, occurrenceAt: number, trigger: SchedulerRun["trigger"]): SchedulerRun {
    return { id: randomUUID(), scheduleId: schedule.id, scheduleName: schedule.name, projectId: schedule.projectId,
      occurrenceAt, timezone: schedule.timezone, trigger, status: "preparing", startedAt: this.now() };
  }
  private recordMissed(schedule: Schedule, now: number): void {
    const run = { ...this.newRun(schedule, schedule.nextOccurrence, "missed"), status: "skipped" as const,
      reason: "Missed while the desktop host was unavailable or the schedule was paused", finishedAt: now, missedUntil: now };
    this.guarded(() => this.store.claim(schedule, run, nextOccurrences(schedule.cron, schedule.timezone, now, 1)[0]!));
  }
  private skipMissed(): void {
    const now = this.now();
    for (const schedule of this.schedules()) if (schedule.enabled && schedule.nextOccurrence <= now) this.recordMissed(schedule, now);
  }
  resume(): void { this.executable(); this.skipMissed(); }
  async runNow(id: string, requestingDeviceId?: string | null): Promise<SchedulerRun> {
    this.executable();
    const schedule = this.find(id);
    const run = this.guarded(() => this.store.claim(schedule, this.newRun(schedule, this.now(), "manual")));
    if (!run) throw new Error("Schedule was deleted");
    if (isActiveRun(run)) void this.dispatch(schedule, run, requestingDeviceId ?? undefined).catch(() => {});
    return run;
  }
  async tick(): Promise<void> {
    if (this.ticking || this.closed || this.fault || !this.options.desktopOwned) return;
    this.ticking = true;
    try {
      const now = this.now();
      for (const schedule of this.schedules()) {
        if (!schedule.enabled || schedule.nextOccurrence > now) continue;
        const next = nextOccurrences(schedule.cron, schedule.timezone, schedule.nextOccurrence, 1)[0]!;
        if (next <= now) { this.recordMissed(schedule, now); continue; }
        const run = this.guarded(() => this.store.claim(schedule, this.newRun(schedule, schedule.nextOccurrence, "cron"), next));
        if (run && isActiveRun(run)) void this.dispatch(schedule, run).catch(() => {});
      }
    } finally { this.ticking = false; }
  }
  private finish(id: string, status: RunStatus, reason?: string): void {
    this.guarded(() => this.store.updateRun(id, (r) => isActiveRun(r)
      ? { ...r, status, ...(reason ? { reason } : {}), ...(status === "running" || status === "needs-input" ? {} : { finishedAt: this.now() }) }
      : r));
  }
  private async dispatch(schedule: Schedule, run: SchedulerRun, requestingDeviceId?: string): Promise<void> {
    let reservation: SchedulerRun | undefined;
    let delivered = false;
    const authorize = async () => {
      const authorRefusal = await this.options.authorize(schedule);
      if (authorRefusal || !requestingDeviceId || requestingDeviceId === schedule.authorDeviceId) return authorRefusal;
      return this.options.authorize({ ...schedule, authorDeviceId: requestingDeviceId });
    };
    try {
      const refusal = await authorize();
      if (refusal) { this.finish(run.id, "skipped", refusal); return; }
      const supported = await this.options.supportedAgents();
      if (!supported.some((a) => a.agentId === schedule.agentId && a.modes.includes(schedule.mode))) {
        this.finish(run.id, "failed", "Scheduled agent or mode is no longer available; edit the schedule to choose an installed agent"); return;
      }
      const prepared = await this.options.prepare(schedule, run, (identity) => {
        reservation = { ...run, ...identity };
        if (this.cancelling.has(run.id) || !this.runs().some((r) => r.id === run.id && isActiveRun(r))) throw new Error("Scheduled preparation was stopped");
        this.guarded(() => this.store.bind(run.id, identity));
      });
      reservation = { ...run, sessionId: prepared.sessionId, runtimeGeneration: prepared.runtimeGeneration, checkoutId: prepared.checkoutId };
      this.executable();
      const latest = this.guarded(() => this.store.schedules(true)).find((s) => s.id === schedule.id)!;
      if ((["projectId", "agentId", "mode", "prompt", "approvalPolicy", "workspace", "baseBranch", "authorDeviceId"] as const)
        .some((key) => latest[key] !== schedule[key])) {
        this.finish(run.id, "skipped", "Execution settings changed during preparation; the new settings apply to the next occurrence"); return;
      }
      const revoked = await authorize();
      if (revoked) { this.finish(run.id, "skipped", revoked); return; }
      if (this.cancelling.has(run.id) || !this.guarded(() => this.store.runs()).some((r) => r.id === run.id && isActiveRun(r))) return;
      const bound = this.guarded(() => this.store.runs()).find((r) => r.id === run.id);
      if (!bound?.sessionId || !bound.runtimeGeneration) throw new Error("Scheduled launch did not durably associate its session before prompt delivery");
      await prepared.deliverPrompt();
      delivered = true;
      const current = this.guarded(() => this.store.runs()).find((r) => r.id === run.id);
      if (current?.status === "preparing") this.finish(run.id, "running");
    } catch (error) {
      if (!this.fault && !this.closed && !this.cancelling.has(run.id)) this.finish(run.id, "failed", launchFailureReason(error));
    } finally {
      if (reservation && !delivered) {
        try { await this.options.stop(reservation); }
        catch { /* The run is terminal or storage-failed; no prompt may be resubmitted to recover cancellation. */ }
      }
      if (!this.closed && !this.fault) {
        const deleted = this.guarded(() => this.store.schedules(true)).find((s) => s.id === schedule.id && s.deletedAt !== undefined);
        if (deleted) await this.releaseDeleted(deleted);
      }
    }
  }
  observe(event: SchedulerObservation): void {
    if (this.closed || this.fault) return;
    try {
      const run = this.runs().find((r) => isActiveRun(r) && r.projectId === event.projectId && r.sessionId === event.sessionId
        && r.runtimeGeneration === event.runtimeGeneration);
      if (run && !this.cancelling.has(run.id)) this.finish(run.id, event.status, event.reason);
    } catch { /* Storage failure is surfaced by capabilities without breaking agent event delivery. */ }
  }
  async stop(id: string): Promise<void> {
    this.executable();
    const run = this.runs().find((r) => r.id === id);
    if (!run || !isActiveRun(run)) throw new Error("Run is no longer active");
    this.cancelling.add(id);
    try {
      if (run.sessionId || run.status !== "preparing") await this.options.stop(run);
      this.finish(id, "interrupted", "Stopped by user");
    } finally { this.cancelling.delete(id); }
  }
  interruptProject(projectId: string, reason: string): void {
    if (this.closed || this.fault) return;
    try {
      for (const run of this.runs().filter((r) => r.projectId === projectId && isActiveRun(r))) this.finish(run.id, "interrupted", reason);
    } catch { /* Restart reconciliation records interruption if storage could not accept shutdown. */ }
  }
  hasActiveProject(projectId: string): boolean {
    try { return this.runs().some((r) => r.projectId === projectId && isActiveRun(r)); }
    catch { return true; }
  }
  ownsCheckout(projectId: string, checkoutId: string): boolean {
    try { return this.schedules().some((s) => s.projectId === projectId && s.checkoutId === checkoutId); }
    catch { return true; }
  }
  close(): void {
    if (this.closed) return;
    if (this.timer) clearInterval(this.timer);
    this.closed = true;
    this.store.close();
  }
}
