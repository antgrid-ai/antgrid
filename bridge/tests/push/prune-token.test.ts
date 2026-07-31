import { test, expect } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadPairedPhones } from "../../src/paired-phones";
import { prunePushToken } from "../../src/push/prune";

function seed(pushToken: string) {
  const dir = mkdtempSync(join(tmpdir(), "ab-prune-"));
  const store = loadPairedPhones(dir);
  store.upsert({
    phonePubkey: "PK", phoneDeviceId: "d1", pairedAt: "2026-07-01T00:00:00.000Z",
    lastSeenAt: "2026-07-01T00:00:00.000Z",
    pushToken, pushProvider: "fcm", pushPubkey: "xpk",
  });
  return store;
}

test("prunePushToken clears the matching token but keeps pushPubkey", () => {
  const store = seed("dead-token");
  prunePushToken(store, "dead-token");
  const phone = store.get("PK");
  expect(phone?.pushToken).toBeUndefined();
  expect(phone?.pushProvider).toBeUndefined();
  expect(phone?.pushPubkey).toBe("xpk"); // push identity survives a token rotation
});

test("prunePushToken is a no-op when no phone has that token", () => {
  const store = seed("live-token");
  prunePushToken(store, "some-other-token");
  expect(store.get("PK")?.pushToken).toBe("live-token");
});

test("prunePushToken preserves the rest of the identity row", () => {
  const store = seed("dead-token");
  prunePushToken(store, "dead-token");
  const phone = store.get("PK");
  expect(phone?.phoneDeviceId).toBe("d1");
  expect(phone?.pairedAt).toBe("2026-07-01T00:00:00.000Z");
  expect(phone?.lastSeenAt).toBe("2026-07-01T00:00:00.000Z");
});
