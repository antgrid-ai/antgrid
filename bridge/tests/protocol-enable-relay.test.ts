import { expect, test } from "bun:test";
import { parseMessage } from "../src/protocol";

const BASE = { id: "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11", timestamp: 0 };
const DEVICE_UUID = "0bbd1111-2222-3333-4444-555566667777";

test("agent:enableRelay accepts enriched auth + urls", () => {
  const msg = parseMessage(
    JSON.stringify({
      ...BASE,
      type: "agent:enableRelay",
      relayUrl: "https://relay.example.com",
      licenseApiUrl: "https://api.example.com",
      auth: {
        deviceUuid: DEVICE_UUID,
        ed25519Pub: "cHVia2V5",
        ed25519Priv: "cHJpdmtleQ",
        clientId: "cid",
        clientSecret: "secret",
      },
    }),
  );
  expect(msg?.type).toBe("agent:enableRelay");
  // @ts-expect-error narrowed at runtime
  expect(msg?.auth?.deviceUuid).toBe(DEVICE_UUID);
});

test("agent:enableRelay still accepts the bare form", () => {
  const msg = parseMessage(JSON.stringify({ ...BASE, type: "agent:enableRelay" }));
  expect(msg?.type).toBe("agent:enableRelay");
});

test("agent:enableRelay accepts the static-token form", () => {
  const msg = parseMessage(
    JSON.stringify({
      ...BASE,
      type: "agent:enableRelay",
      auth: { deviceUuid: DEVICE_UUID, ed25519Pub: "a", ed25519Priv: "b", licenseToken: "tok" },
    }),
  );
  expect(msg?.type).toBe("agent:enableRelay");
});

test("agent:enableRelay rejects a malformed deviceUuid", () => {
  const msg = parseMessage(
    JSON.stringify({
      ...BASE,
      type: "agent:enableRelay",
      auth: { deviceUuid: "not-a-uuid", ed25519Pub: "a", ed25519Priv: "b", licenseToken: "tok" },
    }),
  );
  expect(msg).toBeNull();
});

test("agent:enableRelay rejects a non-URL licenseApiUrl", () => {
  const msg = parseMessage(
    JSON.stringify({
      ...BASE,
      type: "agent:enableRelay",
      licenseApiUrl: "notaurl",
    }),
  );
  expect(msg).toBeNull();
});
