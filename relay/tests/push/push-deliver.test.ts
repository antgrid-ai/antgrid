import { test, expect, afterAll, beforeAll } from "bun:test";
import { startServer, connect, connectHello, defaultConfig, waitForMessage } from "../helpers/relay-harness.js";
import type { RelayServer } from "../../src/server.js";

let relay: RelayServer;
const sent: Array<{ token: string; data: Record<string, string> }> = [];
const fcmSender = {
  async send(token: string, data: Record<string, string>) {
    sent.push({ token, data });
    return "ok" as const;
  },
};

beforeAll(() => {
  relay = startServer(defaultConfig, { fcmSender });
});
afterAll(() => relay.stop());

test("authenticated agent push:deliver forwards to FCM and replies push:result", async () => {
  const { ws } = await connectHello(relay, { deviceId: "push-agent-1" });
  const resultP = waitForMessage(ws);
  ws.send(JSON.stringify({
    type: "push:deliver",
    pushToken: "tok-1",
    provider: "fcm",
    blob: { epk: "ZXBr", box: "Ym94" },
  }));
  const result = await resultP;
  expect(sent).toHaveLength(1);
  expect(sent[0].token).toBe("tok-1");
  expect(sent[0].data).toEqual({ epk: "ZXBr", box: "Ym94" });
  expect(result).toEqual({ type: "push:result", pushToken: "tok-1", ok: true });
  ws.close();
});

test("unauthenticated push:deliver is rejected", async () => {
  const ws = await connect(relay);
  const errP = waitForMessage(ws);
  ws.send(JSON.stringify({ type: "push:deliver", pushToken: "t", provider: "fcm", blob: { epk: "a", box: "b" } }));
  const err = await errP;
  // A push:deliver sent before hello is not a recognized first frame at all —
  // the relay only accepts a `hello` as the first message on a socket.
  expect(err.type).toBe("error");
  expect(err.code).toBe("PROTOCOL_VIOLATION");
  ws.close();
});

test("push:deliver from an app device is rejected", async () => {
  const { ws } = await connectHello(relay, { deviceId: "push-app-1", deviceType: "app" });

  const errP = waitForMessage(ws);
  ws.send(JSON.stringify({ type: "push:deliver", pushToken: "t", provider: "fcm", blob: { epk: "a", box: "b" } }));
  const err = await errP;
  expect(err.type).toBe("error");
  expect(err.code).toBe("NOT_AUTHENTICATED");
  ws.close();
});

test("push:deliver with no fcmSender configured replies unconfigured", async () => {
  const r = startServer(defaultConfig);
  const { ws } = await connectHello(r, { deviceId: "push-agent-unconfigured" });
  const resultP = waitForMessage(ws);
  ws.send(JSON.stringify({
    type: "push:deliver",
    pushToken: "tok-2",
    provider: "fcm",
    blob: { epk: "ZXBr", box: "Ym94" },
  }));
  const result = await resultP;
  expect(result).toEqual({ type: "push:result", pushToken: "tok-2", ok: false, reason: "unconfigured" });
  ws.close();
  r.stop();
});

test("push:deliver surfaces unregistered/error reasons from the FCM sender", async () => {
  const outcomes = ["unregistered", "error"] as const;
  let call = 0;
  const flakySender = {
    async send(_token: string, _data: Record<string, string>) {
      return outcomes[call++];
    },
  };
  const r = startServer(defaultConfig, { fcmSender: flakySender });
  const { ws } = await connectHello(r, { deviceId: "push-agent-flaky" });

  for (const expected of outcomes) {
    const resultP = waitForMessage(ws);
    ws.send(JSON.stringify({
      type: "push:deliver",
      pushToken: `tok-${expected}`,
      provider: "fcm",
      blob: { epk: "ZXBr", box: "Ym94" },
    }));
    const result = await resultP;
    expect(result).toEqual({ type: "push:result", pushToken: `tok-${expected}`, ok: false, reason: expected });
  }

  ws.close();
  r.stop();
});

test("push:deliver is rate-limited per (agent, token)", async () => {
  const r = startServer({ ...defaultConfig, rateLimitMsgPerSec: 2 }, { fcmSender });
  const { ws } = await connectHello(r, { deviceId: "push-agent-rl" });

  // Send the first two (within the limit) sequentially, waiting for each
  // push:result, so their async FCM-send replies can't race with the
  // rate-limited third message's synchronous error reply below.
  for (let i = 0; i < 2; i++) {
    const resultP = waitForMessage(ws);
    ws.send(JSON.stringify({
      type: "push:deliver",
      pushToken: "tok-rl",
      provider: "fcm",
      blob: { epk: "ZXBr", box: "Ym94" },
    }));
    await resultP;
  }

  const errP = waitForMessage(ws);
  ws.send(JSON.stringify({
    type: "push:deliver",
    pushToken: "tok-rl",
    provider: "fcm",
    blob: { epk: "ZXBr", box: "Ym94" },
  }));
  const err = await errP;
  expect(err).toMatchObject({ type: "error", code: "MESSAGE_RATE_LIMITED" });

  ws.close();
  r.stop();
});
