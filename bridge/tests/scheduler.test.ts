import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Database } from "bun:sqlite";
import { CRON_PRESETS, nextOccurrences, validateCron, validateTimezone, SchedulerService, SchedulerStore,
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
  approvalPolicy: "default", workspace: "worktree", cron: "* * * * *", timezone: "UTC", enabled: true };
async function settle() { for (let i = 0; i < 12; i++) await Promise.resolve(); }
function fixture(overrides: Partial<SchedulerOptions> = {}, abDir = fresh()) {
  let time = Date.parse("2026-01-01T00:00:00Z");
  let sequence = 0;
  const delivered: string[] = [];
  const prepared: { checkoutId?: string }[] = [];
  const options: SchedulerOptions = {
    abDir, desktopOwned: true, now: () => time, timezone: "UTC", supportedAgents: () => [{ agentId: "claude", modes: ["terminal", "chat"] }],
    authorize: () => null, stop: async () => {},
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
  test("renaming preserves execution authorization while execution edits replace it", async () => {
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
  test("enforces overlap and capacity without queueing", async () => {
    const f = fixture(); const a = await f.service.create(input); const b = await f.service.create({ ...input, name: "Second" }); const c = await f.service.create({ ...input, name: "Third" });
    await f.service.runNow(a.id); await f.service.runNow(b.id); await settle();
    expect((await f.service.runNow(a.id)).reason).toContain("still active");
    expect((await f.service.runNow(c.id)).reason).toContain("two active");
    await settle(); expect(f.delivered).toHaveLength(2);
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
  test("restart interrupts uncertain launches and consolidates missed interval", async () => {
    const dir = fresh(); const f = fixture({}, dir); const schedule = await f.service.create(input);
    await f.service.runNow(schedule.id); await settle(); f.service.close();
    const time = f.now() + 7 * 24 * 60 * 60_000;
    const next = fixture({ now: () => time }, dir);
    expect(next.service.runs().map((r) => r.status).sort()).toEqual(["interrupted", "skipped"]);
    await next.service.tick(); await settle(); expect(next.delivered).toHaveLength(0);
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
  test("rechecks authorization after preparation before prompt delivery", async () => {
    let checks = 0;
    const stopped: string[] = [];
    const f = fixture({ authorize: () => ++checks === 1 ? null : "Remote access was disabled", stop: async (run) => { stopped.push(run.sessionId!); } });
    const schedule = await f.service.create(input, "phone"); await f.service.runNow(schedule.id); await settle();
    expect(f.service.runs()[0]!.status).toBe("skipped"); expect(f.delivered).toHaveLength(0);
    expect(stopped).toEqual(["session-1"]);
  });
  test("remote manual run of a local schedule rechecks the initiating device", async () => {
    let remoteChecks = 0;
    const f = fixture({ authorize: (schedule) => schedule.authorDeviceId === "phone" && ++remoteChecks > 1 ? "Remote access revoked" : null });
    const schedule = await f.service.create(input); await f.service.runNow(schedule.id, "phone"); await settle();
    expect(f.service.runs()[0]!.status).toBe("skipped"); expect(f.delivered).toHaveLength(0);
    expect(f.service.schedules()[0]!.authorDeviceId).toBeNull();
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
  test("long suspend records one missed interval without replay", async () => {
    const f = fixture(); await f.service.create(input); f.advance(365 * 24 * 60 * 60_000);
    await f.service.tick(); await settle(); expect(f.service.runs()).toHaveLength(1);
    expect(f.service.runs()[0]!.trigger).toBe("missed"); expect(f.delivered).toHaveLength(0);
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
