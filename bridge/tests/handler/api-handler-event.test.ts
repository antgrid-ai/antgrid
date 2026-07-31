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
