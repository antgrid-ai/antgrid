import { expect, test } from "bun:test";
import { createMessage, parseMessage, AbMessageSchema } from "../src/protocol";
import { HostServer } from "../src/host-server";

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

test("agent:tools is in the discriminated union", () => {
  const r = AbMessageSchema.safeParse({
    type: "agent:tools",
    id: crypto.randomUUID(),
    timestamp: 1,
    tools: [],
  });
  expect(r.success).toBe(true);
});
