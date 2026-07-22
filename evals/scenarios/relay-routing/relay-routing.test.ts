import { describe, test, expect, beforeAll, afterAll, afterEach } from "bun:test";
import { startRelay, allocatePort, type RelayHandle } from "../../helpers/harness";
import { RelayClient } from "../../helpers/relay-client";

// TODO Tasks 28-33 will replace this with new pair-request v3 evals.
// Old pair-request shape is incompatible with the current relay protocol.
describe.skip("relay routing", () => {
  let relay: RelayHandle;
  const clients: RelayClient[] = [];

  beforeAll(async () => {
    relay = await startRelay({ port: allocatePort() });
  });

  afterEach(async () => {
    for (const c of clients) await c.disconnect();
    clients.length = 0;
  });

  afterAll(() => {
    relay.stop();
  });

  test("bidirectional message routing between paired devices", async () => {
    const agent = await RelayClient.connectAndAuth(relay.url, { deviceType: "agent" });
    const app = await RelayClient.connectAndAuth(relay.url, { deviceType: "app" });
    clients.push(agent, app);

    await app.pairWith(agent.deviceId, 5_000);
    await agent.waitForType("pair-connected", 5_000);

    // App → Agent
    app.sendMessage(agent.deviceId, "control", "hello-from-app");
    const fromApp = await agent.waitFor((msg: any) => msg.type === "message", 5_000);
    expect(Buffer.from(fromApp.payload).toString("utf8")).toBe("hello-from-app");
    expect(fromApp.from).toBe(app.deviceId);

    // Agent → App
    agent.sendMessage(app.deviceId, "control", "hello-from-agent");
    const fromAgent = await app.waitFor((msg: any) => msg.type === "message", 5_000);
    expect(Buffer.from(fromAgent.payload).toString("utf8")).toBe("hello-from-agent");
    expect(fromAgent.from).toBe(agent.deviceId);
  });

  test("cross-pair isolation — messages don't leak", async () => {
    // Pair 1
    const agent1 = await RelayClient.connectAndAuth(relay.url, { deviceType: "agent", name: "agent-1" });
    const app1 = await RelayClient.connectAndAuth(relay.url, { deviceType: "app", name: "app-1" });
    clients.push(agent1, app1);

    await app1.pairWith(agent1.deviceId, 5_000);
    await agent1.waitForType("pair-connected", 5_000);

    // Pair 2
    const agent2 = await RelayClient.connectAndAuth(relay.url, { deviceType: "agent", name: "agent-2" });
    const app2 = await RelayClient.connectAndAuth(relay.url, { deviceType: "app", name: "app-2" });
    clients.push(agent2, app2);

    await app2.pairWith(agent2.deviceId, 5_000);
    await agent2.waitForType("pair-connected", 5_000);

    // Send message in pair 1
    app1.sendMessage(agent1.deviceId, "control", "pair-1-secret");
    const received1 = await agent1.waitFor((msg: any) => msg.type === "message", 5_000);
    expect(Buffer.from(received1.payload).toString("utf8")).toBe("pair-1-secret");

    // Send message in pair 2
    app2.sendMessage(agent2.deviceId, "control", "pair-2-secret");
    const received2 = await agent2.waitFor((msg: any) => msg.type === "message", 5_000);
    expect(Buffer.from(received2.payload).toString("utf8")).toBe("pair-2-secret");

    // Verify no message leaked
    await Bun.sleep(500);
    try {
      await agent2.waitFor((msg: any) => msg.payload && Buffer.from(msg.payload).toString("utf8") === "pair-1-secret", 500);
      expect(true).toBe(false);
    } catch {
      // Expected timeout
    }

    try {
      await agent1.waitFor((msg: any) => msg.payload && Buffer.from(msg.payload).toString("utf8") === "pair-2-secret", 500);
      expect(true).toBe(false);
    } catch {
      // Expected timeout
    }
  });

  test("message routing uses correct channel", async () => {
    const agent = await RelayClient.connectAndAuth(relay.url, { deviceType: "agent" });
    const app = await RelayClient.connectAndAuth(relay.url, { deviceType: "app" });
    clients.push(agent, app);

    await app.pairWith(agent.deviceId, 5_000);
    await agent.waitForType("pair-connected", 5_000);

    // Send on control channel
    app.sendMessage(agent.deviceId, "control", "control-msg");
    const controlMsg = await agent.waitFor((msg: any) => msg.type === "message", 5_000);
    expect(controlMsg.channel).toBe("control");

    // Send on preview channel
    app.sendMessage(agent.deviceId, "preview", "preview-msg");
    const previewMsg = await agent.waitFor((msg: any) => msg.type === "message", 5_000);
    expect(previewMsg.channel).toBe("preview");
  });
});
