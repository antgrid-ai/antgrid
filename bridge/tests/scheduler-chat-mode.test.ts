import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Database } from "bun:sqlite";
import { SchedulerService, type ScheduleInput, type SchedulerOptions, type Schedule } from "../src/scheduler";
import { SessionManager, lastUsedChatConfig } from "../src/session-manager";
import { agentRuntime } from "../src/agent-runtime";

const dirs: string[] = [];
const services: SchedulerService[] = [];
const fresh = () => { const dir = mkdtempSync(join(tmpdir(), "antgrid-chat-mode-")); dirs.push(dir); return dir; };
afterEach(() => {
  for (const s of services.splice(0)) s.close();
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});
async function settle() { for (let i = 0; i < 12; i++) await Promise.resolve(); }

const chatInput: ScheduleInput = { name: "Review", projectId: "project", agentId: "claude-code", mode: "chat", prompt: "Review code",
  approvalPolicy: "default", workspace: "shared", cron: "* * * * *", timezone: "UTC", enabled: true, catchUp: "latest" };

function fixture(overrides: Partial<SchedulerOptions> = {}, abDir = fresh()) {
  let time = Date.parse("2026-01-01T00:00:00Z");
  const prepared: Schedule[] = [];
  const options: SchedulerOptions = {
    abDir, desktopOwned: true, now: () => time, timezone: "UTC", supportedAgents: () => [{ agentId: "claude-code", modes: ["terminal", "chat"] }],
    stop: async () => {},
    prepare: async (schedule, _run, bind) => {
      prepared.push(schedule);
      const identity = { sessionId: `session-${prepared.length}`, runtimeGeneration: `generation-${prepared.length}` };
      bind(identity);
      return { ...identity, deliverPrompt: async () => {} };
    }, ...overrides,
  };
  const service = new SchedulerService(options); services.push(service);
  return { service, prepared, abDir, advance: (ms: number) => { time += ms; }, now: () => time };
}

/** Rewinds a closed store to the schema before chat modes shipped, so reopening it runs the migration. */
function downgrade(abDir: string, version = 2): void {
  const db = new Database(join(abDir, "scheduler", "scheduler.db"));
  try { db.exec(`PRAGMA user_version = ${version}`); } finally { db.close(); }
}

describe("chatMode normalisation", () => {
  test("is kept on a chat schedule and cleared by a null patch", async () => {
    const f = fixture();
    const made = await f.service.create({ ...chatInput, chatMode: "plan" });
    expect(made.chatMode).toBe("plan");
    const cleared = await f.service.update(made.id, { chatMode: null });
    expect(cleared.chatMode).toBeUndefined();
    expect("chatMode" in f.service.schedules()[0]!).toBe(false);
  });

  test("is dropped when the schedule becomes terminal or bypass, and never stored for them", async () => {
    const f = fixture();
    const made = await f.service.create({ ...chatInput, chatMode: "plan" });
    expect((await f.service.update(made.id, { approvalPolicy: "bypass" })).chatMode).toBeUndefined();
    const again = await f.service.create({ ...chatInput, name: "Again", chatMode: "plan" });
    expect((await f.service.update(again.id, { mode: "terminal" })).chatMode).toBeUndefined();
    expect((await f.service.create({ ...chatInput, name: "Terminal", mode: "terminal", chatMode: "auto" })).chatMode).toBeUndefined();
    expect((await f.service.create({ ...chatInput, name: "Bypass", approvalPolicy: "bypass", chatMode: "auto" })).chatMode).toBeUndefined();
  });

  test("an edit to it counts as an execution change for authorship", async () => {
    const f = fixture();
    const made = await f.service.create(chatInput, { author: { kind: "device", deviceId: "phone-a" } });
    const edited = await f.service.update(made.id, { chatMode: "plan" }, { author: { kind: "device", deviceId: "phone-b" } });
    expect(edited.authorDeviceId).toBe("phone-b");
  });

  test("a change during preparation skips the obsolete run", async () => {
    let release!: () => void;
    const barrier = new Promise<void>((resolve) => { release = resolve; });
    let deliveries = 0;
    const f = fixture({ prepare: async (_schedule, _run, bind) => {
      const identity = { sessionId: "session", runtimeGeneration: "generation" };
      bind(identity); await barrier; return { ...identity, deliverPrompt: async () => { deliveries++; } };
    } });
    const made = await f.service.create({ ...chatInput, chatMode: "default" });
    await f.service.runNow(made.id); await settle();
    await f.service.update(made.id, { chatMode: "plan" });
    release(); await settle();
    expect(f.service.runs()[0]!.status).toBe("skipped");
    expect(deliveries).toBe(0);
  });
});

describe("capabilities", () => {
  test("list claude-code's modes for its chat mode only", async () => {
    const f = fixture({ supportedAgents: () => [{ agentId: "claude-code", modes: ["terminal", "chat"] }, { agentId: "codex", modes: ["terminal", "chat"] },
      { agentId: "cursor-agent", modes: ["terminal"] }] });
    const { chatModes } = await f.service.capabilities();
    expect(Object.keys(chatModes ?? {})).toEqual(["claude-code"]);
    expect(chatModes!["claude-code"]!.map((m) => m.id)).toEqual(["default", "auto", "acceptEdits", "plan"]);
    expect(JSON.stringify(chatModes)).not.toContain("gated");
  });
});

describe("carry-over from the pre-mode store", () => {
  const seed = async (overrides: Partial<ScheduleInput>[] = [{}]) => {
    const dir = fresh();
    const f = fixture({}, dir);
    const made: Schedule[] = [];
    for (const [i, over] of overrides.entries()) made.push(await f.service.create({ ...chatInput, name: `S${i}`, ...over }));
    f.service.close();
    downgrade(dir);
    return { dir, made };
  };

  test("marks only chat schedules that are not bypass", async () => {
    const { dir } = await seed([{}, { mode: "terminal" }, { approvalPolicy: "bypass" }]);
    const f = fixture({}, dir);
    expect(f.service.schedules().map((s) => [s.name, s.chatModeCarryOver === true])).toEqual([["S0", true], ["S1", false], ["S2", false]]);
  });

  test("a deleted schedule is not marked", async () => {
    const dir = fresh();
    const f = fixture({}, dir);
    const made = await f.service.create(chatInput);
    await f.service.delete(made.id);
    f.service.close();
    downgrade(dir);
    expect(fixture({}, dir).service.store.schedules(true)[0]!.chatModeCarryOver).toBeUndefined();
  });

  test("a fresh store marks nothing, and neither does reopening a current one", async () => {
    const dir = fresh();
    const f = fixture({}, dir);
    expect(f.service.schedules()).toHaveLength(0);
    await f.service.create(chatInput);
    f.service.close();
    expect(fixture({}, dir).service.schedules()[0]!.chatModeCarryOver).toBeUndefined();
  });

  test("resolves the last-used mode, clears the marker, and leaves updatedAt and the author alone", async () => {
    // Authored on a phone and last edited by an agent, so an app-authored update() would visibly re-stamp both.
    const dir = fresh();
    const seeding = fixture({}, dir);
    const made = await seeding.service.create(chatInput, { author: { kind: "device", deviceId: "phone-a" } });
    await seeding.service.update(made.id, { prompt: "Review code again" }, { author: { kind: "agent", sessionId: "planner", sessionName: "Planner" } });
    const seeded = seeding.service.schedules()[0]!;
    expect(seeded).toMatchObject({ authorDeviceId: "phone-a", editedBySessionName: "Planner" });
    seeding.service.close();
    downgrade(dir);
    // Later than the seed, but short of the next occurrence, so tick() itself writes nothing.
    const later = seeded.updatedAt + 30_000;
    const f = fixture({ resolveChatModeCarryOver: async () => "auto", now: () => later }, dir);
    expect(f.service.schedules()[0]!.chatModeCarryOver).toBe(true);
    f.service.start();
    await f.service.tick();
    expect(f.service.schedules()[0]).toEqual({ ...seeded, chatMode: "auto" });
  });

  test("an agent or project edit during the pass resolves again for the new agent", async () => {
    const agents = () => [{ agentId: "claude-code", modes: ["terminal", "chat"] as ("terminal" | "chat")[] },
      { agentId: "codex", modes: ["terminal", "chat"] as ("terminal" | "chat")[] }];
    const dir = fresh();
    const seeding = fixture({ supportedAgents: agents }, dir);
    const made = await seeding.service.create(chatInput);
    seeding.service.close();
    downgrade(dir);
    let resolveClaude!: (mode: string) => void;
    const asked: string[] = [];
    const f = fixture({ supportedAgents: agents, resolveChatModeCarryOver: (schedule) => {
      asked.push(schedule.agentId);
      return schedule.agentId === "claude-code" ? new Promise<string>((resolve) => { resolveClaude = resolve; }) : Promise.resolve(undefined);
    } }, dir);
    f.service.start();
    await settle();
    await f.service.update(made.id, { agentId: "codex" });
    resolveClaude("auto");
    await f.service.tick();
    expect(asked).toEqual(["claude-code", "codex"]);
    const after = f.service.schedules()[0]!;
    expect(after).toMatchObject({ agentId: "codex" });
    expect(after.chatMode).toBeUndefined();
    expect(after.chatModeCarryOver).toBeUndefined();
  });

  test("an unresolvable or modeless config clears the marker and leaves the mode unset", async () => {
    for (const resolve of [async () => undefined, async (): Promise<string> => { throw new Error("unreadable"); }]) {
      const { dir } = await seed();
      const f = fixture({ resolveChatModeCarryOver: resolve }, dir);
      f.service.start();
      await f.service.tick();
      const after = f.service.schedules()[0]!;
      expect(after.chatMode).toBeUndefined();
      expect(after.chatModeCarryOver).toBeUndefined();
    }
  });

  test("a crash between the migration and the pass resolves at the next start", async () => {
    const { dir } = await seed();
    fixture({}, dir).service.close();
    const f = fixture({ resolveChatModeCarryOver: async () => "acceptEdits" }, dir);
    expect(f.service.schedules()[0]!.chatModeCarryOver).toBe(true);
    f.service.start();
    await f.service.tick();
    expect(f.service.schedules()[0]).toMatchObject({ chatMode: "acceptEdits" });
  });

  test("a marked schedule is not dispatched until the pass has finished", async () => {
    const { dir } = await seed();
    let resolveMode!: (mode: string) => void;
    const pending = new Promise<string>((resolve) => { resolveMode = resolve; });
    const f = fixture({ resolveChatModeCarryOver: () => pending }, dir);
    f.service.start();
    f.advance(120_000);
    const ticking = f.service.tick();
    await settle();
    expect(f.prepared).toHaveLength(0);
    resolveMode("auto");
    await ticking; await settle();
    expect(f.prepared).toHaveLength(1);
    expect(f.prepared[0]!.chatMode).toBe("auto");
  });

  test("an explicit edit made during the pass wins over the carried-over mode", async () => {
    const { dir, made } = await seed();
    let resolveMode!: (mode: string) => void;
    const pending = new Promise<string>((resolve) => { resolveMode = resolve; });
    const f = fixture({ resolveChatModeCarryOver: () => pending }, dir);
    f.service.start();
    await f.service.update(made[0]!.id, { chatMode: "plan" });
    resolveMode("auto");
    await f.service.tick();
    expect(f.service.schedules()[0]).toMatchObject({ chatMode: "plan" });
    expect(f.service.schedules()[0]!.chatModeCarryOver).toBeUndefined();
  });
});

describe("scheduled chat launch", () => {
  function persistedConfig(storeDir: string, sessionId: string): Record<string, string> | undefined {
    const file = JSON.parse(readFileSync(join(storeDir, "agents", "p", "sessions.json"), "utf8")) as { sessions: { id: string; config?: Record<string, string> }[] };
    return file.sessions.find((s) => s.id === sessionId)?.config;
  }
  const manager = (root: string) => new SessionManager({
    projectId: "p", projectPath: root, storeDir: root, terminalManager: {} as any,
    agentSpec: { command: "codex", name: "codex" }, agentRuntime, sendMessage: () => {},
  });
  const spec = { scheduleId: "s", name: "Nightly", agentId: "codex", mode: "chat" as const, approvalPolicy: "default" as const, workspace: "shared" as const };

  test("takes the schedule's mode over the last-used one, keeps the other inherited keys, and has no mode when unset", async () => {
    const root = fresh();
    const m = manager(root);
    const old = m.create("old", { tool: "codex", mode: "chat" });
    m.setSessionConfig(old.id, "mode", "auto");
    m.setSessionConfig(old.id, "model", "big");

    const pinned = await m.prepareScheduledSession({ ...spec, chatMode: "plan" }, async () => {});
    m.flushNow();
    expect(persistedConfig(root, pinned.sessionId)).toEqual({ mode: "plan", model: "big" });

    const unset = await m.prepareScheduledSession({ ...spec, scheduleId: "t", name: "Other" }, async () => {});
    m.flushNow();
    expect(persistedConfig(root, unset.sessionId)).toEqual({ model: "big" });
  });

  test("a scheduled run's mode never becomes the user's next chat's mode", async () => {
    const root = fresh();
    const m = manager(root);
    const own = m.create("own", { tool: "codex", mode: "chat" });
    m.setSessionConfig(own.id, "mode", "default");
    m.setSessionConfig(own.id, "model", "big");
    // The scheduled entries must be strictly newer, or the tie keeps the user's own chat as "last used" anyway.
    await Bun.sleep(5);
    await m.prepareScheduledSession({ ...spec, chatMode: "auto" }, async () => {});
    await m.prepareScheduledSession({ ...spec, scheduleId: "t", name: "Unpinned" }, async () => {});
    const next = m.create("next", { tool: "codex", mode: "chat" });
    m.flushNow();
    expect(persistedConfig(root, next.id)).toEqual({ mode: "default", model: "big" });
  });

  test("a schedule with a mode and nothing to inherit still gets its mode", async () => {
    const root = fresh();
    const m = manager(root);
    const prepared = await m.prepareScheduledSession({ ...spec, chatMode: "plan" }, async () => {});
    m.flushNow();
    expect(persistedConfig(root, prepared.sessionId)).toEqual({ mode: "plan" });
  });
});

describe("lastUsedChatConfig", () => {
  const row = (over: Record<string, unknown>) => ({ archived: false, mode: "chat", tool: "claude-code", lastUsedAt: 1, config: { mode: "default" }, ...over });

  test("picks the newest non-archived chat entry of the tool with a config", () => {
    expect(lastUsedChatConfig([
      row({ lastUsedAt: 1, config: { mode: "default" } }),
      row({ lastUsedAt: 5, config: { mode: "auto" } }),
      row({ lastUsedAt: 9, config: { mode: "plan" }, archived: true }),
      row({ lastUsedAt: 9, config: { mode: "plan" }, tool: "codex" }),
      row({ lastUsedAt: 9, config: { mode: "plan" }, mode: "terminal" }),
      row({ lastUsedAt: 9, config: {} }),
    ] as any, "claude-code")).toEqual({ mode: "auto" });
  });

  test("skips scheduler-launched entries only when asked, so the carry-over still reads them", () => {
    const rows = [row({ lastUsedAt: 1, config: { mode: "default" } }), row({ lastUsedAt: 5, config: { mode: "auto" }, launchedByScheduleId: "s" })] as any;
    expect(lastUsedChatConfig(rows, "claude-code")).toEqual({ mode: "auto" });
    expect(lastUsedChatConfig(rows, "claude-code", { skipScheduled: true })).toEqual({ mode: "default" });
  });

  test("the disk reader applies the same selection and reads a missing or broken file as nothing", async () => {
    const root = fresh();
    expect(await SessionManager.readLastUsedChatConfig(root, "p", "codex")).toBeUndefined();
    const m = new SessionManager({ projectId: "p", projectPath: root, storeDir: root, terminalManager: {} as any,
      agentSpec: { command: "codex", name: "codex" }, agentRuntime, sendMessage: () => {} });
    const entry = m.create("c", { tool: "codex", mode: "chat" });
    m.setSessionConfig(entry.id, "mode", "auto");
    m.flushNow();
    expect(await SessionManager.readLastUsedChatConfig(root, "p", "codex")).toEqual({ mode: "auto" });
    writeFileSync(join(root, "agents", "p", "sessions.json"), "{ not json");
    expect(await SessionManager.readLastUsedChatConfig(root, "p", "codex")).toBeUndefined();
  });
});
