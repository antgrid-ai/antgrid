// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { test, expect, afterAll, beforeAll } from "bun:test";
import { startServer, connectHello, defaultConfig, waitForMessage } from "../helpers/relay-harness.js";
import type { RelayServer } from "../../src/server.js";
import type { PushSendOptions } from "../../src/push/delivery.js";

let relay: RelayServer;
const apnsSent: Array<{ token: string; data: Record<string, string>; opts?: PushSendOptions }> = [];
const fcmSent: Array<{ token: string; data: Record<string, string> }> = [];
const apnsSender = {
  async send(token: string, data: Record<string, string>, opts?: PushSendOptions) {
    apnsSent.push({ token, data, opts });
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
  expect(apnsSent[0].opts?.collapseKey).toBeUndefined();
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

test("push:deliver provider=apns forwards collapseKey to the APNs sender", async () => {
  const { ws } = await connectHello(relay, { deviceId: "agent-apns-collapse" });
  const resultP = waitForMessage(ws);
  ws.send(JSON.stringify({
    type: "push:deliver",
    pushToken: "apns-tok-collapse",
    provider: "apns",
    blob: { epk: "ZXBr", box: "Ym94" },
    collapseKey: "thread_Key-2",
  }));
  expect(await resultP).toEqual({ type: "push:result", pushToken: "apns-tok-collapse", ok: true });
  expect(apnsSent.find((s) => s.token === "apns-tok-collapse")?.opts).toEqual({ collapseKey: "thread_Key-2" });
  ws.close();
});
