import { describe, it, expect } from "bun:test";
import { generateKeyPairSync, sign } from "node:crypto";
import { verifyPairApproval } from "../src/pair-verify";

// Inline mirror of bridge/src/pair-approval.ts:signPairApproval — kept here
// because relay tsconfig pins rootDir to ./relay, so we can't import across
// packages. The byte layout MUST stay in sync with the agent helper.
const DOMAIN = "antgrid.pair-approval.v1";
const NUL = Buffer.from([0]);
const ED25519_PKCS8_PREFIX = Buffer.from(
  "302e020100300506032b657004220420",
  "hex",
);

function signPairApproval(args: {
  agentEd25519Priv: Uint8Array | Buffer;
  agentDeviceId: string;
  phonePubkey: string;
  phoneDeviceId: string;
  nonce: string;
  expiresAt: string;
}): { signature: string } {
  const sigBody = Buffer.concat([
    Buffer.from(DOMAIN, "utf8"),
    NUL,
    Buffer.from(args.agentDeviceId, "utf8"),
    NUL,
    Buffer.from(args.phonePubkey, "base64"),
    NUL,
    Buffer.from(args.phoneDeviceId, "utf8"),
    NUL,
    Buffer.from(args.nonce, "base64"),
    NUL,
    Buffer.from(args.expiresAt, "utf8"),
  ]);
  const pkcs8 = Buffer.concat([
    ED25519_PKCS8_PREFIX,
    Buffer.from(args.agentEd25519Priv),
  ]);
  const signature = sign(null, sigBody, {
    key: pkcs8,
    format: "der",
    type: "pkcs8",
  });
  return { signature: signature.toString("base64") };
}

describe("verifyPairApproval", () => {
  const kp = generateKeyPairSync("ed25519");
  const privDer = kp.privateKey.export({ type: "pkcs8", format: "der" });
  const pubDer = kp.publicKey.export({ type: "spki", format: "der" });
  const privSeed = Buffer.from(privDer).subarray(-32);
  const pubRaw = Buffer.from(pubDer).subarray(-32).toString("base64");

  const baseArgs = {
    agentDeviceId: "a1",
    phonePubkey: Buffer.alloc(32, 7).toString("base64"),
    phoneDeviceId: "p1",
    nonce: Buffer.alloc(16, 3).toString("base64"),
    expiresAt: new Date(Date.now() + 30_000).toISOString(),
  };

  function makeApproval(overrides: Partial<typeof baseArgs> = {}) {
    const args = { ...baseArgs, ...overrides };
    const { signature } = signPairApproval({
      agentEd25519Priv: privSeed,
      ...args,
    });
    // pairId is the relay-stamped routing key (design §5.2) — verifyPairApproval
    // itself never reads it, but the schema requires it on the wire type.
    return { type: "pair-approval" as const, pairId: "test-pair-id", ...args, signature };
  }

  it("accepts a valid approval", () => {
    const r = verifyPairApproval({
      agentEd25519Pubkey: pubRaw,
      agentDeviceId: baseArgs.agentDeviceId,
      approval: makeApproval(),
      expectedNonce: baseArgs.nonce,
    });
    expect(r.ok).toBe(true);
  });

  it("rejects expired approval", () => {
    const stale = makeApproval({
      expiresAt: new Date(Date.now() - 1).toISOString(),
    });
    const r = verifyPairApproval({
      agentEd25519Pubkey: pubRaw,
      agentDeviceId: baseArgs.agentDeviceId,
      approval: stale,
      expectedNonce: baseArgs.nonce,
    });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.reason).toBe("APPROVAL_EXPIRED");
  });

  it("rejects nonce mismatch", () => {
    const r = verifyPairApproval({
      agentEd25519Pubkey: pubRaw,
      agentDeviceId: baseArgs.agentDeviceId,
      approval: makeApproval(),
      expectedNonce: Buffer.alloc(16, 9).toString("base64"),
    });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.reason).toBe("NONCE_MISMATCH");
  });

  it("rejects forged signature", () => {
    const ok = makeApproval();
    const tampered = { ...ok, signature: Buffer.alloc(64, 0).toString("base64") };
    const r = verifyPairApproval({
      agentEd25519Pubkey: pubRaw,
      agentDeviceId: baseArgs.agentDeviceId,
      approval: tampered,
      expectedNonce: baseArgs.nonce,
    });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.reason).toBe("BAD_SIGNATURE");
  });

  it("rejects sig from a different key", () => {
    const otherKp = generateKeyPairSync("ed25519");
    const otherPub = Buffer.from(
      otherKp.publicKey.export({ type: "spki", format: "der" }),
    )
      .subarray(-32)
      .toString("base64");
    const r = verifyPairApproval({
      agentEd25519Pubkey: otherPub,
      agentDeviceId: baseArgs.agentDeviceId,
      approval: makeApproval(),
      expectedNonce: baseArgs.nonce,
    });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.reason).toBe("BAD_SIGNATURE");
  });
});
