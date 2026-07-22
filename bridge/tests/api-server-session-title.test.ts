import { describe, expect, test } from "bun:test";
import { startApiServer, type AgentContext } from "../src/api-server";

function ctx(over: Partial<AgentContext> = {}): AgentContext {
  return {
    manager: () => null,
    config: () => ({} as any),
    project: () => ({ id: "p1", path: "/tmp" } as any),
    sendAb: () => {},
    ...over,
  };
}

describe("POST /session-title", () => {
  test("valid body routes to onSessionTitle", async () => {
    const seen: any[] = [];
    const srv = startApiServer(ctx({ onSessionTitle: (b) => seen.push(b) }));
    try {
      const res = await fetch(`http://127.0.0.1:${srv.port}/session-title`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ terminalId: "t1", sessionId: "s1", title: "Hi", transcriptPath: "/tmp/t.jsonl", agent: "opencode" }),
      });
      expect(res.status).toBe(200);
      expect(seen).toEqual([{ terminalId: "t1", sessionId: "s1", title: "Hi", transcriptPath: "/tmp/t.jsonl", agent: "opencode" }]);
    } finally { srv.stop(); }
  });

  test("malformed JSON → 400, handler not called", async () => {
    const seen: any[] = [];
    const srv = startApiServer(ctx({ onSessionTitle: (b) => seen.push(b) }));
    try {
      const res = await fetch(`http://127.0.0.1:${srv.port}/session-title`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: "not{json",
      });
      expect(res.status).toBe(400);
      expect(seen).toEqual([]);
    } finally { srv.stop(); }
  });

  test("invalid body → 400, handler not called", async () => {
    const seen: any[] = [];
    const srv = startApiServer(ctx({ onSessionTitle: (b) => seen.push(b) }));
    try {
      const res = await fetch(`http://127.0.0.1:${srv.port}/session-title`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ terminalId: "t1" }), // missing sessionId
      });
      expect(res.status).toBe(400);
      expect(seen).toEqual([]);
    } finally { srv.stop(); }
  });
});
