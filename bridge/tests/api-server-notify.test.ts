import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startApiServer, type AgentContext } from "../src/api-server";
import type { AbMessage } from "../src/protocol";

function ctx(over: Partial<AgentContext> = {}): AgentContext {
  return {
    manager: () => null,
    config: () => ({} as any),
    project: () => ({ id: "p1", path: "/tmp" } as any),
    sendAb: () => {},
    ...over,
  };
}

const tempDirs: string[] = [];

afterAll(() => {
  for (const dir of tempDirs) rmSync(dir, { recursive: true, force: true });
});

function transcript(text: string): string {
  const dir = mkdtempSync(join(tmpdir(), "notify-"));
  tempDirs.push(dir);
  const path = join(dir, "t.jsonl");
  writeFileSync(path, JSON.stringify({
    type: "assistant", message: { role: "assistant", content: [{ type: "text", text }] },
  }), "utf8");
  return path;
}

async function post(port: number, body: unknown) {
  return fetch(`http://127.0.0.1:${port}/notify`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

describe("POST /notify", () => {
  test("resolves the body from a claude transcriptPath", async () => {
    const sent: AbMessage[] = [];
    const srv = startApiServer(ctx({ sendAb: (m) => sent.push(m) }));
    try {
      const res = await post(srv.port, {
        type: "task_complete", agent: "claude", transcriptPath: transcript("Fixed the auth bug"),
      });
      expect(res.status).toBe(200);
      expect((sent[0] as any).message).toBe("Fixed the auth bug");
    } finally { srv.stop(); }
  });

  test("resolves sessionTitle from terminalId", async () => {
    const sent: AbMessage[] = [];
    const srv = startApiServer(ctx({
      sendAb: (m) => sent.push(m),
      sessionName: (id) => (id === "t1" ? "Fix auth bug" : undefined),
    }));
    try {
      await post(srv.port, { type: "task_complete", terminalId: "t1" });
      expect((sent[0] as any).sessionTitle).toBe("Fix auth bug");
    } finally { srv.stop(); }
  });

  test("an unknown terminalId leaves sessionTitle undefined", async () => {
    const sent: AbMessage[] = [];
    const srv = startApiServer(ctx({ sendAb: (m) => sent.push(m), sessionName: () => undefined }));
    try {
      await post(srv.port, { type: "task_complete", terminalId: "nope" });
      expect((sent[0] as any).sessionTitle).toBeUndefined();
    } finally { srv.stop(); }
  });

  test("an inline message wins over transcript resolution", async () => {
    const sent: AbMessage[] = [];
    const srv = startApiServer(ctx({ sendAb: (m) => sent.push(m) }));
    try {
      await post(srv.port, {
        type: "permission_request", agent: "claude", message: "Run rm -rf?", transcriptPath: transcript("ignored"),
      });
      expect((sent[0] as any).message).toBe("Run rm -rf?");
    } finally { srv.stop(); }
  });

  test("a non-claude agent is never parsed as a claude transcript", async () => {
    const sent: AbMessage[] = [];
    const srv = startApiServer(ctx({ sendAb: (m) => sent.push(m) }));
    try {
      await post(srv.port, { type: "task_complete", agent: "gemini", transcriptPath: transcript("nope") });
      expect((sent[0] as any).message).toBeUndefined();
    } finally { srv.stop(); }
  });

  test("a missing transcript fails open to an undefined message", async () => {
    const sent: AbMessage[] = [];
    const srv = startApiServer(ctx({ sendAb: (m) => sent.push(m) }));
    try {
      const res = await post(srv.port, {
        type: "task_complete", agent: "claude", transcriptPath: join(tmpdir(), "gone-8c21.jsonl"),
      });
      expect(res.status).toBe(200);
      expect((sent[0] as any).message).toBeUndefined();
    } finally { srv.stop(); }
  });

  test("today's bare body still works and still emits", async () => {
    const sent: AbMessage[] = [];
    const srv = startApiServer(ctx({ sendAb: (m) => sent.push(m) }));
    try {
      const res = await post(srv.port, { type: "task_complete" });
      expect(res.status).toBe(200);
      expect((sent[0] as any).notificationType).toBe("task_complete");
      expect((sent[0] as any).message).toBeUndefined();
      expect((sent[0] as any).sessionTitle).toBeUndefined();
    } finally { srv.stop(); }
  });

  test("an unknown type is still rejected", async () => {
    const sent: AbMessage[] = [];
    const srv = startApiServer(ctx({ sendAb: (m) => sent.push(m) }));
    try {
      const res = await post(srv.port, { type: "not_a_type" });
      expect(res.status).toBe(400);
      expect(sent).toHaveLength(0);
    } finally { srv.stop(); }
  });
});

describe("POST /turn-start", () => {
  test("fires onTurnStart and emits NO app-facing frame", async () => {
    const sent: AbMessage[] = [];
    let turns = 0;
    const srv = startApiServer(ctx({
      sendAb: (m) => sent.push(m),
      onTurnStart: () => { turns++; },
    }));
    try {
      const res = await fetch(`http://127.0.0.1:${srv.port}/turn-start`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ terminalId: "t1" }),
      });
      expect(res.status).toBe(200);
      expect(turns).toBe(1);
      // A turn-start is state, not a notification — nothing goes on the bus.
      expect(sent).toHaveLength(0);
    } finally { srv.stop(); }
  });

  test("tolerates an empty body", async () => {
    let turns = 0;
    const srv = startApiServer(ctx({ onTurnStart: () => { turns++; } }));
    try {
      const res = await fetch(`http://127.0.0.1:${srv.port}/turn-start`, { method: "POST" });
      expect(res.status).toBe(200);
      expect(turns).toBe(1);
    } finally { srv.stop(); }
  });
});
