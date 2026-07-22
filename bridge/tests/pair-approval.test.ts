import { describe, it, expect } from "bun:test";
import { generateKeyPairSync, verify } from "node:crypto";
import { signPairApproval, buildPairApprovalSigBody } from "../src/pair-approval";

describe("signPairApproval", () => {
  const kp = generateKeyPairSync("ed25519");
  const privDer = kp.privateKey.export({ type: "pkcs8", format: "der" });
  const pubDer = kp.publicKey.export({ type: "spki", format: "der" });
  const privSeed = Buffer.from(privDer).subarray(-32); // raw 32-byte Ed25519 seed

  const args = {
    agentDeviceId: "agent-1",
    phonePubkey: Buffer.from(new Uint8Array(32).fill(7)).toString("base64"),
    phoneDeviceId: "phone-1",
    nonce: Buffer.from(new Uint8Array(16).fill(3)).toString("base64"),
    expiresAt: "2026-04-29T10:00:00.000Z",
  };

  it("produces a verifiable signature", () => {
    const { signature, sigBody } = signPairApproval({ agentEd25519Priv: privSeed, ...args });
    const sigBuf = Buffer.from(signature, "base64");
    const ok = verify(null, sigBody, { key: pubDer, format: "der", type: "spki" }, sigBuf);
    expect(ok).toBe(true);
  });

  it("uses domain-separated null-delimited body", () => {
    const body = buildPairApprovalSigBody(args);
    const decoded = Buffer.from(body).toString("binary");
    expect(decoded.startsWith("antgrid.pair-approval.v1\0")).toBe(true);
    expect(decoded.includes("\0agent-1\0")).toBe(true);
    expect(decoded.endsWith("2026-04-29T10:00:00.000Z")).toBe(true);
  });

  it("prefixes sigBody with the domain-separation tag", () => {
    // The relay challenge-response (see relay-client.ts) signs *raw*
    // nonce bytes with no domain prefix. Our pair-approval body must
    // start with the literal "antgrid.pair-approval.v1\0" so a forged
    // pair-approval can never be replayed as a challenge-response (and
    // vice versa).
    const body = Buffer.from(buildPairApprovalSigBody(args));
    const expectedPrefix = Buffer.concat([
      Buffer.from("antgrid.pair-approval.v1", "utf8"),
      Buffer.from([0x00]),
    ]);
    expect(expectedPrefix.length).toBe(25);
    expect(body.subarray(0, 25).equals(expectedPrefix)).toBe(true);
  });

  it("is not forgeable as a raw-nonce signature even with adversarial inputs", () => {
    // Adversary picks empty agentDeviceId and a nonce whose decoded bytes
    // start with what *would* be a relay challenge prefix. The domain tag
    // still sits in front, so our sigBody cannot be confused with a raw
    // nonce signed under the relay challenge protocol.
    const evilNonce = Buffer.from("antgrid.relay.challenge.v1\0deadbeef", "utf8")
      .toString("base64");
    const adversarial = {
      agentDeviceId: "",
      phonePubkey: args.phonePubkey,
      phoneDeviceId: args.phoneDeviceId,
      nonce: evilNonce,
      expiresAt: args.expiresAt,
    };
    const body = Buffer.from(buildPairApprovalSigBody(adversarial));
    expect(body[0]).toBe("a".charCodeAt(0));
    expect(body.subarray(0, 24).toString("utf8")).toBe("antgrid.pair-approval.v1");
    expect(body[24]).toBe(0x00);

    // A hypothetical "no domain prefix" variant of the same args would
    // differ in the very first byte — proving the prefix is load-bearing.
    const noDomain = Buffer.concat([
      Buffer.from(adversarial.agentDeviceId, "utf8"),
      Buffer.from([0x00]),
      Buffer.from(adversarial.phonePubkey, "base64"),
    ]);
    expect(body[0]).not.toBe(noDomain[0]);
  });
});
