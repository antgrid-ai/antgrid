// bridge/tests/e2e/vectors.test.ts
import { describe, expect, test } from "bun:test";
import vectors from "../../../evals/fixtures/e2e-handshake-vectors.json";
import { buildTranscript } from "../../src/e2e/transcript";
import { deriveSessionKeys } from "../../src/e2e/key-schedule";
import { agentConfirmTag, phoneConfirmTag } from "../../src/e2e/confirm";
import { E2eTransport } from "../../src/e2e/transport";
import { signTranscript, verifyTranscriptSig } from "../../src/e2e/handshake-sig";
import { deriveSharedSecret } from "../../src/key-exchange";

const v = vectors as typeof vectors;
const hex = (s: string) => Buffer.from(s, "hex");
const b64 = (s: string) => Buffer.from(s, "base64");

describe("e2e-handshake-vectors.json (golden)", () => {
  const phoneFields = {
    registrationId: v.ids.registrationId, role: "phone" as const,
    agentDeviceId: v.ids.agentDeviceId, phoneDeviceId: v.ids.phoneDeviceId,
    agentX25519Pub: Buffer.alloc(0), phoneX25519Pub: b64(v.x25519.phonePubB64),
    nonce: b64(v.nonceB64),
  };
  const agentFields = { ...phoneFields, role: "agent" as const, agentX25519Pub: b64(v.x25519.agentPubB64) };

  test("transcript bytes match", () => {
    expect(buildTranscript(phoneFields).toString("hex")).toBe(v.transcripts.phoneSigBodyHex);
    expect(buildTranscript(agentFields).toString("hex")).toBe(v.transcripts.agentSigBodyHex);
  });

  test("signatures match and verify", () => {
    expect(signTranscript(buildTranscript(phoneFields), hex(v.ed25519.phoneSeedHex))).toBe(v.signatures.phoneSigB64);
    expect(signTranscript(buildTranscript(agentFields), hex(v.ed25519.agentSeedHex))).toBe(v.signatures.agentSigB64);
    expect(verifyTranscriptSig(buildTranscript(agentFields), v.ed25519.agentPubB64, v.signatures.agentSigB64)).toBe(true);
    expect(verifyTranscriptSig(buildTranscript(phoneFields), v.ed25519.phonePubB64, v.signatures.phoneSigB64)).toBe(true);
  });

  test("key schedule matches (derived from both sides' DH)", () => {
    const ssAgent = deriveSharedSecret(hex(v.x25519.agentPrivHex), b64(v.x25519.phonePubB64));
    const ssPhone = deriveSharedSecret(hex(v.x25519.phonePrivHex), b64(v.x25519.agentPubB64));
    const kA = deriveSessionKeys(ssAgent, buildTranscript(agentFields));
    const kP = deriveSessionKeys(ssPhone, buildTranscript(agentFields));
    for (const k of [kA, kP]) {
      expect(k.a2p.toString("hex")).toBe(v.keySchedule.kA2pHex);
      expect(k.p2a.toString("hex")).toBe(v.keySchedule.kP2aHex);
      expect(k.confirm.toString("hex")).toBe(v.keySchedule.kConfirmHex);
    }
  });

  test("confirm tags match", () => {
    const ck = hex(v.keySchedule.kConfirmHex);
    expect(agentConfirmTag(ck).toString("hex")).toBe(v.confirm.agentTagHex);
    expect(phoneConfirmTag(ck).toString("hex")).toBe(v.confirm.phoneTagHex);
  });

  test("transport vectors seal and open", () => {
    const agentT = new E2eTransport({ sendKey: hex(v.keySchedule.kA2pHex), recvKey: hex(v.keySchedule.kP2aHex) });
    const phoneT = new E2eTransport({ sendKey: hex(v.keySchedule.kP2aHex), recvKey: hex(v.keySchedule.kA2pHex) });
    for (const t of v.transport) {
      const sealer = t.dir === "a2p" ? agentT : phoneT;
      const opener = t.dir === "a2p" ? phoneT : agentT;
      expect(sealer.seal(t.plaintext, hex(t.nonceHex)).toString("hex")).toBe(t.sealedHex);
      expect(opener.open(hex(t.sealedHex))).toBe(t.plaintext);
    }
  });
});
