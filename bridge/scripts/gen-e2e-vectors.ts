// bridge/scripts/gen-e2e-vectors.ts
// Generates evals/fixtures/e2e-handshake-vectors.json from fixed inputs.
// Run: cd bridge && bun run scripts/gen-e2e-vectors.ts
import { createPrivateKey, createPublicKey } from "node:crypto";
import { buildTranscript } from "../src/e2e/transcript";
import { deriveSessionKeys } from "../src/e2e/key-schedule";
import { agentConfirmTag, phoneConfirmTag } from "../src/e2e/confirm";
import { E2eTransport } from "../src/e2e/transport";
import { signTranscript } from "../src/e2e/handshake-sig";
import { deriveSharedSecret } from "../src/key-exchange";

// X25519 / Ed25519 DER prefixes
const X_PKCS8_PREFIX = Buffer.from("302e020100300506032b656e04220420", "hex");
const ED_PKCS8_PREFIX = Buffer.from("302e020100300506032b657004220420", "hex");

function x25519Pub(rawPriv: Buffer): Buffer {
  const priv = createPrivateKey({
    key: Buffer.concat([X_PKCS8_PREFIX, rawPriv]), format: "der", type: "pkcs8",
  });
  const der = createPublicKey(priv).export({ type: "spki", format: "der" });
  return Buffer.from(der.subarray(der.length - 32));
}

function ed25519Pub(seed: Buffer): Buffer {
  const priv = createPrivateKey({
    key: Buffer.concat([ED_PKCS8_PREFIX, seed]), format: "der", type: "pkcs8",
  });
  const der = createPublicKey(priv).export({ type: "spki", format: "der" });
  return Buffer.from(der.subarray(der.length - 32));
}

// ---- fixed inputs ----
const ids = {
  registrationId: "agent-deterministic.proj-deterministic",
  agentDeviceId: "agent-deterministic.proj-deterministic",
  phoneDeviceId: "phone-deterministic",
};
const agentEdSeed = Buffer.from("a0".repeat(32), "hex");
const phoneEdSeed = Buffer.from("b0".repeat(32), "hex");
const agentXPriv = Buffer.from("c0".repeat(32), "hex");
const phoneXPriv = Buffer.from("d0".repeat(32), "hex");
const nonce = Buffer.alloc(32, 6);

const agentXPub = x25519Pub(agentXPriv);
const phoneXPub = x25519Pub(phoneXPriv);

const phoneSigFields = {
  ...ids, role: "phone" as const,
  agentX25519Pub: Buffer.alloc(0), phoneX25519Pub: phoneXPub, nonce,
};
const agentSigFields = {
  ...ids, role: "agent" as const,
  agentX25519Pub: agentXPub, phoneX25519Pub: phoneXPub, nonce,
};
const phoneSigBody = buildTranscript(phoneSigFields);
const agentSigBody = buildTranscript(agentSigFields);

const ss = deriveSharedSecret(agentXPriv, phoneXPub); // zeroed by deriveSessionKeys
const keys = deriveSessionKeys(ss, buildTranscript(agentSigFields));

const fixedNonceA = Buffer.alloc(12, 1);
const fixedNonceP = Buffer.alloc(12, 2);
const agentT = new E2eTransport({ sendKey: keys.a2p, recvKey: keys.p2a });
const phoneT = new E2eTransport({ sendKey: keys.p2a, recvKey: keys.a2p });

const out = {
  ids,
  ed25519: {
    agentSeedHex: agentEdSeed.toString("hex"),
    agentPubB64: ed25519Pub(agentEdSeed).toString("base64"),
    phoneSeedHex: phoneEdSeed.toString("hex"),
    phonePubB64: ed25519Pub(phoneEdSeed).toString("base64"),
  },
  x25519: {
    agentPrivHex: agentXPriv.toString("hex"),
    agentPubB64: agentXPub.toString("base64"),
    phonePrivHex: phoneXPriv.toString("hex"),
    phonePubB64: phoneXPub.toString("base64"),
  },
  nonceB64: nonce.toString("base64"),
  transcripts: {
    phoneSigBodyHex: phoneSigBody.toString("hex"),
    agentSigBodyHex: agentSigBody.toString("hex"),
  },
  signatures: {
    phoneSigB64: signTranscript(phoneSigBody, phoneEdSeed),
    agentSigB64: signTranscript(agentSigBody, agentEdSeed),
  },
  keySchedule: {
    kA2pHex: keys.a2p.toString("hex"),
    kP2aHex: keys.p2a.toString("hex"),
    kConfirmHex: keys.confirm.toString("hex"),
  },
  confirm: {
    agentTagHex: agentConfirmTag(keys.confirm).toString("hex"),
    phoneTagHex: phoneConfirmTag(keys.confirm).toString("hex"),
  },
  transport: [
    {
      dir: "a2p", plaintext: "hello from agent",
      nonceHex: fixedNonceA.toString("hex"),
      sealedHex: agentT.seal("hello from agent", fixedNonceA).toString("hex"),
    },
    {
      dir: "p2a", plaintext: "hello from phone",
      nonceHex: fixedNonceP.toString("hex"),
      sealedHex: phoneT.seal("hello from phone", fixedNonceP).toString("hex"),
    },
  ],
};

await Bun.write(
  new URL("../../evals/fixtures/e2e-handshake-vectors.json", import.meta.url),
  JSON.stringify(out, null, 2) + "\n",
);
console.log("wrote evals/fixtures/e2e-handshake-vectors.json");
