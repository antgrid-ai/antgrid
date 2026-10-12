import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SchedulePatchSchema, ScheduleInputSchema, SchedulerRefusal, SchedulerService, resolveRunAt, schedulerErrorCode,
  type SchedulerOptions, type ScheduleInput } from "../src/scheduler";

const dirs: string[] = [];
const services: SchedulerService[] = [];
const fresh = () => { const dir = mkdtempSync(join(tmpdir(), "antgrid-oneoff-")); dirs.push(dir); return dir; };
afterEach(() => {
  for (const s of services.splice(0)) s.close();
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});
const START = Date.parse("2026-01-01T00:00:00Z");
const MIN = 60_000;
const DAY = 24 * 60 * MIN;
const recurring: ScheduleInput = { name: "Review", projectId: "project", agentId: "claude", mode: "terminal", prompt: "Review code",
  approvalPolicy: "default", workspace: "shared", cron: "0 9 * * *", timezone: "UTC", enabled: true, catchUp: "latest" };
const { cron: _cron, ...oneOffBase } = recurring;
const once = (runAt: number, extra: Partial<ScheduleInput> = {}): ScheduleInput => ({ ...oneOffBase, name: "Once", runAt, ...extra });
async function settle() { for (let i = 0; i < 12; i++) await Promise.resolve(); }

function fixture(overrides: Partial<SchedulerOptions> = {}, abDir = fresh()) {
  let time = START;
  let sequence = 0;
  const prompts: string[] = [];
  const options: SchedulerOptions = {
    abDir, desktopOwned: true, now: () => time, timezone: "UTC", supportedAgents: () => [{ agentId: "claude", modes: ["terminal", "chat"] }],
    stop: async () => {},
    prepare: async (schedule, _run, bind) => {
      prompts.push(schedule.prompt);
      const identity = { sessionId: `session-${++sequence}`, runtimeGeneration: `generation-${sequence}`, checkoutId: "checkout" };
      bind(identity);
      return { ...identity, deliverPrompt: async () => {} };
    }, ...overrides,
  };
  const service = new SchedulerService(options); services.push(service);
  const observe = (runId: string, status: "running" | "needs-input" | "completed" | "failed") => {
    const run = service.runs().find((r) => r.id === runId)!;
    service.observe({ projectId: run.projectId, sessionId: run.sessionId!, runtimeGeneration: run.runtimeGeneration!, status });
  };
  return { service, prompts, abDir, observe, setTime: (next: number) => { time = next; }, advance: (ms: number) => { time += ms; }, now: () => time };
}
const refusal = async (promise: Promise<unknown>) => {
  try { await promise; } catch (error) { expect(error).toBeInstanceOf(SchedulerRefusal); return (error as SchedulerRefusal).code; }
  throw new Error("expected a refusal");
};

describe("one-off model", () => {
  test("a schedule has exactly one of cron and runAt", async () => {
    expect(ScheduleInputSchema.safeParse({ ...recurring, runAt: START + DAY }).success).toBe(false);
    expect(ScheduleInputSchema.safeParse({ ...oneOffBase }).success).toBe(false);
    expect(ScheduleInputSchema.safeParse(once(START + DAY)).success).toBe(true);
    expect(SchedulePatchSchema.safeParse({ cron: "0 9 * * *", runAt: START + DAY }).success).toBe(false);
    const f = fixture();
    await expect(f.service.create({ ...recurring, runAt: START + DAY })).rejects.toThrow();
  });

  test("the floor applies on create, on a changed runAt and on re-enable, never to an unchanged runAt", async () => {
    const f = fixture();
    expect(await refusal(f.service.create(once(START + 30_000)))).toBe("INVALID_RUN_AT");
    const schedule = await f.service.create(once(START + 2 * MIN));
    expect(await refusal(f.service.update(schedule.id, { runAt: START + 30_000 }))).toBe("INVALID_RUN_AT");
    f.advance(100_000);
    // 20s to go: far inside the floor, but the time itself is unchanged.
    expect((await f.service.update(schedule.id, { name: "Renamed", prompt: "Changed" })).name).toBe("Renamed");
    await f.service.update(schedule.id, { enabled: false });
    f.advance(10 * MIN);
    expect(await refusal(f.service.update(schedule.id, { enabled: true }))).toBe("INVALID_RUN_AT");
    expect(f.service.runs()).toHaveLength(0);
    const retimed = await f.service.update(schedule.id, { runAt: f.now() + 5 * MIN, enabled: true });
    expect(retimed).toMatchObject({ enabled: true, nextOccurrence: f.now() + 5 * MIN });
  });

  test("a patch switches the timetable kind and keeps nextOccurrence in step", async () => {
    const f = fixture();
    const schedule = await f.service.create(recurring);
    const toOnce = await f.service.update(schedule.id, { runAt: START + DAY });
    expect(toOnce.cron).toBeUndefined();
    expect(toOnce).toMatchObject({ runAt: START + DAY, nextOccurrence: START + DAY });
    const back = await f.service.update(schedule.id, { cron: "30 9 * * *" });
    expect(back.runAt).toBeUndefined();
    expect(back.nextOccurrence).toBe(START + 9 * 60 * MIN + 30 * MIN);
    await expect(f.service.update(schedule.id, { cron: "0 9 * * *", runAt: START + DAY } as never)).rejects.toThrow();
  });

  test("a timezone-only patch keeps the instant", async () => {
    const f = fixture();
    const schedule = await f.service.create(once(START + DAY));
    const moved = await f.service.update(schedule.id, { timezone: "Asia/Kolkata" });
    expect(moved).toMatchObject({ runAt: START + DAY, nextOccurrence: START + DAY, timezone: "Asia/Kolkata" });
  });

  test("a one-off is never shown a cron function, and preview of its time is its instant", async () => {
    const f = fixture();
    const schedule = await f.service.create(once(START + DAY));
    expect(schedule.nextOccurrence).toBe(START + DAY);
    expect(schedule.cron).toBeUndefined();
    expect((await f.service.capabilities()).supportsOneOff).toBe(true);
  });
});

describe("one-off lifecycle", () => {
  test("fires on time as cron, and the fired marker is committed with the claim so a restart cannot fire it twice", async () => {
    const dir = fresh();
    const f = fixture({}, dir);
    const schedule = await f.service.create(once(START + 5 * MIN));
    f.setTime(START + 5 * MIN);
    await f.service.tick(); await settle();
    const run = f.service.runs()[0]!;
    expect(run).toMatchObject({ trigger: "cron", status: "running", occurrenceAt: START + 5 * MIN });
    expect(f.service.schedules()[0]).toMatchObject({ firedRunId: run.id, firedAt: run.startedAt, enabled: true });
    await f.service.tick(); await settle();
    expect(f.service.runs()).toHaveLength(1);
    f.service.close();
    const again = fixture({}, dir);
    again.setTime(START + 2 * DAY);
    await again.service.tick(); await settle();
    expect(again.service.runs().filter((r) => r.scheduleId === schedule.id).map((r) => r.trigger)).toEqual(["cron"]);
  });

  test("late with catch-up latest runs however late; late with skip is recorded as missed and finished", async () => {
    const f = fixture();
    const latest = await f.service.create(once(START + 5 * MIN));
    const skip = await f.service.create(once(START + 5 * MIN, { name: "Skipper", catchUp: "skip" }));
    f.setTime(START + 400 * DAY);
    await f.service.tick(); await settle();
    const runs = f.service.runs();
    expect(runs.find((r) => r.scheduleId === latest.id)).toMatchObject({ trigger: "catch-up", status: "running", occurrenceAt: START + 5 * MIN });
    const missed = runs.find((r) => r.scheduleId === skip.id)!;
    expect(missed).toMatchObject({ trigger: "missed", status: "skipped" });
    expect(f.service.schedules().find((s) => s.id === skip.id)).toMatchObject({ firedRunId: missed.id });
    expect(runs).toHaveLength(2);
  });

  test("an active manual run across runAt defers the one-off without consuming it, and it runs afterwards", async () => {
    const f = fixture();
    const schedule = await f.service.create(once(START + 5 * MIN));
    const manual = await f.service.runNow(schedule.id); await settle();
    f.observe(manual.id, "needs-input");
    f.setTime(START + 6 * MIN);
    await f.service.tick(); await settle();
    expect(f.service.runs()).toHaveLength(1);
    expect(f.service.schedules()[0]!.firedRunId).toBeUndefined();
    f.observe(manual.id, "completed");
    f.advance(MIN);
    await f.service.tick(); await settle();
    const runs = f.service.runs();
    expect(runs).toHaveLength(2);
    expect(runs[0]).toMatchObject({ trigger: "catch-up", status: "running" });
    expect(f.service.schedules()[0]!.firedRunId).toBe(runs[0]!.id);
  });

  test("a settings edit during preparation gives the one-off back and it then runs with the new prompt", async () => {
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    let first = true;
    const f = fixture({
      prepare: async (schedule, _run, bind) => {
        const identity = { sessionId: `s-${schedule.prompt}`, runtimeGeneration: `g-${schedule.prompt}` };
        bind(identity);
        if (first) { first = false; await gate; }
        deliveries.push(schedule.prompt);
        return { ...identity, deliverPrompt: async () => {} };
      },
    });
    const deliveries: string[] = [];
    const schedule = await f.service.create(once(START + 5 * MIN));
    f.setTime(START + 5 * MIN);
    await f.service.tick(); await settle();
    expect(f.service.runs()[0]!.status).toBe("preparing");
    await f.service.update(schedule.id, { prompt: "Fresh prompt" });
    release(); await settle();
    expect(f.service.runs()[0]).toMatchObject({ status: "skipped", reason: expect.stringContaining("will run with the new settings") });
    expect(f.service.schedules()[0]!.firedRunId).toBeUndefined();
    f.advance(2 * MIN);
    await f.service.tick(); await settle();
    const runs = f.service.runs();
    expect(runs).toHaveLength(2);
    expect(runs[0]).toMatchObject({ trigger: "catch-up", status: "running" });
    expect(f.service.schedules()[0]!.firedRunId).toBe(runs[0]!.id);
    expect(deliveries.at(-1)).toBe("Fresh prompt");
  });

  test("with catch-up skip, a one-off deferred by an overlap still runs once the overlap ends, however late", async () => {
    const f = fixture();
    const schedule = await f.service.create(once(START + 5 * MIN, { catchUp: "skip" }));
    const manual = await f.service.runNow(schedule.id); await settle();
    f.observe(manual.id, "needs-input");
    f.setTime(START + 6 * MIN);
    await f.service.tick(); await settle();
    expect(f.service.runs()).toHaveLength(1);
    expect(f.service.schedules()[0]!.firedRunId).toBeUndefined();
    f.observe(manual.id, "completed");
    f.setTime(START + 35 * MIN);
    await f.service.tick(); await settle();
    const runs = f.service.runs();
    expect(runs).toHaveLength(2);
    expect(runs[0]).toMatchObject({ trigger: "catch-up", status: "running", occurrenceAt: START + 5 * MIN });
    expect(f.service.schedules()[0]).toMatchObject({ firedRunId: runs[0]!.id });
    expect(f.service.schedules()[0]!.deferredAt).toBeUndefined();
  });

  test("with catch-up skip, a one-off re-armed after a slow preparation runs with the new settings", async () => {
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    let first = true;
    const deliveries: string[] = [];
    const f = fixture({
      prepare: async (schedule, _run, bind) => {
        const identity = { sessionId: `s-${schedule.prompt}`, runtimeGeneration: `g-${schedule.prompt}` };
        bind(identity);
        if (first) { first = false; await gate; }
        return { ...identity, deliverPrompt: async () => { deliveries.push(schedule.prompt); } };
      },
    });
    const schedule = await f.service.create(once(START + 5 * MIN, { catchUp: "skip", prompt: "A" }));
    f.setTime(START + 5 * MIN);
    await f.service.tick(); await settle();
    await f.service.update(schedule.id, { prompt: "B" });
    // Preparation (a worktree, a setup script) outlasts the on-time window before the edit is noticed.
    f.setTime(START + 10 * MIN);
    release(); await settle();
    expect(f.service.runs()[0]).toMatchObject({ status: "skipped", reason: expect.stringContaining("will run with the new settings") });
    f.advance(MIN);
    await f.service.tick(); await settle();
    const runs = f.service.runs();
    expect(runs).toHaveLength(2);
    expect(runs[0]).toMatchObject({ trigger: "catch-up", status: "running" });
    expect(f.service.schedules()[0]!.firedRunId).toBe(runs[0]!.id);
    expect(deliveries).toEqual(["B"]);
  });

  test("a one-off stopped during preparation stays spent even when its settings changed meanwhile", async () => {
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const f = fixture({
      prepare: async (schedule, _run, bind) => {
        const identity = { sessionId: `s-${schedule.prompt}`, runtimeGeneration: `g-${schedule.prompt}` };
        bind(identity);
        await gate;
        return { ...identity, deliverPrompt: async () => {} };
      },
    });
    const schedule = await f.service.create(once(START + 5 * MIN));
    f.setTime(START + 5 * MIN);
    await f.service.tick(); await settle();
    const run = f.service.runs()[0]!;
    await f.service.update(schedule.id, { prompt: "B" });
    await f.service.stop(run.id);
    release(); await settle();
    expect(f.service.runs()[0]).toMatchObject({ id: run.id, status: "interrupted", reason: "Stopped by user" });
    expect(f.service.schedules()[0]!.firedRunId).toBe(run.id);
    f.advance(MIN);
    await f.service.tick(); await settle();
    expect(f.service.runs()).toHaveLength(1);
  });

  test("run now never sets fired and never consumes the one-off", async () => {
    const f = fixture();
    const schedule = await f.service.create(once(START + DAY));
    const run = await f.service.runNow(schedule.id); await settle();
    expect(run.trigger).toBe("manual");
    f.observe(run.id, "completed");
    expect(f.service.schedules()[0]!.firedRunId).toBeUndefined();
    f.setTime(START + DAY);
    await f.service.tick(); await settle();
    expect(f.service.runs()[0]).toMatchObject({ trigger: "cron" });
  });

  test("setting a new time on a finished one-off clears fired", async () => {
    const f = fixture();
    const schedule = await f.service.create(once(START + 5 * MIN));
    f.setTime(START + 5 * MIN);
    await f.service.tick(); await settle();
    f.observe(f.service.runs()[0]!.id, "completed");
    expect(f.service.schedules()[0]!.firedRunId).toBeDefined();
    const retimed = await f.service.update(schedule.id, { runAt: f.now() + 10 * MIN });
    expect(retimed.firedRunId).toBeUndefined();
    expect(retimed.firedAt).toBeUndefined();
    f.advance(10 * MIN);
    await f.service.tick(); await settle();
    expect(f.service.runs()).toHaveLength(2);
  });

  test("a paused one-off whose time passes records nothing", async () => {
    const f = fixture();
    const schedule = await f.service.create(once(START + 5 * MIN));
    await f.service.update(schedule.id, { enabled: false });
    f.setTime(START + DAY);
    await f.service.tick(); await settle();
    expect(f.service.runs()).toHaveLength(0);
    expect(f.service.schedules()[0]!.firedRunId).toBeUndefined();
  });

  test("a schedule that throws in reconcile does not stop the ones after it", async () => {
    const f = fixture();
    // Created first, so the tick reaches it before the good one.
    const bad = await f.service.create(recurring);
    const good = await f.service.create(once(START + 5 * MIN, { name: "Good" }));
    f.service.store.saveSchedule({ ...bad, name: "Bad", cron: "bogus", nextOccurrence: START });
    expect(f.service.schedules().map((s) => s.name)).toEqual(["Bad", "Good"]);
    f.setTime(START + 5 * MIN);
    await f.service.tick(); await settle();
    expect(f.service.runs().map((r) => r.scheduleId)).toEqual([good.id]);
    expect((await f.service.capabilities()).supported).toBe(true);
  });
});

describe("service guard, duplicates and dry runs", () => {
  const deny = () => { throw new SchedulerRefusal("APPROVAL_CEILING", "no"); };

  test("a refused run-now and a refused update leave the scheduler healthy and write nothing", async () => {
    const f = fixture();
    const schedule = await f.service.create(recurring);
    expect(await refusal(f.service.runNow(schedule.id, { guard: deny }))).toBe("APPROVAL_CEILING");
    expect(await refusal(f.service.update(schedule.id, { prompt: "x" }, { guard: deny }))).toBe("APPROVAL_CEILING");
    expect((await f.service.capabilities()).supported).toBe(true);
    expect(f.service.runs()).toHaveLength(0);
    expect(f.service.schedules()[0]!.prompt).toBe("Review code");
  });

  test("a refused re-enable writes no missed run, and a dry-run re-enable writes nothing either", async () => {
    const f = fixture();
    const schedule = await f.service.create(recurring);
    await f.service.update(schedule.id, { enabled: false });
    f.advance(10 * DAY);
    expect(await refusal(f.service.update(schedule.id, { enabled: true }, { guard: deny }))).toBe("APPROVAL_CEILING");
    expect(f.service.runs()).toHaveLength(0);
    const preview = await f.service.update(schedule.id, { enabled: true }, { dryRun: true });
    expect(preview.enabled).toBe(true);
    expect(preview.nextOccurrence).toBeGreaterThan(f.now());
    expect(f.service.runs()).toHaveLength(0);
    expect(f.service.schedules()[0]).toMatchObject({ enabled: false });
    await f.service.update(schedule.id, { enabled: true });
    expect(f.service.runs()).toHaveLength(1);
  });

  test("the guard sees the keys the patch named, not the merged record", async () => {
    const f = fixture();
    const schedule = await f.service.create(recurring);
    const seen: string[][] = [];
    await f.service.update(schedule.id, { enabled: false, prompt: schedule.prompt }, { guard: ({ patchKeys }) => { seen.push([...patchKeys].sort()); } });
    expect(seen).toEqual([["enabled", "prompt"]]);
  });

  test("duplicate names are refused per project, trimmed and case-insensitively, ignoring deleted schedules", async () => {
    const f = fixture();
    const first = await f.service.create(recurring, { rejectDuplicateName: true });
    const code = await refusal(f.service.create({ ...recurring, name: "  review " }, { rejectDuplicateName: true }));
    expect(code).toBe("SCHEDULE_EXISTS");
    await f.service.create({ ...recurring, name: "review", projectId: "other" }, { rejectDuplicateName: true });
    const second = await f.service.create({ ...recurring, name: "Second" }, { rejectDuplicateName: true });
    expect(await refusal(f.service.update(second.id, { name: "REVIEW" }, { rejectDuplicateName: true }))).toBe("SCHEDULE_EXISTS");
    expect((await f.service.update(second.id, { name: "Second" }, { rejectDuplicateName: true })).name).toBe("Second");
    await f.service.delete(first.id);
    await f.service.create({ ...recurring, name: "Review" }, { rejectDuplicateName: true });
    // The app path passes no flag, so its behaviour is unchanged.
    await f.service.create({ ...recurring, name: "Second" });
  });

  test("a dry-run create writes nothing", async () => {
    const f = fixture();
    const preview = await f.service.create(recurring, { dryRun: true });
    expect(preview.id).toBeTruthy();
    expect(f.service.schedules()).toHaveLength(0);
  });

  test("authorship: agent creates record the session, an agent edit keeps the device author, an app edit clears the edit marks", async () => {
    const f = fixture();
    const agent = { kind: "agent", sessionId: "sess-1", sessionName: "Planner" } as const;
    const created = await f.service.create(recurring, { author: agent });
    expect(created).toMatchObject({ authorSessionId: "sess-1", authorSessionName: "Planner", authorDeviceId: null });
    const device = await f.service.create({ ...recurring, name: "From phone" }, { author: { kind: "device", deviceId: "phone" } });
    expect(device.authorSessionId).toBeUndefined();
    const edited = await f.service.update(device.id, { prompt: "Agent wrote this" }, { author: { kind: "agent", sessionId: "sess-2", sessionName: "Helper" } });
    expect(edited).toMatchObject({ authorDeviceId: "phone", editedBySessionName: "Helper", editedAt: f.now() });
    const appEdit = await f.service.update(device.id, { name: "Renamed in app" });
    expect(appEdit.editedBySessionName).toBeUndefined();
    expect(appEdit.editedAt).toBeUndefined();
  });

  test("typed refusals carry their codes", async () => {
    const f = fixture();
    expect(await refusal(f.service.update("missing", { name: "x" }))).toBe("SCHEDULE_NOT_FOUND");
    expect(await refusal(f.service.create({ ...recurring, agentId: "unknown" }))).toBe("AGENT_NOT_SCHEDULABLE");
    const schedule = await f.service.create(recurring);
    await f.service.runNow(schedule.id); await settle();
    expect(await refusal(f.service.update(schedule.id, { workspace: "worktree" }))).toBe("WORKSPACE_LOCKED");
    const headless = fixture({ desktopOwned: false });
    expect(await refusal(headless.service.create(recurring))).toBe("SCHEDULER_UNAVAILABLE");
    expect(schedulerErrorCode(new SchedulerRefusal("INVALID_RUN_AT", "x"))).toBe("INVALID_RUN_AT");
    expect(schedulerErrorCode(new Error("plain"))).toBe("SCHEDULER_ERROR");
  });
});

describe("resolveRunAt", () => {
  test("a local string is read in the given zone and an offset or number is an instant", () => {
    expect(new Date(resolveRunAt("2026-10-09T09:00", "Asia/Kolkata")).toISOString()).toBe("2026-10-09T03:30:00.000Z");
    expect(new Date(resolveRunAt("2026-10-09T09:00:30", "UTC")).toISOString()).toBe("2026-10-09T09:00:30.000Z");
    expect(new Date(resolveRunAt("2026-10-09T09:00+02:00", "Asia/Kolkata")).toISOString()).toBe("2026-10-09T07:00:00.000Z");
    expect(new Date(resolveRunAt("2026-10-09T09:00Z", "Asia/Kolkata")).toISOString()).toBe("2026-10-09T09:00:00.000Z");
    expect(resolveRunAt(1_800_000_000_000, "UTC")).toBe(1_800_000_000_000);
    expect(new Date(resolveRunAt("2026-10-09T09:00-0530", "UTC")).toISOString()).toBe("2026-10-09T14:30:00.000Z");
    expect(new Date(resolveRunAt("2026-10-09T09:00:15+05", "UTC")).toISOString()).toBe("2026-10-09T04:00:15.000Z");
    expect(new Date(resolveRunAt("2026-10-09 09:00z", "UTC")).toISOString()).toBe("2026-10-09T09:00:00.000Z");
  });

  test("a DST gap is refused naming the gap, and the repeated hour resolves to its first instance", () => {
    const gap = () => resolveRunAt("2026-03-08T02:30", "America/New_York");
    expect(gap).toThrow("does not exist");
    try { gap(); } catch (error) { expect((error as SchedulerRefusal).code).toBe("INVALID_RUN_AT"); }
    expect(new Date(resolveRunAt("2026-11-01T01:30", "America/New_York")).toISOString()).toBe("2026-11-01T05:30:00.000Z");
    expect(new Date(resolveRunAt("2026-03-08T03:30", "America/New_York")).toISOString()).toBe("2026-03-08T07:30:00.000Z");
  });

  test("unparseable input is INVALID_RUN_AT and a bad zone keeps the shipped cron code", () => {
    for (const bad of ["tomorrow", "2026-10-09", "2026-02-30T09:00", "2026-10-09T25:00", "", "2026-02-30T09:00Z", "2026-02-30T09:00+02:00",
      "2026-10-09T24:00Z", "2026-10-09T09:00+24:00", "Fri, 09 Oct 2026 09:00 +0000", "2026-10-09T09:00:00 GMT+0000"]) {
      try { resolveRunAt(bad, "UTC"); throw new Error(`accepted ${bad}`); }
      catch (error) { expect((error as SchedulerRefusal).code).toBe("INVALID_RUN_AT"); }
    }
    expect(() => resolveRunAt("2026-10-09T09:00", "Moon/Base")).toThrow("valid IANA timezone");
    expect(schedulerErrorCode((() => { try { resolveRunAt("2026-10-09T09:00", "Moon/Base"); } catch (e) { return e; } })())).toBe("SCHEDULER_INVALID_CRON");
  });
});

describe("store", () => {
  test("rearm releases the claim key so the same occurrence can be claimed again", async () => {
    const f = fixture();
    const schedule = await f.service.create(once(START + 5 * MIN));
    f.setTime(START + 5 * MIN);
    await f.service.tick(); await settle();
    const run = f.service.runs()[0]!;
    f.service.store.rearm(run.id, "reason", f.now());
    expect(f.service.runs()[0]).toMatchObject({ status: "skipped", reason: "reason" });
    expect(f.service.schedules()[0]!.firedRunId).toBeUndefined();
    const claimed = f.service.store.claim(f.service.schedules()[0]!, { ...run, id: "again", status: "preparing" }, undefined, undefined, true);
    expect(claimed?.id).toBe("again");
    expect(schedule.id).toBe(run.scheduleId);
  });

  test("rearm leaves a run that already ended, and its fired marker, alone", async () => {
    const f = fixture();
    await f.service.create(once(START + 5 * MIN));
    f.setTime(START + 5 * MIN);
    await f.service.tick(); await settle();
    const run = f.service.runs()[0]!;
    f.observe(run.id, "failed");
    expect(f.service.store.rearm(run.id, "reason", f.now())).toBe(false);
    expect(f.service.runs()[0]).toMatchObject({ status: "failed" });
    expect(f.service.schedules()[0]!.firedRunId).toBe(run.id);
    expect(f.service.store.claim(f.service.schedules()[0]!, { ...run, id: "again", status: "preparing" })).toBeNull();
  });

  test("an overlap deferral survives a restart and still runs a skip one-off", async () => {
    const dir = fresh();
    const f = fixture({}, dir);
    const schedule = await f.service.create(once(START + 5 * MIN, { catchUp: "skip" }));
    const manual = await f.service.runNow(schedule.id); await settle();
    f.observe(manual.id, "needs-input");
    f.setTime(START + 6 * MIN);
    await f.service.tick(); await settle();
    expect(f.service.schedules()[0]!.deferredAt).toBe(START + 6 * MIN);
    f.service.close();
    const again = fixture({}, dir);
    again.setTime(START + DAY);
    await again.service.tick(); await settle();
    expect(again.service.runs()[0]).toMatchObject({ trigger: "catch-up", status: "running" });
  });

  test("setting a new time drops a deferral, so skip applies to the new time again", async () => {
    const f = fixture();
    const schedule = await f.service.create(once(START + 5 * MIN, { catchUp: "skip" }));
    const manual = await f.service.runNow(schedule.id); await settle();
    f.observe(manual.id, "needs-input");
    f.setTime(START + 6 * MIN);
    await f.service.tick(); await settle();
    f.observe(manual.id, "completed");
    const retimed = await f.service.update(schedule.id, { runAt: f.now() + 5 * MIN });
    expect(retimed.deferredAt).toBeUndefined();
    f.setTime(START + DAY);
    await f.service.tick(); await settle();
    expect(f.service.runs()[0]).toMatchObject({ trigger: "missed", status: "skipped" });
  });
});
