import { describe, expect, test } from "bun:test";
import { createCipheriv, generateKeyPairSync, hkdfSync, randomBytes, randomUUID } from "node:crypto";
import { BUS_MAX_PLAINTEXT_BYTES, BUS_MAX_TTL_MS, BusBlob } from "antgrid-wire";
import { generateEphemeralKeypair, deriveSharedSecret } from "../src/key-exchange";
import { ARTIFACT_CHUNK_B64_MAX, MAX_ENVELOPE_BYTES } from "../src/session-bus/constants";
import { checkEnvelopeSize, type BusEnvelope } from "../src/session-bus/envelope";
import {
  BUS_CLOCK_SKEW_MS,
  busAad,
  busSignedBytes,
  encodeInnerPlaintext,
  isExpired,
  lengthPrefixed,
  openBus,
  sealBus,
  signBusAck,
  verifyBusAck,
  type InnerHeader,
} from "../src/session-bus/seal";
import { signEd25519 } from "../src/ed25519-pkcs8";

function ed25519Pair() {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const seed = privateKey.export({ type: "pkcs8", format: "der" }).subarray(-32);
  const pub = publicKey.export({ type: "spki", format: "der" }).subarray(-32);
  return { seed: Buffer.from(seed).toString("base64"), pub: Buffer.from(pub).toString("base64") };
}

function busKey() {
  const k = generateEphemeralKeypair();
  return { priv: k.privateKey.toString("base64"), pub: k.publicKey.toString("base64") };
}

const sender = ed25519Pair();
const recipient = busKey();
const fromId = randomUUID();
const toId = randomUUID();

function header(over: Partial<InnerHeader> = {}): InnerHeader {
  return {
    v: 1, from: fromId, to: toId, id: randomUUID(), role: "agent", kind: "message",
    sentAt: 1_000_000, expiresAt: 1_000_000 + 60_000, ...over,
  };
}

function seal(h: InnerHeader, body = "hello", to = recipient) {
  const r = sealBus({ header: h, body, signSeedB64: sender.seed, recipientBusPubB64: to.pub });
  if (!r.ok) throw new Error(`seal refused: ${r.code}`);
  return r.blob;
}

function open(h: InnerHeader, blob: BusBlob, over: Partial<Parameters<typeof openBus>[0]> = {}) {
  return openBus({
    blob, from: h.from, to: h.to, id: h.id,
    ownBusPrivB64: recipient.priv, ownBusPubB64: recipient.pub,
    senderEd25519PubB64: sender.pub, ...over,
  });
}

/** Seals arbitrary inner bytes the way sealBus does, with a caller-chosen info
 *  string, so a test can build a blob the real opener must reject. */
function sealRaw(plaintext: Buffer, h: InnerHeader, info: string): BusBlob {
  const eph = generateEphemeralKeypair();
  const recipientPub = Buffer.from(recipient.pub, "base64");
  const shared = deriveSharedSecret(eph.privateKey, recipientPub);
  const key = Buffer.from(hkdfSync("sha256", shared, eph.publicKey, Buffer.concat([Buffer.from(info), recipientPub]), 32));
  const nonce = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, nonce);
  cipher.setAAD(busAad(h.from, h.to, h.id));
  const ct = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  return { epk: eph.publicKey.toString("base64"), box: Buffer.concat([nonce, ct, cipher.getAuthTag()]).toString("base64") };
}

function signedInner(h: InnerHeader, body: string, hJson = JSON.stringify(h)): Buffer {
  return encodeInnerPlaintext(hJson, body, signEd25519(sender.seed, busSignedBytes(h, body)));
}

describe("sealBus / openBus", () => {
  test("round trip", () => {
    const h = header({ role: "orchestrator", kind: "request", correlationId: randomUUID() });
    const out = open(h, seal(h, "héllo \"quoted\" ✓"));
    expect(out).toEqual({ ok: true, header: h, body: "héllo \"quoted\" ✓" });
  });

  test("a re-addressed blob is unopenable, for each of from, to and id", () => {
    const h = header();
    const blob = seal(h);
    expect(open(h, blob, { from: randomUUID() })).toEqual({ ok: false, code: "UNOPENABLE" });
    expect(open(h, blob, { to: randomUUID() })).toEqual({ ok: false, code: "UNOPENABLE" });
    expect(open(h, blob, { id: randomUUID() })).toEqual({ ok: false, code: "UNOPENABLE" });
  });

  test("a blob signed by someone else is BAD_SIGNATURE", () => {
    const h = header();
    expect(open(h, seal(h), { senderEd25519PubB64: ed25519Pair().pub })).toEqual({ ok: false, code: "BAD_SIGNATURE" });
  });

  test("a valid signature over an inner header that differs from the outer one is HEADER_MISMATCH", () => {
    const inner = header({ id: randomUUID() });
    const outer = header({ id: randomUUID() });
    const blob = sealRaw(signedInner(inner, "x"), outer, "antgrid-bus-v1");
    expect(open(outer, blob)).toEqual({ ok: false, code: "HEADER_MISMATCH" });
  });

  test("a flipped tag byte is unopenable", () => {
    const h = header();
    const blob = seal(h);
    const box = Buffer.from(blob.box, "base64");
    box[box.length - 1] ^= 1;
    expect(open(h, { ...blob, box: box.toString("base64") })).toEqual({ ok: false, code: "UNOPENABLE" });
  });

  test("an all-zero epk is unopenable and does not throw", () => {
    const h = header();
    const blob = seal(h);
    const zero = Buffer.alloc(32).toString("base64");
    expect(open(h, { ...blob, epk: zero })).toEqual({ ok: false, code: "UNOPENABLE" });
  });

  test("a plaintext over the cap is refused", () => {
    const h = header();
    const r = sealBus({ header: h, body: "a".repeat(BUS_MAX_PLAINTEXT_BYTES), signSeedB64: sender.seed, recipientBusPubB64: recipient.pub });
    expect(r).toEqual({ ok: false, code: "PLAINTEXT_TOO_LARGE" });
  });

  test("a bad recipient key is refused without throwing", () => {
    const h = header();
    expect(sealBus({ header: h, body: "x", signSeedB64: sender.seed, recipientBusPubB64: "AAAA" }))
      .toEqual({ ok: false, code: "BAD_RECIPIENT_KEY" });
    expect(sealBus({ header: h, body: "x", signSeedB64: sender.seed, recipientBusPubB64: Buffer.alloc(32).toString("base64") }))
      .toEqual({ ok: false, code: "BAD_RECIPIENT_KEY" });
  });

  test("a different recipient key cannot open", () => {
    const h = header();
    const other = busKey();
    expect(open(h, seal(h), { ownBusPrivB64: other.priv, ownBusPubB64: other.pub })).toEqual({ ok: false, code: "UNOPENABLE" });
  });

  test("a blob sealed under the push KDF info does not open", () => {
    const h = header();
    const blob = sealRaw(signedInner(h, "x"), h, "antgrid-push-v1");
    expect(open(h, blob)).toEqual({ ok: false, code: "UNOPENABLE" });
  });

  test("a changed role or kind fails the signature", () => {
    const h = header();
    const signedOver = header({ id: h.id, role: "agent", kind: "message" });
    for (const tampered of [{ ...h, role: "orchestrator" as const }, { ...h, kind: "request" as const }]) {
      const blob = sealRaw(
        encodeInnerPlaintext(JSON.stringify(tampered), "x", signEd25519(sender.seed, busSignedBytes(signedOver, "x"))),
        h, "antgrid-bus-v1",
      );
      expect(open(h, blob)).toEqual({ ok: false, code: "BAD_SIGNATURE" });
    }
  });

  test("a header whose expiry is not after its send, or exceeds the TTL cap, is MALFORMED", () => {
    for (const bad of [
      header({ expiresAt: 1_000_000 }),
      header({ expiresAt: 999_999 }),
      header({ expiresAt: 1_000_000 + BUS_MAX_TTL_MS + 1 }),
    ]) {
      expect(open(bad, seal(bad))).toEqual({ ok: false, code: "MALFORMED" });
    }
    const edge = header({ expiresAt: 1_000_000 + BUS_MAX_TTL_MS });
    expect(open(edge, seal(edge)).ok).toBe(true);
  });

  test("a truncated plaintext and a four-field plaintext are MALFORMED", () => {
    const h = header();
    const full = signedInner(h, "x");
    const four = lengthPrefixed([JSON.stringify(h), "x", signEd25519(sender.seed, busSignedBytes(h, "x")), "extra"]);
    for (const plaintext of [full.subarray(0, full.length - 3), four]) {
      expect(open(h, sealRaw(plaintext, h, "antgrid-bus-v1"))).toEqual({ ok: false, code: "MALFORMED" });
    }
  });

  test("a quote-dense post frame at the envelope cap seals and opens", () => {
    const envelope = { messageId: "m", threadId: null, contextId: "c", parts: [{ kind: "text", text: "" }], metadata: {} };
    const fixed = JSON.stringify(envelope).length;
    // Each quote costs two serialized bytes.
    envelope.parts[0]!.text = "\"".repeat(Math.floor((MAX_ENVELOPE_BYTES - fixed) / 2));
    expect(checkEnvelopeSize(envelope as unknown as BusEnvelope)).toBeNull();
    const body = JSON.stringify({ type: "session-bus:post", id: randomUUID(), timestamp: 1, envelope });
    const h = header();
    expect(open(h, seal(h, body))).toEqual({ ok: true, header: h, body });
  });

  test("a fetch result carrying a full artifact chunk seals and opens", () => {
    const body = JSON.stringify({ type: "session-bus:fetch:result", dataBase64: "A".repeat(ARTIFACT_CHUNK_B64_MAX) });
    const h = header();
    expect(open(h, seal(h, body))).toEqual({ ok: true, header: h, body });
  });
});

describe("isExpired", () => {
  const h = { expiresAt: 10_000_000 };
  test("bounds", () => {
    expect(isExpired(h, h.expiresAt)).toBe(false);
    expect(isExpired(h, h.expiresAt + BUS_CLOCK_SKEW_MS)).toBe(false);
    expect(isExpired(h, h.expiresAt + BUS_CLOCK_SKEW_MS + 1)).toBe(true);
  });

  test("a sentAt ten minutes in the future is not expired", () => {
    const now = 1_000_000;
    expect(isExpired({ expiresAt: now + 10 * 60_000 + 60_000 }, now)).toBe(false);
  });
});

describe("bus ack signature", () => {
  const f = { from: fromId, to: toId, id: randomUUID(), outcome: "refused" as const, code: "NO_SESSION" };

  test("round trip", () => {
    const sig = signBusAck(sender.seed, f);
    expect(verifyBusAck(sender.pub, f, sig)).toBe(true);
    const applied = { ...f, outcome: "applied" as const, code: undefined };
    expect(verifyBusAck(sender.pub, applied, signBusAck(sender.seed, applied))).toBe(true);
  });

  test("a changed outcome, code, to, id or from fails", () => {
    const sig = signBusAck(sender.seed, f);
    expect(verifyBusAck(sender.pub, { ...f, outcome: "applied", code: undefined }, sig)).toBe(false);
    expect(verifyBusAck(sender.pub, { ...f, code: "OTHER" }, sig)).toBe(false);
    expect(verifyBusAck(sender.pub, { ...f, to: randomUUID() }, sig)).toBe(false);
    expect(verifyBusAck(sender.pub, { ...f, id: randomUUID() }, sig)).toBe(false);
    expect(verifyBusAck(sender.pub, { ...f, from: randomUUID() }, sig)).toBe(false);
  });

  test("a signature by another key fails, and garbage does not throw", () => {
    expect(verifyBusAck(sender.pub, f, signBusAck(ed25519Pair().seed, f))).toBe(false);
    expect(verifyBusAck("not-a-key", f, "not-a-sig")).toBe(false);
  });
});
