import { describe, it, expect } from "bun:test";
import { OpencodeDriver, type OpencodeClientLike, type OpencodeEvent } from "../src/agents/opencode/chat-backend";

// Minimal event-queue client: createSession records its opts and resolves to a
// fixed id, events() yields whatever the test pushes. Only the members the title
// path touches carry behaviour; everything else no-ops.
function makeClient(rootId = "sess-1") {
  const queue: OpencodeEvent[] = [];
  const created: Array<{ title?: string; parentID?: string }> = [];
  let waiters: Array<(v: IteratorResult<OpencodeEvent>) => void> = [];
  let ended = false;
  const push = (e: OpencodeEvent) => { const w = waiters.shift(); if (w) w({ value: e, done: false }); else queue.push(e); };
  const done = () => { ended = true; waiters.forEach((w) => w({ value: undefined as any, done: true })); waiters = []; };
  const client: OpencodeClientLike = {
    createSession: async (o) => { created.push(o); return rootId; },
    messages: async () => [],
    deleteMessage: async () => {},
    prompt: async () => {},
    abort: async () => {},
    summarize: async () => {},
    replyPermission: async () => {},
    replyQuestion: async () => {},
    listCommands: async () => [],
    listAgents: async () => [],
    listProviders: async () => ({ all: [], default: {}, connected: [] }),
    command: async () => {},
    events: () => ({
      [Symbol.asyncIterator]() {
        return {
          next(): Promise<IteratorResult<OpencodeEvent>> {
            if (queue.length) return Promise.resolve({ value: queue.shift()!, done: false });
            if (ended) return Promise.resolve({ value: undefined as any, done: true });
            return new Promise((res) => waiters.push(res));
          },
        };
      },
    }),
    dispose: () => done(),
  };
  return { client, push, done, created };
}

const tick = () => new Promise((r) => setTimeout(r, 0));

describe("OpencodeDriver session.updated → onTitle", () => {
  // The whole auto-naming feature hangs off this argument. opencode generates a
  // title from the first prompt ONLY for a session that doesn't already have
  // one; any title passed here disables generation for good, so session.updated
  // never carries a real title and the app stays on "Session N".
  it("creates the session with no title so opencode will generate one", async () => {
    const { client, created } = makeClient();
    const driver = new OpencodeDriver({ sessionId: "s1", client, sendMessage: () => {} });
    await driver.start();
    expect(created).toHaveLength(1);
    expect(created[0]!.title).toBeUndefined();
  });

  it("forwards the root session's generated title", async () => {
    const { client, push } = makeClient("sess-1");
    const titles: string[] = [];
    const driver = new OpencodeDriver({
      sessionId: "s1", client, sendMessage: () => {}, onTitle: (t) => titles.push(t),
    });
    await driver.start(); // rootSessionId = "sess-1"

    push({ type: "session.updated", properties: { info: { id: "sess-1", title: "Fix the login bug" } } });
    await tick();
    expect(titles).toEqual(["Fix the login bug"]);

    // A title for an unrelated session id belongs to another driver — ignored.
    push({ type: "session.updated", properties: { info: { id: "other", title: "x" } } });
    await tick();
    expect(titles).toEqual(["Fix the login bug"]);
  });

  it("ignores a subtask child's own title", async () => {
    const { client, push } = makeClient("sess-1");
    const titles: string[] = [];
    const driver = new OpencodeDriver({
      sessionId: "s1", client, sendMessage: () => {}, onTitle: (t) => titles.push(t),
    });
    await driver.start();

    push({ type: "session.created", properties: { info: { id: "sess-child", parentID: "sess-1", agent: "explore" } } });
    await tick();
    // opencode titles child sessions too; taking one would rename the chat
    // session after whatever a subagent happened to do last.
    push({ type: "session.updated", properties: { info: { id: "sess-child", title: "Find TODOs (@explore subagent)" } } });
    await tick();
    expect(titles).toEqual([]);
  });
});
