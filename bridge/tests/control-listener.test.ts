import { test, expect, afterEach } from "bun:test";
import { ControlListener } from "../src/control-listener";
import type { ControlRequest, ControlResponse } from "../src/control-protocol";

let listener: ControlListener | null = null;
afterEach(async () => { await listener?.stop(); listener = null; });

test("peer resume requires owner bearer and fences before acknowledgement", async () => {
  let fenced = false;
  listener = new ControlListener({ token: "owner-secret", onPeerResume: () => { fenced = true; },
    handler: async (req) => ({ id: req.id, ok: true, type: "project:list", projects: [] }) });
  await listener.start();
  const url = `http://127.0.0.1:${listener.port}/peer-resume`;
  for (const authorization of [undefined, "Bearer wrong"]) {
    expect((await fetch(url, { method: "POST", headers: authorization ? { authorization } : {} })).status).toBe(401);
    expect(fenced).toBe(false);
  }
  const response = await fetch(url, { method: "POST", headers: { authorization: "Bearer owner-secret" } });
  expect(response.status).toBe(202);
  expect(fenced).toBe(true);
  expect(await response.json()).toEqual({ ok: true });
});

async function start(handler: (req: ControlRequest) => Promise<ControlResponse>): Promise<{ port: number; token: string }> {
  const token = "secret-token";
  listener = new ControlListener({ token, handler });
  await listener.start();
  return { port: listener.port, token };
}

test("rejects a request with no Authorization header (401)", async () => {
  const { port } = await start(async (r) => ({ id: r.id, ok: true, type: "project:list", projects: [] }));
  const res = await fetch(`http://127.0.0.1:${port}/control`, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ id: "1", type: "project:list" }),
  });
  expect(res.status).toBe(401);
});

test("rejects a wrong token (401)", async () => {
  const { port } = await start(async (r) => ({ id: r.id, ok: true, type: "project:list", projects: [] }));
  const res = await fetch(`http://127.0.0.1:${port}/control`, {
    method: "POST", headers: { "content-type": "application/json", authorization: "Bearer nope" },
    body: JSON.stringify({ id: "1", type: "project:list" }),
  });
  expect(res.status).toBe(401);
});

test("dispatches a valid request and returns the handler's response", async () => {
  const { port, token } = await start(async (r) => ({ id: r.id, ok: true, type: "project:list", projects: [{ projectId: "p", path: "/tmp/p", running: true, mode: "local" }] }));
  const res = await fetch(`http://127.0.0.1:${port}/control`, {
    method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify({ id: "9", type: "project:list" }),
  });
  expect(res.status).toBe(200);
  const body = await res.json();
  expect(body).toEqual({ id: "9", ok: true, type: "project:list", projects: [{ projectId: "p", path: "/tmp/p", running: true, mode: "local" }] });
});

test("returns a 400 ok:false error for a malformed request body", async () => {
  const { port, token } = await start(async (r) => ({ id: r.id, ok: true, type: "project:list", projects: [] }));
  const res = await fetch(`http://127.0.0.1:${port}/control`, {
    method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify({ id: "1", type: "project:bogus" }),
  });
  expect(res.status).toBe(400);
  const body = await res.json();
  expect(body.ok).toBe(false);
});

test("rejects an oversized body without invoking the handler", async () => {
  let handlerCalled = false;
  const { port, token } = await start(async (r) => { handlerCalled = true; return { id: r.id, ok: true, type: "project:list", projects: [] }; });
  // > 1 MiB body cap. Bun.serve rejects before the fetch handler parses it.
  const huge = "x".repeat(2 * 1024 * 1024);
  const res = await fetch(`http://127.0.0.1:${port}/control`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify({ id: "1", type: "project:list", junk: huge }),
  }).catch(() => null);
  // The request is refused (413 or a dropped connection); the handler never runs.
  if (res) expect(res.status).not.toBe(200);
  expect(handlerCalled).toBe(false);
});
