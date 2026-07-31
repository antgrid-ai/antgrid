import { describe, it, expect } from "bun:test";
import { ClaudeDriver, prettyModelName } from "../src/claude/claude-driver";
import type { ClaudeQueryLike, PromptStreamController } from "../src/claude/spawn-claude";
import type { AbMessage } from "../src/protocol";

describe("prettyModelName", () => {
  it("folds the resolvedModel version into a bare display name", () => {
    expect(prettyModelName("Sonnet", "claude-sonnet-5")).toBe("Sonnet 5");
    expect(prettyModelName("Opus", "claude-opus-4-8")).toBe("Opus 4.8");
  });

  it("drops the trailing 8-digit date stamp", () => {
    expect(prettyModelName("Haiku", "claude-haiku-4-5-20251001")).toBe("Haiku 4.5");
  });

  it("strips the [1m] context marker so the last version segment survives", () => {
    // Regression: claude-opus-4-8[1m] split naively left "8[1m]" (not pure
    // digits) → dropped → "Opus 4". Strip the marker first → "Opus 4.8".
    expect(prettyModelName("Opus", "claude-opus-4-8[1m]")).toBe("Opus 4.8");
  });

  it("leaves a display name that already carries a version untouched", () => {
    expect(prettyModelName("Sonnet 4.5", "claude-sonnet-5")).toBe("Sonnet 4.5");
  });

  it("does not stamp a version onto a synthetic alias row like Default", () => {
    // "Default" resolves to some concrete family — appending "5" would be wrong.
    expect(prettyModelName("Default", "claude-sonnet-5")).toBe("Default");
  });

  it("falls back to the plain name when resolvedModel is missing or version-less", () => {
    expect(prettyModelName("Opus", undefined)).toBe("Opus");
    expect(prettyModelName("Opus", "opus")).toBe("Opus");
  });
});

// Fake query: a manually-driven async iterable + captured control calls.
// `supportedModels` and `initializationResult` are overridable so tests can
// control when model/capability discovery resolves (see the set-config race
// tests and the eager-discovery tests below).
function makeFakeQuery(opts?: {
  supportedModels?: () => Promise<any[]>;
  initializationResult?: () => Promise<any>;
  getContextUsage?: () => Promise<any>;
  setPermissionMode?: (mode: string) => Promise<void>;
  setModel?: (model?: string) => Promise<void>;
  applyFlagSettings?: (settings: any) => Promise<void>;
}) {
  const chunks: any[] = [];
  let push!: (c: any) => void;
  let done = false;
  let failure: unknown = null;
  const waiters: Array<() => void> = [];
  const control = { interrupt: 0, setModel: [] as any[], setPermissionMode: [] as string[], applyFlagSettings: [] as any[] };

  async function* gen() {
    let i = 0;
    while (true) {
      while (i < chunks.length) yield chunks[i++];
      if (done) return;
      if (failure) throw failure;
      await new Promise<void>((r) => waiters.push(r));
    }
  }
  const q: ClaudeQueryLike = Object.assign(gen(), {
    interrupt: async () => { control.interrupt++; },
    setModel: async (m?: string) => { control.setModel.push(m); await opts?.setModel?.(m); },
    setPermissionMode: async (m: string) => { control.setPermissionMode.push(m); await opts?.setPermissionMode?.(m); },
    applyFlagSettings: async (s: any) => { control.applyFlagSettings.push(s); await opts?.applyFlagSettings?.(s); },
    supportedCommands: async () => [],
    supportedModels: opts?.supportedModels ?? (async () => []),
    initializationResult: opts?.initializationResult ?? (async () => ({})),
    ...(opts?.getContextUsage ? { getContextUsage: opts.getContextUsage } : {}),
    close: () => { done = true; waiters.splice(0).forEach((w) => w()); },
  });
  push = (c) => { chunks.push(c); waiters.splice(0).forEach((w) => w()); };
  return {
    q, emit: (c: any) => push(c), control,
    finish: () => { done = true; waiters.splice(0).forEach((w) => w()); },
    // Makes the generator's NEXT iteration throw — used to simulate the SDK's
    // async iterator dying (process crash, transport error) mid-loop.
    fail: (err: unknown) => { failure = err; waiters.splice(0).forEach((w) => w()); },
  };
}

function makeDriver(opts?: {
  fake?: ReturnType<typeof makeFakeQuery>;
  stderrTail?: () => string;
  cwd?: string;
  readTranscript?: (cwd: string, agentSessionId: string) => Promise<any[]> | any[];
}) {
  const sent: AbMessage[] = [];
  const fake = opts?.fake ?? makeFakeQuery();
  let controller!: PromptStreamController;
  const pushed: any[] = [];
  const sessionIds: string[] = [];
  const ended: string[] = [];
  controller = { push: (m) => pushed.push(m), end: (reason) => ended.push(reason), isEnded: () => false };
  const driver = new ClaudeDriver({
    sessionId: "s1",
    sendMessage: (m) => sent.push(m),
    spawn: (_args) => ({ query: fake.q, controller }),
    onSessionId: (id) => sessionIds.push(id),
    ...(opts?.stderrTail ? { stderrTail: opts.stderrTail } : {}),
    ...(opts?.cwd ? { cwd: opts.cwd } : {}),
    ...(opts?.readTranscript ? { readTranscript: opts.readTranscript } : {}),
  });
  return { driver, sent, fake, pushed, sessionIds, ended };
}

// fake.emit() feeds the driver's manually-driven async generator; the
// consumeLoop's `for await` only resumes on a later tick (JS generator
// semantics), so tests must yield back to the event loop before asserting
// on its effects (same pattern as codex-jsonrpc.test.ts's pushInbound()).
async function flush() {
  await new Promise((r) => setImmediate(r));
}

describe("ClaudeDriver.start", () => {
  it("returns immediately from start() and surfaces session_id via onSessionId after init", async () => {
    const { driver, fake, sessionIds } = makeDriver();
    const id = await driver.start();       // must NOT hang — no init emitted yet
    expect(id).toBe("");
    fake.emit({ type: "system", subtype: "init", session_id: "sess-1", model: "claude-opus-4-8",
      slash_commands: ["code-review", "compact"], skills: ["code-review"] });
    await flush();
    expect(sessionIds).toContain("sess-1");
  });

  it("start() does not block on system:init (regression: startup deadlock)", async () => {
    const { driver } = makeDriver();
    // No init chunk is emitted. Before the fix this awaited system:init forever.
    const id = await Promise.race([
      driver.start(),
      new Promise<string>((_r, rej) => setTimeout(() => rej(new Error("start() hung awaiting init")), 1000)),
    ]);
    expect(id).toBe("");
  });

  it("emits agent:capabilities with commands from the init chunk", async () => {
    const { driver, sent, fake } = makeDriver();
    await driver.start();
    fake.emit({ type: "system", subtype: "init", session_id: "sess-1", model: "claude-opus-4-8",
      slash_commands: ["code-review", "security-review"], skills: [] });
    await flush();
    // Both the eager start()-time discovery and onInit's own discovery emit a
    // capabilities frame; find the one carrying commands rather than assuming
    // ordering between the two independent async chains.
    const caps = sent.filter((m) => m.type === "agent:capabilities")
      .find((m) => m.type === "agent:capabilities" && m.commands?.some((c: any) => c.name === "code-review"));
    expect(caps).toBeDefined();
  });

  it("emits real capabilities from initializationResult() before any prompt is sent or init chunk arrives", async () => {
    // initializationResult() is a control-channel RPC that resolves even with
    // nothing pushed to the prompt stream (probe-verified against the real
    // binary), so the real catalog is available at session create — before the
    // first prompt's init chunk — not lazily deferred to it.
    const fake = makeFakeQuery({
      initializationResult: async () => ({
        models: [{ value: "opus", displayName: "Opus" }],
        commands: [{ name: "code-review", description: "Review changes" }],
      }),
    });
    const { driver, sent } = makeDriver({ fake });
    await driver.start(); // no init chunk emitted, no prompt() called
    await flush();
    const caps = sent.filter((m) => m.type === "agent:capabilities")
      .find((m) => m.type === "agent:capabilities" && m.models?.some((mo: any) => mo.id === "opus"));
    expect(caps).toBeDefined();
    if (caps?.type === "agent:capabilities") {
      expect(caps.commands?.some((c: any) => c.name === "code-review")).toBe(true);
    }
  });

  it("keeps early config picks queued when eager discovery fails, applying them once onInit's catalog arrives", async () => {
    // If initializationResult() rejects, the config gate must stay closed so a
    // pick made before the first prompt isn't flushed against an empty catalog
    // and dropped by resolveConfigPick — onInit's discoverModels() is the
    // fallback that populates the catalog and applies the queued pick.
    const models = [{ value: "opus", displayName: "Opus", supportsEffort: true, supportedEffortLevels: ["low", "high"] }];
    const fake = makeFakeQuery({
      initializationResult: async () => { throw new Error("boot failed"); },
      supportedModels: async () => models,
    });
    const { driver, sent } = makeDriver({ fake });
    await driver.start();
    await flush();
    // Pick arrives after the failed eager discovery but before any prompt/init.
    driver.setConfig("model", "opus");
    expect(fake.control.setModel).toEqual([]); // queued, not applied against []
    fake.emit({ type: "system", subtype: "init", session_id: "sess-1", model: "opus", slash_commands: [], skills: [] });
    await flush();
    expect(fake.control.setModel).toEqual(["opus"]); // onInit's catalog flushed it
    const caps = sent.filter((m) => m.type === "agent:capabilities").at(-1);
    if (caps?.type === "agent:capabilities") expect(caps.currentModelId).toBe("opus");
  });

  it("keeps early config picks queued when eager discovery resolves with an EMPTY catalog", async () => {
    // A successful initializationResult() that carries models: [] is not a real
    // catalog — the gate must stay closed exactly as on a throw, or the queued
    // pick would flush against [] and be dropped with no fallback to recover it.
    const models = [{ value: "opus", displayName: "Opus", supportsEffort: true, supportedEffortLevels: ["low", "high"] }];
    const fake = makeFakeQuery({
      initializationResult: async () => ({ models: [] }), // resolves, but empty
      supportedModels: async () => models,
    });
    const { driver, sent } = makeDriver({ fake });
    await driver.start();
    await flush();
    driver.setConfig("model", "opus");
    expect(fake.control.setModel).toEqual([]); // queued, gate stayed closed on []
    fake.emit({ type: "system", subtype: "init", session_id: "sess-1", model: "opus", slash_commands: [], skills: [] });
    await flush();
    expect(fake.control.setModel).toEqual(["opus"]); // onInit's catalog flushed it
    const caps = sent.filter((m) => m.type === "agent:capabilities").at(-1);
    if (caps?.type === "agent:capabilities") expect(caps.currentModelId).toBe("opus");
  });

  it("emits an initial agent:capabilities frame synchronously from start(), before any init chunk", async () => {
    // Regression: the SDK boots its subprocess (and emits system:init) lazily
    // on the first prompt-stream push, so without an early frame nothing
    // reaches the app between session:start and the user's own first prompt —
    // the app's per-session loading indicator (flipped by the first inbound
    // frame; see agent_session_service.dart) stays stuck on a spinner instead
    // of showing "Send a message to start".
    const { driver, sent } = makeDriver();
    await driver.start(); // no init chunk emitted — must still produce a frame
    const caps = sent.find((m) => m.type === "agent:capabilities");
    expect(caps).toBeDefined();
    // The early frame is explicitly not-ready: models aren't discovered yet, so
    // the app shows a loading indicator rather than an empty selector row.
    if (caps?.type === "agent:capabilities") expect(caps.ready).toBe(false);
  });

  it("flips ready:false → ready:true once the model catalog is discovered", async () => {
    const fake = makeFakeQuery({ supportedModels: async () => [{ value: "opus", displayName: "Opus" }] });
    const { driver, sent } = makeDriver({ fake });
    await driver.start();
    const first = sent.find((m) => m.type === "agent:capabilities") as any;
    expect(first.ready).toBe(false);
    expect(first.models).toEqual([]);
    fake.emit({ type: "system", subtype: "init", session_id: "sess-1", model: "opus", slash_commands: [], skills: [] });
    await flush();
    const last = sent.filter((m) => m.type === "agent:capabilities").at(-1) as any;
    expect(last.ready).toBe(true);
    expect(last.models.length).toBeGreaterThan(0);
  });
});

describe("ClaudeDriver turn lifecycle", () => {
  async function started() {
    const h = makeDriver();
    const p = h.driver.start();
    h.fake.emit({ type: "system", subtype: "init", session_id: "sess-1", model: "claude-opus-4-8", slash_commands: [], skills: [] });
    await p;
    return h;
  }

  it("prompt() emits turn-start and pushes a user message", async () => {
    const { driver, sent, pushed } = await started();
    await driver.prompt("hi there");
    expect(sent.find((m) => m.type === "agent:turn-start")).toBeDefined();
    expect(pushed[0].message.content).toBe("hi there");
  });

  it("echoes the user prompt as an agent:item-added(message) — the SDK never does", async () => {
    const { driver, sent } = await started();
    await driver.prompt("hi");
    const added = sent
      .filter((m) => m.type === "agent:item-added")
      .map((m) => (m as any).item)
      .find((i: any) => i.role === "user");
    expect(added?.kind).toBe("message");
    expect(added?.text).toBe("hi");
  });

  it("maps an assistant text block to agent:item-added(message)", async () => {
    const { driver, sent, fake } = await started();
    await driver.prompt("hi");
    fake.emit({ type: "assistant", message: { content: [{ type: "text", text: "hello" }] }, uuid: "u1", session_id: "sess-1" });
    await flush();
    const added = sent
      .filter((m) => m.type === "agent:item-added")
      .map((m) => (m as any).item)
      .find((i: any) => i.role === "assistant");
    expect(added?.kind).toBe("message");
    expect(added?.text).toBe("hello");
  });

  it("maps a tool_use block to a tool_call item with the right toolKind", async () => {
    const { driver, sent, fake } = await started();
    await driver.prompt("run ls");
    fake.emit({ type: "assistant", message: { content: [{ type: "tool_use", id: "t1", name: "Bash", input: { command: "ls" } }] }, uuid: "u2", session_id: "sess-1" });
    await flush();
    const added = sent.filter((m) => m.type === "agent:item-added").map((m) => (m as any).item);
    const tool = added.find((i: any) => i.kind === "tool_call");
    expect(tool?.toolKind).toBe("shell");
  });

  it("keeps title/toolKind when a tool completes (item frames are full replacements)", async () => {
    const { driver, sent, fake } = await started();
    await driver.prompt("run ls");
    fake.emit({ type: "assistant", message: { content: [{ type: "tool_use", id: "t1", name: "Bash", input: { command: "ls" } }] }, uuid: "u2", session_id: "sess-1" });
    await flush();
    fake.emit({ type: "user", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "t1", content: "ok" }] }, session_id: "sess-1" });
    await flush();
    const updated = sent.filter((m) => m.type === "agent:item-updated")
      .map((m) => (m as any).item).find((i: any) => i.itemId === "tool:t1");
    expect(updated?.status).toBe("completed");
    expect(updated?.toolKind).toBe("shell");
    expect(updated?.title).toBe("Bash");
  });

  it("emits agent:turn-end(end_turn) and usage with the model context window", async () => {
    const { driver, sent, fake } = await started();
    await driver.prompt("hi");
    fake.emit({ type: "result", subtype: "success", is_error: false, session_id: "sess-1",
      usage: { input_tokens: 3, output_tokens: 2 },
      modelUsage: {
        "claude-opus-4-8": {
          inputTokens: 3, outputTokens: 2, cacheReadInputTokens: 0, cacheCreationInputTokens: 0,
          webSearchRequests: 0, costUSD: 0.01, contextWindow: 200_000, maxOutputTokens: 32_000,
        },
      },
      duration_ms: 10, num_turns: 1 });
    await flush();
    const end = sent.find((m) => m.type === "agent:turn-end");
    expect(end?.type).toBe("agent:turn-end");
    if (end?.type === "agent:turn-end") expect(end.stopReason).toBe("end_turn");
    const usage = sent.find((m) => m.type === "agent:usage");
    expect(usage?.type).toBe("agent:usage");
    if (usage?.type === "agent:usage") expect(usage.contextWindow).toBe(200_000);
  });

  it("uses the selected model's context window after a live model change", async () => {
    const models = [
      { value: "opus", displayName: "Opus", resolvedModel: "claude-opus-4-8" },
      { value: "sonnet", displayName: "Sonnet", resolvedModel: "claude-sonnet-5" },
    ];
    const fake = makeFakeQuery({
      initializationResult: async () => ({ models }),
      supportedModels: async () => models,
    });
    const { driver, sent } = makeDriver({ fake });
    await driver.start();
    await flush();
    fake.emit({ type: "system", subtype: "init", session_id: "sess-1",
      model: "claude-opus-4-8", slash_commands: [], skills: [] });
    await flush();
    driver.setConfig("model", "sonnet");
    await driver.prompt("hi");
    fake.emit({ type: "result", subtype: "success", is_error: false, session_id: "sess-1",
      usage: { input_tokens: 3, output_tokens: 2 },
      modelUsage: {
        "claude-opus-4-8": { contextWindow: 200_000 },
        "claude-sonnet-5": { contextWindow: 1_000_000 },
      },
      duration_ms: 10, num_turns: 1 });
    await flush();

    const usage = sent.findLast((m) => m.type === "agent:usage");
    expect(usage?.type).toBe("agent:usage");
    if (usage?.type === "agent:usage") expect(usage.contextWindow).toBe(1_000_000);
  });

  it("emits an error agent:turn-end when the consume loop dies mid-turn", async () => {
    const { driver, sent, fake } = await started();
    await driver.prompt("hi");
    // The SDK's async iterator throws (process crash) before any `result` chunk.
    fake.fail(new Error("boom"));
    await flush();
    const end = sent.find((m) => m.type === "agent:turn-end");
    expect(end?.type).toBe("agent:turn-end");
    if (end?.type === "agent:turn-end") {
      expect(end.stopReason).toBe("error");
      expect(end.error).toBeDefined();
    }
  });
});

describe("ClaudeDriver permissions", () => {
  async function started() {
    const h = makeDriver();
    const p = h.driver.start();
    h.fake.emit({ type: "system", subtype: "init", session_id: "sess-1", model: "m", slash_commands: [], skills: [] });
    await p;
    return h;
  }

  it("canUseTool emits agent:permission-request and resolves allow", async () => {
    const { driver, sent } = await started();
    const cut = (driver as any).makeCanUseTool();
    const decision = cut("Bash", { command: "rm x" }, { toolUseID: "t1", requestId: "r1" });
    const req = sent.find((m) => m.type === "agent:permission-request");
    expect(req).toBeDefined();
    const permissionId = (req as any).permissionId;
    driver.resolvePermission(permissionId, "once");
    await expect(decision).resolves.toEqual({ behavior: "allow", updatedInput: { command: "rm x" } });
  });

  it("resolves deny on reject", async () => {
    const { driver, sent } = await started();
    const cut = (driver as any).makeCanUseTool();
    const decision = cut("Bash", { command: "rm x" }, { toolUseID: "t2", requestId: "r2" });
    const permissionId = (sent.find((m) => m.type === "agent:permission-request") as any).permissionId;
    driver.resolvePermission(permissionId, "reject");
    const res = await decision;
    expect(res.behavior).toBe("deny");
  });

  it("offers Always only with SDK suggestions and returns them as updatedPermissions", async () => {
    const { driver, sent } = await started();
    const cut = (driver as any).makeCanUseTool();
    const suggestions = [{ type: "addRules", rules: [{ toolName: "Bash" }], behavior: "allow", destination: "session" }];
    const decision = cut("Bash", { command: "ls" }, { toolUseID: "t9", requestId: "r9", suggestions });
    const req = sent.filter((m) => m.type === "agent:permission-request").at(-1) as any;
    expect(req.options.some((o: any) => o.optionId === "always")).toBe(true);
    driver.resolvePermission(req.permissionId, "always");
    const res = await decision;
    expect(res.behavior).toBe("allow");
    expect(res.updatedPermissions).toEqual(suggestions);
  });

  it("intercepts AskUserQuestion as agent:question, answering via the answers map", async () => {
    const { driver, sent } = await started();
    const cut = (driver as any).makeCanUseTool();
    const decision = cut("AskUserQuestion", { questions: [{ question: "Pick", options: [{ label: "A" }, { label: "B" }] }] }, { toolUseID: "t3", requestId: "r3" });
    const q = sent.find((m) => m.type === "agent:question");
    expect(q).toBeDefined();
    const questionId = (q as any).questionId;
    driver.resolveQuestion(questionId, "0");
    const res = await decision;
    expect(res.behavior).toBe("allow");
    // SDK contract: answers map keyed by question text on updatedInput.
    expect(res.updatedInput.answers).toEqual({ Pick: "A" });
  });
});

describe("ClaudeDriver control", () => {
  async function started() {
    const h = makeDriver();
    const p = h.driver.start();
    h.fake.emit({ type: "system", subtype: "init", session_id: "sess-1", model: "m", slash_commands: [], skills: [] });
    await p;
    return h;
  }

  // The client sends the turnId it renders as open. If its turn-end was lost it
  // names a turn that already finished, and interrupting whatever is live now
  // would kill a turn the user never asked to stop — while the phantom stayed
  // open, since returning true suppresses the manager's reconciling turn-end.
  it("cancel() refuses a stale turnId: the live turn is not interrupted", async () => {
    const { driver, sent, fake } = await started();
    await driver.prompt("long task");
    const live = sent.find((m) => m.type === "agent:turn-start") as any;
    expect(await driver.cancel(`${live.turnId}-stale`)).toBe(false);
    expect(fake.control.interrupt).toBe(0);
    // The live turn is untouched: it still cancels when named, proving the
    // refusal above didn't poison cancelRequested on the way through.
    expect(await driver.cancel(live.turnId)).toBe(true);
    expect(fake.control.interrupt).toBe(1);
  });

  // Older clients (and the manager's own callers) omit it — cancel whatever
  // is live, which is the long-standing behavior.
  it("cancel() with no turnId still interrupts the live turn", async () => {
    const { driver, fake } = await started();
    await driver.prompt("long task");
    expect(await driver.cancel()).toBe(true);
    expect(fake.control.interrupt).toBe(1);
  });

  it("cancel() interrupts and marks the next result as cancelled", async () => {
    const { driver, sent, fake } = await started();
    await driver.prompt("long task");
    await driver.cancel();
    expect(fake.control.interrupt).toBe(1);
    fake.emit({ type: "result", subtype: "success", is_error: false, session_id: "sess-1", usage: {} });
    await flush();
    const end = sent.find((m) => m.type === "agent:turn-end");
    if (end?.type === "agent:turn-end") expect(end.stopReason).toBe("cancelled");
  });

  it("compact() pushes a /compact user message", async () => {
    const { driver, pushed } = await started();
    await driver.compact();
    expect(pushed.at(-1).message.content).toBe("/compact");
  });
});

describe("ClaudeDriver resume", () => {
  it("start(resumeId) that returns a DIFFERENT session_id logs+continues (no throw)", async () => {
    const h = makeDriver();
    const id = await h.driver.start("old-sess");
    // start() resolves immediately, before any init is emitted.
    expect(id).toBe("");
    // SDK reports a fresh id (resume silently failed / forked)
    h.fake.emit({ type: "system", subtype: "init", session_id: "new-sess", model: "m", slash_commands: [], skills: [] });
    await flush();
    // v1 policy: accept the reported id and continue on it (fresh session);
    // the id is surfaced via onSessionId, not start()'s return value.
    expect(h.sessionIds).toContain("new-sess");
  });
});

describe("ClaudeDriver dispose", () => {
  it("resolves once the fake query's iterator completes (close() ends the stream)", async () => {
    const { driver, fake } = makeDriver();
    await driver.start();
    fake.emit({ type: "system", subtype: "init", session_id: "sess-1", model: "m", slash_commands: [], skills: [] });
    await flush();
    // dispose() calls q.close(), which the fake wires to end its generator;
    // if dispose() didn't await the consume loop this would resolve trivially
    // regardless, so the real assertion is that it resolves promptly at all
    // (a regression would hang until the 6s grace timer or abort() fired).
    await Promise.race([
      driver.dispose(),
      new Promise((_r, rej) => setTimeout(() => rej(new Error("dispose() did not resolve")), 2000)),
    ]);
  });

  it("emits no agent:error when the consume loop dies after dispose", async () => {
    const { driver, fake, sent } = makeDriver();
    await driver.start();
    fake.emit({ type: "system", subtype: "init", session_id: "sess-1", model: "m", slash_commands: [], skills: [] });
    await flush();
    await driver.dispose();
    await flush();
    expect(sent.some((m) => m.type === "agent:error")).toBe(false);
  });
});

describe("ClaudeDriver stderr on unexpected loop death", () => {
  it("appends the stderr tail to the emitted agent:error message", async () => {
    const fake = makeFakeQuery();
    const { driver, sent } = makeDriver({ fake, stderrTail: () => "AUTH EXPIRED" });
    await driver.start();
    fake.emit({ type: "system", subtype: "init", session_id: "sess-1", model: "m", slash_commands: [], skills: [] });
    await flush();
    // Simulate the SDK's async iterator throwing (process crash, transport error).
    fake.fail(new Error("boom"));
    await flush();
    const err = sent.find((m) => m.type === "agent:error");
    expect(err).toBeDefined();
    if (err?.type === "agent:error") {
      expect(err.error.message).toContain("AUTH EXPIRED");
    }
  });
});

describe("ClaudeDriver set-config race with model discovery", () => {
  it("applies a setConfig('model', ...) that arrives before supportedModels() resolves", async () => {
    let resolveModels!: (v: any[]) => void;
    const modelsPromise = new Promise<any[]>((r) => { resolveModels = r; });
    // Hold the eager start()-time discovery pending forever so this race is
    // exercised against onInit's discoverModels() specifically (the scenario
    // under test), independent of the separate eager discovery path.
    const fake = makeFakeQuery({
      supportedModels: () => modelsPromise,
      initializationResult: () => new Promise(() => {}),
    });
    const { driver, sent } = makeDriver({ fake });
    const startP = driver.start();
    fake.emit({ type: "system", subtype: "init", session_id: "sess-1", model: "m1", slash_commands: [], skills: [] });
    // onInit is now async and awaits discoverModels(), which is blocked on
    // modelsPromise — give the consume loop a tick to reach that await point.
    await flush();
    // setConfig arrives while capsDiscovered is still false (discovery pending).
    driver.setConfig("model", "m2");
    // Resolve model discovery with the catalog that makes "m2" a valid pick.
    resolveModels([{ value: "m2", displayName: "Model Two" }]);
    await startP;
    await flush();
    const caps = sent.filter((m) => m.type === "agent:capabilities").at(-1);
    expect(caps).toBeDefined();
    if (caps?.type === "agent:capabilities") {
      expect(caps.currentModelId).toBe("m2");
    }
  });
});

describe("ClaudeDriver effort", () => {
  it("surfaces efforts[] on a model from initializationResult()'s supportsEffort/supportedEffortLevels", async () => {
    const fake = makeFakeQuery({
      initializationResult: async () => ({
        models: [{ value: "opus", displayName: "Opus", supportsEffort: true, supportedEffortLevels: ["low", "high", "max"] }],
      }),
    });
    const { driver, sent } = makeDriver({ fake });
    await driver.start();
    await flush();
    const caps = sent.filter((m) => m.type === "agent:capabilities")
      .find((m) => m.type === "agent:capabilities" && m.models?.some((mo: any) => mo.id === "opus"));
    expect(caps).toBeDefined();
    if (caps?.type === "agent:capabilities") {
      expect(caps.models?.find((mo: any) => mo.id === "opus")?.efforts).toEqual(["low", "high", "max"]);
    }
  });

  it("resolves the synthetic \"default\" row to its concrete model at session create, populating the model + effort pills before the first prompt", async () => {
    // Option B: don't surface a bare "Default" — follow the default row's
    // resolvedModel to the concrete alias ("opus") and seed that model's default
    // effort (its 2nd rung). Both must resolve from session create: without a
    // currentModelId the app hides the effort pill and resolveConfigPick rejects
    // effort picks.
    const models = [
      { value: "default", displayName: "Default", resolvedModel: "claude-opus-4-8", supportsEffort: true, supportedEffortLevels: ["low", "high", "max"] },
      { value: "opus", displayName: "Opus", resolvedModel: "claude-opus-4-8", supportsEffort: true, supportedEffortLevels: ["low", "high"] },
    ];
    const fake = makeFakeQuery({ initializationResult: async () => ({ models }) });
    const { driver, sent } = makeDriver({ fake });
    await driver.start();
    await flush();
    const caps = sent.filter((m) => m.type === "agent:capabilities").at(-1);
    expect(caps?.type).toBe("agent:capabilities");
    if (caps?.type === "agent:capabilities") {
      expect(caps.currentModelId).toBe("opus"); // concrete alias, not "default"
      expect(caps.currentEffortId).toBe("high"); // opus's 2nd effort rung
    }
    // The seeded effort was applied to the session up front.
    expect(fake.control.applyFlagSettings).toEqual([{ effortLevel: "high", ultracode: false }]);
  });

  it("maps system:init.model (a resolved wire id) back to the catalog alias for currentModelId", async () => {
    // No "default" row: currentModelId comes from the first prompt's init, whose
    // `model` is the resolved id ("claude-opus-4-8"). It must map to the alias
    // row ("opus") the app looks models up by, not be stored raw (which matches
    // nothing).
    const models = [{ value: "opus", displayName: "Opus", resolvedModel: "claude-opus-4-8", supportsEffort: true, supportedEffortLevels: ["low", "high"] }];
    const fake = makeFakeQuery({ initializationResult: async () => ({ models }), supportedModels: async () => models });
    const { driver, sent } = makeDriver({ fake });
    await driver.start();
    fake.emit({ type: "system", subtype: "init", session_id: "sess-1", model: "claude-opus-4-8", slash_commands: [], skills: [] });
    await flush();
    const caps = sent.filter((m) => m.type === "agent:capabilities").at(-1);
    if (caps?.type === "agent:capabilities") expect(caps.currentModelId).toBe("opus");
  });

  it("surfaces the 2nd effort rung as the model's defaultEffort in the catalog", async () => {
    const models = [{ value: "opus", displayName: "Opus", supportsEffort: true, supportedEffortLevels: ["low", "high", "xhigh", "max"] }];
    const fake = makeFakeQuery({ initializationResult: async () => ({ models }) });
    const { driver, sent } = makeDriver({ fake });
    await driver.start();
    await flush();
    const caps = sent.filter((m) => m.type === "agent:capabilities")
      .find((m) => m.type === "agent:capabilities" && m.models?.some((mo: any) => mo.id === "opus"));
    if (caps?.type === "agent:capabilities") {
      expect(caps.models?.find((mo: any) => mo.id === "opus")?.defaultEffort).toBe("high");
    }
  });

  it("never seeds the appended \"ultracode\" pseudo-rung as a default effort (single-rung xhigh model)", async () => {
    // A model whose only base rung is "xhigh" gains an appended "ultracode"
    // rung, so efforts=["xhigh","ultracode"]. defaultEffort must come from the
    // base levels (base[1] is undefined here) — never "ultracode", which would
    // be applied as a bogus effortLevel that also disables the ultracode flag.
    const models = [{ value: "opus", displayName: "Opus", supportsEffort: true, supportedEffortLevels: ["xhigh"] }];
    const fake = makeFakeQuery({ initializationResult: async () => ({ models }), supportedModels: async () => models });
    const { driver, sent } = makeDriver({ fake });
    await driver.start();
    await flush();
    const caps = sent.filter((m) => m.type === "agent:capabilities").at(-1);
    if (caps?.type === "agent:capabilities") {
      expect(caps.models?.find((mo: any) => mo.id === "opus")?.efforts).toEqual(["xhigh", "ultracode"]);
      expect(caps.models?.find((mo: any) => mo.id === "opus")?.defaultEffort).toBeUndefined();
      expect(caps.currentEffortId).toBeUndefined();
    }
    // No effort was applied (in particular, no bogus {effortLevel:"ultracode"}).
    expect(fake.control.applyFlagSettings).toEqual([]);
  });

  it("re-seeds the default effort for the booted model when system:init reconciles to a different model", async () => {
    // Eager discovery resolves the account default to sonnet (2nd rung
    // "medium") and applies it; the first prompt then boots opus (2nd rung
    // "high"). The seeded effort must re-derive for opus, not stay pinned to
    // sonnet's "medium" (which isn't even in opus's effort list).
    const models = [
      { value: "default", displayName: "Default", resolvedModel: "claude-sonnet-5", supportsEffort: true, supportedEffortLevels: ["low", "medium", "high"] },
      { value: "sonnet", displayName: "Sonnet", resolvedModel: "claude-sonnet-5", supportsEffort: true, supportedEffortLevels: ["low", "medium", "high"] },
      { value: "opus", displayName: "Opus", resolvedModel: "claude-opus-4-8", supportsEffort: true, supportedEffortLevels: ["low", "high"] },
    ];
    const fake = makeFakeQuery({ initializationResult: async () => ({ models }), supportedModels: async () => models });
    const { driver, sent } = makeDriver({ fake });
    await driver.start();
    await flush();
    fake.emit({ type: "system", subtype: "init", session_id: "sess-1", model: "claude-opus-4-8", slash_commands: [], skills: [] });
    await flush();
    const caps = sent.filter((m) => m.type === "agent:capabilities").at(-1);
    if (caps?.type === "agent:capabilities") {
      expect(caps.currentModelId).toBe("opus");
      expect(caps.currentEffortId).toBe("high"); // opus's default, not sonnet's "medium"
    }
    // Seeded sonnet's "medium" eagerly, then re-applied opus's "high" on reconcile.
    expect(fake.control.applyFlagSettings).toEqual([
      { effortLevel: "medium", ultracode: false },
      { effortLevel: "high", ultracode: false },
    ]);
  });

  it("falls back to the first concrete model so currentModelId is never blank when the default row can't resolve", async () => {
    // The "default" row lacks a resolvedModel, so Option B can't follow it to a
    // concrete model — but currentModelId must still be set (the app hides the
    // effort pill and rejects effort picks without one). Fall back to the first
    // concrete row rather than leaving it blank.
    const models = [
      { value: "default", displayName: "Default", supportsEffort: true, supportedEffortLevels: ["low", "high"] },
      { value: "opus", displayName: "Opus", supportsEffort: true, supportedEffortLevels: ["low", "high"] },
    ];
    const fake = makeFakeQuery({ initializationResult: async () => ({ models }) });
    const { driver, sent } = makeDriver({ fake });
    await driver.start();
    await flush();
    const caps = sent.filter((m) => m.type === "agent:capabilities").at(-1);
    if (caps?.type === "agent:capabilities") expect(caps.currentModelId).toBe("opus");
  });

  it("falls back to the \"default\" row when it is the only catalog entry, rather than leaving currentModelId blank", async () => {
    const models = [{ value: "default", displayName: "Default", supportsEffort: true, supportedEffortLevels: ["low", "high"] }];
    const fake = makeFakeQuery({ initializationResult: async () => ({ models }) });
    const { driver, sent } = makeDriver({ fake });
    await driver.start();
    await flush();
    const caps = sent.filter((m) => m.type === "agent:capabilities").at(-1);
    if (caps?.type === "agent:capabilities") expect(caps.currentModelId).toBe("default");
  });

  it("does not override an explicit constructor model with the default row", async () => {
    const models = [
      { value: "default", displayName: "Default", supportsEffort: true, supportedEffortLevels: ["low", "high"] },
      { value: "opus", displayName: "Opus", supportsEffort: true, supportedEffortLevels: ["low", "high"] },
    ];
    const fake = makeFakeQuery({ initializationResult: async () => ({ models }) });
    const sent: AbMessage[] = [];
    const controller: PromptStreamController = { push: () => {}, end: () => {}, isEnded: () => false };
    const driver = new ClaudeDriver({
      sessionId: "s1", model: "opus",
      sendMessage: (m) => sent.push(m),
      spawn: () => ({ query: fake.q, controller }),
    });
    await driver.start();
    await flush();
    const caps = sent.filter((m) => m.type === "agent:capabilities").at(-1);
    if (caps?.type === "agent:capabilities") expect(caps.currentModelId).toBe("opus");
  });

  it("setConfig('effort', ...) applies via applyFlagSettings and echoes currentEffortId", async () => {
    // onInit's own discoverModels() (supportedModels()) runs after the eager
    // start()-time discovery and overwrites capModels — override both so they
    // agree, mirroring the real binary where both RPCs report the same catalog.
    const models = [{ value: "opus", displayName: "Opus", supportsEffort: true, supportedEffortLevels: ["low", "high"] }];
    const fake = makeFakeQuery({
      initializationResult: async () => ({ models }),
      supportedModels: async () => models,
    });
    const { driver, sent } = makeDriver({ fake });
    await driver.start();
    fake.emit({ type: "system", subtype: "init", session_id: "sess-1", model: "opus", slash_commands: [], skills: [] });
    await flush();
    driver.setConfig("effort", "high");
    // Leading entry is the seeded default (opus's 2nd rung == "high"); the pick
    // re-applies the same level.
    expect(fake.control.applyFlagSettings).toEqual([
      { effortLevel: "high", ultracode: false },
      { effortLevel: "high", ultracode: false },
    ]);
    const caps = sent.filter((m) => m.type === "agent:capabilities").at(-1);
    if (caps?.type === "agent:capabilities") expect(caps.currentEffortId).toBe("high");
  });

  it("clears effort via applyFlagSettings(null) when switching to a model that doesn't support it", async () => {
    const models = [
      { value: "opus", displayName: "Opus", supportsEffort: true, supportedEffortLevels: ["low", "high"] },
      { value: "haiku", displayName: "Haiku" },
    ];
    const fake = makeFakeQuery({
      initializationResult: async () => ({ models }),
      supportedModels: async () => models,
    });
    const { driver, sent } = makeDriver({ fake });
    await driver.start();
    fake.emit({ type: "system", subtype: "init", session_id: "sess-1", model: "opus", slash_commands: [], skills: [] });
    await flush();
    driver.setConfig("effort", "high");
    driver.setConfig("model", "haiku");
    // Leading entry is the seeded default for opus; then the explicit high pick;
    // then the clear when switching to effort-less haiku.
    expect(fake.control.applyFlagSettings).toEqual([
      { effortLevel: "high", ultracode: false },
      { effortLevel: "high", ultracode: false },
      { effortLevel: null, ultracode: false },
    ]);
    const caps = sent.filter((m) => m.type === "agent:capabilities").at(-1);
    if (caps?.type === "agent:capabilities") expect(caps.currentEffortId).toBeUndefined();
  });

  it("offers \"ultracode\" as the top effort rung for xhigh-capable models and applies it via the ultracode flag", async () => {
    // ultracode is a session flag (xhigh + dynamic workflows), not an
    // effortLevel value — it must be gated on xhigh and set on its own key.
    const models = [
      { value: "opus", displayName: "Opus", supportsEffort: true, supportedEffortLevels: ["low", "high", "xhigh", "max"] },
      { value: "haiku", displayName: "Haiku" },
    ];
    const fake = makeFakeQuery({ initializationResult: async () => ({ models }), supportedModels: async () => models });
    const { driver, sent } = makeDriver({ fake });
    await driver.start();
    fake.emit({ type: "system", subtype: "init", session_id: "sess-1", model: "opus", slash_commands: [], skills: [] });
    await flush();
    const caps = sent.filter((m) => m.type === "agent:capabilities").at(-1);
    if (caps?.type === "agent:capabilities") {
      // Appended after the catalog levels; haiku (no xhigh) never gets it.
      expect(caps.models?.find((mo: any) => mo.id === "opus")?.efforts).toEqual(["low", "high", "xhigh", "max", "ultracode"]);
      expect(caps.models?.find((mo: any) => mo.id === "haiku")?.efforts).toBeUndefined();
    }
    driver.setConfig("effort", "ultracode");
    // Leading entry is the seeded default (opus's 2nd rung == "high"); then the
    // ultracode flag (NOT effortLevel: "ultracode").
    expect(fake.control.applyFlagSettings).toEqual([
      { effortLevel: "high", ultracode: false },
      { ultracode: true },
    ]);
    // Dropping back to a concrete level lifts the sticky flag.
    driver.setConfig("effort", "high");
    expect(fake.control.applyFlagSettings.at(-1)).toEqual({ effortLevel: "high", ultracode: false });
    const after = sent.filter((m) => m.type === "agent:capabilities").at(-1);
    if (after?.type === "agent:capabilities") expect(after.currentEffortId).toBe("high");
  });
});

describe("ClaudeDriver permission modes", () => {
  it("advertises the \"auto\" permission mode and applies it via setPermissionMode", async () => {
    // Give eager discovery a real catalog so the config gate opens at start()
    // (the real binary always returns one) — mirrors production, where a mode
    // pick before the first prompt applies immediately.
    const fake = makeFakeQuery({ initializationResult: async () => ({ models: [{ value: "opus", displayName: "Opus" }] }) });
    const { driver, sent } = makeDriver({ fake });
    await driver.start();
    await flush();
    const caps = sent.filter((m) => m.type === "agent:capabilities").at(-1);
    expect(caps?.type).toBe("agent:capabilities");
    if (caps?.type === "agent:capabilities") {
      expect(caps.modes?.map((m: any) => m.id)).toContain("auto");
    }
    driver.setConfig("mode", "auto");
    expect(fake.control.setPermissionMode).toContain("auto");
    const after = sent.filter((m) => m.type === "agent:capabilities").at(-1);
    if (after?.type === "agent:capabilities") expect(after.currentModeId).toBe("auto");
  });

  it("survives a CLI control call that rejects the mode as unavailable", async () => {
    // The CLI gates "auto" per-model and answers an unsupported pick with an
    // error verdict, which the SDK surfaces as a rejected setPermissionMode.
    // Unhandled, it reaches the host's process-level unhandledRejection hook
    // and takes down every project on the machine.
    const fake = makeFakeQuery({
      initializationResult: async () => ({ models: [{ value: "opus", displayName: "Opus" }] }),
      setPermissionMode: async (m) => {
        throw new Error(`Cannot set permission mode to ${m}: auto mode unavailable for this model`);
      },
    });
    const { driver } = makeDriver({ fake });
    await driver.start();
    fake.emit({ type: "system", subtype: "init", session_id: "sess-1", model: "m", permissionMode: "default", slash_commands: [], skills: [] });
    await flush();

    const unhandled: unknown[] = [];
    const onUnhandled = (e: unknown) => unhandled.push(e);
    process.on("unhandledRejection", onUnhandled);
    try {
      driver.setConfig("mode", "auto");
      await flush();
      await flush();
    } finally {
      process.off("unhandledRejection", onUnhandled);
    }
    expect(unhandled).toEqual([]);
  });

  it("rolls the mode selection back to the live one when the CLI rejects it", async () => {
    const fake = makeFakeQuery({
      initializationResult: async () => ({ models: [{ value: "opus", displayName: "Opus" }] }),
      setPermissionMode: async (m) => {
        if (m === "auto") throw new Error("auto mode unavailable for this model");
      },
    });
    const { driver, sent } = makeDriver({ fake });
    await driver.start();
    fake.emit({ type: "system", subtype: "init", session_id: "sess-1", model: "m", permissionMode: "default", slash_commands: [], skills: [] });
    await flush();

    driver.setConfig("mode", "auto");
    await flush();
    await flush();
    // The optimistic write must not outlive the rejection — otherwise the app's
    // pill reads "Auto" while the session is still on default.
    const caps = sent.filter((m) => m.type === "agent:capabilities").at(-1);
    expect(caps?.type === "agent:capabilities" && caps.currentModeId).toBe("default");
  });

  it("keeps an accepted mode selection applied", async () => {
    const fake = makeFakeQuery({ initializationResult: async () => ({ models: [{ value: "opus", displayName: "Opus" }] }) });
    const { driver, sent } = makeDriver({ fake });
    await driver.start();
    fake.emit({ type: "system", subtype: "init", session_id: "sess-1", model: "m", permissionMode: "default", slash_commands: [], skills: [] });
    await flush();

    driver.setConfig("mode", "plan");
    await flush();
    await flush();
    const caps = sent.filter((m) => m.type === "agent:capabilities").at(-1);
    expect(caps?.type === "agent:capabilities" && caps.currentModeId).toBe("plan");
  });
});

describe("ClaudeDriver permissionMode seeding", () => {
  it("seeds currentModeId from the init chunk's permissionMode", async () => {
    const { driver, sent, fake } = makeDriver();
    await driver.start();
    fake.emit({ type: "system", subtype: "init", session_id: "sess-1", model: "m", permissionMode: "default", slash_commands: [], skills: [] });
    await flush();
    // The eager start()-time discovery and onInit's own discovery race
    // independently; find the frame carrying currentModeId (only onInit seeds
    // it) rather than assuming ordering between the two.
    const caps = sent.filter((m) => m.type === "agent:capabilities")
      .find((m) => m.type === "agent:capabilities" && m.currentModeId != null);
    expect(caps).toBeDefined();
    if (caps?.type === "agent:capabilities") {
      expect(caps.currentModeId).toBe("default");
    }
  });

  it("re-emits capabilities when a system:status chunk reports a live mode change", async () => {
    const { driver, sent, fake } = makeDriver();
    await driver.start();
    fake.emit({ type: "system", subtype: "init", session_id: "sess-1", model: "m", permissionMode: "default", slash_commands: [], skills: [] });
    await flush();
    // CLI-side toggle (e.g. shift+tab into plan mode) — arrives as a status chunk.
    fake.emit({ type: "system", subtype: "status", status: null, permissionMode: "plan", session_id: "sess-1" });
    await flush();
    const caps = sent.filter((m) => m.type === "agent:capabilities").at(-1);
    expect(caps?.type === "agent:capabilities" && caps.currentModeId).toBe("plan");
  });

  it("does not re-emit for a status chunk whose mode is unchanged", async () => {
    const { driver, sent, fake } = makeDriver();
    await driver.start();
    fake.emit({ type: "system", subtype: "init", session_id: "sess-1", model: "m", permissionMode: "default", slash_commands: [], skills: [] });
    await flush();
    const before = sent.filter((m) => m.type === "agent:capabilities").length;
    // A compaction status chunk (no mode change) must not spam a capabilities frame.
    fake.emit({ type: "system", subtype: "status", status: "compacting", permissionMode: "default", session_id: "sess-1" });
    await flush();
    const after = sent.filter((m) => m.type === "agent:capabilities").length;
    expect(after).toBe(before);
  });
});

describe("ClaudeDriver getTranscriptSnapshot", () => {
  async function started() {
    const h = makeDriver();
    const p = h.driver.start();
    h.fake.emit({ type: "system", subtype: "init", session_id: "sess-1", model: "m", slash_commands: [], skills: [] });
    await p;
    return h;
  }

  it("returns [] before any turn", async () => {
    const { driver } = await started();
    expect(await driver.getTranscriptSnapshot()).toEqual([]);
  });

  it("replays a completed turn's user + assistant text as a resumed-turn frame set", async () => {
    const { driver, fake } = await started();
    await driver.prompt("hi");
    fake.emit({ type: "assistant", message: { content: [{ type: "text", text: "hello" }] }, uuid: "u1", session_id: "sess-1" });
    await flush();
    fake.emit({ type: "result", subtype: "success", is_error: false, session_id: "sess-1", usage: { input_tokens: 1, output_tokens: 1 } });
    await flush();

    const snap = await driver.getTranscriptSnapshot();
    expect(snap.some((m) => m.type === "agent:turn-start")).toBe(true);
    expect(snap.some((m) => m.type === "agent:turn-end")).toBe(true);
    const added = snap.filter((m) => m.type === "agent:item-added").map((m) => (m as any).item);
    const userItem = added.find((i: any) => i.role === "user");
    const assistantItem = added.find((i: any) => i.role === "assistant");
    expect(userItem?.text).toBe("hi");
    expect(assistantItem?.text).toBe("hello");
  });

  it("includes itemId-anchored usage for a live assistant message", async () => {
    const { driver, fake } = await started();
    await driver.prompt("hi");
    fake.emit({
      type: "assistant",
      uuid: "au-1",
      message: {
        id: "api-9",
        role: "assistant",
        usage: { input_tokens: 5, output_tokens: 50, cache_read_input_tokens: 100, cache_creation_input_tokens: 0 },
        content: [{ type: "text", text: "answer" }],
      },
    });
    fake.emit({ type: "result", subtype: "success", usage: { input_tokens: 5, output_tokens: 50 } });
    await flush();
    const snap = await driver.getTranscriptSnapshot();
    const frames = snap.filter((m: any) => m.type === "agent:usage") as any[];
    expect(frames.length).toBe(1);
    expect(frames[0].itemId).toBe("msg:au-1");
    expect(frames[0].last.outputTokens).toBe(50);
  });

  it("backfills from the on-disk transcript on a cold resume (empty in-memory history)", async () => {
    const calls: Array<[string, string]> = [];
    const readTranscript = async (cwd: string, id: string) => {
      calls.push([cwd, id]);
      return [
        { type: "user", message: { role: "user", content: "prior question" }, uuid: "d1" },
        { type: "assistant", message: { role: "assistant", content: [{ type: "text", text: "prior answer" }] }, uuid: "d2" },
      ];
    };
    const h = makeDriver({ cwd: "/proj", readTranscript });
    // Cold resume: start(resumeId) sets the disk anchor before any init/turn.
    await h.driver.start("sess-cold");

    const snap = await h.driver.getTranscriptSnapshot();
    // Read at start (resume-replay) and again for the pull snapshot — both for
    // the same (cwd, resumeId).
    expect(calls.length).toBeGreaterThanOrEqual(1);
    expect(calls.every((c) => c[0] === "/proj" && c[1] === "sess-cold")).toBe(true);
    const texts = snap.filter((m) => m.type === "agent:item-added").map((m) => (m as any).item.text);
    expect(texts).toContain("prior question");
    expect(texts).toContain("prior answer");
  });

  it("pushes on-disk history as a resumed turn during start(resumeId) (codex/opencode parity)", async () => {
    const readTranscript = async () => [
      { type: "user", message: { role: "user", content: "old q" }, uuid: "d1" },
      { type: "assistant", message: { role: "assistant", content: [{ type: "text", text: "old a" }] }, uuid: "d2" },
    ];
    const h = makeDriver({ cwd: "/proj", readTranscript });
    await h.driver.start("sess-cold");
    // Replay frames must be emitted onto the stream at start time — the app
    // renders resumed history from this push, not from a later snapshot pull.
    // They travel as ONE frame: sent per-item, a long transcript overruns the
    // relay's per-pair rate limit and the dropped tail takes agent:turn-end
    // with it, leaving the app rendering a turn that never closes.
    const replays = h.sent.filter((m) => m.type === "agent:transcript-replay");
    expect(replays.length).toBe(1);
    const frames = (replays[0] as any).frames as any[];
    const added = frames.filter((f) => f.type === "agent:item-added").map((f) => f.item);
    expect(frames.some((f) => f.type === "agent:turn-start")).toBe(true);
    expect(added.find((i: any) => i.role === "user")?.text).toBe("old q");
    expect(added.find((i: any) => i.role === "assistant")?.text).toBe("old a");
    expect(frames.some((f) => f.type === "agent:turn-end")).toBe(true);
    // Atomicity is the whole point: nothing about the replay may reach the wire
    // as a standalone frame that the relay could drop independently.
    expect(h.sent.some((m) => m.type === "agent:item-added")).toBe(false);
  });

  it("does not push a replay when starting fresh (no resumeId)", async () => {
    let called = 0;
    const readTranscript = async () => { called++; return []; };
    const h = makeDriver({ cwd: "/proj", readTranscript });
    await h.driver.start(); // no resumeId
    expect(called).toBe(0);
    expect(h.sent.some((m) => m.type === "agent:item-added")).toBe(false);
  });

  it("falls back to in-memory replay when the on-disk transcript is empty", async () => {
    const readTranscript = async () => [];
    const h = makeDriver({ cwd: "/proj", readTranscript });
    const p = h.driver.start();
    h.fake.emit({ type: "system", subtype: "init", session_id: "sess-1", model: "m", slash_commands: [], skills: [] });
    await p;
    await h.driver.prompt("live");
    h.fake.emit({ type: "assistant", message: { content: [{ type: "text", text: "reply" }] }, uuid: "u1", session_id: "sess-1" });
    await flush();
    h.fake.emit({ type: "result", subtype: "success", is_error: false, session_id: "sess-1" });
    await flush();

    const snap = await h.driver.getTranscriptSnapshot();
    const texts = snap.filter((m) => m.type === "agent:item-added").map((m) => (m as any).item.text);
    expect(texts).toContain("live");
    expect(texts).toContain("reply");
  });
});

describe("ClaudeDriver early context usage", () => {
  it("emits agent:usage from eager initialization before any prompt or system:init", async () => {
    const fake = makeFakeQuery({
      initializationResult: async () => ({ models: [{ value: "opus", displayName: "Opus" }] }),
      getContextUsage: async () => ({ totalTokens: 30000, maxTokens: 200000, rawMaxTokens: 200000, percentage: 15 }),
    });
    const { driver, sent } = makeDriver({ fake });
    await driver.start();
    await flush();
    await flush();
    const frames = sent.filter((m: any) => m.type === "agent:usage") as any[];
    expect(frames.length).toBe(1);
    expect(frames[0].contextWindow).toBe(200000);
    expect(frames[0].last.totalTokens).toBe(30000);
    expect(frames[0].itemId).toBeUndefined();
  });

  it("refreshes eager context usage when system:init arrives", async () => {
    let request = 0;
    const fake = makeFakeQuery({
      getContextUsage: async () => ({
        totalTokens: request++ === 0 ? 10000 : 30000,
        maxTokens: 200000,
      }),
    });
    const { driver, sent } = makeDriver({ fake });
    await driver.start();
    await flush();
    await flush();
    fake.emit({ type: "system", subtype: "init", session_id: "sess-1", slash_commands: [] });
    await flush();
    await flush();

    const frames = sent.filter((m: any) => m.type === "agent:usage") as any[];
    expect(frames.length).toBe(2);
    expect(frames[0].last.totalTokens).toBe(10000);
    expect(frames[1].last.totalTokens).toBe(30000);
  });

  it("fail-soft: a rejecting getContextUsage emits nothing and does not crash", async () => {
    const fake = makeFakeQuery({ getContextUsage: async () => { throw new Error("not supported"); } });
    const { driver, sent } = makeDriver({ fake });
    await driver.start();
    fake.emit({ type: "system", subtype: "init", session_id: "sess-1", slash_commands: [] });
    await flush();
    await flush();
    expect(sent.filter((m: any) => m.type === "agent:usage").length).toBe(0);
  });

  it("fail-soft: a query without getContextUsage emits nothing", async () => {
    const { driver, sent, fake } = makeDriver();
    await driver.start();
    fake.emit({ type: "system", subtype: "init", session_id: "sess-1", slash_commands: [] });
    await flush();
    await flush();
    expect(sent.filter((m: any) => m.type === "agent:usage").length).toBe(0);
  });

  it("keeps the newest context response when re-init requests resolve out of order", async () => {
    const pending: Array<(value: any) => void> = [];
    const fake = makeFakeQuery({
      getContextUsage: () => new Promise((resolve) => pending.push(resolve)),
    });
    const { driver, sent } = makeDriver({ fake });
    await driver.start();
    await flush();
    await flush();
    expect(pending.length).toBe(1); // eager initializationResult request
    fake.emit({ type: "system", subtype: "init", session_id: "sess-1", slash_commands: [] });
    await flush();
    await flush();
    fake.emit({ type: "system", subtype: "init", session_id: "sess-1", slash_commands: [] });
    await flush();
    await flush();
    expect(pending.length).toBe(3);

    pending[2]({ totalTokens: 10000, maxTokens: 200000 });
    await flush();
    pending[1]({ totalTokens: 50000, maxTokens: 200000 });
    pending[0]({ totalTokens: 90000, maxTokens: 200000 });
    await flush();

    const frames = sent.filter((m: any) => m.type === "agent:usage") as any[];
    expect(frames.length).toBe(1);
    expect(frames[0].last.totalTokens).toBe(10000);
  });

  it("does not emit when a pending context request resolves after dispose", async () => {
    let resolveContext!: (value: any) => void;
    const fake = makeFakeQuery({
      getContextUsage: () => new Promise((resolve) => { resolveContext = resolve; }),
    });
    const { driver, sent } = makeDriver({ fake });
    await driver.start();
    await flush();
    await flush();

    await driver.dispose();
    resolveContext({ totalTokens: 30000, maxTokens: 200000 });
    await flush();

    expect(sent.filter((m: any) => m.type === "agent:usage").length).toBe(0);
  });
});

describe("ClaudeDriver compaction", () => {
  async function started() {
    const h = makeDriver();
    const p = h.driver.start();
    h.fake.emit({ type: "system", subtype: "init", session_id: "sess-1", model: "m", slash_commands: [], skills: [] });
    await p;
    return h;
  }

  it("tolerates status + compact_boundary + a mid-stream re-init + a plain-text synthetic user chunk without erroring", async () => {
    const { driver, sent, fake, sessionIds } = await started();
    await driver.prompt("hi");
    fake.emit({ type: "assistant", message: { content: [{ type: "text", text: "hello" }] }, uuid: "u1", session_id: "sess-1" });
    await flush();
    await driver.compact();

    fake.emit({ type: "system", subtype: "status", status: "compacting", session_id: "sess-1" });
    await flush();
    fake.emit({ type: "system", subtype: "status", status: null, compact_result: "success", session_id: "sess-1" });
    await flush();
    // Mid-stream re-init on the SAME session id (probe-verified behavior).
    fake.emit({ type: "system", subtype: "init", session_id: "sess-1", model: "m", slash_commands: [], skills: [] });
    await flush();
    fake.emit({
      type: "system", subtype: "compact_boundary", session_id: "sess-1", uuid: "cb1",
      compact_metadata: { trigger: "manual", pre_tokens: 30243, post_tokens: 3071, duration_ms: 18394 },
    });
    await flush();
    // Post-compaction synthetic user chunk: plain text, not tool_result blocks.
    fake.emit({ type: "user", message: { role: "user", content: "This session is being continued from a previous conversation..." }, session_id: "sess-1" });
    await flush();

    expect(sent.some((m) => m.type === "agent:error")).toBe(false);
    // Only the compaction item frame should have come out of this sequence
    // (plus whatever the initial "hi"/"hello" turn produced) — no bogus items
    // from the status/plain-text-user chunks.
    const addedKinds = sent.filter((m) => m.type === "agent:item-added").map((m) => (m as any).item.kind);
    expect(addedKinds).toContain("compaction");
    expect(addedKinds.every((k) => k === "message" || k === "compaction")).toBe(true);
    // Re-init reported the same session id — not a double/different persist.
    expect(sessionIds.filter((id) => id === "sess-1").length).toBeGreaterThanOrEqual(1);
    expect(sessionIds.every((id) => id === "sess-1")).toBe(true);
  });

  it("does not log a resume mismatch again on the mid-stream re-init after compaction", async () => {
    const h = makeDriver();
    const p = h.driver.start("old-sess");
    h.fake.emit({ type: "system", subtype: "init", session_id: "new-sess", model: "m", slash_commands: [], skills: [] });
    await p;
    await flush();
    // A second init (e.g. post-compaction) reporting a DIFFERENT id than the
    // original resumeRequested must not re-trigger mismatch handling — the
    // check only applies to the first init after start(resumeId).
    h.fake.emit({ type: "system", subtype: "init", session_id: "yet-another-sess", model: "m", slash_commands: [], skills: [] });
    await flush();
    expect(h.sessionIds).toEqual(["new-sess", "yet-another-sess"]);
  });
});

// The driver applies picks fire-and-forget and the host turns any unhandled
// rejection into a full shutdown (index.ts), so the rollback path itself must be
// total — including when the transport write inside it fails.
describe("ClaudeDriver pick rollback", () => {
  // `failWrite` decides, per agent:capabilities frame (n = 1-based), whether the
  // transport write throws — letting each test fail only the frame it cares about.
  function makeDriverWithWrites(
    fake: ReturnType<typeof makeFakeQuery>,
    failWrite: (n: number) => boolean,
  ) {
    const controller: PromptStreamController = { push: () => {}, end: () => {}, isEnded: () => false };
    let n = 0;
    return new ClaudeDriver({
      sessionId: "s1",
      sendMessage: (m) => { if (m.type === "agent:capabilities" && failWrite(++n)) throw new Error("transport closed"); },
      spawn: (_args) => ({ query: fake.q, controller }),
    });
  }

  async function withUnhandledWatch(fn: () => Promise<void>): Promise<unknown[]> {
    const unhandled: unknown[] = [];
    const onUnhandled = (e: unknown) => unhandled.push(e);
    process.on("unhandledRejection", onUnhandled);
    try { await fn(); } finally { process.off("unhandledRejection", onUnhandled); }
    return unhandled;
  }

  it("survives a transport write that fails while rolling a rejected pick back", async () => {
    const fake = makeFakeQuery({
      initializationResult: async () => ({ models: [{ value: "opus", displayName: "Opus" }] }),
      setPermissionMode: async () => { throw new Error("auto mode unavailable for this model"); },
    });
    // Only the rollback's re-emit fails. setConfig's own optimistic emit is
    // synchronous and surfaces through the manager as agent:error, not a crash.
    let failNow = false;
    const driver = makeDriverWithWrites(fake, () => failNow);
    await driver.start();
    await flush();
    const unhandled = await withUnhandledWatch(async () => {
      driver.setConfig("mode", "auto");
      failNow = true;
      await flush(); await flush();
    });
    expect(unhandled).toEqual([]);
  });

  it("survives a transport write that fails in the discovery tail", async () => {
    const fake = makeFakeQuery({ initializationResult: async () => ({ models: [{ value: "opus", displayName: "Opus" }] }) });
    // start()'s early "loading" frame must still land; the later one is the tail's.
    const driver = makeDriverWithWrites(fake, (n) => n > 1);
    const unhandled = await withUnhandledWatch(async () => {
      await driver.start();
      await flush(); await flush();
    });
    expect(unhandled).toEqual([]);
  });

  it("does not let a stale rejection clobber a newer pick the CLI accepted", async () => {
    let rejectAuto!: (e: unknown) => void;
    const fake = makeFakeQuery({
      initializationResult: async () => ({ models: [{ value: "opus", displayName: "Opus" }] }),
      setPermissionMode: (m) =>
        m === "auto" ? new Promise<void>((_res, rej) => { rejectAuto = rej; }) : Promise.resolve(),
    });
    const { driver, sent } = makeDriver({ fake });
    await driver.start();
    fake.emit({ type: "system", subtype: "init", session_id: "sess-1", model: "m", permissionMode: "default", slash_commands: [], skills: [] });
    await flush();
    driver.setConfig("mode", "auto");  // in flight, will be rejected
    driver.setConfig("mode", "plan");  // accepted while auto is still pending
    await flush();
    rejectAuto(new Error("auto mode unavailable for this model"));
    await flush(); await flush();
    const last = sent.filter((m) => m.type === "agent:capabilities").at(-1);
    expect(last?.type === "agent:capabilities" && last.currentModeId).toBe("plan");
  });
});

describe("ClaudeDriver rate-limit snapshot", () => {
  // The CLI emits rate_limit_event with `rate_limit_info.resetsAt` in epoch
  // SECONDS (verified in the 2.1.220 binary: `new Date(e*1000)`), separately
  // from the failing result chunk — hence the cache.
  async function started() {
    const h = makeDriver();
    const p = h.driver.start();
    h.fake.emit({ type: "system", subtype: "init", session_id: "sess-1", model: "claude-opus-4-8", slash_commands: [], skills: [] });
    await p;
    return h;
  }

  function failedResult() {
    return { type: "result", subtype: "error_during_execution", is_error: true, session_id: "sess-1",
      errors: ["Claude usage limit reached"], duration_ms: 10, num_turns: 1 };
  }

  function lastTurnEnd(sent: AbMessage[]) {
    const end = sent.findLast((m) => m.type === "agent:turn-end");
    return end?.type === "agent:turn-end" ? end : undefined;
  }

  it("classifies a failed turn as rate_limited with a positive retryAfterMs", async () => {
    const { driver, sent, fake } = await started();
    await driver.prompt("hi");
    const resetsAtSec = Math.floor(Date.now() / 1000) + 600;
    fake.emit({ type: "rate_limit_event", session_id: "sess-1", uuid: "u1",
      rate_limit_info: { status: "rejected", resetsAt: resetsAtSec, rateLimitType: "five_hour" } });
    await flush();
    fake.emit(failedResult());
    await flush();
    const end = lastTurnEnd(sent);
    expect(end?.stopReason).toBe("error");
    expect(end?.error?.category).toBe("rate_limited");
    expect(end?.error?.retryable).toBe(true);
    expect(end?.error?.retryAfterMs).toBeGreaterThan(0);
    expect(end?.error?.retryAfterMs).toBeLessThanOrEqual(600_000);
  });

  it("reports the limit with no retryAfterMs when the event carried no reset time", async () => {
    const { driver, sent, fake } = await started();
    await driver.prompt("hi");
    fake.emit({ type: "rate_limit_event", session_id: "sess-1", uuid: "u1",
      rate_limit_info: { status: "rejected" } });
    await flush();
    fake.emit(failedResult());
    await flush();
    const end = lastTurnEnd(sent);
    expect(end?.error?.category).toBe("rate_limited");
    expect(end?.error?.retryAfterMs).toBeUndefined();
  });

  it("leaves a failure unclassified when no limit was reported", async () => {
    const { driver, sent, fake } = await started();
    await driver.prompt("hi");
    fake.emit(failedResult());
    await flush();
    expect(lastTurnEnd(sent)?.error?.category).toBe("unknown");
  });

  it("ignores a status that is not a rejection", async () => {
    const { driver, sent, fake } = await started();
    await driver.prompt("hi");
    fake.emit({ type: "rate_limit_event", session_id: "sess-1", uuid: "u1",
      rate_limit_info: { status: "allowed_warning", resetsAt: Math.floor(Date.now() / 1000) + 600 } });
    await flush();
    fake.emit(failedResult());
    await flush();
    expect(lastTurnEnd(sent)?.error?.category).toBe("unknown");
  });

  it("forgets a limit whose window has already closed", async () => {
    const { driver, sent, fake } = await started();
    await driver.prompt("hi");
    // A rejection whose reset time is in the past: the window it describes is
    // over, so a later failure is some other problem. Classifying it as a limit
    // would hand the handler a wake time already gone.
    fake.emit({ type: "rate_limit_event", session_id: "sess-1", uuid: "u1",
      rate_limit_info: { status: "rejected", resetsAt: Math.floor(Date.now() / 1000) - 60 } });
    await flush();
    fake.emit(failedResult());
    await flush();
    expect(lastTurnEnd(sent)?.error?.category).toBe("unknown");
  });

  it("forgets the limit once a turn succeeds", async () => {
    const { driver, sent, fake } = await started();
    await driver.prompt("hi");
    fake.emit({ type: "rate_limit_event", session_id: "sess-1", uuid: "u1",
      rate_limit_info: { status: "rejected", resetsAt: Math.floor(Date.now() / 1000) + 600 } });
    await flush();
    fake.emit({ type: "result", subtype: "success", is_error: false, session_id: "sess-1", duration_ms: 5, num_turns: 1 });
    await flush();
    await driver.prompt("again");
    fake.emit(failedResult());
    await flush();
    expect(lastTurnEnd(sent)?.error?.category).toBe("unknown");
  });

  it("classifies a mid-turn stream death during a limit window as rate_limited", async () => {
    const { driver, sent, fake } = await started();
    await driver.prompt("hi");
    fake.emit({ type: "rate_limit_event", session_id: "sess-1", uuid: "u1",
      rate_limit_info: { status: "rejected", resetsAt: Math.floor(Date.now() / 1000) + 600 } });
    await flush();
    fake.fail(new Error("boom"));
    await flush();
    const end = lastTurnEnd(sent);
    expect(end?.stopReason).toBe("error");
    expect(end?.error?.category).toBe("rate_limited");
  });
});
