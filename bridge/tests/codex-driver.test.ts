import { describe, it, expect } from "bun:test";
import { CodexDriver, type CodexEndpoint } from "../src/codex/codex-driver";
import type { AbMessage } from "../src/protocol";

// Fake endpoint: capture outbound, let the test fire notifications/requests.
// opts.onRequest, when given, overrides the default canned responses per call
// (used by the resume test to script thread/resume without touching every
// other case's fixed response table).
function makeFakeEndpoint(opts?: { onRequest?: (method: string, params: any) => any }) {
  const requests: Array<{ method: string; params: any }> = [];
  const notifs = new Map<string, (p: any) => void>();
  const reqHandlers = new Map<string, (p: any, rpcId?: number | string) => any>();
  const responses: Record<string, any> = {
    "thread/start": {
      thread: { id: "th1" },
      model: "gpt-5.2",
      reasoningEffort: "medium",
      activePermissionProfile: { id: ":workspace" },
    },
    "turn/start": { turn: { id: "tn1" } },
    "turn/interrupt": {},
    "thread/compact/start": {},
    "thread/rollback": { thread: { id: "th1", turns: [] } },
    "initialize": { userAgent: "codex" },
    "model/list": { data: [
      { id: "gpt-5.2", model: "gpt-5.2", displayName: "GPT-5.2", isDefault: true,
        supportedReasoningEfforts: [{ reasoningEffort: "low" }, { reasoningEffort: "high" }],
        defaultReasoningEffort: "medium" },
      { id: "hidden-x", model: "hidden-x", displayName: "Hidden", hidden: true },
    ] },
    "permissionProfile/list": { data: [
      { id: ":workspace", allowed: true },
      { id: "locked", description: "not allowed", allowed: false },
    ] },
    "skills/list": { data: [
      { cwd: "/x", skills: [{ name: "code-review", description: "Review changes", path: "/x/.codex/skills/code-review", enabled: true }], errors: [] },
    ] },
  };
  let closeHandler: (() => void) | undefined;
  const ep: CodexEndpoint = {
    request: async (method, params) => {
      requests.push({ method, params });
      if (opts?.onRequest) return opts.onRequest(method, params);
      return responses[method] ?? {};
    },
    notify: () => {},
    onNotification: (m, h) => { notifs.set(m, h); },
    onRequest: (m, h) => { reqHandlers.set(m, h as any); },
    onClose: (h) => { closeHandler = h; },
    dispose: () => {},
  };
  return {
    ep,
    requests,
    fire: (m: string, p: any) => notifs.get(m)?.(p),
    reqHandlers,
    close: () => closeHandler?.(),
  };
}

async function startedDriver() {
  const { ep, requests, fire, reqHandlers, close } = makeFakeEndpoint();
  const sent: AbMessage[] = [];
  const driver = new CodexDriver({ sessionId: "s1", endpoint: ep, sendMessage: (m) => sent.push(m), cwd: "/x" });
  await driver.start();
  return { driver, requests, fire, reqHandlers, sent, close };
}

describe("CodexDriver", () => {
  it("initializes and starts a thread on start()", async () => {
    const { requests } = await startedDriver();
    // Capability discovery (model/list etc.) is dispatched fire-and-forget from
    // inside start(), so its requests land before start() resolves too.
    expect(requests.map((r) => r.method).slice(0, 2)).toEqual(["initialize", "thread/start"]);
  });

  it("prompt() sends turn/start with the text as input", async () => {
    const { driver, requests } = await startedDriver();
    await driver.prompt("hello");
    const turn = requests.find((r) => r.method === "turn/start");
    expect(turn?.params.threadId).toBe("th1");
    expect(turn?.params.input[0]).toEqual({ type: "text", text: "hello" });
  });

  it("emits agent:turn-start on turn/started and agent:turn-end on turn/completed", async () => {
    const { fire, sent } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    fire("turn/completed", { threadId: "th1", turn: { id: "tn1", status: "completed" } });
    expect(sent.find((m) => m.type === "agent:turn-start")).toBeDefined();
    const end = sent.find((m) => m.type === "agent:turn-end");
    expect(end?.type).toBe("agent:turn-end");
    if (end?.type === "agent:turn-end") expect(end.stopReason).toBe("end_turn");
  });

  it("emits an error agent:turn-end when codex closes mid-turn (no turn/completed)", async () => {
    const { fire, sent, close } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    // codex process exits before turn/completed — the endpoint's stdout closes.
    close();
    const end = sent.find((m) => m.type === "agent:turn-end");
    expect(end?.type).toBe("agent:turn-end");
    if (end?.type === "agent:turn-end") {
      expect(end.turnId).toBe("tn1");
      expect(end.stopReason).toBe("error");
      expect(end.error).toBeDefined();
    }
  });

  it("does not emit a turn-end on close when idle (no active turn)", async () => {
    const { sent, close } = await startedDriver();
    close();
    expect(sent.find((m) => m.type === "agent:turn-end")).toBeUndefined();
  });

  it("emits agent:item-added on item/started and agent:item-updated on item/completed", async () => {
    const { fire, sent } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    fire("item/started", { threadId: "th1", turnId: "tn1", item: { type: "agentMessage", id: "i1", text: "" } });
    fire("item/completed", { threadId: "th1", turnId: "tn1", item: { type: "agentMessage", id: "i1", text: "done" } });
    expect(sent.find((m) => m.type === "agent:item-added")).toBeDefined();
    const upd = sent.find((m) => m.type === "agent:item-updated");
    expect(upd?.type).toBe("agent:item-updated");
    if (upd?.type === "agent:item-updated") expect(upd.item.text).toBe("done");
  });

  it("emits agent:item-delta on agentMessage deltas in arrival order", async () => {
    const { fire, sent } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    fire("item/agentMessage/delta", { itemId: "i1", turnId: "tn1", delta: "a" });
    fire("item/agentMessage/delta", { itemId: "i1", turnId: "tn1", delta: "b" });
    const deltas = sent.filter((m) => m.type === "agent:item-delta");
    expect(deltas.length).toBe(2);
    if (deltas[0].type === "agent:item-delta" && deltas[1].type === "agent:item-delta") {
      expect(deltas[0].textChunk).toBe("a");
      expect(deltas[1].textChunk).toBe("b");
    }
  });

  it("forwards commandExecution output deltas as agent:item-delta", async () => {
    const { fire, sent } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    fire("item/commandExecution/outputDelta", { itemId: "i1", turnId: "tn1", delta: "build ok\n" });
    const delta = sent.find((m) => m.type === "agent:item-delta");
    expect(delta?.type).toBe("agent:item-delta");
    if (delta?.type === "agent:item-delta") {
      expect(delta.itemId).toBe("i1");
      expect(delta.textChunk).toBe("build ok\n");
    }
  });

  it("start() rejects with the spawn diagnosis when the endpoint dies with one", async () => {
    const { ep } = makeFakeEndpoint({
      onRequest: () => { throw new Error("endpoint disposed"); },
    });
    const driver = new CodexDriver({
      sessionId: "s1",
      endpoint: ep,
      sendMessage: () => {},
      cwd: "/x",
      diagnoseStartFailure: async () =>
        "Codex is already in use by another app. Close it and try again.",
    });
    await expect(driver.start()).rejects.toThrow(/already in use/);
  });

  it("start() rejects with the original error when there is no diagnosis", async () => {
    const { ep } = makeFakeEndpoint({
      onRequest: () => { throw new Error("endpoint disposed"); },
    });
    const driver = new CodexDriver({
      sessionId: "s1",
      endpoint: ep,
      sendMessage: () => {},
      cwd: "/x",
      diagnoseStartFailure: async () => null,
    });
    await expect(driver.start()).rejects.toThrow("endpoint disposed");
  });

  it("does NOT forward experimental item/plan/delta (would mismatch completed plan)", async () => {
    const { fire, sent } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    fire("item/plan/delta", { itemId: "i1", turnId: "tn1", delta: "step 1" });
    expect(sent.filter((m) => m.type === "agent:item-delta")).toHaveLength(0);
  });

  it("forwards reasoning content deltas as agent:item-delta", async () => {
    const { fire, sent } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    fire("item/reasoning/textDelta", { itemId: "r1", turnId: "tn1", delta: "think", contentIndex: 0 });
    const delta = sent.find((m) => m.type === "agent:item-delta");
    expect(delta?.type).toBe("agent:item-delta");
    if (delta?.type === "agent:item-delta") expect(delta.textChunk).toBe("think");
  });

  it("separates summary paragraphs from summaryIndex alone (no summaryPartAdded)", async () => {
    const { fire, sent } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    // codex may not emit summaryPartAdded; the blank line must still come from
    // the summaryIndex advancing on the text delta itself.
    fire("item/reasoning/summaryTextDelta", { turnId: "tn1", itemId: "r1", delta: "first", summaryIndex: 0 });
    fire("item/reasoning/summaryTextDelta", { turnId: "tn1", itemId: "r1", delta: "second", summaryIndex: 1 });
    const chunks = sent
      .filter((m) => m.type === "agent:item-delta")
      .map((m) => (m.type === "agent:item-delta" ? m.textChunk : ""));
    expect(chunks).toEqual(["first", "\n\n", "second"]);
  });

  it("drops summary deltas once the content channel has claimed an item", async () => {
    const { fire, sent } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    fire("item/reasoning/textDelta", { turnId: "tn1", itemId: "r1", delta: "raw" });
    fire("item/reasoning/summaryTextDelta", { turnId: "tn1", itemId: "r1", delta: "summary", summaryIndex: 0 });
    const chunks = sent
      .filter((m) => m.type === "agent:item-delta")
      .map((m) => (m.type === "agent:item-delta" ? m.textChunk : ""));
    expect(chunks).toEqual(["raw"]);
  });

  it("drops content deltas once the summary channel has claimed an item", async () => {
    const { fire, sent } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    // Reverse of the above: summary streams first, so a late content delta must
    // be muted rather than interleaved (the snapshot reconciles the final text).
    fire("item/reasoning/summaryTextDelta", { turnId: "tn1", itemId: "r1", delta: "summary", summaryIndex: 0 });
    fire("item/reasoning/textDelta", { turnId: "tn1", itemId: "r1", delta: "raw" });
    const chunks = sent
      .filter((m) => m.type === "agent:item-delta")
      .map((m) => (m.type === "agent:item-delta" ? m.textChunk : ""));
    expect(chunks).toEqual(["summary"]);
  });

  it("clears the content-channel guard at turn end", async () => {
    const { fire, sent } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    fire("item/reasoning/textDelta", { turnId: "tn1", itemId: "r1", delta: "raw" });
    fire("turn/completed", { turn: { id: "tn1", status: "completed" } });
    fire("turn/started", { threadId: "th1", turn: { id: "tn2" } });
    fire("item/reasoning/summaryTextDelta", { turnId: "tn2", itemId: "r1", delta: "next-turn summary", summaryIndex: 0 });
    const chunks = sent
      .filter((m) => m.type === "agent:item-delta")
      .map((m) => (m.type === "agent:item-delta" ? m.textChunk : ""));
    expect(chunks).toEqual(["raw", "next-turn summary"]);
  });

  it("emits agent:usage from thread/tokenUsage/updated (renames cached -> cacheRead)", async () => {
    const { fire, sent } = await startedDriver();
    fire("thread/tokenUsage/updated", {
      threadId: "th1", turnId: "tn1",
      tokenUsage: {
        total: { totalTokens: 100, inputTokens: 60, outputTokens: 40, cachedInputTokens: 20, reasoningOutputTokens: 5 },
        last: { totalTokens: 10, inputTokens: 6, outputTokens: 4, cachedInputTokens: 0, reasoningOutputTokens: 0 },
        modelContextWindow: 200000,
      },
    });
    const usage = sent.find((m) => m.type === "agent:usage");
    expect(usage?.type).toBe("agent:usage");
    if (usage?.type === "agent:usage") {
      expect(usage.total.totalTokens).toBe(100);
      expect(usage.total.cacheReadTokens).toBe(20);
      expect(usage.contextWindow).toBe(200000);
    }
  });

  it("emits a structured plan item from turn/plan/updated keyed by plan:<turnId>", async () => {
    const { fire, sent } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    fire("turn/plan/updated", {
      threadId: "th1", turnId: "tn1", explanation: null,
      plan: [{ step: "scout", status: "completed" }, { step: "build", status: "inProgress" }],
    });
    const plan = sent.find((m) => m.type === "agent:item-updated");
    expect(plan?.type).toBe("agent:item-updated");
    if (plan?.type === "agent:item-updated") {
      expect(plan.itemId).toBe("plan:tn1");
      expect(plan.item.kind).toBe("plan");
      expect(plan.item.entries?.[0]).toEqual({ text: "scout", status: "completed" });
      expect(plan.item.entries?.[1].status).toBe("running");
    }
  });

  it("suppresses the text-blob plan item once a structured plan has arrived for the turn", async () => {
    const { fire, sent } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    fire("turn/plan/updated", { threadId: "th1", turnId: "tn1", explanation: null, plan: [{ step: "a", status: "pending" }] });
    fire("item/completed", { threadId: "th1", turnId: "tn1", item: { type: "plan", id: "p1", text: "- a" } });
    const plans = sent.filter((m) => m.type === "agent:item-updated" && m.itemId === "plan:tn1");
    // one structured emission; the later text blob is ignored (no duplicate plan row)
    expect(plans).toHaveLength(1);
    expect(sent.some((m) => m.type === "agent:item-updated" && m.itemId === "p1")).toBe(false);
  });

  it("clears structured-plan suppression state on turn/completed (no unbounded growth)", async () => {
    const { fire, sent } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    fire("turn/plan/updated", { threadId: "th1", turnId: "tn1", explanation: null, plan: [{ step: "a", status: "pending" }] });
    // While the turn is live the text blob is suppressed (structured wins).
    fire("item/completed", { threadId: "th1", turnId: "tn1", item: { type: "plan", id: "p1", text: "- a" } });
    expect(sent.filter((m) => m.type === "agent:item-updated" && m.itemId === "plan:tn1")).toHaveLength(1);
    // turn/completed must drop the turn's suppression entry, else the Set leaks.
    fire("turn/completed", { turn: { id: "tn1", status: "completed" } });
    fire("item/completed", { threadId: "th1", turnId: "tn1", item: { type: "plan", id: "p2", text: "- a" } });
    // Entry gone → the post-turn text blob is emitted, not swallowed by stale state.
    expect(sent.filter((m) => m.type === "agent:item-updated" && m.itemId === "plan:tn1")).toHaveLength(2);
  });

  it("turns a command approval request into agent:permission-request and resolves it", async () => {
    const { fire, reqHandlers, sent, driver } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    const handler = reqHandlers.get("item/commandExecution/requestApproval")!;
    const replyPromise = handler({ threadId: "th1", turnId: "tn1", itemId: "i1", command: "rm -rf /" });
    const perm = sent.find((m) => m.type === "agent:permission-request");
    expect(perm?.type).toBe("agent:permission-request");
    let permissionId = "";
    if (perm?.type === "agent:permission-request") permissionId = perm.permissionId;
    driver.resolvePermission(permissionId, "ok");
    const reply = await replyPromise;
    expect(reply).toEqual({ decision: "accept" });
  });

  it("command approval offers allow-for-session and maps it to acceptForSession", async () => {
    const { fire, reqHandlers, sent, driver } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    const handler = reqHandlers.get("item/commandExecution/requestApproval")!;
    const replyPromise = handler({ itemId: "i1", command: "npm i" });
    const perm = sent.find((m) => m.type === "agent:permission-request");
    let permissionId = "";
    if (perm?.type === "agent:permission-request") {
      permissionId = perm.permissionId;
      expect(perm.options.map((o) => o.optionId)).toEqual(["ok", "always", "no"]);
      expect(perm.options.map((o) => o.kind)).toEqual(["allow_once", "allow_always", "reject"]);
    }
    driver.resolvePermission(permissionId, "always");
    expect(await replyPromise).toEqual({ decision: "acceptForSession" });
  });

  it("command approval maps deny to decline", async () => {
    const { fire, reqHandlers, sent, driver } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    const handler = reqHandlers.get("item/commandExecution/requestApproval")!;
    const replyPromise = handler({ itemId: "i1", command: "rm -rf /" });
    const perm = sent.find((m) => m.type === "agent:permission-request");
    if (perm?.type === "agent:permission-request") driver.resolvePermission(perm.permissionId, "no");
    expect(await replyPromise).toEqual({ decision: "decline" });
  });

  // Production codex requests fileChange approval BEFORE emitting item/started
  // (approval → run), so the cached-title path below only engages if that
  // ordering ever changes; the fallback test after it is today's real behavior.
  it("file-change approval title lists the cached changed paths", async () => {
    const { fire, reqHandlers, sent, driver } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    fire("item/started", {
      turnId: "tn1",
      item: {
        type: "fileChange", id: "fc1", status: "inProgress",
        changes: [
          { path: "a.ts", kind: { type: "update" }, diff: "d1" },
          { path: "b.ts", kind: { type: "add" }, diff: "d2" },
        ],
      },
    });
    const handler = reqHandlers.get("item/fileChange/requestApproval")!;
    const replyPromise = handler({ itemId: "fc1" });
    const perm = sent.filter((m) => m.type === "agent:permission-request").at(-1);
    let permissionId = "";
    if (perm?.type === "agent:permission-request") {
      permissionId = perm.permissionId;
      expect(perm.title).toBe("Apply changes to 2 file(s): a.ts, b.ts");
    }
    driver.resolvePermission(permissionId, "ok");
    expect(await replyPromise).toEqual({ decision: "accept" });
  });

  it("file-change approval falls back to the generic title with no cached paths", async () => {
    const { fire, reqHandlers, sent, driver } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    const handler = reqHandlers.get("item/fileChange/requestApproval")!;
    const replyPromise = handler({ itemId: "missing" });
    const perm = sent.find((m) => m.type === "agent:permission-request");
    if (perm?.type === "agent:permission-request") {
      expect(perm.title).toBe("Apply file changes?");
      driver.resolvePermission(perm.permissionId, "no");
    }
    await replyPromise;
  });

  it("permissions approval echoes the requested profile with turn scope on allow", async () => {
    const { fire, reqHandlers, sent, driver } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    const handler = reqHandlers.get("item/permissions/requestApproval")!;
    const profile = { network: { enabled: true }, fileSystem: { write: true } };
    const replyPromise = handler({ itemId: "i1", reason: "needs net", permissions: profile });
    const perm = sent.find((m) => m.type === "agent:permission-request");
    let permissionId = "";
    if (perm?.type === "agent:permission-request") {
      permissionId = perm.permissionId;
      expect(perm.title).toBe("Grant permissions: network, file system");
      expect(perm.reason).toBe("needs net");
      expect(perm.options.map((o) => o.optionId)).toEqual(["ok", "always", "no"]);
    }
    driver.resolvePermission(permissionId, "ok");
    expect(await replyPromise).toEqual({ permissions: profile, scope: "turn" });
  });

  it("permissions approval uses session scope for allow-for-session", async () => {
    const { fire, reqHandlers, sent, driver } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    const handler = reqHandlers.get("item/permissions/requestApproval")!;
    const replyPromise = handler({ itemId: "i1", permissions: { network: { enabled: true } } });
    const perm = sent.find((m) => m.type === "agent:permission-request");
    if (perm?.type === "agent:permission-request") driver.resolvePermission(perm.permissionId, "always");
    expect(await replyPromise).toEqual({ permissions: { network: { enabled: true } }, scope: "session" });
  });

  it("permissions approval denies with an empty grant", async () => {
    const { fire, reqHandlers, sent, driver } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    const handler = reqHandlers.get("item/permissions/requestApproval")!;
    const replyPromise = handler({ itemId: "i1", permissions: { fileSystem: { write: true } } });
    const perm = sent.find((m) => m.type === "agent:permission-request");
    if (perm?.type === "agent:permission-request") {
      expect(perm.title).toBe("Grant permissions: file system");
      driver.resolvePermission(perm.permissionId, "no");
    }
    expect(await replyPromise).toEqual({ permissions: {}, scope: "turn" });
  });

  it("requestUserInput emits one agent:question per entry and replies once with all answers", async () => {
    const { fire, reqHandlers, sent, driver } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    const handler = reqHandlers.get("item/tool/requestUserInput")!;
    const replyPromise = handler({
      itemId: "i1",
      questions: [
        { id: "cq1", header: "Branch", question: "Which branch?", isOther: false, isSecret: false,
          options: [{ label: "main", description: "" }, { label: "dev", description: "d" }] },
        { id: "cq2", header: "Note", question: "Any note?", isOther: false, isSecret: false, options: null },
      ],
    });
    const qs = sent.filter((m) => m.type === "agent:question");
    expect(qs).toHaveLength(2);
    const [q1, q2] = qs;
    if (q1?.type === "agent:question" && q2?.type === "agent:question") {
      expect(q1.kind).toBe("single_select");
      expect(q1.prompt).toBe("Which branch?");
      expect(q1.options?.map((o) => o.label)).toEqual(["main", "dev"]);
      expect(q2.kind).toBe("text");
      driver.resolveQuestion(q1.questionId, "1"); // synthetic index id -> label "dev"
      driver.resolveQuestion(q2.questionId, "looks good");
    }
    expect(await replyPromise).toEqual({
      answers: { cq1: { answers: ["dev"] }, cq2: { answers: ["looks good"] } },
    });
  });

  it("requestUserInput with isOther falls back to a text question", async () => {
    const { fire, reqHandlers, sent, driver } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    const handler = reqHandlers.get("item/tool/requestUserInput")!;
    const replyPromise = handler({
      itemId: "i1",
      questions: [{ id: "cq1", header: "H", question: "Custom?", isOther: true, isSecret: false,
        options: [{ label: "a", description: "" }] }],
    });
    const q = sent.find((m) => m.type === "agent:question");
    if (q?.type === "agent:question") {
      expect(q.kind).toBe("text");
      driver.resolveQuestion(q.questionId, "my own value");
    }
    expect(await replyPromise).toEqual({ answers: { cq1: { answers: ["my own value"] } } });
  });

  it("requestUserInput marks secret questions on the wire", async () => {
    const { fire, reqHandlers, sent, driver } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    const handler = reqHandlers.get("item/tool/requestUserInput")!;
    const replyPromise = handler({
      itemId: "i1",
      questions: [{ id: "cq1", header: "Token", question: "API token?", isOther: false, isSecret: true, options: null }],
    });
    const q = sent.find((m) => m.type === "agent:question");
    if (q?.type === "agent:question") {
      expect(q.isSecret).toBe(true);
      driver.resolveQuestion(q.questionId, "sk-123");
    }
    expect(await replyPromise).toEqual({ answers: { cq1: { answers: ["sk-123"] } } });
  });

  // See the claude-driver equivalent: a client whose turn-end was lost names a
  // finished turn, and interrupting the live one instead stops work the user
  // never asked to stop while leaving the phantom turn open forever.
  it("cancel() refuses a stale turnId: no turn/interrupt is issued", async () => {
    const { driver, fire, requests } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    expect(await driver.cancel("tn-stale")).toBe(false);
    expect(requests.find((r) => r.method === "turn/interrupt")).toBeUndefined();
    // Naming the live turn still works.
    expect(await driver.cancel("tn1")).toBe(true);
    expect(requests.find((r) => r.method === "turn/interrupt")?.params).toEqual({
      threadId: "th1", turnId: "tn1",
    });
  });

  it("cancel() calls turn/interrupt with the active turn id", async () => {
    const { driver, fire, requests } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    await driver.cancel();
    const intr = requests.find((r) => r.method === "turn/interrupt");
    expect(intr?.params).toEqual({ threadId: "th1", turnId: "tn1" });
  });

  it("resumes an existing thread and replays its history", async () => {
    const sent: AbMessage[] = [];
    const { ep, requests } = makeFakeEndpoint({
      onRequest: (method) => {
        if (method === "initialize") return {};
        if (method === "thread/resume") {
          return {
            thread: {
              id: "th-resumed",
              turns: [{ id: "t0", items: [{ id: "i1", type: "agentMessage", text: "prior" }] }],
            },
          };
        }
        return {};
      },
    });
    const driver = new CodexDriver({ sessionId: "s1", endpoint: ep, sendMessage: (m) => sent.push(m), cwd: "/x" });
    const id = await driver.start("th-resumed");
    expect(id).toBe("th-resumed");
    expect(requests.some((r) => r.method === "thread/resume" && r.params.threadId === "th-resumed")).toBe(true);
    expect(requests.some((r) => r.method === "thread/start")).toBe(false);
    // Replayed history reaches the app as ONE batched frame: per-frame replay
    // exceeds the relay's rate limit, which drops the overflow (losing the
    // trailing turn-end) with no retransmit.
    const replays = sent.filter((m) => m.type === "agent:transcript-replay");
    expect(replays.length).toBe(1);
    expect((replays[0] as any).frames.map((f: any) => f.type)).toEqual(
      expect.arrayContaining(["agent:turn-start", "agent:item-added", "agent:turn-end"]),
    );
  });

  it("getTranscriptSnapshot returns [] before a thread exists", async () => {
    const { ep } = makeFakeEndpoint();
    const driver = new CodexDriver({ sessionId: "s1", endpoint: ep, sendMessage: () => {}, cwd: "/x" });
    expect(await driver.getTranscriptSnapshot()).toEqual([]);
  });

  it("getTranscriptSnapshot re-derives completed turns via thread/read, excluding the in-progress turn", async () => {
    const { ep, requests } = makeFakeEndpoint({
      onRequest: (method) => {
        if (method === "thread/start") return { thread: { id: "th1" } };
        if (method === "thread/read") {
          return {
            thread: {
              id: "th1",
              turns: [
                { id: "t0", status: "completed", items: [{ id: "i1", type: "agentMessage", text: "done" }] },
                { id: "t1", status: "inProgress", items: [{ id: "i2", type: "agentMessage", text: "streaming" }] },
              ],
            },
          };
        }
        return {};
      },
    });
    const driver = new CodexDriver({ sessionId: "s1", endpoint: ep, sendMessage: () => {}, cwd: "/x" });
    await driver.start();
    const frames = await driver.getTranscriptSnapshot();

    expect(requests.some((r) =>
      r.method === "thread/read" && r.params.threadId === "th1" && r.params.includeTurns === true,
    )).toBe(true);
    const turnStarts = frames.filter((m) => m.type === "agent:turn-start").map((m: any) => m.turnId);
    expect(turnStarts).toEqual(["t0"]);
    expect(frames.filter((m) => m.type === "agent:item-added").length).toBe(1);
  });

  it("getTranscriptSnapshot fails soft to [] when thread/read throws", async () => {
    const { ep } = makeFakeEndpoint({
      onRequest: (method) => {
        if (method === "thread/start") return { thread: { id: "th1" } };
        if (method === "thread/read") throw new Error("boom");
        return {};
      },
    });
    const driver = new CodexDriver({ sessionId: "s1", endpoint: ep, sendMessage: () => {}, cwd: "/x" });
    await driver.start();
    expect(await driver.getTranscriptSnapshot()).toEqual([]);
  });

  it("reverts conversation by rolling back from the selected turn and replaying the returned thread", async () => {
    const { driver, fire, requests, sent } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    fire("turn/completed", { threadId: "th1", turn: { id: "tn1", status: "completed" } });
    fire("turn/started", { threadId: "th1", turn: { id: "tn2" } });
    fire("turn/completed", { threadId: "th1", turn: { id: "tn2", status: "completed" } });

    await driver.revert({ turnId: "tn1" });

    const rollback = requests.find((r) => r.method === "thread/rollback");
    expect(rollback?.params).toEqual({ threadId: "th1", numTurns: 2 });
    expect(sent.some((m) => m.type === "agent:session-reset")).toBe(true);
  });

  it("elicitation form collects typed answers and accepts", async () => {
    const { fire, reqHandlers, sent, driver } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    const handler = reqHandlers.get("mcpServer/elicitation/request")!;
    const replyPromise = handler({
      mode: "form", serverName: "srv", message: "Confirm?",
      requestedSchema: { type: "object", properties: { confirmed: { type: "boolean" } } },
    });
    const q = sent.find((m) => m.type === "agent:question");
    expect(q?.type).toBe("agent:question");
    if (q?.type === "agent:question") {
      expect(q.kind).toBe("single_select");
      driver.resolveQuestion(q.questionId, "yes");
    }
    expect(await replyPromise).toEqual({ action: "accept", content: { confirmed: true } });
  });

  it("elicitation url mode accepts on done and declines on decline", async () => {
    const { fire, reqHandlers, sent, driver } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    const handler = reqHandlers.get("mcpServer/elicitation/request")!;
    const replyPromise = handler({ mode: "url", serverName: "srv", message: "Open", url: "https://x.test" });
    const q = sent.find((m) => m.type === "agent:question");
    if (q?.type === "agent:question") driver.resolveQuestion(q.questionId, "decline");
    expect(await replyPromise).toEqual({ action: "decline" });
  });

  it("elicitation json fallback parses the reply and declines with agent:error on bad JSON", async () => {
    const { fire, reqHandlers, sent, driver } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    const handler = reqHandlers.get("mcpServer/elicitation/request")!;
    const ok = handler({ mode: "openai/form", serverName: "srv", message: "m", requestedSchema: {} });
    const q1 = sent.filter((m) => m.type === "agent:question").at(-1);
    if (q1?.type === "agent:question") driver.resolveQuestion(q1.questionId, '{"a":1}');
    expect(await ok).toEqual({ action: "accept", content: { a: 1 } });

    const bad = handler({ mode: "openai/form", serverName: "srv", message: "m", requestedSchema: {} });
    const q2 = sent.filter((m) => m.type === "agent:question").at(-1);
    if (q2?.type === "agent:question") driver.resolveQuestion(q2.questionId, "not json");
    expect(await bad).toEqual({ action: "decline" });
    const err = sent.find((m) => m.type === "agent:error");
    expect(err?.type).toBe("agent:error");
  });

  it("serverRequest/resolved cancels a pending approval and emits agent:request-retracted", async () => {
    const { fire, reqHandlers, sent, driver } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    const handler = reqHandlers.get("item/commandExecution/requestApproval")!;
    const replyPromise = handler({ itemId: "i1", command: "x" }, 42);
    fire("serverRequest/resolved", { threadId: "th1", requestId: 42 });
    expect(await replyPromise).toEqual({ decision: "cancel" });
    const perm = sent.find((m) => m.type === "agent:permission-request");
    const retracted = sent.find((m) => m.type === "agent:request-retracted");
    if (perm?.type === "agent:permission-request" && retracted?.type === "agent:request-retracted") {
      expect(retracted.permissionId).toBe(perm.permissionId);
    } else {
      throw new Error("missing permission-request or request-retracted frame");
    }
    // A late answer is a no-op — the pending entry is gone.
    if (perm?.type === "agent:permission-request") driver.resolvePermission(perm.permissionId, "ok");
  });

  it("serverRequest/resolved with no requestId retracts nothing", async () => {
    const { fire, reqHandlers, sent } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    const handler = reqHandlers.get("item/commandExecution/requestApproval")!;
    void handler({ itemId: "i1", command: "x" }, 42);
    // A malformed resolution (missing id) must not collapse to the "" key and
    // fire an unrelated retractor.
    fire("serverRequest/resolved", { threadId: "th1" });
    expect(sent.some((m) => m.type === "agent:request-retracted")).toBe(false);
  });

  it("turn/completed retracts pending questions with a partial answers reply", async () => {
    const { fire, reqHandlers, sent } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    const handler = reqHandlers.get("item/tool/requestUserInput")!;
    const replyPromise = handler({
      itemId: "i1",
      questions: [{ id: "cq1", header: "H", question: "Q?", isOther: false, isSecret: false, options: null }],
    }, 7);
    fire("turn/completed", { turn: { id: "tn1", status: "interrupted" } });
    expect(await replyPromise).toEqual({ answers: { cq1: { answers: [] } } });
    const q = sent.find((m) => m.type === "agent:question");
    const retracted = sent.find((m) => m.type === "agent:request-retracted");
    if (q?.type === "agent:question" && retracted?.type === "agent:request-retracted") {
      expect(retracted.questionId).toBe(q.questionId);
    } else {
      throw new Error("missing question or request-retracted frame");
    }
  });

  it("dispose retracts and cancels everything still pending", async () => {
    const { fire, reqHandlers, sent, driver } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    const cmd = reqHandlers.get("item/commandExecution/requestApproval")!({ itemId: "i1", command: "x" }, 1);
    const elic = reqHandlers.get("mcpServer/elicitation/request")!({ mode: "url", message: "m", url: "u" }, 2);
    await driver.dispose();
    expect(await cmd).toEqual({ decision: "cancel" });
    expect(await elic).toEqual({ action: "cancel" });
    expect(sent.filter((m) => m.type === "agent:request-retracted")).toHaveLength(2);
  });
});

describe("capabilities discovery", () => {
  const tick = () => new Promise((r) => setTimeout(r, 0));
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

  it("emits agent:capabilities with normalized models, modes, and commands", async () => {
    const { sent } = await startedDriver();
    await tick();
    const caps = capsOf(sent);
    expect(caps).toBeDefined();
    expect(caps.models).toEqual([
      { id: "gpt-5.2", name: "GPT-5.2", efforts: ["low", "high"], defaultEffort: "medium" },
    ]); // hidden model filtered
    expect(caps.modes).toEqual([{ id: ":workspace", name: ":workspace" }]); // allowed:false filtered
    expect(caps.commands.map((c: any) => c.id)).toEqual(["skill:code-review", "builtin:compact", "builtin:review"]);
  });

  it("seeds current ids from the thread/start response", async () => {
    const { sent } = await startedDriver();
    await tick();
    const caps = capsOf(sent);
    expect(caps.currentModelId).toBe("gpt-5.2");
    expect(caps.currentEffortId).toBe("medium");
    expect(caps.currentModeId).toBe(":workspace");
  });

  it("is fail-soft: a failing discovery query only omits its section", async () => {
    const { ep, fire, reqHandlers } = makeFakeEndpoint({
      onRequest: (method) => {
        if (method === "model/list") throw new Error("unsupported");
        if (method === "thread/start") return { thread: { id: "th1" } };
        if (method === "permissionProfile/list") return { data: [{ id: ":workspace", allowed: true }] };
        if (method === "skills/list") return { data: [] };
        return {};
      },
    });
    const sent: AbMessage[] = [];
    const driver = new CodexDriver({ sessionId: "s1", endpoint: ep, sendMessage: (m) => sent.push(m), cwd: "/x" });
    await driver.start();
    await tick();
    const caps = capsOf(sent);
    expect(caps.models).toEqual([]);
    expect(caps.modes).toEqual([{ id: ":workspace", name: ":workspace" }]);
    expect(caps.commands.map((c: any) => c.id)).toEqual(["builtin:compact", "builtin:review"]);
  });

  it("setConfig stores advertised ids, re-emits, and applies them on turn/start", async () => {
    const { driver, requests, sent } = await startedDriver();
    await tick();
    driver.setConfig("model", "gpt-5.2");
    driver.setConfig("effort", "high");
    driver.setConfig("mode", ":workspace");
    const caps = capsOf(sent);
    expect(caps.currentEffortId).toBe("high");
    await driver.prompt("go");
    const turn = requests.findLast((r) => r.method === "turn/start");
    expect(turn?.params.model).toBe("gpt-5.2");
    expect(turn?.params.effort).toBe("high");
    expect(turn?.params.permissions).toBe(":workspace");
  });

  it("setConfig ignores ids that were not advertised", async () => {
    const { driver, sent } = await startedDriver();
    await tick();
    const before = sent.filter((m) => m.type === "agent:capabilities").length;
    driver.setConfig("model", "made-up-model");
    driver.setConfig("effort", "ultra");
    expect(sent.filter((m) => m.type === "agent:capabilities").length).toBe(before); // no echo
  });

  it("queues picks that race ahead of discovery and applies them once it lands", async () => {
    // A resumed session replays yesterday's populated pickers to the app
    // instantly, so a pick can arrive while the lists are still empty.
    const { driver, sent } = await startedDriver();
    driver.setConfig("model", "gpt-5.2");
    driver.setConfig("effort", "high");
    await tick();
    const caps = capsOf(sent);
    expect(caps.currentModelId).toBe("gpt-5.2");
    expect(caps.currentEffortId).toBe("high");
  });

  it("routes builtin:compact to thread/compact/start and builtin:review to review/start", async () => {
    const { driver, requests } = await startedDriver();
    await tick();
    await driver.prompt("", "builtin:compact");
    expect(requests.some((r) => r.method === "thread/compact/start")).toBe(true);
    await driver.prompt("focus on perf", "builtin:review");
    const review = requests.findLast((r) => r.method === "review/start");
    expect(review?.params.target).toEqual({ type: "custom", instructions: "focus on perf" });
    await driver.prompt("", "builtin:review");
    expect(requests.findLast((r) => r.method === "review/start")?.params.target).toEqual({ type: "uncommittedChanges" });
  });

  it("routes skill commands as a skill input part with the discovered path", async () => {
    const { driver, requests } = await startedDriver();
    await tick();
    await driver.prompt("this module", "skill:code-review");
    const turn = requests.findLast((r) => r.method === "turn/start");
    expect(turn?.params.input).toEqual([
      { type: "skill", name: "code-review", path: "/x/.codex/skills/code-review" },
      { type: "text", text: "this module" },
    ]);
  });

  it("falls back to plain text for an unknown commandId", async () => {
    const { driver, requests } = await startedDriver();
    await tick();
    await driver.prompt("hello", "cmd:not-codex");
    const turn = requests.findLast((r) => r.method === "turn/start");
    expect(turn?.params.input).toEqual([{ type: "text", text: "hello" }]);
  });
});
