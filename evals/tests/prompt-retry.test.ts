import { test, expect } from "bun:test";
import { promptUntilTurnStart } from "../helpers/chat";

// A pure unit test — no relay, no agent binary, no network — even though every
// other file in evals/tests spawns a real environment. It lives here because
// `bridge/tsconfig.json` pins `rootDir` to bridge/, so importing this helper
// from bridge/tests fails typecheck with TS6059 (the type-only RelayClient
// import drags relay-client.ts across the boundary too). Keep it selectable by
// filename for a fast CI tier rather than moving it out of the workspace that
// owns the code under test.
//
// What it pins: `promptUntilTurnStart` re-sends agent:prompt ONLY on the
// warm-up rejection. A bare timeout means the prompt was accepted and the turn
// is merely slow — re-prompting there bills a second model turn against real
// codex / opencode credits and leaves a duplicate user message in the
// transcript. That bug shipped and survived unnoticed because every suite using
// this helper was skipped, so the assertions are on the SEND COUNT: the thing
// that silently regressed is the thing measured.

/** A RelayClient stub that counts prompts and replays scripted waitFor outcomes. */
function fakeApp(script: Array<Record<string, unknown> | null>) {
  const sent: Record<string, unknown>[] = [];
  let i = 0;
  return {
    sent,
    sendOnStream: (_streamId: string, msg: Record<string, unknown>) => sent.push(msg),
    // `null` scripts a timeout: the real waitFor rejects, it never resolves null.
    waitFor: async (_match: unknown, _timeoutMs: number) => {
      const next = i < script.length ? script[i++] : null;
      if (next === null) throw new Error("timeout");
      return next;
    },
  };
}

const TURN = { type: "agent:turn-start", sessionId: "s1", turnId: "t1" };
const WARMUP = {
  type: "agent:error",
  sessionId: "s1",
  error: { message: "chat session not started" },
};
const FATAL = { type: "agent:error", sessionId: "s1", error: { message: "boom" } };

test("a timeout does not re-prompt", async () => {
  const app = fakeApp([null]);
  await expect(promptUntilTurnStart(app as never, "st1", "s1")).rejects.toThrow(
    /no agent:turn-start/,
  );
  expect(app.sent.length).toBe(1);
});

test("the warm-up rejection re-prompts exactly once each", async () => {
  const app = fakeApp([WARMUP, WARMUP, TURN]);
  const evt = await promptUntilTurnStart(app as never, "st1", "s1");
  expect(evt.turnId).toBe("t1");
  expect(app.sent.length).toBe(3);
});

test("a real driver error surfaces without re-prompting", async () => {
  const app = fakeApp([FATAL]);
  await expect(promptUntilTurnStart(app as never, "st1", "s1")).rejects.toThrow(/boom/);
  expect(app.sent.length).toBe(1);
});

test("an immediate turn-start sends exactly one prompt", async () => {
  const app = fakeApp([TURN]);
  await promptUntilTurnStart(app as never, "st1", "s1");
  expect(app.sent.length).toBe(1);
});
