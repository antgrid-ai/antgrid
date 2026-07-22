import { describe, it, expect } from "bun:test";
import { parseMessage, createMessage } from "../src/protocol";

describe("agent:* outbound schemas", () => {
  it("round-trips agent:turn-start", () => {
    const msg = createMessage("agent:turn-start", { sessionId: "s1", turnId: "t1" });
    const parsed = parseMessage(JSON.stringify(msg));
    expect(parsed?.type).toBe("agent:turn-start");
  });

  it("round-trips agent:turn-end with stopReason + usage + error", () => {
    const msg = createMessage("agent:turn-end", {
      sessionId: "s1",
      turnId: "t1",
      stopReason: "error",
      usage: { inputTokens: 10, outputTokens: 5, totalTokens: 15 },
      error: { category: "server_error", message: "500", retryable: true, httpStatus: 500 },
    });
    const parsed = parseMessage(JSON.stringify(msg));
    expect(parsed?.type).toBe("agent:turn-end");
    if (parsed?.type === "agent:turn-end") {
      expect(parsed.stopReason).toBe("error");
      expect(parsed.error?.category).toBe("server_error");
    }
  });

  it("round-trips agent:item-added with a tool_call item carrying diff + terminal content", () => {
    const msg = createMessage("agent:item-added", {
      sessionId: "s1",
      turnId: "t1",
      itemId: "i1",
      item: {
        itemId: "i1",
        kind: "tool_call",
        status: "running",
        toolKind: "edit",
        title: "Apply patch",
        content: [
          { type: "diff", path: "a.ts", newText: "x" },
          { type: "terminal", data: "ok\n" },
        ],
      },
    });
    const parsed = parseMessage(JSON.stringify(msg));
    expect(parsed?.type).toBe("agent:item-added");
    if (parsed?.type === "agent:item-added") {
      expect(parsed.item.kind).toBe("tool_call");
      expect(parsed.item.content?.[0].type).toBe("diff");
    }
  });

  it("round-trips agent:item-delta and agent:permission-request", () => {
    const delta = parseMessage(JSON.stringify(createMessage("agent:item-delta", {
      sessionId: "s1", turnId: "t1", itemId: "i1", textChunk: "hello",
    })));
    expect(delta?.type).toBe("agent:item-delta");

    const perm = parseMessage(JSON.stringify(createMessage("agent:permission-request", {
      sessionId: "s1", permissionId: "p1", itemId: "i1", title: "Run rm -rf?",
      options: [{ optionId: "ok", label: "Allow", kind: "allow_once" }],
    })));
    expect(perm?.type).toBe("agent:permission-request");
  });

  it("round-trips agent:usage with total/last breakdown + contextWindow", () => {
    const msg = createMessage("agent:usage", {
      sessionId: "s1",
      turnId: "t1",
      total: { totalTokens: 100, inputTokens: 60, outputTokens: 40, cacheReadTokens: 20, reasoningTokens: 5 },
      last: { totalTokens: 10 },
      contextWindow: 200000,
    });
    const parsed = parseMessage(JSON.stringify(msg));
    expect(parsed?.type).toBe("agent:usage");
    if (parsed?.type === "agent:usage") {
      expect(parsed.total.cacheReadTokens).toBe(20);
      expect(parsed.contextWindow).toBe(200000);
    }
  });

  it("rejects an unknown stopReason", () => {
    const bad = {
      id: "00000000-0000-0000-0000-000000000000",
      timestamp: 0, type: "agent:turn-end", sessionId: "s", turnId: "t", stopReason: "bogus",
    };
    expect(parseMessage(JSON.stringify(bad))).toBeNull();
  });

  it("round-trips agent:capabilities with model efforts and current ids", () => {
    const msg = createMessage("agent:capabilities", {
      sessionId: "s1",
      commands: [{ id: "builtin:compact", name: "compact", description: "Summarize history" }],
      modes: [{ id: ":workspace", name: ":workspace" }],
      models: [{ id: "gpt-5.2", name: "GPT-5.2", efforts: ["low", "medium", "high"], defaultEffort: "medium" }],
      currentModelId: "gpt-5.2",
      currentEffortId: "medium",
      currentModeId: ":workspace",
    });
    const parsed = parseMessage(JSON.stringify(msg));
    expect(parsed?.type).toBe("agent:capabilities");
    if (parsed?.type === "agent:capabilities") {
      expect(parsed.models?.[0]?.efforts).toEqual(["low", "medium", "high"]);
      expect(parsed.models?.[0]?.defaultEffort).toBe("medium");
      expect(parsed.currentEffortId).toBe("medium");
    }
  });
});

describe("agent:* inbound control plane", () => {
  it("round-trips agent:prompt with optional commandId", () => {
    const msg = createMessage("agent:prompt", { sessionId: "s1", requestId: "r1", text: "hi" });
    const parsed = parseMessage(JSON.stringify(msg));
    expect(parsed?.type).toBe("agent:prompt");
    if (parsed?.type === "agent:prompt") expect(parsed.text).toBe("hi");
  });

  it("round-trips cancel, session-action, permission-resolve, question-resolve", () => {
    expect(parseMessage(JSON.stringify(createMessage("agent:cancel", { sessionId: "s1" })))?.type)
      .toBe("agent:cancel");
    expect(parseMessage(JSON.stringify(createMessage("agent:session-action", { sessionId: "s1", action: "compact" })))?.type)
      .toBe("agent:session-action");
    expect(parseMessage(JSON.stringify(createMessage("agent:permission-resolve", { sessionId: "s1", permissionId: "p1", optionId: "ok" })))?.type)
      .toBe("agent:permission-resolve");
    expect(parseMessage(JSON.stringify(createMessage("agent:question-resolve", { sessionId: "s1", questionId: "q1", answer: "yes" })))?.type)
      .toBe("agent:question-resolve");
  });

  it("rejects a session-action with an unknown action", () => {
    const bad = { id: "00000000-0000-0000-0000-000000000000", timestamp: 0, type: "agent:session-action", sessionId: "s", action: "wipe" };
    expect(parseMessage(JSON.stringify(bad))).toBeNull();
  });
});
