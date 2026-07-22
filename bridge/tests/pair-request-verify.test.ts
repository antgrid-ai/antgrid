import { describe, it, expect } from "bun:test";
import { generateKeyPairSync, sign, type KeyObject } from "node:crypto";
import {
  buildPairRequestSigBody,
  verifyPairRequest,
} from "../src/pair-request-verify";

type Ed25519KeyPair = { publicKey: KeyObject; privateKey: KeyObject };

// Ed25519 PKCS8 prefix duplicated from pair-approval.ts so each test file is
// self-contained.
const ED25519_PKCS8_PREFIX = Buffer.from(
  "302e020100300506032b657004220420",
  "hex",
);

function freshKp(): Ed25519KeyPair {
  return generateKeyPairSync("ed25519");
}

function pubRaw(kp: Ed25519KeyPair): string {
  const spki = kp.publicKey.export({ type: "spki", format: "der" }) as Buffer;
  return spki.subarray(spki.length - 32).toString("base64");
}

describe("buildPairRequestSigBody", () => {
  it("produces the canonical NUL-delimited layout for known inputs", () => {
    // All-zero pubkey (32 bytes), all-one nonce (16 bytes), fixed ISO.
    const body = buildPairRequestSigBody({
      agentDeviceId: "a",
      phonePubkey: Buffer.alloc(32, 0).toString("base64"),
      phoneDeviceId: "p",
      nonce: Buffer.alloc(16, 1).toString("base64"),
      requestedAt: "2030-01-01T00:00:00.000Z",
    });
    const expected = Buffer.from(
      // "antgrid.pair-request.v1"
      "616e74677269642e706169722d726571756573742e7631" +
      "00" +
      // "a"
      "61" +
      "00" +
      // 32 zero bytes (decoded phonePubkey)
      "0000000000000000000000000000000000000000000000000000000000000000" +
      "00" +
      // "p"
      "70" +
      "00" +
      // 16 one-bytes (decoded nonce)
      "01010101010101010101010101010101" +
      "00" +
      // "2030-01-01T00:00:00.000Z"
      "323033302d30312d30315430303a30303a30302e3030305a",
      "hex",
    );
    expect(Buffer.from(body).equals(expected)).toBe(true);
  });
});

describe("verifyPairRequest", () => {
  function signedRequest(overrides: Partial<{
    agentDeviceId: string;
    phonePubkey: string;
    phoneDeviceId: string;
    nonce: string;
    requestedAt: string;
    signerKp: Ed25519KeyPair;
  }> = {}) {
    const kp = overrides.signerKp ?? freshKp();
    const phonePubkey = overrides.phonePubkey ?? pubRaw(kp);
    const args = {
      agentDeviceId: overrides.agentDeviceId ?? "agent-1",
      phonePubkey,
      phoneDeviceId: overrides.phoneDeviceId ?? "phone-1",
      nonce: overrides.nonce ?? Buffer.alloc(16, 9).toString("base64"),
      requestedAt: overrides.requestedAt ?? new Date().toISOString(),
    };
    const body = buildPairRequestSigBody(args);
    const phoneSignature = sign(null, body, kp.privateKey).toString("base64");
    return { args, phoneSignature, kp };
  }

  it("accepts a valid signature inside the window", () => {
    const { args, phoneSignature } = signedRequest();
    expect(verifyPairRequest({ ...args, phoneSignature })).toEqual({ ok: true });
  });

  it("rejects a signature made with a different key as BAD_SIGNATURE", () => {
    const { args } = signedRequest();
    const evilKp = freshKp();
    const body = buildPairRequestSigBody(args);
    const phoneSignature = sign(null, body, evilKp.privateKey).toString("base64");
    expect(verifyPairRequest({ ...args, phoneSignature })).toEqual({
      ok: false,
      reason: "BAD_SIGNATURE",
    });
  });

  it("rejects a tampered phoneDeviceId as BAD_SIGNATURE", () => {
    const { args, phoneSignature } = signedRequest();
    expect(
      verifyPairRequest({ ...args, phoneDeviceId: "different", phoneSignature }),
    ).toEqual({ ok: false, reason: "BAD_SIGNATURE" });
  });

  it("rejects a request older than 30 s as STALE_REQUEST", () => {
    const now = Date.now();
    const { args, phoneSignature } = signedRequest({
      requestedAt: new Date(now - 31_000).toISOString(),
    });
    expect(verifyPairRequest({ ...args, phoneSignature, now })).toEqual({
      ok: false,
      reason: "STALE_REQUEST",
    });
  });

  it("rejects a request more than 5 s into the future as STALE_REQUEST", () => {
    const now = Date.now();
    const { args, phoneSignature } = signedRequest({
      requestedAt: new Date(now + 6_000).toISOString(),
    });
    expect(verifyPairRequest({ ...args, phoneSignature, now })).toEqual({
      ok: false,
      reason: "STALE_REQUEST",
    });
  });

  it("tolerates up to 5 s of forward skew", () => {
    const now = Date.now();
    const { args, phoneSignature } = signedRequest({
      requestedAt: new Date(now + 3_000).toISOString(),
    });
    expect(verifyPairRequest({ ...args, phoneSignature, now })).toEqual({ ok: true });
  });

  it("rejects an unparseable timestamp as STALE_REQUEST", () => {
    const { args, phoneSignature } = signedRequest();
    expect(
      verifyPairRequest({ ...args, requestedAt: "not-a-date", phoneSignature }),
    ).toEqual({ ok: false, reason: "STALE_REQUEST" });
  });

  it("rejects a phonePubkey that isn't 32 raw bytes as BAD_SIGNATURE", () => {
    const { args, phoneSignature } = signedRequest();
    expect(
      verifyPairRequest({
        ...args,
        phonePubkey: Buffer.alloc(16, 0).toString("base64"),
        phoneSignature,
      }),
    ).toEqual({ ok: false, reason: "BAD_SIGNATURE" });
  });
});
