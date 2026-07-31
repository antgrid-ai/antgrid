import { describe, it, expect } from "bun:test";
import { OpencodeDriver, type OpencodeClientLike, type OpencodeEvent } from "../src/opencode/opencode-driver";
import type { DriverLifecycleEvent } from "../src/agents/types";
import type { AbMessage } from "../src/protocol";

// Fake client: a manual event queue + recorded calls. events() yields whatever
// the test pushes, then ends when `end()` is called.
function makeFakeClient(
  rootIdOrOverrides: string | Partial<OpencodeClientLike> = "ses_root",
) {
  const rootId = typeof rootIdOrOverrides === "string" ? rootIdOrOverrides : "ses_root";
  const overrides = typeof rootIdOrOverrides === "string" ? {} : rootIdOrOverrides;
  const calls: Array<{ m: string; args: any[] }> = [];
  let push!: (e: OpencodeEvent) => void;
  let done!: () => void;
  const queue: OpencodeEvent[] = [];
  let waiters: Array<{
    res: (v: IteratorResult<OpencodeEvent>) => void;
    rej: (e: unknown) => void;
  }> = [];
  let ended = false;
  let failure: unknown = null;
  push = (e) => { const w = waiters.shift(); if (w) w.res({ value: e, done: false }); else queue.push(e); };
  done = () => { ended = true; waiters.forEach((w) => w.res({ value: undefined as any, done: true })); waiters = []; };
  // Simulate the opencode server exiting mid-stream: the events() iterator
  // rejects rather than ending cleanly (which is what dispose()/done() does).
  const fail = (err: unknown) => { failure = err; const ws = waiters; waiters = []; ws.forEach((w) => w.rej(err)); };
  const client: OpencodeClientLike = {
    createSession: async (o) => { calls.push({ m: "createSession", args: [o] }); return rootId; },
    messages: async (s) => { calls.push({ m: "messages", args: [s] }); return []; },
    deleteMessage: async (s, messageId) => { calls.push({ m: "deleteMessage", args: [s, messageId] }); },
    prompt: async (s, t, o) => { calls.push({ m: "prompt", args: [s, t, o] }); },
    abort: async (s) => { calls.push({ m: "abort", args: [s] }); },
    summarize: async (s, model) => { calls.push({ m: "summarize", args: [s, model] }); },
    replyPermission: async (s, id, r) => { calls.push({ m: "replyPermission", args: [s, id, r] }); },
    replyQuestion: async (id, a) => { calls.push({ m: "replyQuestion", args: [id, a] }); },
    listCommands: async () => { calls.push({ m: "listCommands", args: [] }); return [
      { name: "review", description: "Review changes", hints: ["$ARGUMENTS"], source: "command", template: "..." },
      { name: "hello-skill", source: "skill", hints: [], template: "..." },
    ]; },
    listAgents: async () => { calls.push({ m: "listAgents", args: [] }); return [
      { name: "build", description: "Default agent", mode: "primary" },
      { name: "plan", mode: "primary" },
      { name: "general", mode: "subagent" },
      { name: "compaction", mode: "primary", hidden: true },
    ]; },
    listProviders: async () => { calls.push({ m: "listProviders", args: [] }); return {
      all: [
        { id: "anthropic", name: "Anthropic", models: {
          "claude-sonnet-5": { id: "claude-sonnet-5", name: "Claude Sonnet 5", variants: { thinking: {} }, limit: { context: 195000, output: 8192 } },
        } },
        { id: "openai", name: "OpenAI", models: { "gpt-5.2": { id: "gpt-5.2", name: "GPT-5.2" } } },
      ],
      default: { anthropic: "claude-sonnet-5" },
      connected: ["anthropic"],
    }; },
    command: async (s: string, o: any) => { calls.push({ m: "command", args: [s, o] }); },
    events: () => ({
      [Symbol.asyncIterator]() {
        return {
          next(): Promise<IteratorResult<OpencodeEvent>> {
            if (queue.length) return Promise.resolve({ value: queue.shift()!, done: false });
            if (failure) return Promise.reject(failure);
            if (ended) return Promise.resolve({ value: undefined as any, done: true });
            return new Promise((res, rej) => waiters.push({ res, rej }));
          },
        };
      },
    }),
    dispose: () => { calls.push({ m: "dispose", args: [] }); done(); },
    ...overrides,
  };
  return { client, calls, push, done, fail, rootId };
}

async function startedDriver(rootId = "ses_root") {
  const fake = makeFakeClient(rootId);
  const sent: AbMessage[] = [];
  const driver = new OpencodeDriver({ sessionId: "s1", client: fake.client, sendMessage: (m) => sent.push(m) });
  await driver.start();
  return { driver, sent, ...fake };
}

// Let the microtask-driven event loop process pushed events.
const tick = () => new Promise((r) => setTimeout(r, 0));

describe("OpencodeDriver", () => {
  it("creates a session on start()", async () => {
    const { calls } = await startedDriver();
    expect(calls.find((c) => c.m === "createSession")).toBeDefined();
  });

  it("prompt() emits agent:turn-start and calls prompt()", async () => {
    const { driver, sent, calls } = await startedDriver();
    await driver.prompt("do it");
    expect(sent.find((m) => m.type === "agent:turn-start")).toBeDefined();
    expect(calls.find((c) => c.m === "prompt")?.args).toEqual(["ses_root", "do it", {}]);
  });

  it("root session.idle emits agent:turn-end end_turn", async () => {
    const { driver, sent, push } = await startedDriver();
    await driver.prompt("x");
    push({ type: "session.idle", properties: { sessionID: "ses_root" } });
    await tick();
    const end = sent.find((m) => m.type === "agent:turn-end");
    expect(end).toBeDefined();
    if (end?.type === "agent:turn-end") expect(end.stopReason).toBe("end_turn");
  });

  it("emits an error agent:turn-end when the event stream dies mid-turn", async () => {
    const { driver, sent, fail } = await startedDriver();
    await driver.prompt("x");
    // opencode server exits before session.idle — the events() stream throws.
    fail(new Error("stream closed"));
    await tick();
    const end = sent.find((m) => m.type === "agent:turn-end");
    expect(end?.type).toBe("agent:turn-end");
    if (end?.type === "agent:turn-end") {
      expect(end.stopReason).toBe("error");
      expect(end.error).toBeDefined();
    }
  });

  it("text part.updated emits item-added then item-updated; part.delta emits item-delta", async () => {
    const { driver, sent, push } = await startedDriver();
    await driver.prompt("x");
    push({ type: "message.updated", properties: { sessionID: "ses_root", info: { id: "m1", role: "assistant" } } });
    push({ type: "message.part.updated", properties: { sessionID: "ses_root", part: { id: "p1", type: "text", messageID: "m1", text: "He" } } });
    push({ type: "message.part.delta", properties: { sessionID: "ses_root", messageID: "m1", partID: "p1", field: "text", delta: "llo" } });
    push({ type: "message.part.updated", properties: { sessionID: "ses_root", part: { id: "p1", type: "text", messageID: "m1", text: "Hello" } } });
    await tick();
    expect(sent.find((m) => m.type === "agent:item-added")?.type).toBe("agent:item-added");
    expect(sent.find((m) => m.type === "agent:item-delta")?.type).toBe("agent:item-delta");
    expect(sent.filter((m) => m.type === "agent:item-updated").length).toBeGreaterThan(0);
  });

  it("a part id reused in a new turn emits item-added again (per-turn seen-state cleared)", async () => {
    const { driver, sent, push } = await startedDriver();
    // turn-0: first sighting of p1 -> item-added
    await driver.prompt("a");
    push({ type: "message.updated", properties: { sessionID: "ses_root", info: { id: "m1", role: "assistant" } } });
    push({ type: "message.part.updated", properties: { sessionID: "ses_root", part: { id: "p1", type: "text", messageID: "m1", text: "x" } } });
    push({ type: "session.idle", properties: { sessionID: "ses_root" } });
    await tick();
    // turn-1: same part id; without per-turn clear this would be item-updated
    await driver.prompt("b");
    push({ type: "message.updated", properties: { sessionID: "ses_root", info: { id: "m2", role: "assistant" } } });
    push({ type: "message.part.updated", properties: { sessionID: "ses_root", part: { id: "p1", type: "text", messageID: "m2", text: "y" } } });
    await tick();
    const added = sent.filter((m) => m.type === "agent:item-added" && m.itemId === "p1");
    expect(added.length).toBe(2);
  });

  it("todo.updated emits a plan item keyed plan:<turnId>", async () => {
    const { driver, sent, push } = await startedDriver();
    await driver.prompt("x");
    push({ type: "todo.updated", properties: { sessionID: "ses_root", todos: [{ content: "a", status: "in_progress" }] } });
    await tick();
    const plan = sent.find((m) => m.type === "agent:item-updated" && m.item.kind === "plan");
    expect(plan).toBeDefined();
    if (plan?.type === "agent:item-updated") expect(plan.item.entries?.[0]).toEqual({ text: "a", status: "running" });
  });

  it("child session.created becomes a subtask anchor; child items carry parentItemId", async () => {
    const { driver, sent, push } = await startedDriver();
    await driver.prompt("x");
    push({ type: "session.created", properties: { sessionID: "ses_child", info: { id: "ses_child", parentID: "ses_root", agent: "build", title: "subtask" } } });
    push({ type: "message.updated", properties: { sessionID: "ses_child", info: { id: "cm1", role: "assistant" } } });
    push({ type: "message.part.updated", properties: { sessionID: "ses_child", part: { id: "cp1", type: "text", messageID: "cm1", text: "child" } } });
    await tick();
    const sub = sent.find((m) => (m.type === "agent:item-added") && m.item.kind === "subtask");
    expect(sub?.type).toBe("agent:item-added");
    const childItem = sent.find((m) => m.type === "agent:item-added" && m.item.kind === "message" && m.item.parentItemId === "subtask:ses_child");
    expect(childItem).toBeDefined();
  });

  it("child session.idle flips the subtask to completed", async () => {
    const { driver, sent, push } = await startedDriver();
    await driver.prompt("x");
    push({ type: "session.created", properties: { sessionID: "ses_child", info: { id: "ses_child", parentID: "ses_root" } } });
    push({ type: "session.idle", properties: { sessionID: "ses_child" } });
    await tick();
    const flip = sent.find((m) => m.type === "agent:item-updated" && m.item.kind === "subtask" && m.item.status === "completed");
    expect(flip).toBeDefined();
  });

  it("permission.asked emits agent:permission-request; resolvePermission replies once", async () => {
    const { driver, sent, push, calls } = await startedDriver();
    push({ type: "permission.asked", properties: { id: "perm1", sessionID: "ses_root", permission: "Run rm?" } });
    await tick();
    const perm = sent.find((m) => m.type === "agent:permission-request");
    expect(perm?.type).toBe("agent:permission-request");
    driver.resolvePermission("perm1", "once");
    expect(calls.find((c) => c.m === "replyPermission")?.args).toEqual(["ses_root", "perm1", "once"]);
  });

  it("question.asked emits agent:question with prompt+options; resolveQuestion replies", async () => {
    const { driver, sent, push, calls } = await startedDriver();
    push({ type: "question.asked", properties: { id: "q1", sessionID: "ses_root", questions: [{ question: "Which file?", header: "pick", options: [{ label: "a.ts", description: "first" }, { label: "b.ts", description: "second" }], multiple: false }] } });
    await tick();
    const q = sent.find((m) => m.type === "agent:question");
    expect(q?.type).toBe("agent:question");
    if (q?.type === "agent:question") {
      expect(q.prompt).toBe("Which file?");
      expect(q.kind).toBe("single_select");
      expect(q.options?.map((o) => o.label)).toEqual(["a.ts", "b.ts"]);
    }
    driver.resolveQuestion("q1", "a.ts");
    expect(calls.find((c) => c.m === "replyQuestion")?.args).toEqual(["q1", "a.ts"]);
  });

  it("resolveQuestion translates a single option id to its label", async () => {
    const { driver, push, calls } = await startedDriver();
    push({ type: "question.asked", properties: { id: "q1", sessionID: "ses_root", questions: [{ question: "yn", options: [{ label: "Yes" }, { label: "No" }], multiple: false }] } });
    await tick();
    driver.resolveQuestion("q1", "1");
    expect(calls.find((c) => c.m === "replyQuestion")?.args).toEqual(["q1", "No"]);
  });

  it("resolveQuestion translates multi-select option ids to labels element-wise", async () => {
    const { driver, push, calls } = await startedDriver();
    push({ type: "question.asked", properties: { id: "q1", sessionID: "ses_root", questions: [{ question: "files", options: [{ label: "a.ts" }, { label: "b.ts" }], multiple: true }] } });
    await tick();
    driver.resolveQuestion("q1", ["0", "1"]);
    expect(calls.find((c) => c.m === "replyQuestion")?.args).toEqual(["q1", ["a.ts", "b.ts"]]);
  });

  it("resolveQuestion passes a free-form text answer through unchanged (no options)", async () => {
    const { driver, push, calls } = await startedDriver();
    push({ type: "question.asked", properties: { id: "q1", sessionID: "ses_root", questions: [{ question: "name?" }] } });
    await tick();
    driver.resolveQuestion("q1", "free text");
    expect(calls.find((c) => c.m === "replyQuestion")?.args).toEqual(["q1", "free text"]);
  });

  it("resolveQuestion passes a non-index value through unchanged (already a label)", async () => {
    const { driver, push, calls } = await startedDriver();
    push({ type: "question.asked", properties: { id: "q1", sessionID: "ses_root", questions: [{ question: "yn", options: [{ label: "Yes" }, { label: "No" }], multiple: false }] } });
    await tick();
    driver.resolveQuestion("q1", "Yes");
    expect(calls.find((c) => c.m === "replyQuestion")?.args).toEqual(["q1", "Yes"]);
  });

  it("a question with multiple:true maps to kind multi_select", async () => {
    const { driver, sent, push } = await startedDriver();
    push({ type: "question.asked", properties: { id: "q2", sessionID: "ses_root", questions: [{ question: "Pick many", header: "multi", options: [{ label: "x", description: "" }], multiple: true }] } });
    await tick();
    const q = sent.find((m) => m.type === "agent:question");
    expect(q).toBeDefined();
    if (q?.type === "agent:question") expect(q.kind).toBe("multi_select");
  });

  // See the claude-driver equivalent. opencode aborts the whole session rather
  // than a named turn, so honouring the id matters most here: a stale cancel
  // would abort the live turn with no way to aim it.
  it("cancel() refuses a stale turnId: the session is not aborted and the live turn ends normally", async () => {
    const { driver, sent, push, calls } = await startedDriver();
    await driver.prompt("x");
    const live = sent.find((m) => m.type === "agent:turn-start") as any;
    expect(await driver.cancel(`${live.turnId}-stale`)).toBe(false);
    expect(calls.find((c) => c.m === "abort")).toBeUndefined();
    // cancelRequested must not have been set on the way out: the live turn ends
    // on its own terms, not mislabelled as cancelled.
    push({ type: "session.idle", properties: { sessionID: "ses_root" } });
    await tick();
    const end = sent.find((m) => m.type === "agent:turn-end");
    expect(end).toBeDefined();
    if (end?.type === "agent:turn-end") expect(end.stopReason).toBe("end_turn");
  });

  it("cancel() makes the abort-induced root idle end the turn as cancelled", async () => {
    const { driver, sent, push, calls } = await startedDriver();
    await driver.prompt("x");
    await driver.cancel();
    expect(calls.find((c) => c.m === "abort")?.args).toEqual(["ses_root"]);
    push({ type: "session.idle", properties: { sessionID: "ses_root" } });
    await tick();
    const end = sent.find((m) => m.type === "agent:turn-end");
    expect(end).toBeDefined();
    if (end?.type === "agent:turn-end") expect(end.stopReason).toBe("cancelled");
  });

  it("a stale cancelRequested does not bleed into the next turn", async () => {
    const { driver, sent, push } = await startedDriver();
    await driver.prompt("a");
    push({ type: "session.idle", properties: { sessionID: "ses_root" } }); // turn-0 ends end_turn, activeTurnId=null
    await tick();
    await driver.cancel();                                                  // sets cancelRequested with no active turn
    push({ type: "session.idle", properties: { sessionID: "ses_root" } }); // early-return; without fix the flag leaks
    await tick();
    await driver.prompt("b");                                               // turn-1
    push({ type: "session.idle", properties: { sessionID: "ses_root" } }); // without fix -> 'cancelled'; with fix -> 'end_turn'
    await tick();
    const ends = sent.filter((m) => m.type === "agent:turn-end");
    const last = ends[ends.length - 1];
    expect(last).toBeDefined();
    if (last?.type === "agent:turn-end") expect(last.stopReason).toBe("end_turn");
  });

  it("root session.error ends the turn with an error", async () => {
    const { driver, sent, push } = await startedDriver();
    await driver.prompt("x");
    push({ type: "session.error", properties: { sessionID: "ses_root", error: { name: "ProviderAuthError", data: { message: "401" } } } });
    await tick();
    const end = sent.find((m) => m.type === "agent:turn-end");
    expect(end).toBeDefined();
    if (end?.type === "agent:turn-end") { expect(end.stopReason).toBe("error"); expect(end.error?.category).toBe("auth"); }
  });

  it("session.error with an omitted sessionID still ends the active root turn", async () => {
    const { driver, sent, push } = await startedDriver();
    await driver.prompt("x");
    // opencode's EventSessionError.properties.sessionID is optional; a top-level
    // error can arrive without it. The active turn must still close as an error.
    push({ type: "session.error", properties: { error: { name: "ProviderAuthError", data: { message: "401" } } } });
    await tick();
    const end = sent.find((m) => m.type === "agent:turn-end");
    expect(end).toBeDefined();
    if (end?.type === "agent:turn-end") { expect(end.stopReason).toBe("error"); expect(end.error?.category).toBe("auth"); }
  });

  it("ending a turn drops a still-pending permission (resolvePermission becomes a no-op)", async () => {
    const { driver, push, calls } = await startedDriver();
    await driver.prompt("x");
    push({ type: "permission.asked", properties: { id: "perm1", sessionID: "ses_root", permission: "Run rm?" } });
    push({ type: "session.idle", properties: { sessionID: "ses_root" } }); // turn ends -> pending permission cleared
    await tick();
    driver.resolvePermission("perm1", "once");
    expect(calls.find((c) => c.m === "replyPermission")).toBeUndefined();
  });

  it("ending a turn drops a still-pending question's option mapping (answer passes through)", async () => {
    const { driver, push, calls } = await startedDriver();
    await driver.prompt("x");
    push({ type: "question.asked", properties: { id: "q1", sessionID: "ses_root", questions: [{ question: "yn", options: [{ label: "Yes" }, { label: "No" }], multiple: false }] } });
    push({ type: "session.idle", properties: { sessionID: "ses_root" } }); // turn ends -> option labels cleared
    await tick();
    driver.resolveQuestion("q1", "1");
    // With the mapping cleared, the index is no longer translated to "No".
    expect(calls.find((c) => c.m === "replyQuestion")?.args).toEqual(["q1", "1"]);
  });

  it("retracts pending permissions and questions when the turn ends", async () => {
    const { driver, sent, push } = await startedDriver();
    await driver.prompt("x");
    push({ type: "permission.asked", properties: { id: "perm1", sessionID: "ses_root", permission: "Run rm?" } });
    // Free-text question (no options) — must be retractable too, which is why
    // pendingQuestionIds exists (questionOptions only tracks option-questions).
    push({ type: "question.asked", properties: { id: "q1", sessionID: "ses_root", questions: [{ question: "name?" }] } });
    push({ type: "session.idle", properties: { sessionID: "ses_root" } });
    await tick();
    const retracted = sent.filter((m) => m.type === "agent:request-retracted");
    expect(retracted).toHaveLength(2);
    const ids = retracted.map((m) =>
      m.type === "agent:request-retracted" ? (m.permissionId ?? m.questionId) : "");
    expect(ids).toContain("perm1");
    expect(ids).toContain("q1");
  });

  it("retracts a still-pending permission on dispose (torn down mid-turn)", async () => {
    const { driver, sent, push } = await startedDriver();
    await driver.prompt("x");
    push({ type: "permission.asked", properties: { id: "perm1", sessionID: "ses_root", permission: "Run rm?" } });
    await tick();
    driver.dispose();
    const retracted = sent.filter((m) => m.type === "agent:request-retracted");
    expect(retracted).toHaveLength(1);
    expect(retracted[0]?.type === "agent:request-retracted" ? retracted[0].permissionId : "").toBe("perm1");
  });

  it("does not retract prompts that were already answered", async () => {
    const { driver, sent, push } = await startedDriver();
    await driver.prompt("x");
    push({ type: "permission.asked", properties: { id: "perm1", sessionID: "ses_root", permission: "Run rm?" } });
    push({ type: "question.asked", properties: { id: "q1", sessionID: "ses_root", questions: [{ question: "yn", options: [{ label: "Yes" }, { label: "No" }], multiple: false }] } });
    await tick();
    driver.resolvePermission("perm1", "once");
    driver.resolveQuestion("q1", "0");
    push({ type: "session.idle", properties: { sessionID: "ses_root" } });
    await tick();
    expect(sent.filter((m) => m.type === "agent:request-retracted")).toHaveLength(0);
  });

  it("assistant message tokens emit agent:usage", async () => {
    const { driver, sent, push } = await startedDriver();
    await driver.prompt("x");
    // Real opencode AssistantMessage.tokens never carries `total` — totalTokens
    // is derived from the leaf counters (see mapTokens).
    push({ type: "message.updated", properties: { sessionID: "ses_root", info: { id: "m1", role: "assistant", tokens: { input: 30, output: 20, reasoning: 0, cache: { read: 4, write: 0 } } } } });
    await tick();
    const usage = sent.find((m) => m.type === "agent:usage");
    expect(usage).toBeDefined();
    if (usage?.type === "agent:usage") { expect(usage.total.totalTokens).toBe(54); expect(usage.total.cacheReadTokens).toBe(4); }
  });

  // The context-window size (needed to render the app's ContextMeter) comes
  // from provider/model discovery (client.provider.list()'s `limit.context`),
  // not from the per-message tokens payload — it must be looked up by the
  // active message's providerID/modelID once discovery has landed.
  it("assistant message tokens include contextWindow looked up from discovered model limits", async () => {
    const { driver, sent, push } = await startedDriver();
    await tick(); // let discoverCapabilities() land before the model is used
    await driver.prompt("x");
    push({
      type: "message.updated",
      properties: {
        sessionID: "ses_root",
        info: {
          id: "m1",
          role: "assistant",
          providerID: "anthropic",
          modelID: "claude-sonnet-5",
          tokens: { input: 30, output: 20, reasoning: 0, cache: { read: 4, write: 0 } },
        },
      },
    });
    await tick();
    const usage = sent.find((m) => m.type === "agent:usage");
    expect(usage).toBeDefined();
    if (usage?.type === "agent:usage") expect(usage.contextWindow).toBe(195000);
  });

  it("omits contextWindow when the active model's limit wasn't discovered", async () => {
    const { driver, sent, push } = await startedDriver();
    await tick();
    await driver.prompt("x");
    push({
      type: "message.updated",
      properties: {
        sessionID: "ses_root",
        info: {
          id: "m1",
          role: "assistant",
          providerID: "openai",
          modelID: "gpt-5.2",
          tokens: { input: 10, output: 5, reasoning: 0, cache: { read: 0, write: 0 } },
        },
      },
    });
    await tick();
    const usage = sent.find((m) => m.type === "agent:usage");
    expect(usage).toBeDefined();
    if (usage?.type === "agent:usage") expect(usage.contextWindow).toBeUndefined();
  });

  it("resumes by reusing the stored session id and replaying messages", async () => {
    const sent: any[] = [];
    let created = 0;
    let messagesFor: string | null = null as string | null;
    const { client } = makeFakeClient({
      createSession: async () => { created++; return "should-not-be-called"; },
      messages: async (sid: string) => {
        messagesFor = sid;
        return [{ info: { id: "m1", role: "assistant" }, parts: [{ id: "p1", type: "text", text: "prior" }] }];
      },
    });
    const driver = new OpencodeDriver({ sessionId: "s1", client, sendMessage: (m) => sent.push(m) });
    const id = await driver.start("sess-abc");
    expect(id).toBe("sess-abc");
    expect(created).toBe(0); // resume must NOT create a new session
    expect(messagesFor).toBe("sess-abc");
    // One batched frame, not a frame per item — see createTranscriptReplay.
    const replays = sent.filter((m) => m.type === "agent:transcript-replay");
    expect(replays.length).toBe(1);
    expect(replays[0].frames.some((f: any) => f.type === "agent:item-added")).toBe(true);
  });

  it("reverts conversation by deleting the selected message and following messages, then replaying history", async () => {
    const history = [
      { info: { id: "m1", role: "user" }, parts: [{ id: "p1", type: "text", messageID: "m1", text: "first" }] },
      { info: { id: "m2", role: "assistant" }, parts: [{ id: "p2", type: "text", messageID: "m2", text: "reply" }] },
      { info: { id: "m3", role: "user" }, parts: [{ id: "p3", type: "text", messageID: "m3", text: "second" }] },
    ];
    const fake = makeFakeClient({
      messages: async (sid: string) => {
        fake.calls.push({ m: "messages", args: [sid] });
        return history;
      },
    });
    const sent: AbMessage[] = [];
    const driver = new OpencodeDriver({ sessionId: "s1", client: fake.client, sendMessage: (m) => sent.push(m) });
    await driver.start("ses_root");

    await driver.revert({ messageId: "m2" });

    expect(fake.calls.filter((c) => c.m === "deleteMessage").map((c) => c.args)).toEqual([
      ["ses_root", "m2"],
      ["ses_root", "m3"],
    ]);
    expect(sent.some((m) => m.type === "agent:session-reset")).toBe(true);
  });

  it("re-seeds live usage from the newest assistant that survives revert", async () => {
    let history: any[] = [
      {
        info: { id: "m1", role: "assistant", providerID: "anthropic", modelID: "claude-sonnet-5",
          tokens: { input: 100, output: 50, reasoning: 0, cache: { read: 10, write: 0 } } },
        parts: [{ id: "p1", type: "text", messageID: "m1", text: "keep" }],
      },
      { info: { id: "m2", role: "user" }, parts: [{ id: "p2", type: "text", messageID: "m2", text: "remove" }] },
      {
        info: { id: "m3", role: "assistant", providerID: "openai", modelID: "gpt-5.2",
          tokens: { input: 900, output: 100, reasoning: 0, cache: { read: 0, write: 0 } } },
        parts: [{ id: "p3", type: "text", messageID: "m3", text: "remove reply" }],
      },
    ];
    let fake!: ReturnType<typeof makeFakeClient>;
    fake = makeFakeClient({
      messages: async (sid: string) => {
        fake.calls.push({ m: "messages", args: [sid] });
        return history;
      },
      deleteMessage: async (sid: string, messageId: string) => {
        fake.calls.push({ m: "deleteMessage", args: [sid, messageId] });
        history = history.filter((m) => m.info.id !== messageId);
      },
    });
    const sent: AbMessage[] = [];
    const driver = new OpencodeDriver({ sessionId: "s1", client: fake.client, sendMessage: (m) => sent.push(m) });
    await driver.start("ses_root");
    await tick();
    sent.length = 0;

    await driver.revert({ messageId: "m2" });

    const resetAt = sent.findIndex((m) => m.type === "agent:session-reset");
    const liveUsage = sent.slice(resetAt + 1)
      .filter((m: any) => m.type === "agent:usage" && !m.itemId) as any[];
    expect(liveUsage).toHaveLength(1);
    expect(liveUsage[0].total.totalTokens).toBe(160);
    expect(liveUsage[0].contextWindow).toBe(195000);
    const caps = sent.slice(resetAt + 1).filter((m) => m.type === "agent:capabilities").at(-1);
    expect(caps?.type === "agent:capabilities" ? caps.currentModelId : undefined)
      .toBe("anthropic/claude-sonnet-5");
  });

  it("clears stale usage when revert removes all history", async () => {
    let history: any[] = [
      {
        info: { id: "m1", role: "assistant", providerID: "anthropic", modelID: "claude-sonnet-5",
          tokens: { input: 1000, output: 500, reasoning: 0, cache: { read: 0, write: 0 } } },
        parts: [{ id: "p1", type: "text", messageID: "m1", text: "remove" }],
      },
    ];
    let fake!: ReturnType<typeof makeFakeClient>;
    fake = makeFakeClient({
      messages: async () => history,
      deleteMessage: async (_sid: string, messageId: string) => {
        history = history.filter((m) => m.info.id !== messageId);
      },
    });
    const sent: AbMessage[] = [];
    const driver = new OpencodeDriver({ sessionId: "s1", client: fake.client, sendMessage: (m) => sent.push(m) });
    await driver.start("ses_root");
    await tick();
    driver.setConfig("model", "anthropic/claude-sonnet-5");
    sent.length = 0;

    await driver.revert({ messageId: "m1" });

    const resetAt = sent.findIndex((m) => m.type === "agent:session-reset");
    const liveUsage = sent.slice(resetAt + 1)
      .filter((m: any) => m.type === "agent:usage" && !m.itemId) as any[];
    expect(liveUsage).toHaveLength(1);
    expect(liveUsage[0].total).toEqual({});
    expect(liveUsage[0].contextWindow).toBe(195000);
  });

  it("getTranscriptSnapshot returns [] before any session exists", async () => {
    const fake = makeFakeClient();
    const driver = new OpencodeDriver({ sessionId: "s1", client: fake.client, sendMessage: () => {} });
    expect(await driver.getTranscriptSnapshot()).toEqual([]);
  });

  it("getTranscriptSnapshot returns [] while a turn is actively streaming", async () => {
    const { driver } = await startedDriver();
    await driver.prompt("hi"); // sets activeTurnId; no session.idle pushed, so it stays set
    expect(await driver.getTranscriptSnapshot()).toEqual([]);
  });

  it("getTranscriptSnapshot replays history via client.messages() once idle", async () => {
    const history = [
      {
        info: { id: "m1", role: "user", time: { created: 1000 } },
        parts: [{ id: "p1", type: "text", messageID: "m1", text: "hi" }],
      },
    ];
    const fake = makeFakeClient({ messages: async () => history });
    const driver = new OpencodeDriver({ sessionId: "s1", client: fake.client, sendMessage: () => {} });
    await driver.start();
    const frames = await driver.getTranscriptSnapshot();

    // The two frame assertions prove client.messages()' history was fetched and
    // replayed. We deliberately do NOT assert on fake.calls here: passing
    // { messages } to makeFakeClient REPLACES the call-recording default via the
    // `...overrides` spread, so a messages() call would never be recorded — an
    // assertion on it can't pass even when the read happened.
    expect(frames.some((m) => m.type === "agent:turn-start")).toBe(true);
    expect(frames.some((m) => m.type === "agent:item-added")).toBe(true);
  });

  it("getTranscriptSnapshot fails soft to [] when messages() throws", async () => {
    const fake = makeFakeClient({ messages: async () => { throw new Error("boom"); } });
    const driver = new OpencodeDriver({ sessionId: "s1", client: fake.client, sendMessage: () => {} });
    await driver.start();
    expect(await driver.getTranscriptSnapshot()).toEqual([]);
  });
});

describe("capabilities discovery", () => {
  const capsOf = (sent: AbMessage[]) => sent.filter((m) => m.type === "agent:capabilities").at(-1) as any;

  it("emits a not-ready frame on start, then a ready frame once discovery lands", async () => {
    const { sent } = await startedDriver();
    const first = sent.find((m) => m.type === "agent:capabilities") as any;
    expect(first.ready).toBe(false);
    expect(first.models).toEqual([]); // catalog not discovered yet
    await tick();
    const last = capsOf(sent);
    expect(last.ready).toBe(true);
    expect(last.models.length).toBeGreaterThan(0);
  });

  it("emits normalized commands, modes, and connected-provider models", async () => {
    const { sent } = await startedDriver();
    await tick();
    const caps = capsOf(sent);
    expect(caps.commands.map((c: any) => c.id)).toEqual(["cmd:review", "cmd:hello-skill", "builtin:compact"]);
    expect(caps.commands[0].argHint).toBe("$ARGUMENTS");
    expect(caps.modes.map((m: any) => m.id)).toEqual(["build", "plan"]); // subagent + hidden filtered
    expect(caps.models).toEqual([
      { id: "anthropic/claude-sonnet-5", name: "Claude Sonnet 5", provider: "Anthropic", efforts: ["thinking"] },
    ]); // openai not connected
  });

  it("is fail-soft when a discovery call rejects", async () => {
    const fake = makeFakeClient({ listProviders: async () => { throw new Error("route missing"); } });
    const sent: AbMessage[] = [];
    const driver = new OpencodeDriver({ sessionId: "s1", client: fake.client, sendMessage: (m) => sent.push(m) });
    await driver.start();
    await tick();
    const caps = capsOf(sent);
    expect(caps.models).toEqual([]);
    expect(caps.commands.length).toBeGreaterThan(0);
  });

  it("re-emits currentModelId when the live model is first observed", async () => {
    const { sent, push } = await startedDriver();
    await tick();
    push({ type: "message.updated", properties: { info: { id: "m1", role: "assistant", providerID: "anthropic", modelID: "claude-sonnet-5" } } });
    await tick();
    expect(capsOf(sent).currentModelId).toBe("anthropic/claude-sonnet-5");
  });

  it("setConfig stores selections, echoes, and applies them on the next prompt", async () => {
    const { driver, sent, calls } = await startedDriver();
    await tick();
    driver.setConfig("model", "anthropic/claude-sonnet-5");
    driver.setConfig("effort", "thinking");
    driver.setConfig("mode", "plan");
    const caps = sent.filter((m) => m.type === "agent:capabilities").at(-1) as any;
    expect(caps.currentModelId).toBe("anthropic/claude-sonnet-5");
    expect(caps.currentEffortId).toBe("thinking");
    expect(caps.currentModeId).toBe("plan");
    await driver.prompt("go");
    const p = calls.findLast((c) => c.m === "prompt");
    expect(p?.args[2]).toEqual({
      model: { providerID: "anthropic", modelID: "claude-sonnet-5" },
      agent: "plan",
      variant: "thinking",
    });
  });

  it("setConfig ignores unadvertised ids", async () => {
    const { driver, sent } = await startedDriver();
    await tick();
    const before = sent.filter((m) => m.type === "agent:capabilities").length;
    driver.setConfig("model", "bogus/nope");
    driver.setConfig("mode", "general"); // subagent — filtered out of modes
    expect(sent.filter((m) => m.type === "agent:capabilities").length).toBe(before);
  });

  it("queues picks that race ahead of discovery and applies them once it lands", async () => {
    // A resumed session replays yesterday's populated pickers to the app
    // instantly, so a pick can arrive while the lists are still empty.
    const { driver, sent } = await startedDriver();
    driver.setConfig("model", "anthropic/claude-sonnet-5");
    driver.setConfig("effort", "thinking");
    await tick();
    const caps = sent.filter((m) => m.type === "agent:capabilities").at(-1) as any;
    expect(caps.currentModelId).toBe("anthropic/claude-sonnet-5");
    expect(caps.currentEffortId).toBe("thinking");
  });

  it("routes cmd:* through session.command with args and selections", async () => {
    const { driver, sent, calls } = await startedDriver();
    await tick();
    driver.setConfig("model", "anthropic/claude-sonnet-5");
    await driver.prompt("src/main.ts", "cmd:review");
    expect(sent.filter((m) => m.type === "agent:turn-start").length).toBe(1);
    const cmd = calls.findLast((c) => c.m === "command");
    expect(cmd?.args[0]).toBe("ses_root");
    expect(cmd?.args[1]).toEqual({
      command: "review",
      arguments: "src/main.ts",
      model: "anthropic/claude-sonnet-5",
    });
  });

  it("routes builtin:compact to summarize without opening a turn", async () => {
    const { driver, sent, calls, push } = await startedDriver();
    await tick();
    push({ type: "message.updated", properties: { info: { id: "m1", role: "assistant", providerID: "anthropic", modelID: "claude-sonnet-5" } } });
    await tick();
    await driver.prompt("", "builtin:compact");
    expect(calls.some((c) => c.m === "summarize")).toBe(true);
    expect(sent.filter((m) => m.type === "agent:turn-start").length).toBe(0);
  });
});

describe("opencode early context capacity", () => {
  const resumedHistory = [
    {
      info: { id: "m1", role: "assistant", providerID: "anthropic", modelID: "claude-sonnet-5",
        tokens: { input: 1000, output: 500, reasoning: 0, cache: { read: 0, write: 0 } },
        time: { created: 1720000000000 } },
      parts: [{ id: "p1", type: "text", text: "prior answer", messageID: "m1" }],
    },
  ];

  it("seeds occupancy + capacity for a resumed session without a new response", async () => {
    const fake = makeFakeClient({ messages: async () => resumedHistory });
    const sent: AbMessage[] = [];
    const driver = new OpencodeDriver({ sessionId: "s1", client: fake.client, sendMessage: (m) => sent.push(m) });
    await driver.start("ses_resumed");
    await tick(); // let discoverCapabilities settle
    const meterFrames = sent.filter((m: any) => m.type === "agent:usage" && !(m as any).itemId) as any[];
    expect(meterFrames.length).toBeGreaterThan(0);
    const withOccupancy = meterFrames.find((f) => f.total?.totalTokens === 1500);
    expect(withOccupancy).toBeDefined();
    const withWindow = meterFrames.find((f) => f.contextWindow === 195000);
    expect(withWindow).toBeDefined();
    // The window-bearing frame must not wipe occupancy (lastTokens carry-forward).
    expect(withWindow.total?.totalTokens).toBe(1500);
  });

  it("re-emits capacity when setConfig picks a model", async () => {
    const { driver, sent } = await startedDriver();
    await tick(); // discovery done (capModels populated)
    const before = sent.filter((m: any) => m.type === "agent:usage").length;
    driver.setConfig("model", "anthropic/claude-sonnet-5");
    const frames = sent.filter((m: any) => m.type === "agent:usage") as any[];
    expect(frames.length).toBe(before + 1);
    expect(frames[frames.length - 1].contextWindow).toBe(195000);
  });

  it("emits no capacity frame for a fresh session with no known model", async () => {
    const { sent } = await startedDriver();
    await tick();
    expect(sent.filter((m: any) => m.type === "agent:usage").length).toBe(0);
  });
});

describe("OpencodeDriver capability discovery", () => {
  it("contains a discovery failure instead of taking the whole host down", async () => {
    // start() fire-and-forgets discoverCapabilities(). allSettled covers its
    // RPCs, but the post-processing tail can still throw — a failing transport
    // write is the realistic way. Unguarded, that rejection reaches the host's
    // unhandledRejection hook and shuts down every project on the machine.
    const fake = makeFakeClient();
    const unhandled: unknown[] = [];
    const onUnhandled = (e: unknown) => unhandled.push(e);
    process.on("unhandledRejection", onUnhandled);
    // start() emits its own early "loading" frame first and is awaited by the
    // manager (so it surfaces as agent:error); only fail the later frame, which
    // is the one discovery emits.
    let caps = 0;
    try {
      const driver = new OpencodeDriver({
        sessionId: "s1",
        client: fake.client,
        sendMessage: (m) => { if (m.type === "agent:capabilities" && ++caps > 1) throw new Error("transport closed"); },
      });
      await driver.start();
      await tick();
      await tick();
      driver.dispose();
    } finally {
      process.off("unhandledRejection", onUnhandled);
    }
    expect(unhandled).toEqual([]);
  });
});

describe("OpencodeDriver lifecycle detection", () => {
  async function lifecycleDriver() {
    const fake = makeFakeClient();
    const lifecycle: DriverLifecycleEvent[] = [];
    // One ordered log so a test can assert a park is reported BEFORE the
    // turn-end frame it accompanies.
    const log: string[] = [];
    const driver = new OpencodeDriver({
      sessionId: "s1",
      client: fake.client,
      sendMessage: (m) => log.push(`send:${m.type}`),
      onLifecycle: (evt) => { lifecycle.push(evt); log.push(`lifecycle:${evt.event}`); },
    });
    await driver.start();
    return { driver, lifecycle, log, ...fake };
  }

  const retry = (over: Record<string, unknown> = {}) => ({
    type: "session.status",
    properties: { sessionID: "ses_root", status: { type: "retry", attempt: 1, message: "rate limited", next: 5_000, ...over } },
  });

  it("a retry status parks as a self-resuming limit with the wake time", async () => {
    const { lifecycle, push } = await lifecycleDriver();
    push(retry());
    await tick();
    expect(lifecycle).toEqual([
      { event: "limit_hit", resetsAt: 5_000, selfResuming: true, errorClass: "rate_limit" },
    ]);
  });

  it("a retry status with no wake time omits resetsAt", async () => {
    const { lifecycle, push } = await lifecycleDriver();
    push(retry({ next: undefined }));
    await tick();
    expect(lifecycle).toEqual([{ event: "limit_hit", selfResuming: true, errorClass: "rate_limit" }]);
  });

  it("every retry tick reports again (re-park is the engine's job)", async () => {
    const { lifecycle, push } = await lifecycleDriver();
    push(retry());
    push(retry({ attempt: 2, next: 9_000 }));
    await tick();
    expect(lifecycle.map((e) => e.resetsAt)).toEqual([5_000, 9_000]);
  });

  it("leaving retry clears the limit exactly once", async () => {
    const { lifecycle, push } = await lifecycleDriver();
    push(retry());
    push({ type: "session.status", properties: { sessionID: "ses_root", status: { type: "busy" } } });
    push({ type: "session.status", properties: { sessionID: "ses_root", status: { type: "idle" } } });
    await tick();
    expect(lifecycle.map((e) => e.event)).toEqual(["limit_hit", "limit_cleared"]);
  });

  it("a busy/idle status with no preceding retry reports nothing", async () => {
    const { lifecycle, push } = await lifecycleDriver();
    push({ type: "session.status", properties: { sessionID: "ses_root", status: { type: "busy" } } });
    push({ type: "session.status", properties: { sessionID: "ses_root", status: { type: "idle" } } });
    await tick();
    expect(lifecycle).toEqual([]);
  });

  it("ignores a status for a session outside the root", async () => {
    const { lifecycle, push } = await lifecycleDriver();
    push({ type: "session.status", properties: { sessionID: "ses_child", status: { type: "retry", attempt: 1, message: "x", next: 5_000 } } });
    await tick();
    expect(lifecycle).toEqual([]);
  });

  it("a terminal 429 parks as a limit before the turn-end frame", async () => {
    const { driver, lifecycle, log, push } = await lifecycleDriver();
    await driver.prompt("x");
    push({ type: "session.error", properties: { sessionID: "ses_root", error: { name: "APIError", data: { message: "429", statusCode: 429 } } } });
    await tick();
    expect(lifecycle).toEqual([{ event: "limit_hit", errorClass: "rate_limit" }]);
    expect(log.indexOf("lifecycle:limit_hit")).toBeLessThan(log.indexOf("send:agent:turn-end"));
  });

  it("a terminal non-429 error reports a transient failure", async () => {
    const { driver, lifecycle, push } = await lifecycleDriver();
    await driver.prompt("x");
    push({ type: "session.error", properties: { sessionID: "ses_root", error: { name: "APIError", data: { message: "502", statusCode: 502 } } } });
    await tick();
    expect(lifecycle).toEqual([{ event: "turn_failed", errorClass: "unknown" }]);
  });

  it("does not treat auth or context-overflow failures as transient", async () => {
    for (const name of ["ProviderAuthError", "MessageOutputLengthError"]) {
      const { driver, lifecycle, push } = await lifecycleDriver();
      await driver.prompt("x");
      push({ type: "session.error", properties: { sessionID: "ses_root", error: { name, data: { message: "no" } } } });
      await tick();
      expect(lifecycle).toEqual([]);
    }
  });

  it("does not report a cancelled turn as a failure", async () => {
    const { driver, lifecycle, push } = await lifecycleDriver();
    await driver.prompt("x");
    push({ type: "session.error", properties: { sessionID: "ses_root", error: { name: "MessageAbortedError", data: { message: "aborted" } } } });
    await tick();
    expect(lifecycle).toEqual([]);
  });

  it("does not report a session error that ends no turn", async () => {
    const { lifecycle, push } = await lifecycleDriver();
    push({ type: "session.error", properties: { sessionID: "ses_root", error: { name: "APIError", data: { message: "502", statusCode: 502 } } } });
    await tick();
    expect(lifecycle).toEqual([]);
  });

  it("a driver with no onLifecycle handles the same events", async () => {
    const { driver, sent, push } = await startedDriver();
    await driver.prompt("x");
    push(retry());
    push({ type: "session.error", properties: { sessionID: "ses_root", error: { name: "APIError", data: { message: "429", statusCode: 429 } } } });
    await tick();
    expect(sent.find((m) => m.type === "agent:turn-end")).toBeDefined();
  });
});
