import { test, expect } from "bun:test";
import { generateKeyPairSync, sign, createPublicKey } from "node:crypto";
import { handleInboundPairRequest } from "../src/relay-client";
import { buildPairRequestSigBody } from "../src/pair-request-verify";
import { buildMembershipSigBody } from "../src/account-membership-verify";
import { rawSeedToPkcs8 } from "../src/pair-approval";

const AGENT_ID = "agent-1";
const PHONE_ID = "phone-1";
const NONCE = Buffer.alloc(24, 5).toString("base64");
const REQUESTED_AT = new Date().toISOString();

const pairing = generateKeyPairSync("ed25519");
const pairingSeed = pairing.privateKey.export({ type: "pkcs8", format: "der" }).subarray(16);
const pairingPubB64 = createPublicKey(pairing.privateKey).export({ type: "spki", format: "der" }).subarray(12).toString("base64");
const agentKp = generateKeyPairSync("ed25519");
const agentSeed = agentKp.privateKey.export({ type: "pkcs8", format: "der" }).subarray(16);
const account = generateKeyPairSync("ed25519");
const accountSeed = account.privateKey.export({ type: "pkcs8", format: "der" }).subarray(16);
const accountPubB64 = createPublicKey(account.privateKey).export({ type: "spki", format: "der" }).subarray(12).toString("base64");

function pairingSig(): string {
  const body = buildPairRequestSigBody({
    phonePubkey: pairingPubB64, agentDeviceId: AGENT_ID, phoneDeviceId: PHONE_ID,
    nonce: NONCE, requestedAt: REQUESTED_AT,
  });
  return sign(null, body, { key: rawSeedToPkcs8(pairingSeed), format: "der", type: "pkcs8" }).toString("base64");
}
function membershipSig(): string {
  const body = buildMembershipSigBody({
    agentDeviceId: AGENT_ID, phoneDeviceId: PHONE_ID, phonePubkey: pairingPubB64,
    accountDevicePubkey: accountPubB64, nonce: NONCE,
  });
  return sign(null, body, { key: rawSeedToPkcs8(accountSeed), format: "der", type: "pkcs8" }).toString("base64");
}
function baseMsg(extra: Record<string, unknown>) {
  return {
    type: "pair-request", pairId: "pair-1", agentDeviceId: AGENT_ID, phonePubkey: pairingPubB64,
    phoneDeviceId: PHONE_ID, nonce: NONCE, requestedAt: REQUESTED_AT,
    phoneSignature: pairingSig(), ...extra,
  };
}
function mkArgs(msg: any, getAccountPeerKeys?: () => Promise<Set<string>>) {
  const sent: any[] = [];
  return {
    out: sent,
    args: {
      msg,
      pairedPhones: { has: () => false, get: () => undefined, upsert: () => {} } as any,
      pairingWindow: { consume: () => false } as any, // window CLOSED
      agentDeviceId: AGENT_ID,
      agentEd25519Priv: agentSeed,
      getAccountPeerKeys,
      send: (m: any) => sent.push(m),
    },
  };
}

test("A: forged sameAccount + no membership proof → rejected UNKNOWN_PHONE", async () => {
  const { out, args } = mkArgs(baseMsg({ sameAccount: true }), async () => new Set<string>());
  await handleInboundPairRequest(args as any);
  expect(out[0].type).toBe("pair-rejected");
  expect(out[0].reason).toBe("UNKNOWN_PHONE");
});

test("B: valid proof whose account key is in the set → approved", async () => {
  const { out, args } = mkArgs(
    baseMsg({ accountDevicePubkey: accountPubB64, accountMembershipSig: membershipSig() }),
    async () => new Set([accountPubB64]),
  );
  await handleInboundPairRequest(args as any);
  expect(out[0].type).toBe("pair-approval");
});

test("C: valid signature but account key NOT in the set → rejected UNKNOWN_PHONE", async () => {
  const { out, args } = mkArgs(
    baseMsg({ accountDevicePubkey: accountPubB64, accountMembershipSig: membershipSig() }),
    async () => new Set(["someotherkey"]),
  );
  await handleInboundPairRequest(args as any);
  expect(out[0].type).toBe("pair-rejected");
  expect(out[0].reason).toBe("UNKNOWN_PHONE");
});
