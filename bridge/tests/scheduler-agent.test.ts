import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostServer } from "../src/host-server";
import { SchedulerRefusal, type AgentCaller, type SchedulerAgentErrorCode, type SchedulerService, type SchedulerRun } from "../src/scheduler";
import { computeProjectId } from "../src/project-id";
import { ProjectCore } from "../src/project-core";

const DAY = 24 * 60 * 60_000;
let root: string;
let previous: string | undefined;
let host: HostServer;

const git = (cwd: string, ...args: string[]) => {
  const result = Bun.spawnSync(["git", "-c", "user.email=t@example.com", "-c", "user.name=T", ...args], { cwd });
  if (result.exitCode !== 0) throw new Error(`git ${args.join(" ")}: ${result.stderr.toString()}`);
};
function gitProject(name: string): string {
  const folder = join(root, name); mkdirSync(folder);
  git(folder, "init", "-b", "main");
  writeFileSync(join(folder, "a.txt"), "a");
  git(folder, "add", "."); git(folder, "commit", "-m", "init");
  return folder;
}
function plainProject(name: string): string { const folder = join(root, name); mkdirSync(folder); return folder; }
async function open(folder: string): Promise<string> {
  const projectId = computeProjectId(folder);
  await host.open(projectId, folder, "local");
  return projectId;
}
const scheduler = () => (host as unknown as { scheduler: SchedulerService }).scheduler;

beforeEach(async () => {
  root = mkdtempSync(join(tmpdir(), "scheduler-agent-"));
  previous = process.env.ANTGRID_DIR;
  process.env.ANTGRID_DIR = join(root, "state");
  host = new HostServer({ desktopOwned: true, warmCap: 4 });
  spyOn(host, "buildToolsAdvertisement").mockResolvedValue([
    { tool: "claude-code", path: "fixture", label: "Claude", chatCapable: true },
    { tool: "opencode", path: "fixture", label: "opencode", chatCapable: true },
  ]);
  await host.startControlPlane();
});
afterEach(async () => {
  await host.shutdown();
  spyOn(host, "buildToolsAdvertisement").mockRestore();
  if (previous === undefined) delete process.env.ANTGRID_DIR; else process.env.ANTGRID_DIR = previous;
  rmSync(root, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
});

const caller = (projectId: string, over: Partial<AgentCaller> = {}): AgentCaller => ({
  projectId, sessionId: "caller-session", sessionName: "Planner", agentId: "claude-code", mode: "terminal", approvalLevel: "gated", scheduled: false, ...over,
});
const call = (c: AgentCaller, method: Parameters<HostServer["schedulerRequestForAgent"]>[1], params: Record<string, unknown> = {}) =>
  host.schedulerRequestForAgent(c, method, params) as Promise<any>;
const refusalCode = async (promise: Promise<unknown>): Promise<SchedulerAgentErrorCode> => {
  try { await promise; } catch (error) { expect(error).toBeInstanceOf(SchedulerRefusal); return (error as SchedulerRefusal).code; }
  throw new Error("expected a refusal");
};
const create = (c: AgentCaller, over: Record<string, unknown> = {}) =>
  call(c, "create", { name: "Nightly review", prompt: "Review the diff", cron: "0 9 * * *", ...over });
const futureLocal = (days: number) => new Date(Date.now() + days * DAY).toISOString().slice(0, 16);

describe("create defaults", () => {
  test("a git project defaults to a worktree on its current branch, with the machine timezone and safe settings", async () => {
    const projectId = await open(gitProject("repo"));
    const result = await create(caller(projectId));
    expect(result.saved).toBe(true);
    expect(result.schedule).toMatchObject({ projectId, agentId: "claude-code", mode: "terminal", approvalPolicy: "default", workspace: "worktree",
      baseBranch: "main", catchUp: "latest", enabled: true, timezone: scheduler().timezone, authorSessionId: "caller-session", authorSessionName: "Planner",
      authorDeviceId: null });
    expect(result.echo).toMatchObject({ resolvedBaseBranch: "main", machineTimezone: scheduler().timezone });
    expect(result.echo.occurrences).toHaveLength(3);
    expect(result.echo.perDay).toBeUndefined();
  });

  test("a plain folder defaults to the shared workspace and an explicit worktree is refused", async () => {
    const projectId = await open(plainProject("plain"));
    expect((await create(caller(projectId))).schedule).toMatchObject({ workspace: "shared" });
    expect(await refusalCode(create(caller(projectId), { name: "Isolated", workspace: "worktree" }))).toBe("WORKTREE_UNSUPPORTED");
  });

  test("a detached HEAD needs an explicit base branch", async () => {
    const folder = gitProject("detached");
    const projectId = await open(folder);
    git(folder, "checkout", "--detach");
    expect(await refusalCode(create(caller(projectId)))).toBe("INVALID_ARGUMENT");
    expect((await create(caller(projectId), { baseBranch: "main" })).schedule.baseBranch).toBe("main");
  });

  test("the caller's agent and mode are used and never substituted", async () => {
    const projectId = await open(plainProject("agents"));
    expect((await create(caller(projectId, { mode: "chat" }), { name: "Chat" })).schedule).toMatchObject({ agentId: "claude-code", mode: "chat" });
    const custom = caller(projectId, { agentId: undefined });
    expect(await refusalCode(create(custom, { name: "Custom" }))).toBe("AGENT_NOT_SCHEDULABLE");
    await expect(create(custom, { name: "Custom" })).rejects.toThrow("claude-code (terminal, chat)");
    expect((await create(custom, { name: "Named", agentId: "claude-code" })).schedule.agentId).toBe("claude-code");
    expect(await refusalCode(create(caller(projectId), { name: "Missing agent", agentId: "cursor-agent" }))).toBe("AGENT_NOT_SCHEDULABLE");
  });

  test("a sub-hourly cadence echoes how many runs a day it means", async () => {
    const projectId = await open(plainProject("busy"));
    const result = await create(caller(projectId), { cron: "*/5 * * * *" });
    expect(result.echo.perDay).toBeGreaterThanOrEqual(287);
    expect(result.echo.perDay).toBeLessThanOrEqual(289);
  });

  test("a dry run validates and echoes without saving, and a duplicate name is refused naming the existing id", async () => {
    const projectId = await open(plainProject("dry"));
    const dry = await create(caller(projectId), { dryRun: true });
    expect(dry.saved).toBe(false);
    expect(scheduler().schedules()).toHaveLength(0);
    const real = await create(caller(projectId));
    const dup = create(caller(projectId), { name: " nightly REVIEW " });
    expect(await refusalCode(dup)).toBe("SCHEDULE_EXISTS");
    await expect(dup).rejects.toThrow(real.schedule.id);
    expect((await create(caller(projectId), { name: "nightly review", dryRun: true }).catch((e) => e)).code).toBe("SCHEDULE_EXISTS");
  });

  test("a dryRun that is not a boolean is refused rather than read as a real write", async () => {
    const projectId = await open(plainProject("dry-type"));
    for (const dryRun of ["true", 1, "false", null]) {
      expect(await refusalCode(create(caller(projectId), { name: `Preview ${String(dryRun)}`, dryRun }))).toBe("INVALID_ARGUMENT");
    }
    await expect(create(caller(projectId), { dryRun: "true" })).rejects.toThrow("dryRun");
    expect(scheduler().schedules()).toHaveLength(0);
    const made = (await create(caller(projectId))).schedule;
    expect(await refusalCode(call(caller(projectId), "update", { id: made.id, prompt: "Changed", dryRun: "true" }))).toBe("INVALID_ARGUMENT");
    expect(scheduler().schedules()[0]!.prompt).toBe("Review the diff");
  });
});

describe("approval ceiling", () => {
  test("a gated caller cannot create bypass or an agent whose default does not prompt", async () => {
    const projectId = await open(plainProject("ceiling"));
    const gated = caller(projectId);
    expect(await refusalCode(create(gated, { approvalPolicy: "bypass" }))).toBe("APPROVAL_CEILING");
    expect(await refusalCode(create(gated, { agentId: "opencode" }))).toBe("APPROVAL_CEILING");
    expect(await refusalCode(create(caller(projectId, { agentId: undefined }), { agentId: "opencode" }))).toBe("APPROVAL_CEILING");
    const own = await create(gated);
    expect(await refusalCode(call(gated, "update", { id: own.schedule.id, approvalPolicy: "bypass" }))).toBe("APPROVAL_CEILING");
    expect(await refusalCode(call(gated, "update", { id: own.schedule.id, agentId: "opencode" }))).toBe("APPROVAL_CEILING");
    expect((await call(gated, "update", { id: own.schedule.id, prompt: "Updated" })).schedule.prompt).toBe("Updated");
    expect(scheduler().schedules()).toHaveLength(1);
  });

  test("a gated caller may only pause or delete an ungated schedule", async () => {
    const projectId = await open(plainProject("ungated"));
    const ungated = caller(projectId, { approvalLevel: "ungated" });
    const gated = caller(projectId);
    const made = (await create(ungated, { approvalPolicy: "bypass" })).schedule;
    expect(made.approvalPolicy).toBe("bypass");
    expect(await refusalCode(call(gated, "update", { id: made.id, prompt: "Edited" }))).toBe("APPROVAL_CEILING");
    expect(await refusalCode(call(gated, "runNow", { id: made.id }))).toBe("APPROVAL_CEILING");
    expect(await refusalCode(call(gated, "update", { id: made.id, enabled: false, prompt: made.prompt }))).toBe("APPROVAL_CEILING");
    expect(await refusalCode(call(gated, "update", { id: made.id, enabled: false, name: made.name }))).toBe("APPROVAL_CEILING");
    expect((await call(gated, "update", { id: made.id, enabled: false })).schedule.enabled).toBe(false);
    expect(await refusalCode(call(gated, "update", { id: made.id, enabled: true }))).toBe("APPROVAL_CEILING");
    expect((await scheduler().capabilities()).supported).toBe(true);
    expect(await call(gated, "delete", { id: made.id })).toEqual({ deleted: made.id });
  });

  test("an ungated caller may do all of it", async () => {
    const projectId = await open(plainProject("free"));
    const ungated = caller(projectId, { approvalLevel: "ungated" });
    const launch = spyOn(ProjectCore.prototype, "prepareScheduledSession").mockImplementation(async (_spec, bind) => {
      const identity = { sessionId: "scheduled", checkoutId: "main", runtimeGeneration: "generation" };
      await bind(identity);
      return { ...identity, deliverPrompt: async () => {} };
    });
    try {
      const made = (await create(ungated, { agentId: "opencode", approvalPolicy: "bypass" })).schedule;
      expect((await call(ungated, "update", { id: made.id, prompt: "Edited", approvalPolicy: "default" })).schedule.prompt).toBe("Edited");
      expect((await call(ungated, "runNow", { id: made.id })).run.trigger).toBe("manual");
      expect(await call(ungated, "delete", { id: made.id })).toEqual({ deleted: made.id });
    } finally { launch.mockRestore(); }
  });
});

describe("project scope", () => {
  test("results are filtered to the caller's project, include the user's schedules, and never carry the project list", async () => {
    const a = await open(plainProject("alpha"));
    const b = await open(plainProject("beta"));
    const settings = (projectId: string, name: string) => ({ name, projectId, agentId: "claude-code", mode: "chat", prompt: "p",
      approvalPolicy: "default", workspace: "shared", cron: "0 9 * * *", timezone: "UTC", enabled: true, catchUp: "latest" });
    const mine = (await host.schedulerRequest("scheduler.create", { schedule: settings(a, "From the app") }) as any).schedule;
    const theirs = (await host.schedulerRequest("scheduler.create", { schedule: settings(b, "Other project") }) as any).schedule;
    const listed = await call(caller(a), "list");
    expect(listed.schedules.map((s: any) => s.id)).toEqual([mine.id]);
    expect(listed.projects).toBeUndefined();
    expect(listed.header).toMatchObject({ available: true, agents: expect.arrayContaining([{ agentId: "claude-code", modes: ["terminal", "chat"] }]) });
    expect(await refusalCode(call(caller(a), "update", { id: theirs.id, name: "Hijacked" }))).toBe("SCHEDULE_NOT_FOUND");
    expect(await refusalCode(call(caller(a), "runNow", { id: theirs.id }))).toBe("SCHEDULE_NOT_FOUND");
    expect(await refusalCode(call(caller(a), "delete", { id: theirs.id }))).toBe("SCHEDULE_NOT_FOUND");
    expect(await refusalCode(call(caller(a), "runs", { scheduleId: theirs.id }))).toBe("SCHEDULE_NOT_FOUND");
    expect(await refusalCode(call(caller(a), "delete", { id: "unknown" }))).toBe("SCHEDULE_NOT_FOUND");
    const stored = scheduler().store.schedules(true).find((s) => s.id === theirs.id)!;
    expect(stored).toMatchObject({ name: "Other project", projectId: b });
    expect(stored.deletedAt).toBeUndefined();
    expect(scheduler().runs()).toHaveLength(0);
    expect((await call(caller(a), "update", { id: mine.id, name: "Renamed by an agent" })).schedule.projectId).toBe(a);
    expect(await refusalCode(call(caller(a), "update", { id: mine.id, projectId: b }))).toBe("INVALID_ARGUMENT");
    expect(await refusalCode(create(caller(a), { projectId: b }))).toBe("INVALID_ARGUMENT");
  });

  test("the project-wide runs list holds only the caller's project's runs", async () => {
    const a = await open(plainProject("runs-a"));
    const b = await open(plainProject("runs-b"));
    const mine = (await create(caller(a))).schedule;
    const theirs = (await create(caller(b))).schedule;
    const record = (schedule: typeof mine, projectId: string, id: string): SchedulerRun => ({ id, scheduleId: schedule.id, scheduleName: schedule.name,
      projectId, occurrenceAt: Date.now(), trigger: "manual", status: "completed", startedAt: Date.now(), finishedAt: Date.now(), sessionId: `${id}-session` });
    const stored = () => scheduler().schedules();
    scheduler().store.claim(stored().find((s) => s.id === mine.id)!, record(mine, a, "mine"));
    scheduler().store.claim(stored().find((s) => s.id === theirs.id)!, record(theirs, b, "theirs"));
    expect(scheduler().runs()).toHaveLength(2);
    const listed = await call(caller(a), "runs", {});
    expect(listed.runs.map((run: SchedulerRun) => run.id)).toEqual(["mine"]);
    expect(listed.more).toBe(0);
    expect((await call(caller(b), "runs")).runs.map((run: SchedulerRun) => run.id)).toEqual(["theirs"]);
  });

  test("the service guard refuses a schedule an app edit moved to another project in the meantime", async () => {
    const a = await open(plainProject("moving-a"));
    const b = await open(plainProject("moving-b"));
    const made = (await create(caller(a))).schedule;
    const pending = call(caller(a), "update", { id: made.id, prompt: "Edited" });
    // The agent request awaits capability probing before it re-reads the record; the app wins that window.
    scheduler().store.saveSchedule({ ...scheduler().schedules()[0]!, projectId: b });
    expect(await refusalCode(pending)).toBe("SCHEDULE_NOT_FOUND");
    expect(scheduler().schedules()[0]).toMatchObject({ projectId: b, prompt: "Review the diff" });
    expect((await scheduler().capabilities()).supported).toBe(true);
  });
});

describe("sessions the scheduler launched", () => {
  test("are read-only, by marker or by a run record, and may still read", async () => {
    const projectId = await open(plainProject("scheduled"));
    const made = (await create(caller(projectId))).schedule;
    const marked = caller(projectId, { scheduled: true });
    for (const [method, params] of [["create", { name: "x", prompt: "p", cron: "0 9 * * *" }], ["update", { id: made.id, prompt: "x" }],
      ["delete", { id: made.id }], ["runNow", { id: made.id }]] as const) {
      expect(await refusalCode(call(marked, method, params))).toBe("SCHEDULED_SESSION_READ_ONLY");
    }
    expect((await call(marked, "list")).schedules).toHaveLength(1);
    expect((await call(marked, "runs")).runs).toEqual([]);
    const run: SchedulerRun = { id: "run-1", scheduleId: made.id, scheduleName: made.name, projectId, occurrenceAt: Date.now(), trigger: "manual",
      status: "running", startedAt: Date.now(), sessionId: "launched-session", runtimeGeneration: "generation", checkoutId: "checkout" };
    scheduler().store.claim(scheduler().schedules()[0]!, run);
    const unmarked = caller(projectId, { sessionId: "launched-session" });
    expect(await refusalCode(call(unmarked, "delete", { id: made.id }))).toBe("SCHEDULED_SESSION_READ_ONLY");
    expect(scheduler().schedules()).toHaveLength(1);
    expect((await call(unmarked, "list")).schedules).toHaveLength(1);
  });
});

describe("errors and results", () => {
  test("validation failures name the field and keep the shipped cron code", async () => {
    const projectId = await open(gitProject("errors"));
    const c = caller(projectId);
    expect(await refusalCode(call(c, "create", { name: "No prompt", cron: "0 9 * * *" }))).toBe("INVALID_ARGUMENT");
    await expect(call(c, "create", { name: "No prompt", cron: "0 9 * * *" })).rejects.toThrow("prompt");
    expect(await refusalCode(create(c, { surprise: true }))).toBe("INVALID_ARGUMENT");
    expect(await refusalCode(create(c, { cron: undefined }))).toBe("INVALID_ARGUMENT");
    expect(await refusalCode(create(c, { runAt: futureLocal(2) }))).toBe("INVALID_ARGUMENT");
    expect(await refusalCode(create(c, { cron: "@daily" }))).toBe("SCHEDULER_INVALID_CRON");
    expect(await refusalCode(create(c, { timezone: "Moon/Base" }))).toBe("SCHEDULER_INVALID_CRON");
    const made = (await create(c)).schedule;
    expect(await refusalCode(call(c, "update", { id: made.id, cron: "0 9 * * *", runAt: futureLocal(2) }))).toBe("INVALID_ARGUMENT");
    scheduler().store.saveSchedule({ ...scheduler().schedules()[0]!, workspaceCreated: true });
    expect(await refusalCode(call(c, "update", { id: made.id, workspace: "shared" }))).toBe("WORKSPACE_LOCKED");
    // The app path keeps its shipped code for the same failure.
    await expect(host.schedulerRequest("scheduler.preview", { cron: "@daily", timezone: "UTC" })).rejects.toMatchObject({ code: "SCHEDULER_INVALID_CRON" });
  });

  test("without a desktop-owned scheduler a list reports unavailable and every other verb is refused", async () => {
    const headless = new HostServer({ desktopOwned: false, warmCap: 1 });
    try {
      const listed = await headless.schedulerRequestForAgent(caller("project"), "list", {}) as any;
      expect(listed).toMatchObject({ header: { available: false }, schedules: [] });
      expect(listed.header.reason).toBeTruthy();
      for (const [method, params] of [["create", { name: "x", prompt: "p", cron: "0 9 * * *" }], ["update", { id: "x" }], ["delete", { id: "x" }],
        ["runNow", { id: "x" }], ["runs", {}]] as const) {
        expect(await refusalCode(headless.schedulerRequestForAgent(caller("project"), method, params))).toBe("SCHEDULER_UNAVAILABLE");
      }
    } finally { await headless.shutdown(); }
  });

  test("runs are newest first, capped at twenty with the remainder counted, and never carry the hook run id or checkout", async () => {
    const projectId = await open(plainProject("history"));
    const made = (await create(caller(projectId))).schedule;
    const base = Date.now();
    for (let i = 0; i < 23; i++) {
      scheduler().store.claim(scheduler().schedules()[0]!, { id: `run-${i}`, scheduleId: made.id, scheduleName: made.name, projectId, occurrenceAt: base + i,
        trigger: "manual", status: "completed", startedAt: base + i, finishedAt: base + i, sessionId: `s-${i}`, runtimeGeneration: "secret", checkoutId: "checkout-1" });
    }
    const result = await call(caller(projectId), "runs", { scheduleId: made.id });
    expect(result.runs).toHaveLength(20);
    expect(result.more).toBe(3);
    expect(result.runs[0].id).toBe("run-22");
    for (const run of result.runs) expect(run).not.toHaveProperty("runtimeGeneration"), expect(run).not.toHaveProperty("checkoutId");
    const active: SchedulerRun = { id: "live", scheduleId: made.id, scheduleName: made.name, projectId, occurrenceAt: base + 99, trigger: "manual",
      status: "needs-input", startedAt: base + 99, sessionId: "s-live", runtimeGeneration: "secret", checkoutId: "checkout-1" };
    scheduler().store.claim(scheduler().schedules()[0]!, active);
    const row = (await call(caller(projectId), "list")).schedules[0];
    expect(row.activeRun).toMatchObject({ id: "live", status: "needs-input" });
    expect(row.activeRun).not.toHaveProperty("runtimeGeneration");
    expect(row.activeRun).not.toHaveProperty("checkoutId");
  });
});

describe("one-off schedules", () => {
  test("an agent creates and edits a one-off by local time, resolved in the schedule's own timezone", async () => {
    const projectId = await open(plainProject("oneoff"));
    const c = caller(projectId);
    const made = (await create(c, { cron: undefined, runAt: futureLocal(3), timezone: "Asia/Kolkata" })).schedule;
    expect(made.cron).toBeUndefined();
    expect(made.runAt).toBe(Date.parse(`${futureLocal(3)}:00Z`) - 5.5 * 3_600_000);
    expect(made.nextOccurrence).toBe(made.runAt);
    const moved = (await call(c, "update", { id: made.id, runAt: futureLocal(4) })).schedule;
    expect(moved.runAt).toBe(Date.parse(`${futureLocal(4)}:00Z`) - 5.5 * 3_600_000);
    const tzOnly = (await call(c, "update", { id: made.id, timezone: "UTC" })).schedule;
    expect(tzOnly.runAt).toBe(moved.runAt);
    const offset = (await call(c, "update", { id: made.id, runAt: "2099-01-01T00:00:00+02:00" })).schedule;
    expect(new Date(offset.runAt).toISOString()).toBe("2098-12-31T22:00:00.000Z");
    expect(await refusalCode(call(c, "update", { id: made.id, runAt: "2026-03-08T02:30", timezone: "America/New_York" }))).toBe("INVALID_RUN_AT");
    expect(await refusalCode(call(c, "update", { id: made.id, runAt: 1000 }))).toBe("INVALID_RUN_AT");
    expect(await refusalCode(create(c, { name: "Too soon", cron: undefined, runAt: Date.now() + 5_000 }))).toBe("INVALID_RUN_AT");
    const echo = (await call(c, "update", { id: made.id, name: "Echo", dryRun: true }));
    expect(echo.saved).toBe(false);
    expect(echo.echo.occurrences).toEqual([offset.runAt]);
  });

  test("the agent list carries recurring and one-off records, and a finished one-off names its run", async () => {
    const projectId = await open(plainProject("mixed"));
    const c = caller(projectId);
    await create(c);
    const once = (await create(c, { name: "Once", cron: undefined, runAt: futureLocal(2) })).schedule;
    const run: SchedulerRun = { id: "fired", scheduleId: once.id, scheduleName: once.name, projectId, occurrenceAt: once.runAt, trigger: "cron",
      status: "completed", startedAt: Date.now(), finishedAt: Date.now() };
    scheduler().store.claim(scheduler().schedules().find((s) => s.id === once.id)!, run, undefined, undefined, true);
    const rows = (await call(c, "list")).schedules;
    expect(rows).toHaveLength(2);
    expect(rows.find((r: any) => r.id === once.id)).toMatchObject({ firedRunId: "fired", firedRun: { id: "fired", status: "completed" } });
  });

  test("the app list keeps schedules cron-only and puts one-offs in their own key", async () => {
    const projectId = await open(plainProject("app-list"));
    const settings = { name: "Weekly", projectId, agentId: "claude-code", mode: "chat", prompt: "p", approvalPolicy: "default", workspace: "shared",
      cron: "0 9 * * 1", timezone: "UTC", enabled: true, catchUp: "latest" };
    await host.schedulerRequest("scheduler.create", { schedule: settings });
    const { cron: _cron, ...base } = settings;
    const created = (await host.schedulerRequest("scheduler.create", { schedule: { ...base, name: "Once", runAt: futureLocal(2) } }) as any).schedule;
    expect(created.runAt).toBe(Date.parse(`${futureLocal(2)}:00Z`));
    const listed = await host.schedulerRequest("scheduler.list") as any;
    expect(listed.schedules.map((s: any) => s.name)).toEqual(["Weekly"]);
    expect(listed.oneOffSchedules.map((s: any) => s.name)).toEqual(["Once"]);
    expect(listed.schedules.every((s: any) => typeof s.cron === "string")).toBe(true);
    const patched = (await host.schedulerRequest("scheduler.update", { id: created.id, patch: { runAt: futureLocal(5) } }) as any).schedule;
    expect(patched.runAt).toBe(Date.parse(`${futureLocal(5)}:00Z`));
    expect((await host.schedulerRequest("scheduler.capabilities") as any).supportsOneOff).toBe(true);
  });

  test("preview accepts a runAt shape, refuses a DST gap, and refuses mixing the shapes", async () => {
    await open(plainProject("preview"));
    const at = Date.parse("2099-06-01T12:00:00Z");
    expect(await host.schedulerRequest("scheduler.preview", { runAt: at, timezone: "UTC" })).toEqual({ occurrences: [at] });
    expect(await host.schedulerRequest("scheduler.preview", { runAt: "2099-06-01T12:00", timezone: "Asia/Kolkata" }))
      .toEqual({ occurrences: [Date.parse("2099-06-01T06:30:00Z")] });
    await expect(host.schedulerRequest("scheduler.preview", { runAt: "2026-03-08T02:30", timezone: "America/New_York" }))
      .rejects.toMatchObject({ code: "INVALID_RUN_AT" });
    await expect(host.schedulerRequest("scheduler.preview", { runAt: at, cron: "0 9 * * *", timezone: "UTC" })).rejects.toThrow();
  });
});

describe("chat permission mode", () => {
  const chatCaller = (projectId: string, over: Partial<AgentCaller> = {}) => caller(projectId, { mode: "chat", ...over });
  let counter = 0;
  const chat = (c: AgentCaller, over: Record<string, unknown> = {}) => create(c, { name: `Chat ${++counter}`, mode: "chat", ...over });

  test("a gated caller is refused a mode that approves tools without asking, on create and update", async () => {
    const projectId = await open(plainProject("modes"));
    const gated = chatCaller(projectId);
    for (const chatMode of ["auto", "acceptEdits"]) {
      expect(await refusalCode(chat(gated, { chatMode }))).toBe("APPROVAL_CEILING");
    }
    const own = (await chat(gated)).schedule;
    for (const chatMode of ["auto", "acceptEdits"]) {
      expect(await refusalCode(call(gated, "update", { id: own.id, chatMode }))).toBe("APPROVAL_CEILING");
    }
    expect(scheduler().schedules()).toHaveLength(1);
  });

  test("a gated caller may pick the modes that still prompt", async () => {
    const projectId = await open(plainProject("gated-modes"));
    const gated = chatCaller(projectId);
    expect((await chat(gated, { chatMode: "default" })).schedule.chatMode).toBe("default");
    const plan = (await chat(gated, { chatMode: "plan" })).schedule;
    expect(plan.chatMode).toBe("plan");
    expect((await call(gated, "update", { id: plan.id, chatMode: "default" })).schedule.chatMode).toBe("default");
    expect((await call(gated, "update", { id: plan.id, chatMode: null })).schedule.chatMode).toBeUndefined();
  });

  test("a mode the registry does not list counts as ungated", async () => {
    const projectId = await open(plainProject("unknown-mode"));
    expect(await refusalCode(chat(chatCaller(projectId), { chatMode: "build" }))).toBe("APPROVAL_CEILING");
    expect((await chat(chatCaller(projectId, { approvalLevel: "ungated" }), { chatMode: "build" })).schedule.chatMode).toBe("build");
  });

  test("against a schedule pinned to an ungated mode a gated caller may only pause or delete", async () => {
    const projectId = await open(plainProject("pinned"));
    const made = (await chat(chatCaller(projectId, { approvalLevel: "ungated" }), { chatMode: "auto" })).schedule;
    const gated = chatCaller(projectId);
    expect(await refusalCode(call(gated, "update", { id: made.id, prompt: "Edited" }))).toBe("APPROVAL_CEILING");
    expect(await refusalCode(call(gated, "update", { id: made.id, chatMode: "default" }))).toBe("APPROVAL_CEILING");
    expect(await refusalCode(call(gated, "runNow", { id: made.id }))).toBe("APPROVAL_CEILING");
    expect((await call(gated, "update", { id: made.id, enabled: false })).schedule.enabled).toBe(false);
    expect(await call(gated, "delete", { id: made.id })).toEqual({ deleted: made.id });
  });

  test("a schedule still awaiting its carry-over counts as ungated", async () => {
    // The startup pass may yet write an ungated mode onto it, so an edit judged before then must fail closed.
    const projectId = await open(plainProject("awaiting-carry-over"));
    const gated = chatCaller(projectId);
    const made = (await chat(gated)).schedule;
    scheduler().store.saveSchedule({ ...scheduler().schedules().find((s) => s.id === made.id)!, chatModeCarryOver: true });
    expect(await refusalCode(call(gated, "update", { id: made.id, prompt: "Edited" }))).toBe("APPROVAL_CEILING");
    expect(scheduler().schedules().find((s) => s.id === made.id)!.prompt).toBe(made.prompt);
    expect((await call(gated, "update", { id: made.id, enabled: false })).schedule.enabled).toBe(false);
  });

  test("a terminal schedule drops the mode, so it never counts as ungated", async () => {
    const projectId = await open(plainProject("terminal-mode"));
    const made = (await create(caller(projectId), { chatMode: "auto" })).schedule;
    expect(made.chatMode).toBeUndefined();
  });

  test("the carry-over marker never leaves the bridge", async () => {
    const projectId = await open(plainProject("marker"));
    const made = (await chat(chatCaller(projectId))).schedule;
    scheduler().store.saveSchedule({ ...scheduler().schedules()[0]!, chatModeCarryOver: true });
    expect(scheduler().schedules()[0]!.chatModeCarryOver).toBe(true);
    expect(JSON.stringify(await call(chatCaller(projectId), "list"))).not.toContain("chatModeCarryOver");
    expect(JSON.stringify(await host.schedulerRequest("scheduler.list"))).not.toContain("chatModeCarryOver");
    const edited = await host.schedulerRequest("scheduler.update", { id: made.id, patch: { prompt: "Edited" } });
    expect(JSON.stringify(edited)).not.toContain("chatModeCarryOver");
  });

  test("capabilities list claude-code's four modes", async () => {
    const capabilities = await host.schedulerRequest("scheduler.capabilities") as { chatModes?: Record<string, { id: string }[]> };
    expect(capabilities.chatModes?.["claude-code"]?.map((m) => m.id)).toEqual(["default", "auto", "acceptEdits", "plan"]);
    expect(capabilities.chatModes?.opencode).toBeUndefined();
  });
});
