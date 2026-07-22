import { describe, it, expect } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { createPrivateKey, createPublicKey, sign } from "node:crypto";
import { buildPairRequestSigBody } from "../src/pair-request-verify";

const ED25519_PKCS8_PREFIX = Buffer.from(
  "302e020100300506032b657004220420",
  "hex",
);

describe("pair-request cross-language vectors", () => {
  it("generates a deterministic fixture for cross-lang verification", () => {
    // Deterministic 32-byte phone seed — same byte pattern as the
    // pair-approval vectors so the fixture format is recognisable.
    const seed = Buffer.from("0123456789abcdef0123456789abcdef", "utf8");
    expect(seed.length).toBe(32);

    const priv = createPrivateKey({
      key: Buffer.concat([ED25519_PKCS8_PREFIX, seed]),
      format: "der",
      type: "pkcs8",
    });
    const pubDer = createPublicKey(priv).export({ type: "spki", format: "der" });
    const phonePubkeyB64 = Buffer.from(pubDer).subarray(-32).toString("base64");

    const args = {
      agentDeviceId: "agent-deterministic",
      phonePubkey: phonePubkeyB64,
      phoneDeviceId: "phone-deterministic",
      nonce: Buffer.alloc(16, 6).toString("base64"),
      requestedAt: "2030-01-01T00:00:00.000Z",
    };

    const sigBody = buildPairRequestSigBody(args);
    const signature = sign(null, sigBody, priv).toString("base64");

    const vectors = {
      phoneSeedHex: seed.toString("hex"),
      phonePubkeyB64,
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
      "pair-request-vectors.json",
    );
    mkdirSync(dirname(outPath), { recursive: true });
    writeFileSync(outPath, JSON.stringify(vectors, null, 2));

    expect(vectors.signatureB64.length).toBeGreaterThan(80);
    expect(vectors.sigBodyHex.length).toBeGreaterThan(0);
    expect(vectors.phonePubkeyB64.length).toBe(44); // base64 of 32 bytes (padded)
  });
});
