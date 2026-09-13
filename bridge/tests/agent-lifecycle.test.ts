import { describe, expect, it } from "bun:test";
import { StructuredAgentManager, type StructuredDriver, type DriverRunContext } from "../src/structured/structured-manager";
import { OpencodeDriver, type OpencodeClientLike } from "../../packages/antgrid-agents/src/agents/opencode/chat-backend";
import { waitServerGone } from "../../packages/antgrid-agents/src/agents/opencode/spawn";
import { createMessage, type AbMessage } from "../src/protocol";

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

function driver(overrides: Partial<StructuredDriver> = {}): StructuredDriver {
  return {
    start: async () => "native", prompt: async () => {}, cancel: async () => false,
    compact: async () => {}, revert: async () => {}, setConfig: () => {},
    resolvePermission: () => {}, resolveQuestion: () => {}, dispose: () => {},
    ...overrides,
  };
}

describe("agent run lifecycle", () => {
  it("reports unsupported optional conversation operations", async () => {
    const sent: AbMessage[] = [];
    const manager = new StructuredAgentManager({
      driverFactory: () => driver({ compact: undefined, revert: undefined }),
      sendMessage: (message) => sent.push(message), onAgentSession: () => {},
    });
    await manager.startChat({ sessionId: "s", tool: "opencode" });
    await manager.handleAgentMessage(createMessage("agent:session-action", { sessionId: "s", action: "compact" }));
    await manager.handleAgentMessage(createMessage("agent:session-action", { sessionId: "s", action: "revert" }));
    const errors = sent.filter((message) => message.type === "agent:error");
    expect(errors.map((message) => message.error.message)).toEqual([
      "This agent does not support compact", "This agent does not support revert",
    ]);
    await manager.disposeAll();
  });

  it("closes callbacks captured by a factory that throws", async () => {
    let captured: ((message: AbMessage) => void) | undefined;
    let run: DriverRunContext | undefined;
    const sent: AbMessage[] = [];
    const identities: string[] = [];
    const manager = new StructuredAgentManager({
      driverFactory: (_, __, send, ___, ____, context) => {
        captured = send;
        run = context;
        throw new Error("factory failed");
      },
      sendMessage: (message) => sent.push(message), onAgentSession: (_, id) => identities.push(id),
    });
    await expect(manager.startChat({ sessionId: "s", tool: "opencode" })).rejects.toThrow("factory failed");
    captured?.(createMessage("agent:capabilities", { sessionId: "s", ready: true }));
    run?.onAgentSession("late");
    expect(run?.signal.aborted).toBe(true);
    expect(sent).toEqual([]);
    expect(identities).toEqual([]);
  });

  it("stops a pending start immediately without registering it or delivering its prompt", async () => {
    const startup = deferred<string>();
    let signal: AbortSignal | undefined;
    let disposed = 0;
    let prompted = 0;
    const identities: string[] = [];
    const manager = new StructuredAgentManager({
      driverFactory: () => driver({
        start: async (_, cancellation) => { signal = cancellation; return startup.promise; },
        dispose: () => { disposed++; }, prompt: async () => { prompted++; },
      }),
      sendMessage: () => {}, onAgentSession: (_, id) => identities.push(id),
    });
    const starting = manager.startChat({ sessionId: "s", tool: "opencode", initialPrompt: "hello" });
    await manager.stopChat("s");
    await starting;
    expect(signal?.aborted).toBe(true);
    expect(disposed).toBe(1);
    startup.resolve("late-native");
    await Promise.resolve();
    expect(identities).toEqual([]);
    expect(prompted).toBe(0);
  });

  it("keeps failed teardown observable and refuses a replacement", async () => {
    let factories = 0;
    const manager = new StructuredAgentManager({
      driverFactory: () => { factories++; return driver({ dispose: async () => { throw new Error("still alive"); } }); },
      sendMessage: () => {}, onAgentSession: () => {},
    });
    await manager.startChat({ sessionId: "s", tool: "opencode" });
    await expect(manager.stopChat("s")).rejects.toThrow("still alive");
    await expect(manager.stopChat("s")).rejects.toThrow("still alive");
    await expect(manager.startChat({ sessionId: "s", tool: "opencode" })).rejects.toThrow("still alive");
    expect(factories).toBe(1);
  });

  it("handles synchronous dispose failure as a rejected teardown", async () => {
    const manager = new StructuredAgentManager({
      driverFactory: () => driver({ dispose: () => { throw new Error("dispose failed"); } }),
      sendMessage: () => {}, onAgentSession: () => {},
    });
    await manager.startChat({ sessionId: "s", tool: "opencode" });
    await expect(manager.stopChat("s")).rejects.toThrow("dispose failed");
  });

  it("closes the old driver's output sink across a restart", async () => {
    const sinks: Array<(message: AbMessage) => void> = [];
    const sent: AbMessage[] = [];
    const manager = new StructuredAgentManager({
      driverFactory: (_, __, send) => { sinks.push(send); return driver(); },
      sendMessage: (message) => sent.push(message), onAgentSession: () => {},
    });
    await manager.startChat({ sessionId: "s", tool: "opencode" });
    await manager.stopChat("s");
    await manager.startChat({ sessionId: "s", tool: "opencode" });
    sent.length = 0;
    sinks[0](createMessage("agent:capabilities", { sessionId: "s", ready: true }));
    expect(sent).toEqual([]);
    sinks[1](createMessage("agent:capabilities", { sessionId: "s", ready: true }));
    expect(sent).toHaveLength(1);
    await manager.disposeAll();
  });

  it("rejects identity callbacks and prompt failures from a replaced run", async () => {
    const runs: DriverRunContext[] = [];
    const identities: string[] = [];
    const sent: AbMessage[] = [];
    const prompt = deferred<void>();
    const manager = new StructuredAgentManager({
      driverFactory: (_, __, ___, ____, _____, run) => {
        runs.push(run!);
        return driver({ prompt: () => prompt.promise });
      },
      sendMessage: (message) => sent.push(message), onAgentSession: (_, id) => identities.push(id),
    });
    await manager.startChat({ sessionId: "s", tool: "opencode" });
    const prompting = manager.handleAgentMessage(createMessage("agent:prompt", { sessionId: "s", requestId: "p", text: "hello" }));
    await manager.stopChat("s");
    await manager.startChat({ sessionId: "s", tool: "opencode" });
    sent.length = 0;
    identities.length = 0;
    runs[0].onAgentSession("old-native");
    prompt.reject(new Error("old prompt failed"));
    await prompting;
    expect(sent).toEqual([]);
    expect(identities).toEqual([]);
    expect(runs[0].isCurrent()).toBe(false);
    runs[1].onAgentSession("new-native");
    expect(identities).toEqual(["new-native"]);
    await manager.disposeAll();
  });

  it("finishes replay cleanup before a queued restart can publish its catalog", async () => {
    const disposal = deferred<void>();
    let factories = 0;
    let replay: AbMessage | undefined;
    const manager = new StructuredAgentManager({
      driverFactory: (_, __, send) => {
        factories++;
        return driver({
          start: async () => { send(createMessage("agent:capabilities", { sessionId: "s", ready: true })); return "native"; },
          dispose: factories === 1 ? () => disposal.promise : () => {},
        });
      },
      sendMessage: (message) => { replay = message; }, onAgentSession: () => {},
      dropSessionReplay: () => { replay = undefined; },
    });
    await manager.startChat({ sessionId: "s", tool: "opencode" });
    const stopping = manager.stopChat("s");
    disposal.resolve();
    await Promise.resolve();
    await manager.startChat({ sessionId: "s", tool: "opencode" });
    await stopping;
    expect(replay).toMatchObject({ type: "agent:capabilities", ready: true });
    await manager.disposeAll();
  });

  it("keeps the teardown gate closed when final replay cleanup fails", async () => {
    let drops = 0;
    let factories = 0;
    const manager = new StructuredAgentManager({
      driverFactory: () => { factories++; return driver(); },
      sendMessage: () => {}, onAgentSession: () => {},
      dropSessionReplay: () => { if (++drops === 2) throw new Error("replay cleanup failed"); },
    });
    await manager.startChat({ sessionId: "s", tool: "opencode" });
    await expect(manager.stopChat("s")).rejects.toThrow("replay cleanup failed");
    await expect(manager.startChat({ sessionId: "s", tool: "opencode" })).rejects.toThrow("replay cleanup failed");
    expect(factories).toBe(1);
  });

  it("suppresses OpenCode capability discovery after disposal completes", async () => {
    const discovery = deferred<any[]>();
    let disposed = 0;
    const client = {
      createSession: async () => "native", events: async function* () {},
      listCommands: () => discovery.promise,
      listAgents: async () => [],
      listProviders: async () => ({ all: [], default: {}, connected: [] }),
      dispose: async () => { disposed++; },
    } as unknown as OpencodeClientLike;
    const sent: AbMessage[] = [];
    const session = new OpencodeDriver({ sessionId: "s", client, sendMessage: (message) => sent.push(message) });
    await session.start();
    await session.dispose();
    await session.dispose();
    sent.length = 0;
    discovery.resolve([{ name: "late" }]);
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(sent).toEqual([]);
    expect(disposed).toBe(1);
    await expect(session.prompt("late prompt")).rejects.toThrow("disposed");
  });
});

describe("OpenCode teardown confirmation", () => {
  it("accepts a refused connection", async () => {
    const probe = async () => { throw Object.assign(new Error("refused"), { code: "ECONNREFUSED" }); };
    await waitServerGone("http://unused", 10, probe);
  });

  it("does not mistake a request timeout for a stopped server", async () => {
    const probe = async () => { throw new DOMException("slow server", "TimeoutError"); };
    await expect(waitServerGone("http://unused", 1, probe)).rejects.toThrow("timed out");
  });

  it("rejects when the server continues answering", async () => {
    const probe = async () => new Response("alive");
    await expect(waitServerGone("http://unused", 1, probe)).rejects.toThrow("timed out");
  });
});
