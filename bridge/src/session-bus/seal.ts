// Sealing for agent-to-agent bus mail that crosses the relay. The relay queues
// and forwards the blob and must never be able to read it: the body is sealed to
// the recipient machine's bus key (ephemeral-static X25519, HKDF, AES-256-GCM —
// the same construction as push/seal.ts), and the sender signs the inner header
// and body with its Ed25519 device key so a recipient can attribute it. Keep in
// lockstep with the wire schemas in packages/antgrid-wire/src/bus-protocol.ts.
//
// Nothing here logs: a failure is reported by code alone, because the inputs on
// the failure paths are exactly the secrets (keys, plaintext, signatures).
import { createCipheriv, createDecipheriv, hkdfSync, randomBytes } from "node:crypto";
import { z } from "zod/v4";
import { BUS_MAX_PLAINTEXT_BYTES, BUS_MAX_TTL_MS, type BusBlob } from "antgrid-wire";
import { signEd25519, verifyEd25519 } from "../ed25519-pkcs8";
import { deriveSharedSecret, generateEphemeralKeypair } from "../key-exchange";

export const BUS_SEAL_INFO = "antgrid-bus-v1";
export const BUS_AAD_LABEL = "antgrid/bus-aad/1";
export const BUS_SIG_LABEL = "antgrid/bus-sig/1";
export const BUS_ACK_LABEL = "antgrid/bus-ack/1";
/** How far past `expiresAt` a recipient still accepts mail. There is no test for
 *  a `sentAt` in the future: it is signed by a sender the recipient already
 *  trusts, and refusing it would make a machine whose clock runs behind refuse
 *  all mail terminally while the relay hello (which self-heals the same skew)
 *  keeps it looking connected. */
export const BUS_CLOCK_SKEW_MS = 5 * 60_000;

const NONCE_LEN = 12;
const TAG_LEN = 16;
const SIG_B64 = /^[A-Za-z0-9+/]{86}==$/;

export const InnerHeaderSchema = z
  .object({
    v: z.literal(1),
    from: z.string().uuid(),
    to: z.string().uuid(),
    id: z.string().uuid(),
    role: z.enum(["agent", "orchestrator"]),
    kind: z.enum(["message", "request", "response"]),
    correlationId: z.string().uuid().optional(),
    sentAt: z.number().int().nonnegative(),
    expiresAt: z.number().int().nonnegative(),
  })
  .refine((h) => h.expiresAt > h.sentAt && h.expiresAt - h.sentAt <= BUS_MAX_TTL_MS);
export type InnerHeader = z.infer<typeof InnerHeaderSchema>;

/** 4-byte big-endian length before each field, so no field can bleed into its
 *  neighbour and a signature or AAD over the whole is unambiguous. */
export function lengthPrefixed(fields: (string | Buffer)[]): Buffer {
  const parts: Buffer[] = [];
  for (const f of fields) {
    const bytes = typeof f === "string" ? Buffer.from(f, "utf8") : f;
    const len = Buffer.alloc(4);
    len.writeUInt32BE(bytes.length, 0);
    parts.push(len, bytes);
  }
  return Buffer.concat(parts);
}

/** Binary rather than a JSON wrapper so the body is not re-escaped: a
 *  quote-dense frame would otherwise double in size and miss the plaintext cap. */
export function encodeInnerPlaintext(hJson: string, body: string, sig: string): Buffer {
  return lengthPrefixed([hJson, body, sig]);
}

export function decodeInnerPlaintext(buf: Buffer): { hJson: string; body: string; sig: string } | null {
  const fields: Buffer[] = [];
  let at = 0;
  while (at < buf.length) {
    if (fields.length === 3 || at + 4 > buf.length) return null;
    const len = buf.readUInt32BE(at);
    at += 4;
    if (len > buf.length - at) return null;
    fields.push(buf.subarray(at, at + len));
    at += len;
  }
  if (fields.length !== 3) return null;
  const [h, b, s] = fields as [Buffer, Buffer, Buffer];
  if (b.length > BUS_MAX_PLAINTEXT_BYTES) return null;
  try {
    const utf8 = new TextDecoder("utf-8", { fatal: true });
    const sig = utf8.decode(s);
    if (!SIG_B64.test(sig)) return null;
    return { hJson: utf8.decode(h), body: utf8.decode(b), sig };
  } catch {
    return null;
  }
}

/** Binds the box to its outer envelope: a blob re-addressed to another
 *  recipient, sender or id fails to open instead of opening under a new label. */
export function busAad(from: string, to: string, id: string): Buffer {
  return lengthPrefixed([BUS_AAD_LABEL, from, to, id]);
}

export function busSignedBytes(h: InnerHeader, body: string): Buffer {
  return lengthPrefixed([
    BUS_SIG_LABEL, "1", h.from, h.to, h.id, h.role, h.kind,
    h.correlationId ?? "", String(h.sentAt), String(h.expiresAt), body,
  ]);
}

function sealKey(shared: Buffer, epk: Buffer, recipientPub: Buffer): Buffer {
  // The recipient key rides the info so the same shared secret cannot be reused
  // under a different recipient label; epk is the salt as in the push seal.
  return Buffer.from(hkdfSync("sha256", shared, epk, Buffer.concat([Buffer.from(BUS_SEAL_INFO, "utf8"), recipientPub]), 32));
}

export type SealBusResult =
  | { ok: true; blob: BusBlob }
  | { ok: false; code: "PLAINTEXT_TOO_LARGE" | "BAD_RECIPIENT_KEY" };

export function sealBus(args: {
  header: InnerHeader;
  body: string;
  signSeedB64: string;
  recipientBusPubB64: string;
}): SealBusResult {
  const { header, body } = args;
  const recipientPub = Buffer.from(args.recipientBusPubB64, "base64");
  if (recipientPub.length !== 32) return { ok: false, code: "BAD_RECIPIENT_KEY" };
  let sig: string;
  let plaintext: Buffer;
  try {
    sig = signEd25519(args.signSeedB64, busSignedBytes(header, body));
    plaintext = encodeInnerPlaintext(JSON.stringify(header), body, sig);
  } catch {
    return { ok: false, code: "BAD_RECIPIENT_KEY" };
  }
  if (plaintext.length > BUS_MAX_PLAINTEXT_BYTES) return { ok: false, code: "PLAINTEXT_TOO_LARGE" };

  const eph = generateEphemeralKeypair();
  let shared: Buffer | null = null;
  let key: Buffer | null = null;
  try {
    shared = deriveSharedSecret(eph.privateKey, recipientPub);
    key = sealKey(shared, eph.publicKey, recipientPub);
    const nonce = randomBytes(NONCE_LEN);
    const cipher = createCipheriv("aes-256-gcm", key, nonce);
    cipher.setAAD(busAad(header.from, header.to, header.id));
    const ct = Buffer.concat([cipher.update(plaintext), cipher.final()]);
    const box = Buffer.concat([nonce, ct, cipher.getAuthTag()]);
    return { ok: true, blob: { epk: eph.publicKey.toString("base64"), box: box.toString("base64") } };
  } catch {
    // A low-order recipient key makes the DH throw; that is the key's fault.
    return { ok: false, code: "BAD_RECIPIENT_KEY" };
  } finally {
    eph.privateKey.fill(0);
    shared?.fill(0);
    key?.fill(0);
  }
}

export type OpenBusResult =
  | { ok: true; header: InnerHeader; body: string }
  | { ok: false; code: "UNOPENABLE" | "MALFORMED" | "BAD_SIGNATURE" | "HEADER_MISMATCH" };

export function openBus(args: {
  blob: BusBlob;
  from: string;
  to: string;
  id: string;
  ownBusPrivB64: string;
  ownBusPubB64: string;
  senderEd25519PubB64: string;
}): OpenBusResult {
  const epk = Buffer.from(args.blob.epk, "base64");
  const box = Buffer.from(args.blob.box, "base64");
  const ownPub = Buffer.from(args.ownBusPubB64, "base64");
  if (epk.length !== 32 || box.length < NONCE_LEN + TAG_LEN) return { ok: false, code: "UNOPENABLE" };

  const ownPriv = Buffer.from(args.ownBusPrivB64, "base64");
  let shared: Buffer | null = null;
  let key: Buffer | null = null;
  let plaintext: Buffer;
  try {
    shared = deriveSharedSecret(ownPriv, epk);
    key = sealKey(shared, epk, ownPub);
    const decipher = createDecipheriv("aes-256-gcm", key, box.subarray(0, NONCE_LEN));
    decipher.setAAD(busAad(args.from, args.to, args.id));
    decipher.setAuthTag(box.subarray(box.length - TAG_LEN));
    plaintext = Buffer.concat([decipher.update(box.subarray(NONCE_LEN, box.length - TAG_LEN)), decipher.final()]);
  } catch {
    return { ok: false, code: "UNOPENABLE" };
  } finally {
    ownPriv.fill(0);
    shared?.fill(0);
    key?.fill(0);
  }

  const inner = decodeInnerPlaintext(plaintext);
  if (!inner) return { ok: false, code: "MALFORMED" };
  let header: InnerHeader;
  try {
    const parsed = InnerHeaderSchema.safeParse(JSON.parse(inner.hJson));
    if (!parsed.success) return { ok: false, code: "MALFORMED" };
    header = parsed.data;
  } catch {
    return { ok: false, code: "MALFORMED" };
  }
  if (header.from !== args.from || header.to !== args.to || header.id !== args.id) {
    return { ok: false, code: "HEADER_MISMATCH" };
  }
  if (!verifyEd25519(args.senderEd25519PubB64, busSignedBytes(header, inner.body), inner.sig)) {
    return { ok: false, code: "BAD_SIGNATURE" };
  }
  return { ok: true, header, body: inner.body };
}

export function isExpired(header: Pick<InnerHeader, "expiresAt">, now: number): boolean {
  return now > header.expiresAt + BUS_CLOCK_SKEW_MS;
}

export interface BusAckFields {
  from: string;
  to: string;
  id: string;
  outcome: "applied" | "refused";
  code?: string;
}

export function busAckSignedBytes(f: BusAckFields): Buffer {
  return lengthPrefixed([BUS_ACK_LABEL, f.from, f.to, f.id, f.outcome, f.code ?? ""]);
}

export function signBusAck(seedB64: string, fields: BusAckFields): string {
  return signEd25519(seedB64, busAckSignedBytes(fields));
}

export function verifyBusAck(pubB64: string, fields: BusAckFields, sig: string): boolean {
  return verifyEd25519(pubB64, busAckSignedBytes(fields), sig);
}
