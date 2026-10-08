import { randomUUID } from "node:crypto";
import { type MissedOccurrences, missedOccurrences, nextOccurrences, validateCron, validateTimezone } from "./cron";
import { MISSED_COUNT_CAP, SCHEDULE_INPUT_KEYS, ScheduleInputSchema, SchedulePatchSchema, isActiveRun, type Schedule, type ScheduleInput, type SchedulePatch,
  type SchedulerCapabilities, type SchedulerRun, type RunStatus } from "./models";
import { agentSpec } from "antgrid-agents/builtins";
import { SchedulerRefusal } from "./agent";
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
// An occurrence this recent is simply due, not missed: tick granularity and a slow wake should still run it as "cron".
const ON_TIME_MS = 60_000;
// A one-off must be at least this far ahead when it is created, re-timed or resumed, so the tick that claims it cannot
// race the write that stored it.
export const ONE_OFF_FLOOR_MS = 60_000;
export const CATCH_UP_MIN_LEAD_MS = 15 * 60_000;
const UNAVAILABLE_REASON = "Missed while the desktop app was closed or the computer was asleep";
const MISSED_REASONS = {
  unavailable: UNAVAILABLE_REASON,
  paused: "Missed while the schedule was paused",
  superseded: `${UNAVAILABLE_REASON}; only the latest missed run is caught up`,
  shortLead: `${UNAVAILABLE_REASON}; not caught up because the next run is due within 15 minutes`,
} as const;
const OWNERSHIP_CLEANUP_ERROR = "A deleted schedule still owns its workspace. Restore checkout metadata and reopen the desktop app to retry ownership release.";

export type SchedulerAuthor =
  | { kind: "device"; deviceId: string | null }
  | { kind: "agent"; sessionId: string; sessionName: string };
export interface SchedulerGuardInput {
  op: "create" | "update" | "runNow";
  /** The keys the caller named, before they were merged over the stored record. */
  patchKeys: readonly string[];
  original?: Schedule;
  next: Schedule;
}
/** Runs synchronously in the same window as the write it authorizes, and throws a {@link SchedulerRefusal} to refuse. */
export type SchedulerGuard = (input: SchedulerGuardInput) => void;
export interface SchedulerWriteOptions {
  author?: SchedulerAuthor;
  guard?: SchedulerGuard;
  /** Validates and returns the record that would be saved, writing nothing. */
  dryRun?: boolean;
  rejectDuplicateName?: boolean;
}
const APP_AUTHOR: SchedulerAuthor = { kind: "device", deviceId: null };
/** A chat permission mode only means something to a chat run that is not already bypassing prompts. */
function normalizeChatMode<T extends { mode: string; approvalPolicy: string; chatMode?: string }>(input: T): T {
  if (input.chatMode !== undefined && (input.mode !== "chat" || input.approvalPolicy === "bypass")) delete input.chatMode;
  return input;
}
const sameName = (a: string, b: string) => a.trim().toLowerCase() === b.trim().toLowerCase();

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
  prepare: (schedule: Schedule, run: SchedulerRun, bind: (identity: ScheduledSessionIdentity) => void) => Promise<
    ScheduledSessionIdentity & { deliverPrompt: () => Promise<void> }>;
  stop: (run: SchedulerRun) => Promise<void>;
  releaseWorkspace?: (schedule: Schedule) => Promise<void>;
  /** The chat `mode` a schedule marked by the migration was effectively running in, or undefined for the backend
   *  default. Rejecting counts as undefined: the marker is cleared either way. */
  resolveChatModeCarryOver?: (schedule: Schedule) => Promise<string | undefined>;
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
  private carryOver?: Promise<void>;

  constructor(private readonly options: SchedulerOptions) {
    this.now = options.now ?? Date.now;
    this.timezone = validateTimezone(options.timezone ?? Intl.DateTimeFormat().resolvedOptions().timeZone);
    this.store = new SchedulerStore(options.abDir);
    try {
      for (const run of this.store.runs().filter(isActiveRun)) {
        this.store.updateRun(run.id, (r) => ({ ...r, status: "interrupted", finishedAt: this.now(),
          reason: "Desktop host restarted; uncertain prompt delivery will not be replayed" }));
      }
    } catch (error) { this.store.close(); throw error; }
  }

  start(): void {
    if (this.timer || this.closed) return;
    void this.cleanupDeleted().catch(() => {});
    this.carryOver ??= this.resolveCarryOver().catch(() => {});
    this.timer = setInterval(() => { void this.tick().catch(() => {}); }, 1_000);
    this.timer.unref?.();
  }
  /**
   * Settles every schedule the store migration marked. Idempotent and rerun at each start while a marker remains, so a
   * crash after the migration loses nothing. tick() and runNow() wait on it: a marked schedule dispatched first would
   * run in the backend default instead of the mode it was carried over from.
   */
  private async resolveCarryOver(): Promise<void> {
    const resolve = this.options.resolveChatModeCarryOver;
    if (!resolve) return;
    for (const { id } of this.schedules().filter((s) => s.chatModeCarryOver)) {
      let resolvedFor: Schedule | undefined;
      let mode: string | undefined;
      for (;;) {
        // Re-read: an edit during the await wins, and a plain write keeps the author and updatedAt the user last saw.
        const current = this.schedules().find((s) => s.id === id);
        if (!current?.chatModeCarryOver) break;
        // A mode read for another agent or project is meaningless here (and an id the registry does not know for this
        // agent would make the schedule ungated), so an agent or project edit during the await resolves again.
        if (resolvedFor?.agentId === current.agentId && resolvedFor.projectId === current.projectId) {
          const { chatModeCarryOver: _marker, ...rest } = current;
          const applies = mode !== undefined && current.chatMode === undefined && current.mode === "chat" && current.approvalPolicy !== "bypass";
          this.guarded(() => this.store.saveSchedule(applies ? { ...rest, chatMode: mode } : rest));
          break;
        }
        resolvedFor = current;
        try { mode = await resolve(current); } catch { mode = undefined; }
        if (this.closed || this.fault) return;
      }
    }
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
    if (!this.options.desktopOwned) throw new SchedulerRefusal("SCHEDULER_UNAVAILABLE", "Scheduled execution requires the target desktop app to remain open");
    if (this.closed || this.fault) throw new SchedulerRefusal("SCHEDULER_UNAVAILABLE", this.fault ?? "Scheduler is closed");
  }
  async capabilities(): Promise<SchedulerCapabilities> {
    const error = this.fault ?? (this.cleanupFailures.size ? OWNERSHIP_CLEANUP_ERROR : undefined);
    const agents = await this.options.supportedAgents();
    const chatModes = Object.fromEntries(agents.filter((a) => a.modes.includes("chat")).flatMap((a) => {
      const modes = agentSpec(a.agentId)?.chatPermissionModes;
      return modes ? [[a.agentId, modes.map(({ id, name, description }) => ({ id, name, ...(description ? { description } : {}) }))]] : [];
    }));
    return { supported: this.options.desktopOwned && !this.closed && !this.fault, timezone: this.timezone, supportsBaseBranchClear: true, supportsCatchUp: true, supportsOneOff: true,
            agents, ...(Object.keys(chatModes).length ? { chatModes } : {}), ...(error ? { error } : {}) };
  }
  schedules(): Schedule[] { return this.guarded(() => this.store.schedules()); }
  runs(scheduleId?: string): SchedulerRun[] { return this.guarded(() => this.store.runs(scheduleId)); }
  preview(cron: string, timezone = this.timezone): number[] { return nextOccurrences(cron, timezone, this.now()); }
  // Capped so a minute-level cron stays small on the wire; the app reads a full cap as "at least".
  upcoming(schedule: Schedule, windowMs = 86_400_000, cap = 48): number[] {
    if (!schedule.enabled || schedule.cron === undefined) return [];
    const now = this.now();
    try { return nextOccurrences(schedule.cron, schedule.timezone, now, cap).filter((at) => at < now + windowMs); }
    catch { return []; }
  }
  private find(id: string): Schedule {
    const schedule = this.schedules().find((s) => s.id === id);
    if (!schedule) throw new SchedulerRefusal("SCHEDULE_NOT_FOUND", "Schedule no longer exists");
    return schedule;
  }
  private assertSupported(agents: SchedulerCapabilities["agents"], agentId: string, mode: string): void {
    if (agents.some((agent) => agent.agentId === agentId && agent.modes.includes(mode as "terminal" | "chat"))) return;
    const list = agents.map((agent) => `${agent.agentId} (${agent.modes.join(", ")})`).join("; ") || "none";
    throw new SchedulerRefusal("AGENT_NOT_SCHEDULABLE",
      `This installed agent and mode do not support opening prompts and observable turn completion. Schedulable: ${list}`);
  }
  private assertRunAtFloor(runAt: number, now: number): void {
    if (runAt < now + ONE_OFF_FLOOR_MS) throw new SchedulerRefusal("INVALID_RUN_AT", "The one-off time has already passed; set a new time.");
  }
  private assertNameFree(projectId: string, name: string, exceptId?: string): void {
    const clash = this.guarded(() => this.store.schedules()).find((s) => s.projectId === projectId && s.id !== exceptId && sameName(s.name, name));
    if (clash) throw new SchedulerRefusal("SCHEDULE_EXISTS", `A schedule named "${clash.name}" already exists in this project (id ${clash.id}); update it instead.`);
  }
  private async validated(input: unknown): Promise<ScheduleInput> {
    const parsed = normalizeChatMode(ScheduleInputSchema.parse(input));
    if (parsed.cron !== undefined) parsed.cron = validateCron(parsed.cron, parsed.timezone);
    else validateTimezone(parsed.timezone);
    this.assertSupported(await this.options.supportedAgents(), parsed.agentId, parsed.mode);
    return parsed;
  }
  async create(input: unknown, options: SchedulerWriteOptions = {}): Promise<Schedule> {
    this.executable();
    const parsed = await this.validated(input);
    const now = this.now();
    if (parsed.runAt !== undefined) this.assertRunAtFloor(parsed.runAt, now);
    const author = options.author ?? APP_AUTHOR;
    const schedule: Schedule = { ...parsed, id: randomUUID(), authorDeviceId: author.kind === "device" ? author.deviceId : null,
      ...(author.kind === "agent" ? { authorSessionId: author.sessionId, authorSessionName: author.sessionName } : {}),
      workspaceCreated: false, createdAt: now, updatedAt: now,
      nextOccurrence: parsed.runAt ?? nextOccurrences(parsed.cron!, parsed.timezone, now, 1)[0]! };
    // From here to the write nothing awaits, so the checks below cannot be invalidated by another request.
    options.guard?.({ op: "create", patchKeys: [], next: schedule });
    if (options.rejectDuplicateName) this.assertNameFree(schedule.projectId, schedule.name);
    if (options.dryRun) return schedule;
    this.guarded(() => this.store.saveSchedule(schedule));
    return schedule;
  }
  async update(id: string, patch: unknown, options: SchedulerWriteOptions = {}): Promise<Schedule> {
    this.executable();
    const parsed: SchedulePatch = SchedulePatchSchema.parse(patch);
    const changes = { ...parsed, ...(parsed.baseBranch === null ? { baseBranch: undefined } : {}) };
    const agents = await this.options.supportedAgents();
    const original = this.find(id);
    if ((original.workspaceCreated || this.runs(id).some(isActiveRun)) && (["projectId", "workspace", "baseBranch"] as const)
      .some((key) => key in changes && changes[key] !== original[key])) {
      throw new SchedulerRefusal("WORKSPACE_LOCKED", "Project, workspace, and base branch cannot change after the schedule workspace is created");
    }
    const merged: Record<string, unknown> = { ...Object.fromEntries(SCHEDULE_INPUT_KEYS.map((key) => [key, original[key]])), ...changes };
    // Naming one timetable kind switches the schedule to it.
    if (changes.runAt !== undefined) delete merged.cron;
    if (changes.cron !== undefined) delete merged.runAt;
    if (merged.chatMode === null) delete merged.chatMode;
    const input = normalizeChatMode(ScheduleInputSchema.parse(merged));
    if (input.cron !== undefined) input.cron = validateCron(input.cron, input.timezone);
    else validateTimezone(input.timezone);
    this.assertSupported(agents, input.agentId, input.mode);
    const now = this.now();
    const runAtChanged = input.runAt !== original.runAt;
    // An unchanged time is never re-checked, so renaming or re-prompting a pending one-off still works as it nears.
    if (input.runAt !== undefined && (runAtChanged || (!original.enabled && input.enabled && original.firedRunId === undefined))) {
      this.assertRunAtFloor(input.runAt, now);
    }
    let nextOccurrence = original.nextOccurrence;
    if (input.runAt !== undefined) nextOccurrence = input.runAt;
    else if (input.cron !== original.cron || input.timezone !== original.timezone) nextOccurrence = nextOccurrences(input.cron!, input.timezone, now, 1)[0]!;
    const executionChanged = (["projectId", "agentId", "mode", "prompt", "approvalPolicy", "workspace", "baseBranch", "cron", "runAt", "timezone", "enabled", "catchUp", "chatMode"] as const)
      .some((key) => input[key] !== original[key]);
    const author = options.author ?? APP_AUTHOR;
    const { editedBySessionName: _by, editedAt: _at, ...base } = original;
    const next: Schedule = { ...base, ...input, updatedAt: now, nextOccurrence,
      authorDeviceId: author.kind === "device" && executionChanged ? author.deviceId : original.authorDeviceId,
      ...(author.kind === "agent" ? { editedBySessionName: author.sessionName, editedAt: now } : {}) };
    if (input.cron === undefined) delete next.cron;
    if (input.runAt === undefined) delete next.runAt;
    if (input.chatMode === undefined) delete next.chatMode;
    // Any decision about the mode, including clearing it, settles the carry-over.
    if ("chatMode" in parsed) delete next.chatModeCarryOver;
    // "Set a new time": a different instant, or a switch back to a recurring timetable, makes a finished one-off pending again.
    if (runAtChanged) { delete next.firedRunId; delete next.firedAt; delete next.deferredAt; }
    options.guard?.({ op: "update", patchKeys: Object.keys(parsed), original, next });
    if (options.rejectDuplicateName && !sameName(input.name, original.name)) this.assertNameFree(next.projectId, next.name, id);
    // Only reachable with the timetable unchanged, so the paused interval's own continuation is the next occurrence.
    const resumed = input.cron !== undefined && !original.enabled && input.enabled && nextOccurrence <= now;
    if (options.dryRun) return resumed ? { ...next, nextOccurrence: this.missedSince(original, now).following } : next;
    if (resumed) next.nextOccurrence = this.recordMissed(original, now, "paused");
    this.guarded(() => this.store.saveSchedule(next));
    return next;
  }
  async delete(id: string): Promise<void> {
    this.executable();
    const schedule = this.guarded(() => this.store.schedules(true)).find((s) => s.id === id);
    if (!schedule) throw new SchedulerRefusal("SCHEDULE_NOT_FOUND", "Schedule no longer exists");
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
  private missedRecord(schedule: Schedule, count: number, until: number, reason: string, now: number): SchedulerRun {
    return { ...this.newRun(schedule, schedule.nextOccurrence, "missed"), status: "skipped", reason, finishedAt: now,
      missedUntil: until, missedCount: Math.min(count, MISSED_COUNT_CAP) };
  }
  /** Records every occurrence due since `schedule.nextOccurrence` as one skipped interval; never runs anything. */
  private recordMissed(schedule: Schedule, now: number, reason: keyof typeof MISSED_REASONS): number {
    const missed = this.missedSince(schedule, now);
    this.guarded(() => this.store.claim(schedule, this.missedRecord(schedule, missed.count, missed.latest, MISSED_REASONS[reason], now), missed.following));
    return missed.following;
  }
  /** Callers guarantee `nextOccurrence <= now`, so the stored occurrence is always at least the first one missed. */
  private missedSince(schedule: Schedule, now: number): MissedOccurrences {
    if (schedule.cron === undefined) throw new Error("A one-off schedule has no recurring timetable");
    // One extra so a count above the cap is distinguishable from exactly the cap.
    return missedOccurrences(schedule.cron, schedule.timezone, schedule.nextOccurrence, now, MISSED_COUNT_CAP + 1)!;
  }
  resume(): void { this.executable(); void this.tick().catch(() => {}); }
  async runNow(id: string, options: Pick<SchedulerWriteOptions, "guard"> = {}): Promise<SchedulerRun> {
    this.executable();
    await this.carryOver;
    const schedule = this.find(id);
    options.guard?.({ op: "runNow", patchKeys: [], original: schedule, next: schedule });
    const run = this.guarded(() => this.store.claim(schedule, this.newRun(schedule, this.now(), "manual")));
    if (!run) throw new Error("Schedule was deleted");
    if (isActiveRun(run)) void this.dispatch(schedule, run).catch(() => {});
    return run;
  }
  /** A one-off has one occurrence and no timetable, so it never reaches the missed-interval arithmetic. */
  private reconcileOneOff(schedule: Schedule, runAt: number, now: number): void {
    const onTime = now - runAt < ON_TIME_MS;
    // "skip" writes off an occurrence the desktop missed. One handed back by an overlap or a re-arm fell due while the
    // desktop was open, and it is late only because it waited, so it runs.
    const skipped = !onTime && schedule.catchUp === "skip" && schedule.deferredAt === undefined;
    // However late, "latest" still runs it: with no next occurrence there is no lead rule to apply.
    const run = skipped ? this.missedRecord(schedule, 1, runAt, MISSED_REASONS.unavailable, now)
      : this.newRun(schedule, runAt, onTime ? "cron" : "catch-up");
    const claimed = this.guarded(() => this.store.claim(schedule, run, undefined, undefined, true));
    if (claimed && isActiveRun(claimed)) void this.dispatch(schedule, claimed).catch(() => {});
  }
  private reconcile(schedule: Schedule, now: number): void {
    if (schedule.runAt !== undefined) return this.reconcileOneOff(schedule, schedule.runAt, now);
    const { latest, count, previous, following: next } = this.missedSince(schedule, now);
    const onTime = now - latest < ON_TIME_MS;
    const catchUp = !onTime && schedule.catchUp === "latest" && next - now >= CATCH_UP_MIN_LEAD_MS;
    if (!onTime && !catchUp) {
      const reason = schedule.catchUp === "latest" ? MISSED_REASONS.shortLead : MISSED_REASONS.unavailable;
      this.guarded(() => this.store.claim(schedule, this.missedRecord(schedule, count, latest, reason, now), next));
      return;
    }
    const earlier = count > 1
      ? this.missedRecord(schedule, count - 1, previous!, catchUp ? MISSED_REASONS.superseded : MISSED_REASONS.unavailable, now) : undefined;
    const run = this.guarded(() => this.store.claim(schedule, this.newRun(schedule, latest, catchUp ? "catch-up" : "cron"), next, earlier));
    if (run && isActiveRun(run)) void this.dispatch(schedule, run).catch(() => {});
  }
  async tick(): Promise<void> {
    if (this.ticking || this.closed || this.fault || !this.options.desktopOwned) return;
    this.ticking = true;
    try {
      await this.carryOver;
      const now = this.now();
      for (const schedule of this.schedules()) {
        if (!schedule.enabled || schedule.nextOccurrence > now || schedule.firedRunId !== undefined) continue;
        // One unreconcilable record must not starve the schedules after it. A storage fault latches in guarded()
        // and is checked here so it still stops the sweep.
        try { this.reconcile(schedule, now); }
        catch { if (this.fault || this.closed) return; }
      }
    } finally { this.ticking = false; }
  }
  private finish(id: string, status: RunStatus, reason?: string): void {
    this.guarded(() => this.store.updateRun(id, (r) => isActiveRun(r)
      ? { ...r, status, ...(reason ? { reason } : {}), ...(status === "running" || status === "needs-input" ? {} : { finishedAt: this.now() }) }
      : r));
  }
  private async dispatch(schedule: Schedule, run: SchedulerRun): Promise<void> {
    let reservation: SchedulerRun | undefined;
    let delivered = false;
    try {
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
      // Ahead of the settings check: a run stopped or failed during preparation has spent its occurrence, and must
      // not be handed back to run again.
      if (this.cancelling.has(run.id) || !this.guarded(() => this.store.runs()).some((r) => r.id === run.id && isActiveRun(r))) return;
      const latest = this.guarded(() => this.store.schedules(true)).find((s) => s.id === schedule.id)!;
      // A one-off occurrence is the only one it will ever have, so a time claimed under old settings is given back
      // rather than spent. A manual run was never the one-off's occurrence.
      const oneOff = schedule.runAt !== undefined && run.trigger !== "manual";
      if ((["projectId", "agentId", "mode", "prompt", "approvalPolicy", "workspace", "baseBranch", "chatMode", ...(oneOff ? ["runAt" as const] : [])] as const)
        .some((key) => latest[key] !== schedule[key])) {
        if (oneOff) {
          this.guarded(() => this.store.rearm(run.id, "Execution settings changed during preparation; the one-off will run with the new settings", this.now()));
        } else {
          this.finish(run.id, "skipped", "Execution settings changed during preparation; the new settings apply to the next occurrence");
        }
        return;
      }
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
