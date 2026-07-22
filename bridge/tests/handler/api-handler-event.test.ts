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

test("POST /handler-event rejects an invalid event value", async () => {
  const h = startApiServer(baseCtx({ onHandlerEvent: () => {} }));
  const res = await fetch(`http://127.0.0.1:${h.port}/handler-event`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ terminalId: "t1", event: "nope" }),
  });
  expect(res.status).toBe(400);
  h.stop();
});
