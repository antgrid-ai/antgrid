import { test, expect, afterAll, beforeAll } from "bun:test";
import { startServer, connectHello, defaultConfig, waitForMessage } from "../helpers/relay-harness.js";
import type { RelayServer } from "../../src/server.js";

let relay: RelayServer;
const apnsSent: Array<{ token: string; data: Record<string, string> }> = [];
const fcmSent: Array<{ token: string; data: Record<string, string> }> = [];
const apnsSender = {
  async send(token: string, data: Record<string, string>) {
    apnsSent.push({ token, data });
    return "ok" as const;
  },
};
const fcmSender = {
  async send(token: string, data: Record<string, string>) {
    fcmSent.push({ token, data });
    return "ok" as const;
  },
};

// Both senders configured: provider routing is only meaningful when either
// could have handled the message.
beforeAll(() => { relay = startServer(defaultConfig, { apnsSender, fcmSender }); });
afterAll(() => relay.stop());

test("push:deliver provider=apns forwards to the APNs sender, not FCM", async () => {
  const { ws } = await connectHello(relay, { deviceId: "agent-apns" });
  const resultP = waitForMessage(ws);
  ws.send(JSON.stringify({
    type: "push:deliver",
    pushToken: "apns-tok",
    provider: "apns",
    blob: { epk: "ZXBr", box: "Ym94" },
  }));
  const result = await resultP;
  expect(apnsSent).toHaveLength(1);
  expect(apnsSent[0].token).toBe("apns-tok");
  expect(apnsSent[0].data).toEqual({ epk: "ZXBr", box: "Ym94" });
  expect(fcmSent).toHaveLength(0);
  expect(result).toEqual({ type: "push:result", pushToken: "apns-tok", ok: true });
  ws.close();
});

test("provider=apns with no apnsSender replies unconfigured even when FCM is configured", async () => {
  const r = startServer(defaultConfig, { fcmSender });
  const { ws } = await connectHello(r, { deviceId: "agent-apns-unconfigured" });
  const resultP = waitForMessage(ws);
  ws.send(JSON.stringify({
    type: "push:deliver",
    pushToken: "t",
    provider: "apns",
    blob: { epk: "a", box: "b" },
  }));
  expect(await resultP).toEqual({
    type: "push:result",
    pushToken: "t",
    ok: false,
    reason: "unconfigured",
  });
  ws.close();
  r.stop();
});
