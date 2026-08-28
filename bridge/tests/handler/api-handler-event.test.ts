// bridge/tests/handler/api-handler-event.test.ts
import { test, expect } from "bun:test";
import { startApiServer } from "../../src/api-server";

function baseCtx(over: any = {}) {
  return {
    manager: () => null, config: () => ({}) as any, project: () => ({ id: "p1", path: "/p", name: "p" }) as any,
    sendAb: () => {}, ...over,
  };
}

test("POST /handler-event forwards a valid body to onHandlerEvent", async () => {
  const got: any[] = [];
  const h = startApiServer(baseCtx({ onHandlerEvent: (b: any) => got.push(b) }));
  const res = await fetch(`http://127.0.0.1:${h.port}/handler-event`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ terminalId: "t1", event: "awaiting_input", agent: "claude", transcriptPath: "/x.jsonl" }),
  });
  expect(res.status).toBe(200);
  expect(got).toHaveLength(1);
  expect(got[0].event).toBe("awaiting_input");
  h.stop();
});

test("POST /handler-event forwards the lifecycle kinds with their optional fields", async () => {
  const got: any[] = [];
  const h = startApiServer(baseCtx({ onHandlerEvent: (b: any) => got.push(b) }));
  const post = (body: unknown) => fetch(`http://127.0.0.1:${h.port}/handler-event`, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
  });
  expect((await post({ terminalId: "t1", event: "limit_hit", resetsAt: 1234, errorClass: "rate_limit" })).status).toBe(200);
  expect((await post({ terminalId: "t1", event: "limit_cleared" })).status).toBe(200);
  expect((await post({ terminalId: "t1", event: "turn_failed", errorClass: "overloaded" })).status).toBe(200);
  expect(got.map((b) => b.event)).toEqual(["limit_hit", "limit_cleared", "turn_failed"]);
  expect(got[0].resetsAt).toBe(1234);
  expect(got[0].errorClass).toBe("rate_limit");
  expect(got[2].errorClass).toBe("overloaded");
  h.stop();
});

test("POST /handler-event rejects an invalid event value", async () => {
  const h = startApiServer(baseCtx({ onHandlerEvent: () => {} }));
  const res = await fetch(`http://127.0.0.1:${h.port}/handler-event`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ terminalId: "t1", event: "nope" }),
  });
  expect(res.status).toBe(400);
  h.stop();
});

// ── The stale post-completion idle nudge gate ───────────────────────────────
//
// The agent's notification hook fires the same "waiting for your input" signal
// for a genuine mid-turn block and for its idle nudge after the turn ended, so
// the host answers it from turn state AND from the poster's own reading of the
// message. These pin WHICH events the gate is asked about and which way it fails
// when either half is missing.

test("a stale post-completion awaiting_input is dropped, not forwarded", async () => {
  const got: any[] = [];
  const h = startApiServer(baseCtx({
    onHandlerEvent: (b: any) => got.push(b),
    isStaleIdleNudge: () => true,
  }));
  const res = await fetch(`http://127.0.0.1:${h.port}/handler-event`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ terminalId: "t1", event: "awaiting_input", idleNudge: true }),
  });
  // Still 200 — the hook must not see a failure for a deliberate drop.
  expect(res.status).toBe(200);
  expect(await res.json()).toEqual({ ok: true, stale: true });
  expect(got).toEqual([]);
  h.stop();
});

test("a genuine awaiting_input is forwarded when the reduction says the turn is still live", async () => {
  const got: any[] = [];
  const h = startApiServer(baseCtx({
    onHandlerEvent: (b: any) => got.push(b),
    isStaleIdleNudge: () => false,
  }));
  const res = await fetch(`http://127.0.0.1:${h.port}/handler-event`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ terminalId: "t1", event: "awaiting_input" }),
  });
  expect(res.status).toBe(200);
  expect(await res.json()).toEqual({ ok: true });
  expect(got.map((b) => b.event)).toEqual(["awaiting_input"]);
  h.stop();
});

test("no event kind other than awaiting_input is gated on the predicate", async () => {
  // The load-bearing one: a turn_end or a limit lifecycle event is unambiguous,
  // and suppressing one would strand the engine's own turn bookkeeping.
  const got: any[] = [];
  const h = startApiServer(baseCtx({
    onHandlerEvent: (b: any) => got.push(b),
    isStaleIdleNudge: () => true,
  }));
  const post = (body: unknown) => fetch(`http://127.0.0.1:${h.port}/handler-event`, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
  });
  expect((await post({ terminalId: "t1", event: "turn_end" })).status).toBe(200);
  expect((await post({ terminalId: "t1", event: "limit_hit" })).status).toBe(200);
  expect((await post({ terminalId: "t1", event: "turn_failed" })).status).toBe(200);
  expect((await post({ terminalId: "t1", event: "limit_cleared" })).status).toBe(200);
  expect(got.map((b) => b.event)).toEqual(["turn_end", "limit_hit", "turn_failed", "limit_cleared"]);
  h.stop();
});

test("a context with no isStaleIdleNudge forwards awaiting_input (fail toward forwarding)", async () => {
  // An unwired owner must never silence the supervisor: a dropped genuine block
  // leaves a blocked agent with no further event able to raise it.
  const got: any[] = [];
  const h = startApiServer(baseCtx({ onHandlerEvent: (b: any) => got.push(b) }));
  const res = await fetch(`http://127.0.0.1:${h.port}/handler-event`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ terminalId: "t1", event: "awaiting_input" }),
  });
  expect(res.status).toBe(200);
  expect(await res.json()).toEqual({ ok: true });
  expect(got).toHaveLength(1);
  h.stop();
});

test("the predicate is asked about the event's own terminalId", async () => {
  const asked: string[] = [];
  const h = startApiServer(baseCtx({
    onHandlerEvent: () => {},
    isStaleIdleNudge: (id: string) => { asked.push(id); return false; },
  }));
  await fetch(`http://127.0.0.1:${h.port}/handler-event`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ terminalId: "t2", event: "awaiting_input", idleNudge: true }),
  });
  expect(asked).toEqual(["t2"]);
  h.stop();
});

test("a block the poster did NOT read as the nudge shape survives a latched turn-end", async () => {
  // The gate's other half. This POST is decided before the /notify of the same
  // hook invocation has folded, so turn state alone would drop the one event
  // that reports a genuine mid-turn block — while that /notify goes on to record
  // it as a live "needs you". Reachable whenever the slot's last notification was
  // a turn-end: a lost /turn-start, or Handler's own park push.
  const got: any[] = [];
  const asked: string[] = [];
  const h = startApiServer(baseCtx({
    onHandlerEvent: (b: any) => got.push(b),
    isStaleIdleNudge: (id: string) => { asked.push(id); return true; },
  }));
  const res = await fetch(`http://127.0.0.1:${h.port}/handler-event`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ terminalId: "t1", event: "awaiting_input", idleNudge: false }),
  });
  expect(res.status).toBe(200);
  expect(await res.json()).toEqual({ ok: true });
  expect(got.map((b) => b.event)).toEqual(["awaiting_input"]);
  // Turn state is never even consulted: the poster already said this is a block.
  expect(asked).toEqual([]);
  h.stop();
});

test("an awaiting_input that claims nothing about its shape is forwarded", async () => {
  // A poster predating the field says nothing, and silence must not be read as
  // "this is the idle nudge" — the drop is a suppression, and an unstated answer
  // has to fail toward the supervisor hearing about it.
  const got: any[] = [];
  const h = startApiServer(baseCtx({
    onHandlerEvent: (b: any) => got.push(b),
    isStaleIdleNudge: () => true,
  }));
  const res = await fetch(`http://127.0.0.1:${h.port}/handler-event`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ terminalId: "t1", event: "awaiting_input" }),
  });
  expect(res.status).toBe(200);
  expect(await res.json()).toEqual({ ok: true });
  expect(got).toHaveLength(1);
  h.stop();
});
