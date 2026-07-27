import { test, expect } from "bun:test";
import { rmSync } from "node:fs";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseMessage, createMessage } from "../../src/protocol";
import { loadPairedPhones } from "../../src/paired-phones";

// Standard base64 of 32 raw bytes — the exact shape the app sends
// (base64Encode(pub.bytes) in push_identity.dart / decoded by sealPush).
const VALID_PUSH_PUBKEY = Buffer.alloc(32, 7).toString("base64");

test("push:register parses through the AbMessage schema", () => {
  const msg = createMessage("push:register", { pushToken: "tok", provider: "fcm", pushPubkey: VALID_PUSH_PUBKEY });
  const parsed = parseMessage(JSON.stringify(msg));
  expect(parsed?.type).toBe("push:register");
  if (parsed?.type === "push:register") {
    expect(parsed.pushToken).toBe("tok");
    expect(parsed.provider).toBe("fcm");
    expect(parsed.pushPubkey).toBe(VALID_PUSH_PUBKEY);
  }
});

test("push:register accepts an empty pushToken as the clear signal", () => {
  const msg = createMessage("push:register", { pushToken: "", provider: "fcm", pushPubkey: "" });
  const parsed = parseMessage(JSON.stringify(msg));
  expect(parsed?.type).toBe("push:register");
  if (parsed?.type === "push:register") {
    expect(parsed.pushToken).toBe("");
    expect(parsed.pushPubkey).toBe("");
  }
});

test("push:register rejects a malformed (non-32-byte) pushPubkey", () => {
  // Guards the key-exchange.ts createPublicKey synchronous-throw path.
  const bad = createMessage("push:register", { pushToken: "tok", provider: "fcm", pushPubkey: "pk" });
  expect(parseMessage(JSON.stringify(bad))).toBeNull();
  const shortKey = createMessage("push:register", { pushToken: "tok", provider: "fcm", pushPubkey: Buffer.alloc(16).toString("base64") });
  expect(parseMessage(JSON.stringify(shortKey))).toBeNull();
});

test("paired-phones persists push fields through upsert", () => {
  const dir = mkdtempSync(join(tmpdir(), "ab-pp-"));
  const store = loadPairedPhones(dir);
  store.upsert({
    phonePubkey: "PK", phoneDeviceId: "d1", pairedAt: "2026-07-01T00:00:00.000Z",
    lastSeenAt: "2026-07-01T00:00:00.000Z",
    pushToken: "tok", pushProvider: "fcm", pushPubkey: "xpk", pushUpdatedAt: "2026-07-01T00:00:00.000Z",
  });
  // Re-open from disk to prove persistence:
  const reopened = loadPairedPhones(dir);
  const phone = reopened.get("PK");
  expect(phone?.pushToken).toBe("tok");
  expect(phone?.pushPubkey).toBe("xpk");
  expect(phone?.pushProvider).toBe("fcm");
  expect(phone?.pushUpdatedAt).toBe("2026-07-01T00:00:00.000Z");
  rmSync(dir, { recursive: true });
});

test("paired-phones round-trips a clear (undefined) push fields state", () => {
  const dir = mkdtempSync(join(tmpdir(), "ab-pp-"));
  const store = loadPairedPhones(dir);
  store.upsert({
    phonePubkey: "PK2", phoneDeviceId: "d2", pairedAt: "2026-07-01T00:00:00.000Z",
    lastSeenAt: "2026-07-01T00:00:00.000Z",
    pushToken: "tok", pushProvider: "fcm", pushPubkey: "xpk", pushUpdatedAt: "2026-07-01T00:00:00.000Z",
  });
  const phone = store.get("PK2")!;
  store.upsert({
    ...phone,
    pushToken: undefined,
    pushProvider: undefined,
    pushPubkey: undefined,
    pushUpdatedAt: "2026-07-01T00:01:00.000Z",
  });
  const reopened = loadPairedPhones(dir);
  const cleared = reopened.get("PK2");
  expect(cleared?.pushToken).toBeUndefined();
  expect(cleared?.pushPubkey).toBeUndefined();
  expect(cleared?.pushProvider).toBeUndefined();
  expect(cleared?.pushUpdatedAt).toBe("2026-07-01T00:01:00.000Z");
  rmSync(dir, { recursive: true });
});
