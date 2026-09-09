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

  test("carries the terminalId as sessionId — identity, not the renameable title", async () => {
    const sent: AbMessage[] = [];
    const srv = startApiServer(ctx({
      sendAb: (m) => sent.push(m),
      sessionName: () => "Fix auth bug",
    }));
    try {
      await post(srv.port, { type: "task_complete", terminalId: "t1" });
      expect((sent[0] as any).sessionId).toBe("t1");
    } finally { srv.stop(); }
  });

  test("a notification with no terminalId names no session", async () => {
    const sent: AbMessage[] = [];
    const srv = startApiServer(ctx({ sendAb: (m) => sent.push(m) }));
    try {
      await post(srv.port, { type: "task_complete" });
      expect((sent[0] as any).sessionId).toBeUndefined();
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
      await post(srv.port, { type: "task_complete", agent: "codex", transcriptPath: transcript("nope") });
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
  test("fires onTurnStart with the posted slot and emits NO app-facing frame", async () => {
    const sent: AbMessage[] = [];
    let turns = 0;
    const slots: Array<string | undefined> = [];
    const srv = startApiServer(ctx({
      sendAb: (m) => sent.push(m),
      onTurnStart: (id) => { turns++; slots.push(id); },
    }));
    try {
      const res = await fetch(`http://127.0.0.1:${srv.port}/turn-start`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ terminalId: "t1" }),
      });
      expect(res.status).toBe(200);
      expect(turns).toBe(1);
      expect(slots).toEqual(["t1"]);
      // A turn-start is state, not a notification — nothing goes on the bus.
      expect(sent).toHaveLength(0);
    } finally { srv.stop(); }
  });

  test("tolerates an empty body, naming no session", async () => {
    let turns = 0;
    const slots: Array<string | undefined> = [];
    const srv = startApiServer(ctx({ onTurnStart: (id) => { turns++; slots.push(id); } }));
    try {
      const res = await fetch(`http://127.0.0.1:${srv.port}/turn-start`, { method: "POST" });
      expect(res.status).toBe(200);
      expect(turns).toBe(1);
      expect(slots).toEqual([undefined]);
    } finally { srv.stop(); }
  });
});

describe("POST /notify — the enum this schema hand-mirrors", () => {
  test("an awaiting_input notification is accepted and emitted", async () => {
    // Regression: this member was missing from the copy while every claude idle
    // nudge posted it, so the post was answered 400 — and `runHookInvocation`
    // ignores every response, so the notification simply never arrived.
    const sent: AbMessage[] = [];
    const srv = startApiServer(ctx({ sendAb: (m) => sent.push(m) }));
    try {
      const res = await post(srv.port, { type: "awaiting_input", terminalId: "t1", message: "Claude is waiting for your input" });
      expect(res.status).toBe(200);
      expect((sent[0] as any).notificationType).toBe("awaiting_input");
    } finally { srv.stop(); }
  });

  test("a question notification is accepted and emitted", async () => {
    const sent: AbMessage[] = [];
    const srv = startApiServer(ctx({ sendAb: (m) => sent.push(m) }));
    try {
      const res = await post(srv.port, { type: "question", terminalId: "t1", message: "Which env?" });
      expect(res.status).toBe(200);
      expect((sent[0] as any).notificationType).toBe("question");
      expect((sent[0] as any).message).toBe("Which env?");
    } finally { srv.stop(); }
  });
});

describe("POST /notify — the open-prompt suppression", () => {
  test("a permission_request is dropped while the agent holds a prompt on that slot", async () => {
    // The `question` notify already went out carrying the question itself; this
    // one describes the same block and could only say "Permission needed".
    const sent: AbMessage[] = [];
    const srv = startApiServer(ctx({ sendAb: (m) => sent.push(m), hasOpenAgentPrompt: () => true }));
    try {
      const res = await post(srv.port, { type: "permission_request", terminalId: "t1" });
      expect(res.status).toBe(200);
      expect(await res.json()).toEqual({ ok: true, suppressed: true });
      expect(sent).toHaveLength(0);
    } finally { srv.stop(); }
  });

  test("a turn end is never suppressed by an open prompt", async () => {
    // Scoped to the two ambiguous kinds: a turn end is a different fact and
    // must land whatever the agent is displaying.
    const sent: AbMessage[] = [];
    const srv = startApiServer(ctx({ sendAb: (m) => sent.push(m), hasOpenAgentPrompt: () => true }));
    try {
      expect((await post(srv.port, { type: "task_complete", terminalId: "t1" })).status).toBe(200);
      expect((await post(srv.port, { type: "question", terminalId: "t1", message: "Which env?" })).status).toBe(200);
      expect(sent.map((m) => (m as any).notificationType)).toEqual(["task_complete", "question"]);
    } finally { srv.stop(); }
  });

  test("an unwired context suppresses nothing", async () => {
    // The predicate only ever silences, so absent has to mean "no prompt open".
    const sent: AbMessage[] = [];
    const srv = startApiServer(ctx({ sendAb: (m) => sent.push(m) }));
    try {
      expect((await post(srv.port, { type: "permission_request", terminalId: "t1" })).status).toBe(200);
      expect(sent).toHaveLength(1);
    } finally { srv.stop(); }
  });
});

describe("POST /notify — the gates a claude hook invocation needs", () => {
  test("the post-completion idle nudge is dropped, the same fact /handler-event refuses", async () => {
    // Past the hook's own classification this kind can only BE the nudge — a
    // live block classifies as permission_request — so nothing here would
    // survive the gate legitimately. Without it the dot reads "done" while the
    // phone says "Needs your input" for a session that finished.
    const sent: AbMessage[] = [];
    const srv = startApiServer(ctx({ sendAb: (m) => sent.push(m), isStaleIdleNudge: () => true }));
    try {
      const res = await post(srv.port, { type: "awaiting_input", terminalId: "t1", message: "Claude is waiting for your input" });
      expect(res.status).toBe(200);
      expect(await res.json()).toEqual({ ok: true, stale: true });
      expect(sent).toHaveLength(0);
    } finally { srv.stop(); }
  });

  test("a mid-turn block on the same slot is never dropped as a nudge", async () => {
    const sent: AbMessage[] = [];
    const srv = startApiServer(ctx({ sendAb: (m) => sent.push(m), isStaleIdleNudge: () => true }));
    try {
      expect((await post(srv.port, { type: "permission_request", terminalId: "t1" })).status).toBe(200);
      expect(sent.map((m) => (m as any).notificationType)).toEqual(["permission_request"]);
    } finally { srv.stop(); }
  });

  test("the open-prompt predicate is asked about the tool the post names", async () => {
    // A parallel batch stops on AskUserQuestion AND on a Bash call needing
    // approval; a predicate answering about the SLOT silences the approval
    // nobody has been told about.
    const asked: Array<string | undefined> = [];
    const sent: AbMessage[] = [];
    const srv = startApiServer(ctx({
      sendAb: (m) => sent.push(m),
      hasOpenAgentPrompt: (_id, promptTool) => { asked.push(promptTool); return promptTool === "AskUserQuestion"; },
    }));
    try {
      await post(srv.port, { type: "permission_request", terminalId: "t1", promptTool: "AskUserQuestion" });
      await post(srv.port, { type: "permission_request", terminalId: "t1", promptTool: "Bash" });
      expect(asked).toEqual(["AskUserQuestion", "Bash"]);
      expect(sent).toHaveLength(1);
    } finally { srv.stop(); }
  });
});
