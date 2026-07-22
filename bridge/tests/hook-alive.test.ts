import { test, expect } from "bun:test";
import { startApiServer } from "../src/api-server";
import type { AbMessage } from "../src/protocol";

test("/notify rejects unknown type with 400 and does not emit", async () => {
  const emitted: AbMessage[] = [];
  const handle = startApiServer({
    manager: () => null,
    config: () => ({}) as any,
    project: () => ({ id: "p1", path: "/x", name: "p" }) as any,
    sendAb: (msg: AbMessage) => { emitted.push(msg); },
  } as any);
  const port = handle.port;
  const res = await fetch(`http://127.0.0.1:${port}/notify`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ type: "bogus" }),
  });
  expect(res.status).toBe(400);
  expect(emitted).toHaveLength(0);
  handle.stop();
});

test("/notify accepts valid type and emits notification:push", async () => {
  const emitted: AbMessage[] = [];
  const handle = startApiServer({
    manager: () => null,
    config: () => ({}) as any,
    project: () => ({ id: "p1", path: "/x", name: "p" }) as any,
    sendAb: (msg: AbMessage) => { emitted.push(msg); },
  } as any);
  const port = handle.port;
  const res = await fetch(`http://127.0.0.1:${port}/notify`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ type: "task_complete", message: "done" }),
  });
  expect(res.status).toBe(200);
  expect(emitted).toHaveLength(1);
  expect(emitted[0].type).toBe("notification:push");
  handle.stop();
});

test("/hook-alive invokes onHookAlive with terminalId", async () => {
  let seen: string | null = null;
  const handle = startApiServer({
    manager: () => null,
    config: () => ({}) as any,
    project: () => ({ id: "p1", path: "/x", name: "p" }) as any,
    sendAb: () => {},
    onHookAlive: (id: string) => { seen = id; },
  } as any);
  const port = handle.port;
  await fetch(`http://127.0.0.1:${port}/hook-alive`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ terminalId: "t9" }),
  });
  expect(seen as string | null).toBe("t9");
  handle.stop();
});
