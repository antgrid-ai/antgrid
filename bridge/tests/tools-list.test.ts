import { expect, test } from "bun:test";
import { HostServer } from "../src/host-server";
import { buildAgentCatalog } from "../src/agent-catalog";

test("handleControl answers tools:list with the detected tool catalog", async () => {
  const host = Object.create(HostServer.prototype) as HostServer;
  const res = await (host as any).handleControl({ id: "1", type: "tools:list" });
  expect(res.ok).toBe(true);
  expect(res.type).toBe("tools:list");
  expect(Array.isArray(res.tools)).toBe(true);
});

test("tools:list carries the same registry descriptor as the relay advert", async () => {
  const host = Object.create(HostServer.prototype) as HostServer;
  const res = await (host as any).handleControl({ id: "1", type: "tools:list" });
  expect(res.agents).toEqual(buildAgentCatalog());
});
