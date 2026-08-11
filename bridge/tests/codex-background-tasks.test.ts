import { describe, it, expect } from "bun:test";
import { CodexDriver, type CodexEndpoint } from "../src/agents/codex/chat-backend";
import { mapThreadItem } from "../src/agents/codex/mapping";
import type { AbMessage } from "../src/protocol";

// Minimal fake endpoint (same shape as codex-driver.test.ts's, kept local so
// this file stands alone).
function makeFakeEndpoint() {
  const requests: Array<{ method: string; params: any }> = [];
  const notifs = new Map<string, (p: any) => void>();
  const responses: Record<string, any> = {
    "initialize": {},
    "thread/start": { thread: { id: "th1" }, model: "gpt-5.2" },
    "model/list": { data: [] },
    "permissionProfile/list": { data: [] },
    "skills/list": { data: [] },
    "thread/backgroundTerminals/terminate": { terminated: true },
  };
  let closeHandler: (() => void) | undefined;
  const ep: CodexEndpoint = {
    request: async (method, params) => { requests.push({ method, params }); return responses[method] ?? {}; },
    notify: () => {},
    onNotification: (m, h) => { notifs.set(m, h); },
    onRequest: () => {},
    onClose: (h) => { closeHandler = h; },
    dispose: () => {},
  };
  return { ep, requests, fire: (m: string, p: any) => notifs.get(m)?.(p), close: () => closeHandler?.() };
}

async function startedDriver() {
  const { ep, requests, fire, close } = makeFakeEndpoint();
  const sent: AbMessage[] = [];
  const driver = new CodexDriver({ sessionId: "s1", endpoint: ep, sendMessage: (m) => sent.push(m), cwd: "/x" });
  await driver.start();
  return { driver, requests, fire, sent, close };
}

const lastTasksFrame = (sent: AbMessage[]) =>
  sent.filter((m) => m.type === "agent:background-tasks").at(-1) as any;

const execItem = (status: string) => ({
  id: "it1", type: "commandExecution", command: "bun dev", cwd: "/x",
  status, processId: "4242", aggregatedOutput: "",
});

describe("codex mapping", () => {
  // Regression: codex assigns a processId (the OS pid) to EVERY unified-exec
  // command, foreground included, so surfacing it on the item made a plain
  // `ls` render as a background task for its whole run. Background-ness is the
  // advertised list's to say — never the item's.
  it("never surfaces processId on the item", () => {
    expect(mapThreadItem(execItem("inProgress"))).not.toHaveProperty("backgroundTaskId");
    expect(mapThreadItem(execItem("inProgress"))).not.toHaveProperty("processId");
  });

  it("still maps the exec's user-visible fields", () => {
    const item = mapThreadItem(execItem("inProgress"));
    expect(item?.title).toBe("bun dev");
    expect(item?.toolKind).toBe("shell");
    expect(item?.status).toBe("running");
  });
});

describe("codex background terminals", () => {
  it("advertises an exec still running at turn end, keyed by processId", async () => {
    const { fire, sent } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    fire("item/started", { threadId: "th1", turnId: "tn1", item: execItem("inProgress") });
    fire("turn/completed", { threadId: "th1", turn: { id: "tn1", status: "completed" } });
    const frame = lastTasksFrame(sent);
    expect(frame.tasks).toHaveLength(1);
    expect(frame.tasks[0].taskId).toBe("4242");
    expect(frame.tasks[0].kind).toBe("shell");
    expect(frame.tasks[0].title).toBe("bun dev");
    expect(frame.tasks[0].itemId).toBe("it1");
  });

  it("a foreground command that completes within its turn never appears", async () => {
    const { fire, sent } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    fire("item/started", { threadId: "th1", turnId: "tn1", item: execItem("inProgress") });
    fire("item/completed", { threadId: "th1", turnId: "tn1", item: execItem("completed") });
    fire("turn/completed", { threadId: "th1", turn: { id: "tn1", status: "completed" } });
    expect(sent.filter((m) => m.type === "agent:background-tasks")).toHaveLength(0);
  });

  it("drops the task when the deferred item/completed lands after turn end", async () => {
    const { fire, sent } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    fire("item/started", { threadId: "th1", turnId: "tn1", item: execItem("inProgress") });
    fire("turn/completed", { threadId: "th1", turn: { id: "tn1", status: "completed" } });
    // Process exits during a later turn — codex tags the original turnId.
    fire("item/completed", { threadId: "th1", turnId: "tn1", item: execItem("completed") });
    expect(lastTasksFrame(sent).tasks).toHaveLength(0);
    // The item update itself still flows with the original turn id.
    const upd = sent.filter((m: any) => m.type === "agent:item-updated" && m.itemId === "it1").at(-1) as any;
    expect(upd.turnId).toBe("tn1");
    expect(upd.item.status).toBe("completed");
  });

  it("stopTask sends thread/backgroundTerminals/terminate", async () => {
    const { driver, requests } = await startedDriver();
    await driver.stopTask("4242");
    const req = requests.find((r) => r.method === "thread/backgroundTerminals/terminate");
    expect(req?.params).toEqual({ threadId: "th1", processId: "4242" });
  });

  // What the stop button actually looks like on the wire (probe-verified against
  // a real codex app-server): terminate resolves {terminated:true}, then codex
  // reports the process IT KILLED as status "failed" exitCode -1 — which
  // mapToolStatus turns into "error". A row the user stopped on purpose must not
  // render as a red failure, and only our own terminate can tell the two apart.
  it("a stopped background exec settles as cancelled, not a red error", async () => {
    const { driver, fire, sent } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    fire("item/started", { threadId: "th1", turnId: "tn1", item: execItem("inProgress") });
    fire("turn/completed", { threadId: "th1", turn: { id: "tn1", status: "completed" } });
    await driver.stopTask("4242");
    fire("item/completed", { threadId: "th1", turnId: "tn1", item: { ...execItem("failed"), exitCode: -1 } });
    const upd = sent.filter((m: any) => m.type === "agent:item-updated" && m.itemId === "it1").at(-1) as any;
    expect(upd.item.status).toBe("cancelled");
    expect(lastTasksFrame(sent).tasks).toHaveLength(0);
  });

  it("a background exec that fails on its own still settles as an error", async () => {
    const { fire, sent } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    fire("item/started", { threadId: "th1", turnId: "tn1", item: execItem("inProgress") });
    fire("turn/completed", { threadId: "th1", turn: { id: "tn1", status: "completed" } });
    fire("item/completed", { threadId: "th1", turnId: "tn1", item: { ...execItem("failed"), exitCode: 1 } });
    const upd = sent.filter((m: any) => m.type === "agent:item-updated" && m.itemId === "it1").at(-1) as any;
    expect(upd.item.status).toBe("error");
  });

  it("clears the advertised list when codex dies unexpectedly", async () => {
    const { fire, sent, close } = await startedDriver();
    fire("turn/started", { threadId: "th1", turn: { id: "tn1" } });
    fire("item/started", { threadId: "th1", turnId: "tn1", item: execItem("inProgress") });
    fire("turn/completed", { threadId: "th1", turn: { id: "tn1", status: "completed" } });
    close();
    expect(lastTasksFrame(sent).tasks).toHaveLength(0);
  });
});
