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

// mayRoute's account-derived authorization (Task 1) generalizes routing to
// same-account peers with zero grant setup; this generalizes PRESENCE the
// same way — peer-online/offline must reach same-account cross-type peers
// too, not just grant-linked ones (spec 2026-07-24 §4).
test("same-account, no grant: bidirectional peer-online when the agent connects after the app", async () => {
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
  const agentMessages = waitForMessages(agentWs, 2);
  agentWs.send(JSON.stringify(hello));
  const [welcome, agentPeerOnline] = await agentMessages;

  expect(welcome.type).toBe("welcome");
  expect(agentPeerOnline).toEqual({ type: "peer-online", peerId: appId });
  expect(await appPeerOnline).toEqual({ type: "peer-online", peerId: agentId });
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
