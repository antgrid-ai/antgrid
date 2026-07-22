import { describe, it, expect } from "bun:test";
import { OpencodeDriver, type OpencodeClientLike, type OpencodeEvent } from "../src/opencode/opencode-driver";

// Minimal event-queue client: createSession resolves to a fixed id, events()
// yields whatever the test pushes. Only the members the title path touches carry
// behaviour; everything else no-ops.
function makeClient(rootId = "sess-1") {
  const queue: OpencodeEvent[] = [];
  let waiters: Array<(v: IteratorResult<OpencodeEvent>) => void> = [];
  let ended = false;
  const push = (e: OpencodeEvent) => { const w = waiters.shift(); if (w) w({ value: e, done: false }); else queue.push(e); };
  const done = () => { ended = true; waiters.forEach((w) => w({ value: undefined as any, done: true })); waiters = []; };
  const client: OpencodeClientLike = {
    createSession: async () => rootId,
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
  return { client, push, done };
}

const tick = () => new Promise((r) => setTimeout(r, 0));

describe("OpencodeDriver session.updated → onTitle", () => {
  it("forwards a generated title, filters the seed, and ignores out-of-tree sessions", async () => {
    const { client, push } = makeClient("sess-1");
    const titles: string[] = [];
    const driver = new OpencodeDriver({
      sessionId: "s1", client, sendMessage: () => {},
      title: "proj-seed", onTitle: (t) => titles.push(t),
    });
    await driver.start(); // rootSessionId = "sess-1"

    // Seed title echoed back by opencode at createSession — must NOT auto-name.
    push({ type: "session.updated", properties: { info: { id: "sess-1", title: "proj-seed" } } });
    await tick();
    expect(titles).toEqual([]);

    // Server-generated title for the root session — forwarded.
    push({ type: "session.updated", properties: { info: { id: "sess-1", title: "Fix the login bug" } } });
    await tick();
    expect(titles).toEqual(["Fix the login bug"]);

    // A title for an unrelated session id is not in this driver's tree — ignored.
    push({ type: "session.updated", properties: { info: { id: "other", title: "x" } } });
    await tick();
    expect(titles).toEqual(["Fix the login bug"]);
  });
});
