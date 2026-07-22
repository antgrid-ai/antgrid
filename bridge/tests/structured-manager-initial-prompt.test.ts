import { describe, it, expect } from "bun:test";
import { StructuredAgentManager, type StructuredDriver } from "../src/structured/structured-manager";
import type { AbMessage } from "../src/protocol";

function makeFakeDriver(overrides: Partial<StructuredDriver> = {}): StructuredDriver & { prompts: string[] } {
  const prompts: string[] = [];
  return {
    prompts,
    start: async () => "agent-native-id",
    prompt: async (text: string) => { prompts.push(text); },
    cancel: async () => false,
    compact: async () => {},
    revert: async () => {},
    setConfig: () => {},
    resolvePermission: () => {},
    resolveQuestion: () => {},
    dispose: () => {},
    ...overrides,
  };
}

function makeManager(driver: StructuredDriver, sent: AbMessage[]) {
  return new StructuredAgentManager({
    driverFactory: () => driver,
    sendMessage: (m) => { sent.push(m); },
    onAgentSession: () => {},
  });
}

describe("startChat initialPrompt", () => {
  // codex is chat-capable (isChatCapableTool) — required or startChat throws.
  it("delivers the prompt via driver.prompt after start", async () => {
    const driver = makeFakeDriver();
    const mgr = makeManager(driver, []);
    await mgr.startChat({ sessionId: "s1", tool: "codex", initialPrompt: "hello agent" });
    expect(driver.prompts).toEqual(["hello agent"]);
  });

  it("no prompt / blank prompt → no prompt() call", async () => {
    const driver = makeFakeDriver();
    const mgr = makeManager(driver, []);
    await mgr.startChat({ sessionId: "s1", tool: "codex" });
    await mgr.stopChat("s1");
    await mgr.startChat({ sessionId: "s1", tool: "codex", initialPrompt: "   " });
    expect(driver.prompts).toEqual([]);
  });

  it("prompt rejection emits agent:error but keeps the driver registered", async () => {
    const sent: AbMessage[] = [];
    const driver = makeFakeDriver({ prompt: async () => { throw new Error("boom"); } });
    const mgr = makeManager(driver, sent);
    await mgr.startChat({ sessionId: "s1", tool: "codex", initialPrompt: "hello" });
    const errs = sent.filter((m) => m.type === "agent:error");
    expect(errs.length).toBe(1);
    // still running: a second startChat is the idempotent early-return, no throw
    await mgr.startChat({ sessionId: "s1", tool: "codex" });
  });

  it("a replayed session:start does not re-deliver the initial prompt", async () => {
    // The relay offline-queue can buffer and replay a `session:start`; without a
    // per-session delivered-guard the duplicate re-enters startChat's already-
    // running exit and injects the same prompt as a SECOND user turn into a live
    // chat. Delivery must be at-most-once per session lifetime.
    const driver = makeFakeDriver();
    const mgr = makeManager(driver, []);
    await mgr.startChat({ sessionId: "s1", tool: "codex", initialPrompt: "hello agent" });
    await mgr.startChat({ sessionId: "s1", tool: "codex", initialPrompt: "hello agent" });
    expect(driver.prompts).toEqual(["hello agent"]);
  });

  it("a genuine restart after stop can deliver a fresh initial prompt again", async () => {
    // The guard is per session LIFETIME: tearing the session down clears it so a
    // later relaunch with its own prompt is not mistaken for a replay.
    const driver = makeFakeDriver();
    const mgr = makeManager(driver, []);
    await mgr.startChat({ sessionId: "s1", tool: "codex", initialPrompt: "first" });
    await mgr.stopChat("s1");
    await mgr.startChat({ sessionId: "s1", tool: "codex", initialPrompt: "second" });
    expect(driver.prompts).toEqual(["first", "second"]);
  });
});
