import { test, expect, afterEach } from "bun:test";
import { encodeRouteFrame, FrameKind } from "antgrid-wire";
import {
  startServer,
  defaultConfig,
  connectHello,
  completePairFlow,
  setupPairedDevices,
  signPairApproval,
  relayTestRequestedAt,
  RELAY_TEST_PLACEHOLDER_SIG,
  waitForMessage,
  waitForType,
  generateKeyPair,
  type RelayServer,
} from "./helpers/relay-harness.js";

let relay: RelayServer | undefined;

afterEach(() => {
  relay?.stop();
  relay = undefined;
});

function randomNonce(): string {
  return Buffer.from(crypto.getRandomValues(new Uint8Array(24))).toString("base64");
}

function pairRequestFrame(opts: {
  agentDeviceId: string;
  phonePubkey: string;
  phoneDeviceId: string;
  nonce: string;
  deadline?: number;
}): Record<string, unknown> {
  return {
    type: "pair-request",
    agentDeviceId: opts.agentDeviceId,
    phonePubkey: opts.phonePubkey,
    phoneDeviceId: opts.phoneDeviceId,
    nonce: opts.nonce,
    requestedAt: relayTestRequestedAt(),
    deadline: opts.deadline ?? Date.now() + 60_000,
    phoneSignature: RELAY_TEST_PLACEHOLDER_SIG,
  };
}

/** A ghost pair-request is a cheap liveness probe: the app socket must still
 *  be dispatching messages and reply AGENT_OFFLINE for a nonexistent agent. */
async function expectSocketStillLive(ws: WebSocket): Promise<void> {
  const reply = waitForMessage(ws);
  ws.send(JSON.stringify(pairRequestFrame({
    agentDeviceId: "does-not-exist",
    phonePubkey: "x",
    phoneDeviceId: "ghost-phone",
    nonce: randomNonce(),
  })));
  expect(await reply).toMatchObject({ type: "error", code: "AGENT_OFFLINE" });
}

test("pair-request to an offline agent -> AGENT_OFFLINE (ref=nonce); socket stays open and a retry succeeds once the agent connects", async () => {
  relay = startServer(defaultConfig);
  const app = await connectHello(relay, { deviceId: "grant-app-1", deviceType: "app" });
  const nonce = randomNonce();

  const err = waitForMessage(app.ws);
  app.ws.send(JSON.stringify(pairRequestFrame({
    agentDeviceId: "grant-agent-1",
    phonePubkey: app.publicKeyBase64,
    phoneDeviceId: "grant-app-1",
    nonce,
  })));
  expect(await err).toMatchObject({ type: "error", code: "AGENT_OFFLINE", retryable: true, ref: nonce });

  const agent = await connectHello(relay, { deviceId: "grant-agent-1" });
  const forwarded = waitForType(agent.ws, "pair-request");
  const nonce2 = randomNonce();
  app.ws.send(JSON.stringify(pairRequestFrame({
    agentDeviceId: "grant-agent-1",
    phonePubkey: app.publicKeyBase64,
    phoneDeviceId: "grant-app-1",
    nonce: nonce2,
  })));
  const fwd = await forwarded;
  expect(fwd.agentDeviceId).toBe("grant-agent-1");
  expect(typeof fwd.pairId).toBe("string");
});

test("AGENT_OFFLINE answers are not metered by the pair rate limiter", async () => {
  const cfg = { ...defaultConfig, pairRateLimitPerIp: 2 };
  relay = startServer(cfg);
  const app = await connectHello(relay, { deviceId: "offline-meter-app", deviceType: "app" });

  // Far more attempts than the configured pair rate limit (2/sec) — every one
  // must still answer AGENT_OFFLINE, never PAIR_RATE_LIMITED: the limiter
  // guards the forward to a live agent, and an offline answer never reaches
  // one (server.ts pair-request handler — AGENT_OFFLINE check precedes the
  // rate-limit check).
  for (let i = 0; i < 5; i++) {
    const err = waitForMessage(app.ws);
    app.ws.send(JSON.stringify(pairRequestFrame({
      agentDeviceId: "no-such-agent",
      phonePubkey: app.publicKeyBase64,
      phoneDeviceId: "offline-meter-app",
      nonce: randomNonce(),
    })));
    expect(await err).toMatchObject({ type: "error", code: "AGENT_OFFLINE", retryable: true });
  }
});

test("forwards to a LIVE agent are metered per (phone, agent) pair: a burst gets PAIR_RATE_LIMITED and nothing is forwarded", async () => {
  const cfg = { ...defaultConfig, pairRateLimitPerIp: 2 };
  relay = startServer(cfg);
  const agent = await connectHello(relay, { deviceId: "meter-agent" });
  const app = await connectHello(relay, { deviceId: "meter-app", deviceType: "app" });

  // First two pair-requests in the window both forward to the agent.
  for (let i = 0; i < 2; i++) {
    const fwd = waitForType(agent.ws, "pair-request");
    app.ws.send(JSON.stringify(pairRequestFrame({
      agentDeviceId: "meter-agent",
      phonePubkey: app.publicKeyBase64,
      phoneDeviceId: "meter-app",
      nonce: randomNonce(),
    })));
    await fwd;
  }

  // Watch for an unexpected 3rd forward while we exercise the metered path.
  let sawUnexpectedForward = false;
  const forwardWatch = (e: MessageEvent) => {
    const m = JSON.parse(e.data as string);
    if (m.type === "pair-request") sawUnexpectedForward = true;
  };
  agent.ws.addEventListener("message", forwardWatch as never);

  const nonce = randomNonce();
  const limited = waitForMessage(app.ws);
  app.ws.send(JSON.stringify(pairRequestFrame({
    agentDeviceId: "meter-agent",
    phonePubkey: app.publicKeyBase64,
    phoneDeviceId: "meter-app",
    nonce,
  })));
  expect(await limited).toMatchObject({ type: "error", code: "PAIR_RATE_LIMITED", retryable: true, ref: nonce });

  await new Promise((r) => setTimeout(r, 50));
  agent.ws.removeEventListener("message", forwardWatch as never);
  expect(sawUnexpectedForward).toBe(false);
  expect(app.ws.readyState).toBe(1);
});

test("pending pairs are keyed by the relay-stamped pairId: two phones racing to pair with the same agent don't cross-talk", async () => {
  relay = startServer(defaultConfig);
  const agent = await connectHello(relay, { deviceId: "race-agent" });
  const phone1 = await connectHello(relay, { deviceId: "race-phone-1", deviceType: "app" });
  const phone2 = await connectHello(relay, { deviceId: "race-phone-2", deviceType: "app" });

  const fwd1P = waitForType(agent.ws, "pair-request");
  const nonce1 = randomNonce();
  phone1.ws.send(JSON.stringify(pairRequestFrame({
    agentDeviceId: "race-agent", phonePubkey: phone1.publicKeyBase64, phoneDeviceId: "race-phone-1", nonce: nonce1,
  })));
  const fwd1 = await fwd1P;

  const fwd2P = waitForType(agent.ws, "pair-request");
  const nonce2 = randomNonce();
  phone2.ws.send(JSON.stringify(pairRequestFrame({
    agentDeviceId: "race-agent", phonePubkey: phone2.publicKeyBase64, phoneDeviceId: "race-phone-2", nonce: nonce2,
  })));
  const fwd2 = await fwd2P;

  expect(fwd1.pairId).not.toBe(fwd2.pairId);

  // Approve the SECOND request first — out of arrival order. Only phone2 may
  // observe a result; phone1's pending (a different pairId) must survive.
  const expiresAt2 = new Date(Date.now() + 60_000).toISOString();
  const sig2 = signPairApproval({
    agentDeviceId: "race-agent", phonePubkey: phone2.publicKeyBase64, phoneDeviceId: "race-phone-2",
    nonce: nonce2, expiresAt: expiresAt2, agentEd25519Priv: agent.privateSeed,
  });
  const phone2Connected = waitForType(phone2.ws, "pair-connected");
  agent.ws.send(JSON.stringify({
    type: "pair-approval", pairId: fwd2.pairId, phonePubkey: phone2.publicKeyBase64,
    phoneDeviceId: "race-phone-2", nonce: nonce2, expiresAt: expiresAt2, signature: sig2,
  }));
  await phone2Connected;
  expect(relay.grants.linked("race-agent", phone2.publicKeyBase64)).toBe(true);
  expect(relay.grants.linked("race-agent", phone1.publicKeyBase64)).toBe(false);

  // phone1's still-pending request approves independently and cleanly,
  // proving its pairId was never touched by phone2's approval.
  const expiresAt1 = new Date(Date.now() + 60_000).toISOString();
  const sig1 = signPairApproval({
    agentDeviceId: "race-agent", phonePubkey: phone1.publicKeyBase64, phoneDeviceId: "race-phone-1",
    nonce: nonce1, expiresAt: expiresAt1, agentEd25519Priv: agent.privateSeed,
  });
  const phone1Connected = waitForType(phone1.ws, "pair-connected");
  agent.ws.send(JSON.stringify({
    type: "pair-approval", pairId: fwd1.pairId, phonePubkey: phone1.publicKeyBase64,
    phoneDeviceId: "race-phone-1", nonce: nonce1, expiresAt: expiresAt1, signature: sig1,
  }));
  await phone1Connected;
  expect(relay.grants.linked("race-agent", phone1.publicKeyBase64)).toBe(true);
});

test("forged pair-approval signature -> PAIR_REJECTED to the phone (no close) + INVALID_MESSAGE to the agent (no close)", async () => {
  relay = startServer(defaultConfig);
  const agent = await connectHello(relay, { deviceId: "forge-agent" });
  const phone = await connectHello(relay, { deviceId: "forge-phone", deviceType: "app" });

  const nonce = randomNonce();
  const forwarded = waitForType(agent.ws, "pair-request");
  phone.ws.send(JSON.stringify(pairRequestFrame({
    agentDeviceId: "forge-agent", phonePubkey: phone.publicKeyBase64, phoneDeviceId: "forge-phone", nonce,
  })));
  const fwd = await forwarded;

  const expiresAt = new Date(Date.now() + 60_000).toISOString();
  const phoneErr = waitForType(phone.ws, "error");
  const agentErr = waitForType(agent.ws, "error");
  agent.ws.send(JSON.stringify({
    type: "pair-approval",
    pairId: fwd.pairId,
    phonePubkey: phone.publicKeyBase64,
    phoneDeviceId: "forge-phone",
    nonce,
    expiresAt,
    signature: Buffer.alloc(64, 0).toString("base64"), // not signed by the agent's key
  }));

  expect(await phoneErr).toMatchObject({ type: "error", code: "PAIR_REJECTED", retryable: false, ref: nonce });
  expect(await agentErr).toMatchObject({ type: "error", code: "INVALID_MESSAGE", retryable: false, ref: fwd.pairId });
  expect(relay.grants.size).toBe(0);

  // Neither socket closed.
  expect(phone.ws.readyState).toBe(1);
  expect(agent.ws.readyState).toBe(1);
  await expectSocketStillLive(phone.ws);
});

test("a pair-request past its deadline expires with EXPIRED (retryable), ref=nonce", async () => {
  relay = startServer(defaultConfig);
  const agent = await connectHello(relay, { deviceId: "expiry-agent" });
  const app = await connectHello(relay, { deviceId: "expiry-app", deviceType: "app" });

  const nonce = randomNonce();
  const forwarded = waitForType(agent.ws, "pair-request");
  app.ws.send(JSON.stringify(pairRequestFrame({
    agentDeviceId: "expiry-agent",
    phonePubkey: app.publicKeyBase64,
    phoneDeviceId: "expiry-app",
    nonce,
    deadline: Date.now() + 100,
  })));
  await forwarded;

  const expired = waitForType(app.ws, "error");
  expect(await expired).toMatchObject({ type: "error", code: "EXPIRED", retryable: true, ref: nonce });
}, 8_000);

test("displacement: a new pairing revokes the machine's previous grant with PEER_REPLACED; the displaced socket stays alive", async () => {
  relay = startServer(defaultConfig);
  const agent = await connectHello(relay, { deviceId: "displace-agent" });
  const phone1 = await connectHello(relay, { deviceId: "displace-phone-1", deviceType: "app" });
  const phone2 = await connectHello(relay, { deviceId: "displace-phone-2", deviceType: "app" });

  await completePairFlow({
    agentWs: agent.ws, appWs: phone1.ws, agentId: "displace-agent", appId: "displace-phone-1",
    agentPrivSeed: agent.privateSeed,
  });
  expect(relay.grants.size).toBe(1);

  const phone1Revoked = waitForType(phone1.ws, "grant-revoked");
  await completePairFlow({
    agentWs: agent.ws, appWs: phone2.ws, agentId: "displace-agent", appId: "displace-phone-2",
    agentPrivSeed: agent.privateSeed,
  });

  expect(await phone1Revoked).toEqual({ type: "grant-revoked", peerDeviceId: "displace-agent", reason: "PEER_REPLACED" });
  expect(relay.grants.size).toBe(1);
  expect(relay.grants.linked("displace-agent", phone2.publicKeyBase64)).toBe(true);
  expect(relay.grants.linked("displace-agent", phone1.publicKeyBase64)).toBe(false);

  expect(phone1.ws.readyState).toBe(1);
  await expectSocketStillLive(phone1.ws);
});

test("grant-revoke works from either side", async () => {
  relay = startServer(defaultConfig);
  const { agentWs, appWs, agent, app, agentId, appId } = await setupPairedDevices(relay, "revoke-both");
  expect(relay.grants.size).toBe(1);

  const agentNotified = waitForType(agentWs, "grant-revoked");
  appWs.send(JSON.stringify({ type: "grant-revoke", peerDeviceId: agentId }));
  expect(await agentNotified).toEqual({ type: "grant-revoked", peerDeviceId: appId, reason: "REVOKED" });
  expect(relay.grants.size).toBe(0);
  expect(appWs.readyState).toBe(1);

  await completePairFlow({
    agentWs, appWs, agentId, appId,
    agentPrivSeed: agent.privateSeed,
  });
  expect(relay.grants.size).toBe(1);

  const appNotified = waitForType(appWs, "grant-revoked");
  agentWs.send(JSON.stringify({ type: "grant-revoke", peerDeviceId: appId }));
  expect(await appNotified).toEqual({ type: "grant-revoked", peerDeviceId: agentId, reason: "REVOKED" });
  expect(relay.grants.size).toBe(0);
  expect(agentWs.readyState).toBe(1);
});

test("agent disconnect: paired phones get peer-offline and stay ALIVE — no cascade close", async () => {
  relay = startServer(defaultConfig);
  const { agentWs, appWs, agentId } = await setupPairedDevices(relay, "anti-cascade");

  const peerOffline = waitForType(appWs, "peer-offline");
  agentWs.close();
  expect(await peerOffline).toEqual({ type: "peer-offline", peerId: agentId });

  // The grant itself is untouched by a mere disconnect (only close/revoke drop it).
  expect(relay.grants.peersOf(agentId)).toHaveLength(1);
  expect(appWs.readyState).toBe(1);
  await expectSocketStillLive(appWs);
});

test("the phone's pairing key is a DIFFERENT key from its connection key: pairing succeeds and the grant anchors the connection key", async () => {
  relay = startServer(defaultConfig);
  const agent = await connectHello(relay, { deviceId: "twokey-agent" });
  const phone = await connectHello(relay, { deviceId: "twokey-phone", deviceType: "app" });

  // The real app signs pair-requests with a per-machine pairing keypair
  // (PhoneIdentity) that is generated independently of the DeviceIdentity key
  // it presents at hello. The two are never equal outside tests.
  const pairingPubkey = await generateKeyPair().then((kp) => kp.publicKeyBase64);
  expect(pairingPubkey).not.toBe(phone.publicKeyBase64);

  const nonce = randomNonce();
  const forwarded = waitForType(agent.ws, "pair-request");
  phone.ws.send(JSON.stringify(pairRequestFrame({
    agentDeviceId: "twokey-agent",
    phonePubkey: pairingPubkey,
    phoneDeviceId: "twokey-phone",
    nonce,
  })));
  const fwd = await forwarded;

  const expiresAt = new Date(Date.now() + 60_000).toISOString();
  const approved = waitForType(phone.ws, "pair-approval");
  agent.ws.send(JSON.stringify({
    type: "pair-approval",
    pairId: fwd.pairId,
    phonePubkey: pairingPubkey,
    phoneDeviceId: "twokey-phone",
    nonce,
    expiresAt,
    signature: signPairApproval({
      agentDeviceId: "twokey-agent",
      phonePubkey: pairingPubkey,
      phoneDeviceId: "twokey-phone",
      nonce,
      expiresAt,
      agentEd25519Priv: agent.privateSeed,
    }),
  }));
  expect(await approved).toMatchObject({ type: "pair-approval", phonePubkey: pairingPubkey });
  expect(relay.grants.size).toBe(1);

  // Routing authorizes app→agent by the phone's CONNECTION key (server.ts),
  // so that is what the grant must anchor.
  const delivered = waitForMessage(agent.ws);
  phone.ws.send(encodeRouteFrame(
    { type: "message", to: "twokey-agent", channel: "control" },
    new TextEncoder().encode("hi"),
    FrameKind.sealed,
  ));
  const got = await delivered;
  expect(got.type).not.toBe("error");
});
