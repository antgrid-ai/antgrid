import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Database } from "bun:sqlite";
import { CRON_PRESETS, MISSED_COUNT_CAP, SchedulePatchSchema, missedOccurrences, nextOccurrences, validateCron, validateTimezone, SchedulerService, SchedulerStore,
  type SchedulerOptions, type ScheduleInput, type SchedulerRun } from "../src/scheduler";

const dirs: string[] = [];
const services: SchedulerService[] = [];
const stores: SchedulerStore[] = [];
const fresh = () => { const dir = mkdtempSync(join(tmpdir(), "antgrid-scheduler-")); dirs.push(dir); return dir; };
afterEach(() => {
  for (const s of services.splice(0)) s.close();
  for (const s of stores.splice(0)) s.close();
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});
const input: ScheduleInput = { name: "Review", projectId: "project", agentId: "claude", mode: "terminal", prompt: "Review code",
  approvalPolicy: "default", workspace: "worktree", cron: "* * * * *", timezone: "UTC", enabled: true, catchUp: "latest" };
const DAY = 24 * 60 * 60_000;
const daily: ScheduleInput = { ...input, cron: "0 9 * * *" };
async function settle() { for (let i = 0; i < 12; i++) await Promise.resolve(); }
function fixture(overrides: Partial<SchedulerOptions> = {}, abDir = fresh()) {
  let time = Date.parse("2026-01-01T00:00:00Z");
  let sequence = 0;
  const delivered: string[] = [];
  const prepared: { checkoutId?: string }[] = [];
  const options: SchedulerOptions = {
    abDir, desktopOwned: true, now: () => time, timezone: "UTC", supportedAgents: () => [{ agentId: "claude", modes: ["terminal", "chat"] }],
    stop: async () => {},
    prepare: async (schedule, run, bind) => {
      prepared.push(schedule);
      const identity = { sessionId: `session-${++sequence}`, runtimeGeneration: `generation-${sequence}`, checkoutId: schedule.checkoutId ?? "checkout" };
      bind(identity);
      return { ...identity, deliverPrompt: async () => { delivered.push(run.id); } };
    }, ...overrides,
  };
  const service = new SchedulerService(options); services.push(service);
  return { service, delivered, prepared, setTime: (next: number) => { time = next; }, advance: (ms: number) => { time += ms; }, now: () => time };
}

describe("scheduler cron", () => {
  test("accepts numeric lists, ranges, steps and standard DOM/DOW union", () => {
    expect(validateCron("  0,30 9-17/2 1 * 1-5  ", "UTC")).toBe("0,30 9-17/2 1 * 1-5");
    const times = nextOccurrences("0 9 1 * 1", "UTC", Date.parse("2026-01-01T10:00Z"), 2);
    expect(times.map((t) => new Date(t).toISOString())).toEqual(["2026-01-05T09:00:00.000Z", "2026-01-12T09:00:00.000Z"]);
  });
  test("rejects seconds, macros, aliases and extended syntax", () => {
    for (const cron of ["0 * * * * *", "@daily", "0 9 * * MON", "0 0 L * *", "0 0 * * 1#2", "? * * * *", "H * * * *", "60 * * * *", "*/0 * * * *", "1,,2 * * * *"]) {
      expect(() => validateCron(cron, "UTC")).toThrow();
    }
    expect(() => validateTimezone("+05:30")).toThrow();
    expect(() => validateTimezone("Moon/Base")).toThrow();
  });
  test("presets and explicit timezone produce five next occurrences", () => {
    for (const cron of Object.values(CRON_PRESETS)) expect(nextOccurrences(cron, "Asia/Kolkata", 0)).toHaveLength(5);
    expect(new Date(nextOccurrences(CRON_PRESETS.daily, "Asia/Kolkata", Date.parse("2026-01-01T00:00Z"), 1)[0]!).toISOString())
      .toBe("2026-01-01T03:30:00.000Z");
  });
  test("DST gap and repeated hour follow upstream parser semantics", () => {
    expect(nextOccurrences("0 * * * *", "America/New_York", Date.parse("2026-03-08T06:00Z"), 3).map((t) => new Date(t).toISOString()))
      .toEqual(["2026-03-08T07:00:00.000Z", "2026-03-08T08:00:00.000Z", "2026-03-08T09:00:00.000Z"]);
    const fall = nextOccurrences("0 * * * *", "America/New_York", Date.parse("2026-11-01T04:00Z"), 4);
    expect(new Set(fall).size).toBe(4);
    expect(fall.every((t, i) => i === 0 || t > fall[i - 1]!)).toBe(true);
  });
});

describe("scheduler runtime", () => {
  for (const [transition, expectedDates] of [
    ["spring forward", ["2026-03-07T14:00:00Z", "2026-03-08T13:00:00Z", "2026-03-09T13:00:00Z"]],
    ["fall back", ["2026-10-31T13:00:00Z", "2026-11-01T14:00:00Z", "2026-11-02T14:00:00Z"]],
  ] as const) {
    test(`retains local 09:00 across ${transition} while persisting UTC instants`, async () => {
      const dir = fresh();
      const f = fixture({}, dir);
      const expected = expectedDates.map((date) => Date.parse(date));
      f.setTime(expected[0]! - 60_000);
      const schedule = await f.service.create({ ...input, cron: CRON_PRESETS.daily, timezone: "America/New_York" });
      expect(f.service.preview(schedule.cron, schedule.timezone).slice(0, 3)).toEqual(expected);
      for (const occurrenceAt of expected) {
        expect(f.service.schedules()[0]!.nextOccurrence).toBe(occurrenceAt);
        f.setTime(occurrenceAt);
        await f.service.tick(); await settle();
        const run = f.service.runs().find((candidate) => candidate.occurrenceAt === occurrenceAt)!;
        expect(run).toMatchObject({ trigger: "cron", status: "running", occurrenceAt,
          startedAt: occurrenceAt, timezone: "America/New_York" });
        f.service.observe({ projectId: run.projectId, sessionId: run.sessionId!,
          runtimeGeneration: run.runtimeGeneration!, status: "completed" });
      }
      const db = new Database(join(dir, "scheduler", "scheduler.db"), { readonly: true });
      try {
        const saved = JSON.parse((db.query("SELECT record FROM schedules WHERE id=?").get(schedule.id) as { record: string }).record);
        expect(saved).toMatchObject({ cron: "0 9 * * *", timezone: "America/New_York",
          nextOccurrence: expected[2]! + 24 * 60 * 60_000 });
        const runs = (db.query("SELECT record FROM runs ORDER BY startedAt").all() as { record: string }[])
          .map((row) => JSON.parse(row.record));
        expect(runs.map((run) => run.occurrenceAt)).toEqual(expected);
        expect(runs.map((run) => run.startedAt)).toEqual(expected);
        expect(runs.map((run) => run.finishedAt)).toEqual(expected);
      } finally { db.close(); }
    });
  }
  test("branch clearing is an update-only operation and respects retained workspace locks", async () => {
    const f = fixture();
    expect((await f.service.capabilities()).supportsBaseBranchClear).toBe(true);
    await expect(f.service.create({ ...input, baseBranch: null })).rejects.toThrow();
    const schedule = await f.service.create({ ...input, baseBranch: "main" });
    expect((await f.service.update(schedule.id, { name: "Renamed" })).baseBranch).toBe("main");
    expect((await f.service.update(schedule.id, { baseBranch: null })).baseBranch).toBeUndefined();
    expect(f.service.schedules()[0]!.baseBranch).toBeUndefined();
    await f.service.update(schedule.id, { baseBranch: "main" });
    await f.service.runNow(schedule.id); await settle();
    await expect(f.service.update(schedule.id, { baseBranch: null })).rejects.toThrow("cannot change");
    const run = f.service.runs().find((r) => r.status === "running")!;
    f.service.observe({ projectId: run.projectId, sessionId: run.sessionId!, runtimeGeneration: run.runtimeGeneration!, status: "completed" });
    await expect(f.service.update(schedule.id, { baseBranch: null })).rejects.toThrow("cannot change");
  });
  test("history retains the occurrence timezone after editing the timetable", async () => {
    const f = fixture();
    const schedule = await f.service.create({ ...input, timezone: "America/New_York" });
    await f.service.runNow(schedule.id); await settle();
    await f.service.update(schedule.id, { timezone: "Asia/Kolkata" });
    expect(f.service.runs()[0]!.timezone).toBe("America/New_York");
    expect((await f.service.runNow(schedule.id)).timezone).toBe("Asia/Kolkata");
  });
  test("author device is display metadata that execution edits replace", async () => {
    const f = fixture();
    const schedule = await f.service.create(input, "phone");
    expect((await f.service.update(schedule.id, { name: "Renamed" }, null)).authorDeviceId).toBe("phone");
    expect((await f.service.update(schedule.id, { prompt: "Locally reviewed instructions" }, null)).authorDeviceId).toBeNull();
    expect((await f.service.update(schedule.id, { name: "Remote name" }, "other-phone")).authorDeviceId).toBeNull();
    expect((await f.service.update(schedule.id, { enabled: false }, "other-phone")).authorDeviceId).toBe("other-phone");
  });
  test("preview and dispatch agree and manual launch does not change timetable", async () => {
    const f = fixture(); const expected = f.service.preview(input.cron, input.timezone)[0]!;
    const schedule = await f.service.create(input);
    await f.service.runNow(schedule.id); await settle();
    expect(f.service.schedules()[0]!.nextOccurrence).toBe(expected);
    f.advance(60_000); await f.service.tick(); await settle();
    expect(f.service.runs().find((r) => r.trigger === "cron")?.occurrenceAt).toBe(expected);
    expect(f.service.runs().find((r) => r.trigger === "cron")?.status).toBe("skipped");
  });
  test("overlap skips the same schedule but never caps distinct schedules", async () => {
    const f = fixture();
    const [a, b, c] = [await f.service.create(input), await f.service.create({ ...input, name: "Second" }), await f.service.create({ ...input, name: "Third" })];
    for (const schedule of [a, b, c]) await f.service.runNow(schedule.id);
    await settle();
    expect((await f.service.runNow(a.id)).reason).toContain("still active");
    expect(f.delivered).toHaveLength(3);
  });
  test("pause and resume consolidate missed interval and skip replay", async () => {
    const f = fixture(); const schedule = await f.service.create(input);
    await f.service.update(schedule.id, { enabled: false });
    f.advance(10 * 24 * 60 * 60_000); await f.service.tick();
    expect(f.service.runs()).toHaveLength(0);
    await f.service.update(schedule.id, { enabled: true });
    expect(f.service.runs()).toHaveLength(1);
    expect(f.service.runs()[0]!.trigger).toBe("missed");
    expect(f.delivered).toHaveLength(0);
  });
  test("restart records nothing until the first tick, never replays an interrupted run, then catches up", async () => {
    const dir = fresh(); const f = fixture({}, dir); const schedule = await f.service.create(daily);
    await f.service.runNow(schedule.id); await settle(); f.service.close();
    const time = f.now() + 7 * DAY + 12 * 3_600_000;
    const next = fixture({ now: () => time }, dir);
    expect(next.service.runs().map((r) => r.status)).toEqual(["interrupted"]);
    await next.service.tick(); await settle();
    expect(next.service.runs().map((r) => r.trigger).sort()).toEqual(["catch-up", "manual", "missed"]);
    expect(next.delivered).toHaveLength(1);
  });
  test("subsequent runs share persisted checkout across restart", async () => {
    const dir = fresh(); const f = fixture({}, dir); const schedule = await f.service.create(input);
    await f.service.runNow(schedule.id); await settle();
    const first = f.service.runs()[0]!;
    f.service.observe({ projectId: first.projectId, sessionId: first.sessionId!, runtimeGeneration: first.runtimeGeneration!, status: "completed" });
    f.service.close(); const next = fixture({}, dir);
    await next.service.runNow(schedule.id); await settle();
    expect(next.prepared[0]!.checkoutId).toBe("checkout");
    expect(next.service.runs().every((run) => run.checkoutId === "checkout")).toBe(true);
  });
  test("immutable workspace fields, mutable prompt and pause", async () => {
    const f = fixture(); const schedule = await f.service.create(input); await f.service.runNow(schedule.id); await settle();
    await expect(f.service.update(schedule.id, { projectId: "other" })).rejects.toThrow("cannot change");
    await expect(f.service.update(schedule.id, { workspace: "shared" })).rejects.toThrow("cannot change");
    expect((await f.service.update(schedule.id, { prompt: "Another prompt", enabled: false })).prompt).toBe("Another prompt");
  });
  test("permissions, generation fencing and completion release slot permanently", async () => {
    const f = fixture(); const schedule = await f.service.create(input); await f.service.runNow(schedule.id); await settle();
    const run = f.service.runs()[0]!;
    const identity = { projectId: run.projectId, sessionId: run.sessionId!, runtimeGeneration: run.runtimeGeneration! };
    f.service.observe({ ...identity, runtimeGeneration: "old", status: "completed" });
    expect(f.service.runs()[0]!.status).toBe("running");
    f.service.observe({ ...identity, status: "needs-input" }); expect(f.service.runs()[0]!.status).toBe("needs-input");
    f.service.observe({ ...identity, status: "completed" }); f.service.observe({ ...identity, status: "running" });
    expect(f.service.runs()[0]!.status).toBe("completed");
    expect((await f.service.runNow(schedule.id)).status).toBe("preparing");
  });
  test("launch failure and user stop leave truthful terminal state", async () => {
    const failed = fixture({ prepare: async () => { throw new Error("private prompt must never appear"); } });
    const schedule = await failed.service.create(input); await failed.service.runNow(schedule.id); await settle();
    expect(failed.service.runs()[0]!.status).toBe("failed"); expect(failed.service.runs()[0]!.reason).not.toContain("private prompt");
    const f = fixture(); const other = await f.service.create(input); const run = await f.service.runNow(other.id); await settle();
    await f.service.stop(run.id); expect(f.service.runs()[0]!.status).toBe("interrupted");
  });
  test("known launch errors give actionable reasons without leaking error text", async () => {
    const f = fixture({ prepare: async () => { throw Object.assign(new Error("private contents"), { code: "WORKTREE_MISSING" }); } });
    const schedule = await f.service.create(input); await f.service.runNow(schedule.id); await settle();
    expect(f.service.runs()[0]!.reason).toBe("Schedule workspace is missing. Restore it or create a new schedule.");
  });
  test("runs of a schedule whose author device is gone still dispatch", async () => {
    const f = fixture(); const schedule = await f.service.create(input, "revoked-phone");
    await f.service.runNow(schedule.id); await settle();
    expect(f.service.runs()[0]!.status).toBe("running"); expect(f.delivered).toHaveLength(1);
  });
  test("explicit project shutdown interrupts all active runs", async () => {
    const f = fixture(); const schedule = await f.service.create(input); await f.service.runNow(schedule.id); await settle();
    f.service.interruptProject(schedule.projectId, "Project stopped by user");
    expect(f.service.runs()[0]!.status).toBe("interrupted"); expect(f.service.hasActiveProject(schedule.projectId)).toBe(false);
  });
  test("unsupported agent and headless execution rejected before save", async () => {
    const f = fixture(); await expect(f.service.create({ ...input, agentId: "unsupported" })).rejects.toThrow("observable");
    const headless = fixture({ desktopOwned: false }); await expect(headless.service.create(input)).rejects.toThrow("desktop app");
    expect((await headless.service.capabilities()).supported).toBe(false);
  });
  test("delete retains runs and allows active occurrence to finish", async () => {
    const released: string[] = []; const f = fixture({ releaseWorkspace: async (s) => { released.push(s.id); } });
    const schedule = await f.service.create(input); await f.service.runNow(schedule.id); await settle(); await f.service.delete(schedule.id);
    expect(f.service.schedules()).toHaveLength(0); expect(f.service.runs()[0]!.status).toBe("running"); expect(released).toEqual([schedule.id]);
    await expect(f.service.runNow(schedule.id)).rejects.toThrow("no longer exists");
  });
  test("stop during preparation prevents binding and prompt delivery", async () => {
    let release!: () => void;
    const barrier = new Promise<void>((resolve) => { release = resolve; });
    let deliveries = 0;
    const f = fixture({ prepare: async (_schedule, _run, bind) => {
      await barrier;
      const identity = { sessionId: "late-session", runtimeGeneration: "late-generation" };
      bind(identity); return { ...identity, deliverPrompt: async () => { deliveries++; } };
    } });
    const schedule = await f.service.create(input); const run = await f.service.runNow(schedule.id);
    await settle(); await f.service.stop(run.id); release(); await settle();
    expect(f.service.runs()[0]!.status).toBe("interrupted"); expect(deliveries).toBe(0);
    expect((await f.service.capabilities()).supported).toBe(true);
  });
  test("preparation retains overlap slot while cancellation is pending", async () => {
    let ready!: () => void; let stopped!: () => void;
    const preparation = new Promise<void>((resolve) => { ready = resolve; });
    const cancellation = new Promise<void>((resolve) => { stopped = resolve; });
    let deliveries = 0;
    const f = fixture({ stop: async (run) => {
      f.service.observe({ projectId: run.projectId, sessionId: run.sessionId!, runtimeGeneration: run.runtimeGeneration!, status: "interrupted" });
      await cancellation;
    }, prepare: async (_schedule, _run, bind) => {
      const identity = { sessionId: "session", runtimeGeneration: "generation" }; bind(identity);
      await preparation; return { ...identity, deliverPrompt: async () => { deliveries++; } };
    } });
    const schedule = await f.service.create(input); const run = await f.service.runNow(schedule.id); await settle();
    const stop = f.service.stop(run.id); ready(); await settle();
    expect((await f.service.runNow(schedule.id)).status).toBe("skipped"); expect(deliveries).toBe(0);
    stopped(); await stop; await settle(); expect(f.service.runs().find((r) => r.id === run.id)!.status).toBe("interrupted");
  });
  test("settings edit during preparation skips obsolete prompt", async () => {
    let release!: () => void;
    const barrier = new Promise<void>((resolve) => { release = resolve; });
    let deliveries = 0;
    const f = fixture({ prepare: async (_schedule, _run, bind) => {
      const identity = { sessionId: "session", runtimeGeneration: "generation", checkoutId: "checkout" };
      bind(identity); await barrier; return { ...identity, deliverPrompt: async () => { deliveries++; } };
    } });
    const schedule = await f.service.create(input); await f.service.runNow(schedule.id); await settle();
    await f.service.update(schedule.id, { prompt: "Changed execution settings" }, "other-phone");
    release(); await settle(); expect(f.service.runs()[0]!.status).toBe("skipped"); expect(deliveries).toBe(0);
  });
  test("closing host during preparation never submits uncertain prompt", async () => {
    let release!: () => void;
    const barrier = new Promise<void>((resolve) => { release = resolve; });
    let deliveries = 0;
    const f = fixture({ prepare: async (_schedule, _run, bind) => {
      const identity = { sessionId: "session", runtimeGeneration: "generation" };
      bind(identity); await barrier; return { ...identity, deliverPrompt: async () => { deliveries++; } };
    } });
    const schedule = await f.service.create(input); await f.service.runNow(schedule.id); await settle();
    f.service.close(); release(); await settle(); expect(deliveries).toBe(0);
  });
  test("deleted ownership is released after a late preparation failure", async () => {
    let release!: () => void;
    const barrier = new Promise<void>((resolve) => { release = resolve; });
    let cleanups = 0;
    const f = fixture({ prepare: async () => { await barrier; throw new Error("Setup failed after checkout creation"); },
      releaseWorkspace: async () => { cleanups++; } });
    const schedule = await f.service.create(input); await f.service.runNow(schedule.id); await settle();
    await f.service.delete(schedule.id); expect(cleanups).toBe(1);
    release(); await settle(); expect(cleanups).toBe(2);
    expect(f.service.runs()[0]!.status).toBe("failed");
  });
  test("delete retries failed ownership release idempotently without enabling execution", async () => {
    let unavailable = true;
    const f = fixture({ releaseWorkspace: async () => { if (unavailable) throw new Error("Checkout metadata unavailable"); } });
    const schedule = await f.service.create(input);
    await expect(f.service.delete(schedule.id)).rejects.toThrow("still owns its workspace");
    expect(f.service.schedules()).toHaveLength(0); expect((await f.service.capabilities()).supported).toBe(true);
    expect((await f.service.capabilities()).error).toContain("Restore checkout metadata");
    unavailable = false; await f.service.delete(schedule.id); await f.service.delete(schedule.id);
    expect((await f.service.capabilities()).error).toBeUndefined();
  });
  test("startup retries ownership releases for tombstoned schedules", async () => {
    const dir = fresh(); const f = fixture({ releaseWorkspace: async () => { throw new Error("Unavailable"); } }, dir);
    const schedule = await f.service.create(input); await expect(f.service.delete(schedule.id)).rejects.toThrow(); f.service.close();
    const released: string[] = []; const next = fixture({ releaseWorkspace: async (s) => { released.push(s.id); } }, dir);
    next.service.start(); await settle(); expect(released).toEqual([schedule.id]); expect(next.service.schedules()).toHaveLength(0);
  });
  test("daily schedule asleep from 08:00 to 18:00 catches up the 09:00 occurrence", async () => {
    const f = fixture(); f.setTime(Date.parse("2026-01-01T08:00:00Z"));
    const schedule = await f.service.create(daily);
    f.setTime(Date.parse("2026-01-01T18:00:00Z")); await f.service.tick(); await settle();
    expect(f.service.runs()).toHaveLength(1);
    expect(f.service.runs()[0]).toMatchObject({ trigger: "catch-up", status: "running", occurrenceAt: Date.parse("2026-01-01T09:00:00Z") });
    expect(f.delivered).toHaveLength(1);
    expect(f.service.schedules().find((s) => s.id === schedule.id)!.nextOccurrence).toBe(Date.parse("2026-01-02T09:00:00Z"));
  });
  test("several missed occurrences: latest runs and earlier ones consolidate; skip policy runs nothing", async () => {
    const f = fixture(); f.setTime(Date.parse("2026-01-01T08:00:00Z"));
    await f.service.create(daily); await f.service.create({ ...daily, name: "Skipper", catchUp: "skip" });
    f.setTime(Date.parse("2026-01-04T12:00:00Z")); await f.service.tick(); await settle();
    const runs = f.service.runs();
    const latest = runs.filter((r) => r.scheduleName === "Review"); const skipper = runs.filter((r) => r.scheduleName === "Skipper");
    expect(latest.map((r) => r.trigger).sort()).toEqual(["catch-up", "missed"]);
    expect(latest.find((r) => r.trigger === "catch-up")!.occurrenceAt).toBe(Date.parse("2026-01-04T09:00:00Z"));
    expect(latest.find((r) => r.trigger === "missed")).toMatchObject({ status: "skipped", missedCount: 3, occurrenceAt: Date.parse("2026-01-01T09:00:00Z"),
      missedUntil: Date.parse("2026-01-03T09:00:00Z"), reason: expect.stringContaining("only the latest missed run is caught up") });
    expect(skipper).toHaveLength(1);
    expect(skipper[0]).toMatchObject({ trigger: "missed", status: "skipped", missedCount: 4, missedUntil: Date.parse("2026-01-04T09:00:00Z"),
      reason: "Missed while the desktop app was closed or the computer was asleep" });
    expect(f.delivered).toHaveLength(1);
  });
  test("no catch-up when the next occurrence is within 15 minutes", async () => {
    const f = fixture(); f.setTime(Date.parse("2026-01-01T08:00:00Z"));
    await f.service.create({ ...input, cron: "*/5 * * * *" });
    f.setTime(Date.parse("2026-01-11T08:02:00Z")); await f.service.tick(); await settle();
    const runs = f.service.runs();
    expect(runs).toHaveLength(1);
    expect(runs[0]).toMatchObject({ trigger: "missed", status: "skipped", missedCount: MISSED_COUNT_CAP });
    expect(runs[0]!.reason).toContain("15 minutes"); expect(f.delivered).toHaveLength(0);
  });
  test("minutely schedule after a long gap runs only the on-time occurrence and caps the missed count", async () => {
    const f = fixture(); await f.service.create(input); f.advance(365 * DAY + 30_000);
    await f.service.tick(); await settle();
    const runs = f.service.runs();
    expect(runs.some((r) => r.trigger === "catch-up")).toBe(false);
    expect(runs.find((r) => r.trigger === "missed")).toMatchObject({ missedCount: MISSED_COUNT_CAP });
    expect(runs.filter((r) => r.trigger === "cron")).toHaveLength(1);
  });
  test("a tick 30s late still runs as cron while 61s late runs as catch-up", async () => {
    const at = Date.parse("2026-01-01T09:00:00Z");
    for (const [late, trigger] of [[30_000, "cron"], [61_000, "catch-up"]] as const) {
      const f = fixture(); f.setTime(Date.parse("2026-01-01T08:00:00Z")); await f.service.create(daily);
      f.setTime(at + late); await f.service.tick(); await settle();
      expect(f.service.runs()).toHaveLength(1);
      expect(f.service.runs()[0]).toMatchObject({ trigger, status: "running", occurrenceAt: at });
    }
  });
  test("resume during the on-time window runs the due occurrence instead of skipping it", async () => {
    const f = fixture(); f.setTime(Date.parse("2026-01-01T08:00:00Z")); await f.service.create(daily);
    f.setTime(Date.parse("2026-01-01T09:00:10Z")); f.service.resume(); await settle();
    expect(f.service.runs()).toHaveLength(1); expect(f.service.runs()[0]).toMatchObject({ trigger: "cron", status: "running" });
  });
  test("re-enabling a paused schedule records the paused interval and never catches up", async () => {
    const f = fixture(); f.setTime(Date.parse("2026-01-01T08:00:00Z"));
    const schedule = await f.service.create(daily); await f.service.update(schedule.id, { enabled: false });
    f.setTime(Date.parse("2026-01-05T12:00:00Z")); await f.service.update(schedule.id, { enabled: true }); await settle();
    expect(f.service.runs()).toHaveLength(1);
    expect(f.service.runs()[0]).toMatchObject({ trigger: "missed", missedCount: 5, reason: "Missed while the schedule was paused" });
    expect(f.delivered).toHaveLength(0);
  });
  test("patches carry no defaults: pause, resume and rename keep stored settings", async () => {
    expect(SchedulePatchSchema.parse({ name: "x" })).toEqual({ name: "x" });
    expect(() => SchedulePatchSchema.parse({ unknown: 1 })).toThrow();
    const f = fixture(); const schedule = await f.service.create({ ...input, approvalPolicy: "bypass", catchUp: "skip" });
    await f.service.update(schedule.id, { enabled: false });
    expect(f.service.schedules()[0]).toMatchObject({ approvalPolicy: "bypass", catchUp: "skip", enabled: false });
    await f.service.update(schedule.id, { name: "Renamed" });
    expect(f.service.schedules()[0]).toMatchObject({ enabled: false, name: "Renamed", approvalPolicy: "bypass" });
    await f.service.update(schedule.id, { enabled: true });
    expect(f.service.schedules()[0]).toMatchObject({ approvalPolicy: "bypass", catchUp: "skip", enabled: true });
  });
  test("missed-occurrence helper counts inclusively, caps, and is DST-safe", () => {
    const first = Date.parse("2026-03-07T14:00:00Z");
    const result = missedOccurrences("0 9 * * *", "America/New_York", first, Date.parse("2026-03-09T13:00:00Z"), 100)!;
    expect(result.count).toBe(3);
    expect(new Date(result.latest).toISOString()).toBe("2026-03-09T13:00:00.000Z");
    expect(new Date(result.previous!).toISOString()).toBe("2026-03-08T13:00:00.000Z");
    expect(missedOccurrences("* * * * *", "UTC", 0, 10 * 60_000, 5)!.count).toBe(5);
    expect(missedOccurrences("0 9 * * *", "UTC", Date.parse("2026-01-01T09:00:00Z"), Date.parse("2026-01-01T08:00:00Z"), 5)).toBeNull();
  });
  test("missed-occurrence helper walks the forward timetable through DST gaps and repeated hours", () => {
    const at = (iso: string) => Date.parse(iso);
    const show = (r: ReturnType<typeof missedOccurrences>) => r && { count: r.count, latest: new Date(r.latest).toISOString(),
      previous: r.previous === undefined ? undefined : new Date(r.previous).toISOString(), following: new Date(r.following).toISOString() };
    // Spring forward: next() shifts the nonexistent 02:30 EST to 03:30 EDT (07:30Z); prev() never yields that day.
    expect(show(missedOccurrences("30 2 * * *", "America/New_York", at("2026-03-08T07:30:00Z"), at("2026-03-08T07:30:01Z"), 10)))
      .toEqual({ count: 1, latest: "2026-03-08T07:30:00.000Z", previous: undefined, following: "2026-03-09T06:30:00.000Z" });
    expect(show(missedOccurrences("30 2 * * *", "America/New_York", at("2026-03-07T07:30:00Z"), at("2026-03-09T12:00:00Z"), 10)))
      .toEqual({ count: 3, latest: "2026-03-09T06:30:00.000Z", previous: "2026-03-08T07:30:00.000Z", following: "2026-03-10T06:30:00.000Z" });
    // Waking inside the shifted hour: next() from `now` would skip to tomorrow, but the stored timetable still owes 07:30Z.
    expect(show(missedOccurrences("30 2 * * *", "America/New_York", at("2026-03-07T07:30:00Z"), at("2026-03-08T07:15:00Z"), 10))!.following)
      .toBe("2026-03-08T07:30:00.000Z");
    // Fall back: prev() would answer the second 01:30 (06:30Z), which next() never emits for this cron.
    expect(show(missedOccurrences("30 1 * * *", "America/New_York", at("2026-11-01T05:30:00Z"), at("2026-11-01T06:30:20Z"), 10)))
      .toEqual({ count: 1, latest: "2026-11-01T05:30:00.000Z", previous: undefined, following: "2026-11-02T06:30:00.000Z" });
    // Past the cap the tail is re-seeded; it must still agree with the uncapped forward walk.
    for (const now of [at("2026-03-08T07:10:00Z"), at("2026-11-01T06:35:00Z"), at("2026-11-01T05:55:00Z")]) {
      const full = show(missedOccurrences("*/10 * * * *", "America/New_York", at("2026-03-01T00:00:00Z"), now, 1_000_000))!;
      const capped = show(missedOccurrences("*/10 * * * *", "America/New_York", at("2026-03-01T00:00:00Z"), now, 5))!;
      expect({ ...capped, count: full.count }).toEqual(full);
      expect(capped.count).toBe(5);
    }
  });
  test("a spring-forward gap-day occurrence runs on time, catches up, or is recorded, never silently dropped", async () => {
    const nightly: ScheduleInput = { ...input, cron: "30 2 * * *", timezone: "America/New_York" };
    const gapDay = Date.parse("2026-03-08T07:30:00Z");
    const tomorrow = Date.parse("2026-03-09T06:30:00Z");
    const onTime = fixture(); onTime.setTime(Date.parse("2026-03-07T12:00:00Z"));
    const a = await onTime.service.create(nightly);
    expect(a.nextOccurrence).toBe(gapDay);
    onTime.setTime(gapDay + 1_000); await onTime.service.tick(); await settle();
    expect(onTime.service.runs()).toHaveLength(1);
    expect(onTime.service.runs()[0]).toMatchObject({ trigger: "cron", status: "running", occurrenceAt: gapDay });
    expect(onTime.delivered).toHaveLength(1);
    expect(onTime.service.schedules()[0]!.nextOccurrence).toBe(tomorrow);

    const late = fixture(); late.setTime(Date.parse("2026-03-07T12:00:00Z")); await late.service.create(nightly);
    late.setTime(Date.parse("2026-03-08T12:00:00Z")); await late.service.tick(); await settle();
    expect(late.service.runs()).toHaveLength(1);
    expect(late.service.runs()[0]).toMatchObject({ trigger: "catch-up", occurrenceAt: gapDay });
    expect(late.service.schedules()[0]!.nextOccurrence).toBe(tomorrow);

    const paused = fixture(); paused.setTime(Date.parse("2026-03-07T12:00:00Z"));
    const p = await paused.service.create(nightly); await paused.service.update(p.id, { enabled: false });
    paused.setTime(Date.parse("2026-03-08T12:00:00Z")); await paused.service.update(p.id, { enabled: true }); await settle();
    expect(paused.service.runs()).toHaveLength(1);
    expect(paused.service.runs()[0]).toMatchObject({ trigger: "missed", missedCount: 1, occurrenceAt: gapDay, missedUntil: gapDay });
    expect(paused.service.schedules()[0]!.nextOccurrence).toBe(tomorrow);

    // Waking on the 9th: the gap day is the earlier of two misses and is recorded, ending no earlier than it starts.
    const twoDays = fixture(); twoDays.setTime(Date.parse("2026-03-07T12:00:00Z")); await twoDays.service.create(nightly);
    twoDays.setTime(Date.parse("2026-03-09T12:00:00Z")); await twoDays.service.tick(); await settle();
    const runs = twoDays.service.runs();
    expect(runs.find((r) => r.trigger === "catch-up")).toMatchObject({ occurrenceAt: tomorrow });
    expect(runs.find((r) => r.trigger === "missed")).toMatchObject({ missedCount: 1, occurrenceAt: gapDay, missedUntil: gapDay });
  });
  test("a machine asleep through the first 01:30 of a fall-back day does not run the repeated 01:30 as on time", async () => {
    const f = fixture(); f.setTime(Date.parse("2026-10-31T12:00:00Z"));
    await f.service.create({ ...input, cron: "30 1 * * *", timezone: "America/New_York", catchUp: "skip" });
    expect(f.service.schedules()[0]!.nextOccurrence).toBe(Date.parse("2026-11-01T05:30:00Z"));
    f.setTime(Date.parse("2026-11-01T06:30:20Z")); await f.service.tick(); await settle();
    expect(f.service.runs()).toHaveLength(1);
    expect(f.service.runs()[0]).toMatchObject({ trigger: "missed", status: "skipped", missedCount: 1,
      occurrenceAt: Date.parse("2026-11-01T05:30:00Z"), missedUntil: Date.parse("2026-11-01T05:30:00Z") });
    expect(f.delivered).toHaveLength(0);
  });
  test("async capability validation cannot resurrect a concurrently deleted schedule", async () => {
    let hold = false;
    let release!: () => void;
    const barrier = new Promise<void>((resolve) => { release = resolve; });
    const f = fixture({ supportedAgents: async () => {
      if (hold) await barrier;
      return [{ agentId: "claude", modes: ["terminal"] }];
    } });
    const schedule = await f.service.create(input); hold = true;
    const update = f.service.update(schedule.id, { name: "Later edit" });
    await f.service.delete(schedule.id); release();
    await expect(update).rejects.toThrow("no longer exists"); expect(f.service.schedules()).toHaveLength(0);
  });
});

describe("scheduler durable store", () => {
  test("single owner and stale process recovery are serialized", () => {
    const dir = fresh(); const store = new SchedulerStore(dir); stores.push(store);
    expect(() => new SchedulerStore(dir)).toThrow("Another desktop host"); store.close();
    const db = new Database(store.path); db.query("INSERT INTO scheduler_owner(id,pid,token) VALUES(1,2147483647,'dead')").run(); db.close();
    const recovered = new SchedulerStore(dir); stores.push(recovered); expect(recovered.schedules()).toEqual([]);
  });
  test("a user_version 1 database upgrades to 2 and a newer one is refused", () => {
    const dir = fresh(); const first = new SchedulerStore(dir); first.close();
    const open = (version: number) => { const db = new Database(first.path); db.exec(`PRAGMA user_version = ${version}`); db.close(); };
    open(1); const upgraded = new SchedulerStore(dir); stores.push(upgraded); upgraded.close();
    const db = new Database(first.path); expect((db.query("PRAGMA user_version").get() as { user_version: number }).user_version).toBe(2); db.close();
    open(3); expect(() => new SchedulerStore(dir)).toThrow("requires a newer bridge");
  });
  test("duplicate occurrence claims cannot launch twice", async () => {
    const f = fixture(); const schedule = await f.service.create(input);
    const run: SchedulerRun = { id: "one", scheduleId: schedule.id, scheduleName: schedule.name, projectId: schedule.projectId, occurrenceAt: 100, trigger: "cron", status: "preparing", startedAt: 100 };
    expect(f.service.store.claim(schedule, run)).not.toBeNull(); expect(f.service.store.claim(schedule, { ...run, id: "two" })).toBeNull();
  });
  test("latest 500 terminal records retained without pruning active entries", async () => {
    const f = fixture(); const schedule = await f.service.create(input);
    for (let i = 0; i < 505; i++) {
      f.service.store.claim(schedule, { id: `r${i}`, scheduleId: schedule.id, scheduleName: schedule.name, projectId: schedule.projectId,
        occurrenceAt: i, trigger: "manual", status: "completed", startedAt: i, finishedAt: i });
    }
    expect(f.service.runs()).toHaveLength(500);
    await f.service.runNow(schedule.id); await settle(); expect(f.service.runs()).toHaveLength(501);
  });
  test("storage disappearance latches fault and never recreates or dispatches", async () => {
    const f = fixture(); const schedule = await f.service.create(input); unlinkSync(f.service.store.path);
    expect(() => f.service.runs()).toThrow(); await expect(f.service.runNow(schedule.id)).rejects.toThrow("storage failed");
    expect((await f.service.capabilities()).error).toContain("storage failed"); expect(f.delivered).toHaveLength(0);
  });
  test("failed durable association prevents prompt delivery", async () => {
    const dir = fresh(); let deliveries = 0;
    const f = fixture({ prepare: async (_schedule, _run, bind) => {
      const db = new Database(join(dir, "scheduler", "scheduler.db")); db.exec("DROP TABLE runs"); db.close();
      const identity = { sessionId: "session", runtimeGeneration: "generation" }; bind(identity);
      return { ...identity, deliverPrompt: async () => { deliveries++; } };
    } }, dir);
    const schedule = await f.service.create(input); await f.service.runNow(schedule.id); await settle();
    expect(deliveries).toBe(0); expect((await f.service.capabilities()).supported).toBe(false);
    expect(f.service.hasActiveProject(schedule.projectId)).toBe(true);
    expect(f.service.ownsCheckout(schedule.projectId, "unknown")).toBe(true);
  });
});
