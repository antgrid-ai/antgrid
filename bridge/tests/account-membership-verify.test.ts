import { test, expect } from "bun:test";
import { generateKeyPairSync, sign, createPublicKey } from "node:crypto";
import { buildMembershipSigBody, verifyAccountMembershipSig } from "../src/account-membership-verify";
import { rawSeedToPkcs8 } from "../src/pair-approval";

test("verifyAccountMembershipSig accepts a valid proof and rejects a swapped pairing key", () => {
  const { privateKey } = generateKeyPairSync("ed25519");
  const seed = privateKey.export({ type: "pkcs8", format: "der" }).subarray(16);
  const accountPub = createPublicKey(privateKey).export({ type: "spki", format: "der" }).subarray(12);
  const fields = {
    agentDeviceId: "agent-1", phoneDeviceId: "phone-1",
    phonePubkey: Buffer.alloc(32, 1).toString("base64"),
    accountDevicePubkey: accountPub.toString("base64"),
    nonce: Buffer.alloc(24, 3).toString("base64"),
  };
  const sigB64 = sign(null, buildMembershipSigBody(fields), { key: rawSeedToPkcs8(seed), format: "der", type: "pkcs8" }).toString("base64");

  expect(verifyAccountMembershipSig({ ...fields, sigB64 })).toBe(true);
  // a relay swapping the pairing key invalidates the proof
  expect(verifyAccountMembershipSig({ ...fields, phonePubkey: Buffer.alloc(32, 9).toString("base64"), sigB64 })).toBe(false);
});
