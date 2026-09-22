import { test, expect, afterEach } from "bun:test";
import {
  startServer,
  defaultConfig,
  connect,
  connectHello,
  makeHello,
  makeFakeLicenseGate,
  waitForType,
  waitForMessages,
  decodeMessage,
  type RelayServer,
} from "./helpers/relay-harness.js";

let relay: RelayServer | undefined;

afterEach(() => {
  relay?.stop();
  relay = undefined;
});

// Presence is account-scoped discovery and requires no pairing or payload route.
test("agent connection notifies an existing same-account app only", async () => {
  const sharedToken = "presence-shared-hello";
  const gate = makeFakeLicenseGate({ agentUid: () => `user-app-${sharedToken}` });
  relay = startServer(defaultConfig, { licenseGate: gate });

  const appId = "presence-app-hello";
  const agentId = "presence-agent-hello";

  const app = await connectHello(relay, { deviceId: appId, deviceType: "app", licenseToken: sharedToken });

  // Attach BEFORE the agent connects (the trigger) — no race, mirrors the
  // established waitForType usage elsewhere in this test tree.
  const appPeerOnline = waitForType(app.ws, "peer-online");

  // The agent's own welcome + peer-online are sent back-to-back synchronously
  // in the same hello handler tick, so we must register a listener BEFORE
  // sending the hello (waitForMessages(ws, 2), not connectHello + a
  // late-attached waiter) or the second frame can race past an as-yet-unset
  // listener.
  const { hello } = await makeHello(relay, { deviceId: agentId, deviceType: "agent", licenseToken: sharedToken });
  const agentWs = await connect(relay);
  const agentPresence: Record<string, unknown>[] = [];
  agentWs.addEventListener("message", (e) => {
    const message = decodeMessage((e as MessageEvent).data);
    if (message.type === "peer-online" || message.type === "peer-offline") agentPresence.push(message);
  });
  const agentMessages = waitForMessages(agentWs, 1);
  agentWs.send(JSON.stringify(hello));
  const [welcome] = await agentMessages;

  expect(welcome.type).toBe("welcome");
  expect(await appPeerOnline).toEqual({ type: "peer-online", peerId: agentId });
  await new Promise((resolve) => setTimeout(resolve, 50));
  expect(agentPresence).toEqual([]);
});

test("new app receives online same-account agents without notifying agents", async () => {
  const sharedToken = "presence-app-joins";
  const gate = makeFakeLicenseGate({ agentUid: () => `user-app-${sharedToken}` });
  relay = startServer(defaultConfig, { licenseGate: gate });

  const agent = await connectHello(relay, {
    deviceId: "presence-agent-existing",
    deviceType: "agent",
    licenseToken: sharedToken,
  });
  const agentPresence: Record<string, unknown>[] = [];
  agent.ws.addEventListener("message", (e) => agentPresence.push(decodeMessage((e as MessageEvent).data)));

  const { hello } = await makeHello(relay, {
    deviceId: "presence-app-new",
    deviceType: "app",
    licenseToken: sharedToken,
  });
  const app = await connect(relay);
  const messages = waitForMessages(app, 2);
  app.send(JSON.stringify(hello));
  const [welcome, online] = await messages;

  expect(welcome.type).toBe("welcome");
  expect(online).toEqual({ type: "peer-online", peerId: "presence-agent-existing" });
  await new Promise((resolve) => setTimeout(resolve, 50));
  expect(agentPresence).toEqual([]);
});

test("same-account, no grant: agent close -> app gets peer-offline", async () => {
  const sharedToken = "presence-shared-close";
  const gate = makeFakeLicenseGate({ agentUid: () => `user-app-${sharedToken}` });
  relay = startServer(defaultConfig, { licenseGate: gate });

  const appId = "presence-app-close";
  const agentId = "presence-agent-close";

  const app = await connectHello(relay, { deviceId: appId, deviceType: "app", licenseToken: sharedToken });
  const agent = await connectHello(relay, { deviceId: agentId, deviceType: "agent", licenseToken: sharedToken });

  const peerOffline = waitForType(app.ws, "peer-offline");
  agent.ws.close();
  expect(await peerOffline).toEqual({ type: "peer-offline", peerId: agentId });
});

// Cross-type only: the app's presence handler treats any frame on a
// machine's socket as that machine's presence, so a sibling app must never
// be able to inject/observe presence noise via the same-account path.
test("cross-type only: a second same-account app gets no presence about the first app", async () => {
  const sharedToken = "presence-shared-siblings";
  const gate = makeFakeLicenseGate({ agentUid: () => `user-app-${sharedToken}` });
  relay = startServer(defaultConfig, { licenseGate: gate });

  const app1Id = "presence-app-sib-1";
  const app2Id = "presence-app-sib-2";

  const app1 = await connectHello(relay, { deviceId: app1Id, deviceType: "app", licenseToken: sharedToken });
  const app1Messages: Record<string, unknown>[] = [];
  app1.ws.addEventListener("message", (e) => app1Messages.push(decodeMessage((e as MessageEvent).data)));

  const { hello } = await makeHello(relay, { deviceId: app2Id, deviceType: "app", licenseToken: sharedToken });
  const app2Ws = await connect(relay);
  const app2Messages: Record<string, unknown>[] = [];
  app2Ws.addEventListener("message", (e) => app2Messages.push(decodeMessage((e as MessageEvent).data)));
  app2Ws.send(JSON.stringify(hello));

  await new Promise((r) => setTimeout(r, 150));

  expect(app2Messages.length).toBeGreaterThan(0);
  expect(app2Messages[0]?.type).toBe("welcome");
  expect(app1Messages.some((m) => m.type === "peer-online" || m.type === "peer-offline")).toBe(false);
  expect(app2Messages.some((m) => m.type === "peer-online" || m.type === "peer-offline")).toBe(false);
});
