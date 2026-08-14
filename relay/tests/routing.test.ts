import { test, expect, afterEach } from "bun:test";
import { encodeRouteFrame, FrameKind } from "antgrid-wire";
import {
  startServer,
  defaultConfig,
  connectHello,
  makeFakeLicenseGate,
  waitForMessage,
  waitForType,
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

function previewFrame(to: string, text: string): Uint8Array {
  return encodeRouteFrame(
    { type: "message", to, channel: "preview" },
    new TextEncoder().encode(text),
    FrameKind.sealed,
  );
}

/** Two same-account peers, so `mayRoute` permits and only the budget is in play. */
async function connectPair(relayServer: RelayServer, prefix: string) {
  const sharedToken = `${prefix}-token`;
  const agent = await connectHello(relayServer, {
    deviceId: `${prefix}-agent`,
    licenseToken: sharedToken,
  });
  const app = await connectHello(relayServer, {
    deviceId: `${prefix}-app`,
    deviceType: "app",
    licenseToken: sharedToken,
  });
  return { agent, app, agentId: `${prefix}-agent` };
}

function sameAccountGate(prefix: string) {
  return makeFakeLicenseGate({ agentUid: () => `user-app-${prefix}-token` });
}

// mayRoute is the ONLY routing authority — there is no pairing or grant step
// left to skip. These two pin the property directly.
test("same-account routing needs no grant", async () => {
  const sharedToken = "task4-same-account";
  const gate = makeFakeLicenseGate({ agentUid: () => `user-app-${sharedToken}` });
  relay = startServer(defaultConfig, { licenseGate: gate });
  const agent = await connectHello(relay, { deviceId: "task4-agent-u1", licenseToken: sharedToken });
  const app = await connectHello(relay, { deviceId: "task4-app-u1", deviceType: "app", licenseToken: sharedToken });

  // The app's hello also fans out `peer-online` on the agent socket (same
  // account, both live) — filter for the routed frame specifically.
  const received = waitForType(agent.ws, "message");
  app.ws.send(frame("task4-agent-u1", "hi"));
  const msg = await received;
  expect(msg.from).toBe("task4-app-u1");
});

test("cross-account routing is denied as PEER_OFFLINE (no presence oracle)", async () => {
  relay = startServer(defaultConfig);
  const agent = await connectHello(relay, { deviceId: "task4-agent-u1" });
  const app = await connectHello(relay, { deviceId: "task4-app-u2", deviceType: "app" });

  const err = waitForMessage(app.ws);
  app.ws.send(frame("task4-agent-u1", "hi"));
  const errMsg = await err;
  expect(errMsg.code).toBe("PEER_OFFLINE");
  expect(errMsg.retryable).toBe(true);
});

// The harness's default fake gate derives an agent's uid from its deviceId
// and an app's uid from its licenseToken, so two connections that don't share
// a token/deviceId scheme land on different accounts by default — no grant
// and no account match, so both directions get the uniform PEER_OFFLINE deny
// (no presence oracle for an unauthorized sender).
test("no grant, cross-account -> PEER_OFFLINE in both directions", async () => {
  relay = startServer(defaultConfig);
  const agent = await connectHello(relay, { deviceId: "route-agent-nogrant" });
  const app = await connectHello(relay, { deviceId: "route-app-nogrant", deviceType: "app" });

  const errFromApp = waitForMessage(app.ws);
  app.ws.send(frame("route-agent-nogrant", "hi"));
  expect(await errFromApp).toMatchObject({ type: "error", code: "PEER_OFFLINE", retryable: true });

  const errFromAgent = waitForMessage(agent.ws);
  agent.ws.send(frame("route-app-nogrant", "hi"));
  expect(await errFromAgent).toMatchObject({ type: "error", code: "PEER_OFFLINE", retryable: true });
});

// No grant, no account match, and the target never even connected: the reply
// is identical to the live-cross-account deny above — an unauthorized sender
// learns nothing about whether its target exists (no presence oracle).
test("no grant, target never connected -> PEER_OFFLINE, same reply as a live cross-account deny", async () => {
  relay = startServer(defaultConfig);
  const agent = await connectHello(relay, { deviceId: "route-agent-leak" });

  const err = waitForMessage(agent.ws);
  agent.ws.send(frame("totally-unknown-device", "hi"));
  expect(await err).toMatchObject({ type: "error", code: "PEER_OFFLINE", retryable: true });
});

// mayRoute (relay/src/authz.ts): same-account connections route with zero
// grant setup — it is the ONLY routing authority.
test("same-account, no grant, routes app->agent", async () => {
  const sharedToken = "shared-acct-route";
  const gate = makeFakeLicenseGate({ agentUid: () => `user-app-${sharedToken}` });
  relay = startServer(defaultConfig, { licenseGate: gate });
  const agent = await connectHello(relay, { deviceId: "route-agent-sameacct", licenseToken: sharedToken });
  const app = await connectHello(relay, { deviceId: "route-app-sameacct", deviceType: "app", licenseToken: sharedToken });

  const received = waitForMessage(agent.ws);
  app.ws.send(frame("route-agent-sameacct", "hi"));
  const msg = await received;
  expect(msg.type).toBe("message");
  expect(msg.from).toBe("route-app-sameacct");
  expect(msg.payload).toBe("hi");
});

test("cross-account, no grant -> PEER_OFFLINE; socket stays open for a follow-up", async () => {
  relay = startServer(defaultConfig);
  await connectHello(relay, { deviceId: "route-agent-crossacct" });
  const app = await connectHello(relay, { deviceId: "route-app-crossacct", deviceType: "app" });

  const err1 = waitForMessage(app.ws);
  app.ws.send(frame("route-agent-crossacct", "hi"));
  expect(await err1).toMatchObject({ type: "error", code: "PEER_OFFLINE", retryable: true });

  const err2 = waitForMessage(app.ws);
  app.ws.send(frame("route-agent-crossacct", "hi again"));
  expect(await err2).toMatchObject({ type: "error", code: "PEER_OFFLINE", retryable: true });
});

test("offline same-account target -> PEER_OFFLINE retryable", async () => {
  const sharedToken = "shared-acct-offline";
  const gate = makeFakeLicenseGate({ agentUid: () => `user-app-${sharedToken}` });
  relay = startServer(defaultConfig, { licenseGate: gate });
  const app = await connectHello(relay, {
    deviceId: "route-app-offline-sameacct",
    deviceType: "app",
    licenseToken: sharedToken,
  });

  const err = waitForMessage(app.ws);
  app.ws.send(frame("route-agent-never-connected", "hi"));
  expect(await err).toMatchObject({ type: "error", code: "PEER_OFFLINE", retryable: true });
});

// NOT_AUTHORIZED no longer exists as a routing outcome: mayRoute compares
// only `claims.uid`, which a key rotation on the SAME account never changes.
// A reconnect under a fresh keypair (same account) still routes; there is no
// pubkey-anchored deny path left to deviate into.
test("same-account, no grant: a reconnect under a fresh keypair still routes", async () => {
  const sharedToken = "route-keyrot";
  const gate = makeFakeLicenseGate({ agentUid: () => `user-app-${sharedToken}` });
  relay = startServer(defaultConfig, { licenseGate: gate });
  const agentId = "route-keyrot-agent";
  const appId = "route-keyrot-app";
  const agent = await connectHello(relay, { deviceId: agentId, licenseToken: sharedToken });
  const app = await connectHello(relay, { deviceId: appId, deviceType: "app", licenseToken: sharedToken });

  app.ws.close();
  await new Promise((r) => setTimeout(r, 50));
  // Same deviceId, fresh keypair, same account.
  const rejoined = await connectHello(relay, { deviceId: appId, deviceType: "app", licenseToken: sharedToken });

  // The rejoin also fans out `peer-online` on this same socket (same-account,
  // the agent is still live) — filter for the routed frame specifically.
  const received = waitForType(rejoined.ws, "message");
  agent.ws.send(frame(appId, "hi"));
  const msg = await received;
  expect(msg.type).toBe("message");
  expect(msg.from).toBe(agentId);
});

test("frames are forwarded verbatim including the kind byte (same-account, no grant)", async () => {
  const sharedToken = "route-verbatim";
  const gate = makeFakeLicenseGate({ agentUid: () => `user-app-${sharedToken}` });
  relay = startServer(defaultConfig, { licenseGate: gate });
  const agentId = "route-verbatim-agent";
  const appId = "route-verbatim-app";
  const agent = await connectHello(relay, { deviceId: agentId, licenseToken: sharedToken });
  const app = await connectHello(relay, { deviceId: appId, deviceType: "app", licenseToken: sharedToken });

  // Same-account pair: the app's hello also fans out `peer-online` on the
  // agent socket — filter for the routed frame specifically.
  const received = waitForType(agent.ws, "message");
  app.ws.send(frame(agentId, "handshake-payload", FrameKind.handshake));
  const msg = await received;
  expect(msg.kind).toBe(FrameKind.handshake);
  expect(msg.from).toBe(appId);
  expect(msg.channel).toBe("control");
  expect(msg.payload).toBe("handshake-payload");
});

test("peer offline -> PEER_OFFLINE retryable; nothing is queued, a reconnect delivers nothing", async () => {
  const sharedToken = "route-offline";
  const gate = makeFakeLicenseGate({ agentUid: () => `user-app-${sharedToken}` });
  relay = startServer(defaultConfig, { licenseGate: gate });
  const agentId = "route-offline-agent";
  const appId = "route-offline-app";
  const agent = await connectHello(relay, { deviceId: agentId, licenseToken: sharedToken });
  const app = await connectHello(relay, { deviceId: appId, deviceType: "app", licenseToken: sharedToken });

  app.ws.close();
  await new Promise((r) => setTimeout(r, 50));

  const err = waitForMessage(agent.ws);
  agent.ws.send(frame(appId, "gone"));
  expect(await err).toMatchObject({ type: "error", code: "PEER_OFFLINE", retryable: true });

  // Reconnect under the SAME identity — if anything had been queued, this is
  // the moment it would be flushed. A `peer-online` fan-out is expected on
  // reconnect (the agent is still live); a routed `message` frame carrying
  // the dropped "gone" payload is NOT — that's the actual queue check.
  const rejoin = await connectHello(relay, {
    deviceId: appId,
    deviceType: "app",
    licenseToken: sharedToken,
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

// The pairing rendezvous is deleted (Task 3) and antgrid-wire no longer
// exports PairRequestMessage at all (Task 8) — a hand-rolled pair-request
// frame is now just malformed JSON as far as ClientMessage is concerned. It
// fails `ClientMessage.safeParse` in `handleControlMessage`, which replies
// `error{INVALID_MESSAGE, retryable:false}` WITHOUT closing the socket
// (`sendError`, not `sendErrorAndClose` — see relay/CLAUDE.md's error
// contract: only auth/protocol failures close the socket). This is a
// stronger guarantee than the pre-Task-8 state (where the type still parsed
// but had no switch case): the frame is now rejected at the schema boundary
// rather than silently accepted and ignored.
test("a hand-rolled pair-request frame is rejected INVALID_MESSAGE, forwards nothing, and leaves the socket open", async () => {
  relay = startServer(defaultConfig);
  const agent = await connectHello(relay, { deviceId: "route-pair-gone-agent" });
  const app = await connectHello(relay, { deviceId: "route-pair-gone-app", deviceType: "app" });

  let agentSawMessage = false;
  agent.ws.onmessage = () => {
    agentSawMessage = true;
  };

  const errP = waitForMessage(app.ws);
  app.ws.send(JSON.stringify({
    type: "pair-request",
    agentDeviceId: "route-pair-gone-agent",
    phonePubkey: "AAAA",
    phoneDeviceId: "route-pair-gone-app",
    nonce: "n".repeat(24),
    requestedAt: new Date().toISOString(),
    deadline: Date.now() + 10_000,
    phoneSignature: "sig",
  }));

  expect(await errP).toMatchObject({ type: "error", code: "INVALID_MESSAGE", retryable: false });
  await new Promise((r) => setTimeout(r, 200));
  expect(agentSawMessage).toBe(false);
  expect(app.ws.readyState).toBe(WebSocket.OPEN);
});

// The routed-frame budget is a token bucket, not a fixed window: a page load
// legitimately arrives as a burst, and a fixed window rejects it purely on
// shape. Over budget the frame is DROPPED and the socket kept — the app is the
// only thing that can recover it (see PreviewService's rate-limit retry).
test("routed-frame flood -> MESSAGE_RATE_LIMITED (retryable); bucket refills and routing resumes", async () => {
  relay = startServer(
    { ...defaultConfig, rateLimitMsgPerSec: 2, rateLimitMsgBurst: 2 },
    { licenseGate: sameAccountGate("bucket") },
  );
  const { agent, app, agentId } = await connectPair(relay, "bucket");

  for (let i = 0; i < 2; i++) {
    const received = waitForType(agent.ws, "message");
    app.ws.send(frame(agentId, `burst-${i}`));
    expect((await received).payload).toBe(`burst-${i}`);
  }

  const limited = waitForType(app.ws, "error");
  app.ws.send(frame(agentId, "over-budget"));
  expect(await limited).toMatchObject({ code: "MESSAGE_RATE_LIMITED", retryable: true });
  expect(app.ws.readyState).toBe(WebSocket.OPEN);

  // Refilling at 2/s, so a full second restores the whole burst allowance.
  await new Promise((r) => setTimeout(r, 1_100));
  const afterRefill = waitForType(agent.ws, "message");
  app.ws.send(frame(agentId, "after-refill"));
  expect((await afterRefill).payload).toBe("after-refill");
}, 8_000);

// The regression this keying exists for: `pairKey` sorts, so a single per-pair
// bucket is shared by both directions AND every channel — a preview page load
// would rate-limit the terminal output arriving beside it.
test("a preview-channel flood does not rate-limit the control channel", async () => {
  relay = startServer(
    { ...defaultConfig, rateLimitMsgPerSec: 2, rateLimitMsgBurst: 2 },
    { licenseGate: sameAccountGate("chan") },
  );
  const { agent, app, agentId } = await connectPair(relay, "chan");

  for (let i = 0; i < 2; i++) {
    const received = waitForType(agent.ws, "message");
    app.ws.send(previewFrame(agentId, `preview-${i}`));
    expect((await received).channel).toBe("preview");
  }

  const limited = waitForType(app.ws, "error");
  app.ws.send(previewFrame(agentId, "preview-over"));
  expect(await limited).toMatchObject({ code: "MESSAGE_RATE_LIMITED", retryable: true });

  // Control has its own bucket and is untouched by the preview flood.
  const onControl = waitForType(agent.ws, "message");
  app.ws.send(frame(agentId, "control-unaffected"));
  const routed = await onControl;
  expect(routed.channel).toBe("control");
  expect(routed.payload).toBe("control-unaffected");
}, 8_000);
