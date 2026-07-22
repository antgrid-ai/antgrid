import { generateKeyPairSync, diffieHellman, createPublicKey, createPrivateKey } from "node:crypto";

// DER prefix for X25519 SPKI public key (12 bytes before the 32-byte raw key)
const SPKI_PREFIX = Buffer.from("302a300506032b656e032100", "hex");
// DER prefix for X25519 PKCS8 private key (16 bytes before the 32-byte raw key)
const PKCS8_PREFIX = Buffer.from("302e020100300506032b656e04220420", "hex");

export interface EphemeralKeypair {
  publicKey: Buffer;
  privateKey: Buffer;
}

export function generateEphemeralKeypair(): EphemeralKeypair {
  const { publicKey, privateKey } = generateKeyPairSync("x25519");

  const pubDer = publicKey.export({ type: "spki", format: "der" });
  const privDer = privateKey.export({ type: "pkcs8", format: "der" });

  return {
    publicKey: Buffer.from(pubDer.subarray(SPKI_PREFIX.length)),
    privateKey: Buffer.from(privDer.subarray(PKCS8_PREFIX.length)),
  };
}

export function deriveSharedSecret(myPrivateKey: Buffer, theirPublicKey: Buffer): Buffer {
  const privKeyObj = createPrivateKey({
    key: Buffer.concat([PKCS8_PREFIX, myPrivateKey]),
    format: "der",
    type: "pkcs8",
  });

  const pubKeyObj = createPublicKey({
    key: Buffer.concat([SPKI_PREFIX, theirPublicKey]),
    format: "der",
    type: "spki",
  });

  return Buffer.from(diffieHellman({ privateKey: privKeyObj, publicKey: pubKeyObj }));
}
