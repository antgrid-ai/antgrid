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
});
