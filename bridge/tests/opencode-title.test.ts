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

describe("OpencodeDriver session naming", () => {
  // Antgrid names its own sessions (see ResolvedTitle), so opencode's title is
  // neither read nor written: session.updated carries only opencode's own
  // generated name and is dropped, and nothing is stamped onto opencode's
  // session record here either. Passing one would rename the conversation in
  // the user's own opencode history off a name they never chose.
  it("creates the session without stamping a title on it", async () => {
    const { client, created } = makeClient();
    const driver = new OpencodeDriver({ sessionId: "s1", client, sendMessage: () => {} });
    await driver.start();
    expect(created).toHaveLength(1);
    expect(created[0]!.title).toBeUndefined();
  });

  // opencode is the one agent with no vendor integration to fall back on: it
  // ships no hook, writes no rename we read, and its plugin's inline title is
  // dropped. So the driver ignoring session.updated is the whole of the claim
  // that our generated name survives — a case re-added to the event switch
  // renames the chat after whatever opencode last called the conversation,
  // including a subagent's own title.
  it("drops session.updated, for the root session and for a subtask alike", async () => {
    const { client, push, done } = makeClient("sess-1");
    const sent: unknown[] = [];
    const driver = new OpencodeDriver({
      sessionId: "s1", client, sendMessage: (m) => { sent.push(m); },
    });
    await driver.start();
    sent.length = 0;

    push({ type: "session.updated", properties: { info: { id: "sess-1", title: "Fix the login bug" } } });
    push({
      type: "session.updated",
      properties: { info: { id: "sess-child", parentID: "sess-1", title: "Find TODOs" } },
    });
    await tick();
    expect(sent).toEqual([]);
    done();
  });
});
