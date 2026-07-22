import { test, expect } from "bun:test";
import { ApnsSender, Http2ApnsTransport, type ApnsTransport } from "../../src/push/apns";

const providerToken = { get: async () => "eyJfake.jwt" };

test("send posts a mutable-content alert with epk/box custom keys", async () => {
  let captured: { token: string; headers: Record<string, string>; body: string } | null = null;
  const transport: ApnsTransport = {
    async post(token, headers, body) {
      captured = { token, headers, body };
      return { status: 200, body: "" };
    },
  };
  const sender = new ApnsSender({ bundleId: "ai.radhaai.antgrid", providerToken, transport });
  const res = await sender.send("device-hex-1", { epk: "ZXBr", box: "Ym94" });

  expect(res).toBe("ok");
  expect(captured!.token).toBe("device-hex-1");
  expect(captured!.headers.authorization).toBe("bearer eyJfake.jwt");
  expect(captured!.headers["apns-topic"]).toBe("ai.radhaai.antgrid");
  expect(captured!.headers["apns-push-type"]).toBe("alert");
  expect(captured!.headers["apns-priority"]).toBe("10");
  const payload = JSON.parse(captured!.body);
  // Ciphertext is carried in TOP-LEVEL custom keys (APNs surfaces them in userInfo).
  expect(payload.epk).toBe("ZXBr");
  expect(payload.box).toBe("Ym94");
  // The relay is content-blind: it writes only a GENERIC placeholder alert.
  expect(payload.aps["mutable-content"]).toBe(1);
  expect(typeof payload.aps.alert.title).toBe("string");
  expect(payload.aps.alert.title).not.toContain("Deploy"); // never real content
});

test("410 Unregistered maps to 'unregistered'", async () => {
  const transport: ApnsTransport = {
    async post() { return { status: 410, body: JSON.stringify({ reason: "Unregistered" }) }; },
  };
  const sender = new ApnsSender({ bundleId: "b", providerToken, transport });
  expect(await sender.send("dead", { epk: "a", box: "b" })).toBe("unregistered");
});

test("400 BadDeviceToken maps to 'unregistered'", async () => {
  const transport: ApnsTransport = {
    async post() { return { status: 400, body: JSON.stringify({ reason: "BadDeviceToken" }) }; },
  };
  const sender = new ApnsSender({ bundleId: "b", providerToken, transport });
  expect(await sender.send("bad", { epk: "a", box: "b" })).toBe("unregistered");
});

test("410 with a non-JSON body still maps to 'unregistered'", async () => {
  const transport: ApnsTransport = {
    async post() { return { status: 410, body: "<html>gateway</html>" }; },
  };
  const sender = new ApnsSender({ bundleId: "b", providerToken, transport });
  expect(await sender.send("dead", { epk: "a", box: "b" })).toBe("unregistered");
});

test("other errors map to 'error'", async () => {
  const transport: ApnsTransport = {
    async post() { return { status: 400, body: JSON.stringify({ reason: "DeviceTokenNotForTopic" }) }; },
  };
  const sender = new ApnsSender({ bundleId: "b", providerToken, transport });
  expect(await sender.send("x", { epk: "a", box: "b" })).toBe("error");
});

test("session-level connection failure rejects instead of crashing the process", async () => {
  // Port 1 is closed → http2 session emits 'error' (ECONNREFUSED). Without the
  // session error handler this surfaces as an uncaughtException that would kill
  // the test runner, so this test guards the fix directly.
  const transport = new Http2ApnsTransport({ production: false, host: "https://127.0.0.1:1" });
  await expect(transport.post("dev", { authorization: "bearer x" }, "{}")).rejects.toThrow();
});
