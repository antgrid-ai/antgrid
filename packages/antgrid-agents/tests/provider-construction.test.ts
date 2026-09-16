import { describe, expect, it } from "bun:test";
import { createDriver as createCodexDriver } from "../src/agents/codex/driver";
import { createDriver as createOpencodeDriver } from "../src/agents/opencode/driver";
import type { CodexEndpoint } from "../src/agents/codex/chat-backend";
import type { OpencodeClientLike } from "../src/agents/opencode/chat-backend";
import type { DriverCtx } from "../src/agents/types";
import { createAgentRunScope } from "../src/run-scope";

function context(): DriverCtx {
  return {
    scope: createAgentRunScope({ runId: "test", isCurrent: () => true, emit: () => {} }),
    sessionId: "s", projectId: "p", projectPath: "/checkout", approvalPolicy: "default",
    chatAugment: () => ({ args: [], env: {} }), send: () => {},
    onAgentSession: () => {}, emitUpdateCheck: () => {},
  };
}

function endpoint(overrides: Partial<CodexEndpoint> = {}): CodexEndpoint {
  return {
    request: async (method) => method === "thread/start" ? { thread: { id: "native" } } : {},
    notify: () => {}, onNotification: () => {}, onRequest: () => {}, onClose: () => {}, dispose: () => {},
    ...overrides,
  };
}

describe("owned provider startup", () => {
  it("constructs Codex without allocating and starts only once", async () => {
    let spawns = 0;
    let augments = 0;
    let kills = 0;
    const ctx = context();
    ctx.chatAugment = () => { augments++; return { args: [], env: {} }; };
    const driver = createCodexDriver(ctx, () => {
      spawns++;
      return { endpoint: endpoint(), failureDiagnosis: Promise.resolve(null), kill: async () => { kills++; } };
    });
    expect(spawns).toBe(0);
    expect(augments).toBe(0);
    expect(typeof driver.stopTask).toBe("function");
    expect(await driver.start()).toBeUndefined();
    expect(await driver.start()).toBeUndefined();
    expect(spawns).toBe(1);
    expect(augments).toBe(1);
    await driver.dispose();
    await driver.dispose();
    expect(kills).toBe(1);
    await expect(driver.start()).rejects.toThrow("disposed");
    expect(spawns).toBe(1);
  });

  it("can dispose Codex before startup without ever spawning", async () => {
    let spawns = 0;
    const driver = createCodexDriver(context(), () => {
      spawns++;
      return { endpoint: endpoint(), failureDiagnosis: Promise.resolve(null), kill: async () => {} };
    });
    await driver.dispose();
    await expect(driver.start()).rejects.toThrow("disposed");
    expect(spawns).toBe(0);
  });

  it("retains ownership when Codex handler registration fails after allocation", async () => {
    let kills = 0;
    const driver = createCodexDriver(context(), () => ({
      endpoint: endpoint({ onNotification: () => { throw new Error("registration failed"); } }),
      failureDiagnosis: Promise.resolve(null), kill: async () => { kills++; },
    }));
    await expect(driver.start()).rejects.toThrow("registration failed");
    await driver.dispose();
    expect(kills).toBe(1);
  });

  it("does not allocate Codex for an already-cancelled startup", async () => {
    let spawns = 0;
    const driver = createCodexDriver(context(), () => {
      spawns++;
      return { endpoint: endpoint(), failureDiagnosis: Promise.resolve(null), kill: async () => {} };
    });
    const abort = new AbortController();
    abort.abort(new Error("cancelled"));
    await expect(driver.start(undefined, abort.signal)).rejects.toThrow("cancelled");
    await driver.dispose();
    expect(spawns).toBe(0);
  });

  it("never starts an OpenCode server after cold disposal", async () => {
    let spawns = 0;
    const driver = createOpencodeDriver(context(), async () => { spawns++; throw new Error("unexpected spawn"); });
    await driver.dispose();
    driver.resolveQuestion("late", "answer");
    await expect(driver.start()).rejects.toThrow("disposed");
    await Promise.resolve();
    expect(spawns).toBe(0);
  });

  it("waits for an allocated OpenCode server and closes it without sending queued requests", async () => {
    let release!: (value: { client: OpencodeClientLike }) => void;
    const spawned = new Promise<{ client: OpencodeClientLike }>((resolve) => { release = resolve; });
    let spawns = 0;
    let requests = 0;
    let closes = 0;
    const client = {
      createSession: async () => { requests++; return "native"; },
      listCommands: async () => { requests++; return []; },
      listAgents: async () => { requests++; return []; },
      listProviders: async () => { requests++; return { all: [], default: {}, connected: [] }; },
      events: async function* () { requests++; },
      dispose: async () => { closes++; },
    } as unknown as OpencodeClientLike;
    const driver = createOpencodeDriver(context(), () => { spawns++; return spawned; });
    expect(spawns).toBe(0);
    const starting = driver.start();
    const outcome = starting.then(() => null, (error: unknown) => error);
    let finished = false;
    const stopping = Promise.resolve(driver.dispose()).then(() => { finished = true; });
    await Promise.resolve();
    expect(finished).toBe(false);
    release({ client });
    await stopping;
    expect(await outcome).toBeInstanceOf(Error);
    expect(String(await outcome)).toContain("disposed");
    expect(spawns).toBe(1);
    expect(closes).toBe(1);
    expect(requests).toBe(0);
  });
});
