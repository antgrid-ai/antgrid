import { test, expect, afterEach } from "bun:test";
import { encodeRouteFrame, FrameKind } from "antgrid-wire";
import {
  startServer,
  defaultConfig,
  connectHello,
  setupPairedDevices,
  waitForMessage,
  decodeMessage,
  type RelayServer,
} from "./helpers/relay-harness.js";

let relay: RelayServer | undefined;

afterEach(() => {
  relay?.stop();
  relay = undefined;
});

function frame(to: string, text: string, kind: FrameKind = FrameKind.sealed): Uint8Array {
  return encodeRouteFrame({ type: "message", to, channel: "control" }, new TextEncoder().encode(text), kind);
}

test("no grant -> NOT_AUTHORIZED in both directions", async () => {
  relay = startServer(defaultConfig);
  const agent = await connectHello(relay, { deviceId: "route-agent-nogrant" });
  const app = await connectHello(relay, { deviceId: "route-app-nogrant", deviceType: "app" });

  const errFromApp = waitForMessage(app.ws);
  app.ws.send(frame("route-agent-nogrant", "hi"));
  expect(await errFromApp).toMatchObject({ type: "error", code: "NOT_AUTHORIZED", retryable: false });

  const errFromAgent = waitForMessage(agent.ws);
  agent.ws.send(frame("route-app-nogrant", "hi"));
  expect(await errFromAgent).toMatchObject({ type: "error", code: "NOT_AUTHORIZED", retryable: false });
});

// Deviation from the spec's literal text (see work order): the grant check
// runs BEFORE reachability, so an ungranted sender learns nothing about
// whether its target even exists — it always gets NOT_AUTHORIZED, never a
// presence-leaking PEER_OFFLINE.
test("deviation: an ungranted sender targeting a nonexistent device still gets NOT_AUTHORIZED, not PEER_OFFLINE", async () => {
  relay = startServer(defaultConfig);
  const agent = await connectHello(relay, { deviceId: "route-agent-leak" });

  const err = waitForMessage(agent.ws);
  agent.ws.send(frame("totally-unknown-device", "hi"));
  expect(await err).toMatchObject({ type: "error", code: "NOT_AUTHORIZED", retryable: false });
});

// Deviation: a live target reachable by deviceId but reconnected under a
// pubkey the agent never approved must still be refused, not routed.
test("deviation: a live target under a non-approved pubkey still gets NOT_AUTHORIZED", async () => {
  relay = startServer(defaultConfig);
  const { agentWs, appWs, agentId, appId } = await setupPairedDevices(relay, "route-keyrot");

  appWs.close();
  await new Promise((r) => setTimeout(r, 50));
  // Same deviceId, but a FRESH keypair — the agent's grant still points at
  // the old pubkey, so this identity was never approved.
  await connectHello(relay, { deviceId: appId, deviceType: "app" });

  const err = waitForMessage(agentWs);
  agentWs.send(frame(appId, "hi"));
  expect(await err).toMatchObject({ type: "error", code: "NOT_AUTHORIZED", retryable: false });
});

test("with a grant, frames are forwarded verbatim including the kind byte", async () => {
  relay = startServer(defaultConfig);
  const { agentWs, appWs, agentId, appId } = await setupPairedDevices(relay, "route-verbatim");

  const received = waitForMessage(agentWs);
  appWs.send(frame(agentId, "handshake-payload", FrameKind.handshake));
  const msg = await received;
  expect(msg.kind).toBe(FrameKind.handshake);
  expect(msg.from).toBe(appId);
  expect(msg.channel).toBe("control");
  expect(msg.payload).toBe("handshake-payload");
});

test("peer offline -> PEER_OFFLINE retryable; nothing is queued, a reconnect delivers nothing", async () => {
  relay = startServer(defaultConfig);
  const { agentWs, appWs, app, agentId, appId } = await setupPairedDevices(relay, "route-offline");

  appWs.close();
  await new Promise((r) => setTimeout(r, 50));

  const err = waitForMessage(agentWs);
  agentWs.send(frame(appId, "gone"));
  expect(await err).toMatchObject({ type: "error", code: "PEER_OFFLINE", retryable: true });

  // Reconnect under the SAME identity the grant links — if anything had been
  // queued, this is the moment it would be flushed. A `peer-online` fan-out is
  // expected on reconnect (the agent is still live); a routed `message` frame
  // carrying the dropped "gone" payload is NOT — that's the actual queue check.
  const rejoin = await connectHello(relay, {
    deviceId: appId,
    deviceType: "app",
    publicKeyBase64: app.publicKeyBase64,
    privateSeed: app.privateSeed,
  });
  let gotRoutedMessage = false;
  rejoin.ws.onmessage = (e) => {
    if (decodeMessage(e.data).type === "message") gotRoutedMessage = true;
  };
  await new Promise((r) => setTimeout(r, 200));
  expect(gotRoutedMessage).toBe(false);
});

test("JSON control-message flood -> MESSAGE_RATE_LIMITED (retryable); dropped, socket kept", async () => {
  const cfg = { ...defaultConfig, jsonRateLimitPerSec: 2, jsonRateLimitBurst: 2 };
  relay = startServer(cfg);
  const { ws } = await connectHello(relay, { deviceId: "route-flood" });

  // Consume the burst sequentially so these acks can't race the rate-limited
  // reply below (the same discipline as the push-deliver rate-limit test).
  for (const id of ["a", "b"]) {
    const ack = waitForMessage(ws);
    ws.send(JSON.stringify({ type: "stream-close", streamId: id }));
    expect(await ack).toEqual({ type: "stream-closed", streamId: id });
  }

  const limited = waitForMessage(ws);
  ws.send(JSON.stringify({ type: "stream-close", streamId: "c" }));
  expect(await limited).toMatchObject({ type: "error", code: "MESSAGE_RATE_LIMITED", retryable: true });

  // Socket stays open and keeps dispatching once the bucket refills.
  await new Promise((r) => setTimeout(r, 1_100));
  const opened = waitForMessage(ws);
  ws.send(JSON.stringify({ type: "stream-open", streamId: "after-flood" }));
  expect(await opened).toEqual({ type: "stream-opened", streamId: "after-flood" });
}, 8_000);
