import { describe, it, expect } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { createPrivateKey, createPublicKey } from "node:crypto";
import { signPairApproval } from "../src/pair-approval";

// PKCS8 prefix for an Ed25519 raw 32-byte seed (RFC 8410). Mirrors
// `ED25519_PKCS8_PREFIX` in pair-approval.ts; duplicated here so the test
// fixture is self-contained for cross-language reproduction.
const ED25519_PKCS8_PREFIX = Buffer.from(
  "302e020100300506032b657004220420",
  "hex",
);

describe("pair-approval cross-language vectors", () => {
  it("generates a deterministic fixture for cross-lang verification", () => {
    // Deterministic 32-byte seed (32 ASCII chars).
    const seed = Buffer.from("0123456789abcdef0123456789abcdef", "utf8");
    expect(seed.length).toBe(32);

    const args = {
      agentDeviceId: "agent-deterministic",
      phonePubkey: Buffer.alloc(32, 4).toString("base64"),
      phoneDeviceId: "phone-deterministic",
      nonce: Buffer.alloc(16, 6).toString("base64"),
      expiresAt: "2030-01-01T00:00:00.000Z",
    };

    const { signature, sigBody } = signPairApproval({
      agentEd25519Priv: seed,
      ...args,
    });

    // Derive Ed25519 pubkey from the seed deterministically.
    const priv = createPrivateKey({
      key: Buffer.concat([ED25519_PKCS8_PREFIX, seed]),
      format: "der",
      type: "pkcs8",
    });
    const pubDer = createPublicKey(priv).export({ type: "spki", format: "der" });
    const pubRaw = Buffer.from(pubDer).subarray(-32).toString("base64");

    // sigBody is the raw canonical bytes (not SHA-256). The Dart verifier
    // reproduces the same bytes from `args` and verifies the signature
    // directly — no hashing step.
    const vectors = {
      seedHex: seed.toString("hex"),
      pubkeyB64: pubRaw,
      args,
      sigBodyHex: Buffer.from(sigBody).toString("hex"),
      signatureB64: signature,
    };

    const outPath = join(
      __dirname,
      "..",
      "..",
      "evals",
      "fixtures",
      "pair-approval-vectors.json",
    );
    mkdirSync(dirname(outPath), { recursive: true });
    writeFileSync(outPath, JSON.stringify(vectors, null, 2));

    expect(vectors.signatureB64.length).toBeGreaterThan(80);
    expect(vectors.sigBodyHex.length).toBeGreaterThan(0);
    expect(vectors.pubkeyB64.length).toBeGreaterThan(0);
  });
});
