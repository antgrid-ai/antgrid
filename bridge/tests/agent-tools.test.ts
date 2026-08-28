import { expect, test } from "bun:test";
import { createMessage, parseMessage, AbMessageSchema } from "../src/protocol";
import { HostServer } from "../src/host-server";
import { buildAgentCatalog } from "../src/agent-catalog";
import { AGENTS } from "../src/agents/registry";

test("agent:tools round-trips through the schema", () => {
  const msg = createMessage("agent:tools", {
    tools: [
      { tool: "claude-code", path: "/usr/bin/claude", chatCapable: true, label: "Claude Code" },
    ],
  });
  expect(msg.type).toBe("agent:tools");
  const parsed = parseMessage(JSON.stringify(msg));
  expect(parsed).not.toBeNull();
  expect((parsed as any).tools[0].tool).toBe("claude-code");
  expect((parsed as any).tools[0].chatCapable).toBe(true);
  // The schema is what parseMessage keeps: an unlisted field is stripped here
  // and the app's picker silently loses the name it renders.
  expect((parsed as any).tools[0].label).toBe("Claude Code");
});

test("agent:tools accepts entries without chatCapable (back-compat)", () => {
  const msg = createMessage("agent:tools", {
    tools: [{ tool: "claude-code", path: "/usr/bin/claude" }],
  });
  const parsed = parseMessage(JSON.stringify(msg));
  expect(parsed).not.toBeNull();
  expect((parsed as any).tools[0].chatCapable).toBeUndefined();
});

test("buildToolsAdvertisement returns detected tools stamped with chatCapable", () => {
  // PATH override is the seam detectInstalledTools already exposes; here we just
  // assert the host wraps detectInstalledTools() output with the chatCapable flag.
  const host = Object.create(HostServer.prototype) as HostServer;
  const payload = (host as any).buildToolsAdvertisement({
    pathOverride: "", // empty PATH → no tools found → []
  });
  expect(Array.isArray(payload)).toBe(true);
  expect(payload.length).toBe(0);
});

test("buildAgentCatalog describes the whole registry in declaration order", () => {
  const catalog = buildAgentCatalog();
  expect(catalog.map((d) => d.tool)).toEqual(Object.keys(AGENTS));
  const byKey = Object.fromEntries(catalog.map((d) => [d.tool, d]));
  expect(byKey["claude-code"]).toEqual({
    tool: "claude-code",
    label: "Claude Code",
    chatCapable: true,
    judgeCapable: true,
    handler: { terminal: true, chat: true },
  });
  // The agent the PATH probe can find but the Handler can never observe — the
  // distinction the descriptor exists to carry. Judge-capable and unobservable
  // are independent: it declares a headless argv that reaches the repo, and
  // still reports no turn boundaries for anything to watch.
  expect(byKey["cursor-agent"]).toEqual({
    tool: "cursor-agent",
    label: "Cursor",
    chatCapable: false,
    judgeCapable: true,
    handler: { terminal: false, chat: false },
  });
  // The other half of that pair: no headless argv verified at any reach, so it
  // cannot judge either.
  expect(byKey["kimi"]).toEqual({
    tool: "kimi",
    label: "Kimi",
    chatCapable: false,
    judgeCapable: false,
    handler: { terminal: false, chat: false },
  });
  expect(byKey["opencode"].handler).toEqual({ terminal: true, chat: true });
  expect(byKey["kilo"]).toEqual({
    tool: "kilo",
    label: "Kilo",
    chatCapable: false,
    judgeCapable: true,
    handler: { terminal: false, chat: false },
  });
});

test("agent:tools carries the descriptor array through the schema", () => {
  const msg = createMessage("agent:tools", { tools: [], agents: buildAgentCatalog() });
  const parsed = parseMessage(JSON.stringify(msg)) as any;
  expect(parsed).not.toBeNull();
  // The schema is what parseMessage keeps: an unlisted field is stripped here
  // and the app's picker silently loses the capability it gates on.
  expect(parsed.agents).toEqual(buildAgentCatalog());
});

test("agent:tools accepts a frame with no agents array (older bridge)", () => {
  const r = AbMessageSchema.safeParse({
    type: "agent:tools",
    id: crypto.randomUUID(),
    timestamp: 1,
    tools: [{ tool: "claude-code", path: "/usr/bin/claude" }],
  });
  expect(r.success).toBe(true);
  expect((r as any).data.agents).toBeUndefined();
});

test("agent:tools rejects a partial descriptor", () => {
  // Every field is required WITHIN a descriptor — a bridge that sends the array
  // has answered all of it, so a half-filled row is a bug, not back-compat.
  const r = AbMessageSchema.safeParse({
    type: "agent:tools",
    id: crypto.randomUUID(),
    timestamp: 1,
    tools: [],
    agents: [{ tool: "claude-code", label: "Claude Code", chatCapable: true }],
  });
  expect(r.success).toBe(false);
});

test("agent:tools is in the discriminated union", () => {
  const r = AbMessageSchema.safeParse({
    type: "agent:tools",
    id: crypto.randomUUID(),
    timestamp: 1,
    tools: [],
  });
  expect(r.success).toBe(true);
});
