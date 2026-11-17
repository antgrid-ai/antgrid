import { z } from "zod/v4";
import { RawKey32Schema } from "./machine-directory";

// Agent-to-agent session-bus frames on the central socket. The relay queues and
// forwards `blob` without being able to open it (sealed to the recipient's bus
// key); it reads only the envelope fields below. Keep in lockstep with the
// bridge sealer and the relay queue.

// Hard cap on one inbound control frame; every bus bound below must leave the
// serialized frame inside it with headroom for the envelope fields.
export const RELAY_MAX_CONTROL_FRAME_BYTES = 128 * 1024;
// Largest plaintext a sender may seal. Sized so the base64 `box` plus the rest
// of a bus:send stays well under RELAY_MAX_CONTROL_FRAME_BYTES.
export const BUS_MAX_PLAINTEXT_BYTES = 92_160;
// base64 length of nonce(12) + ciphertext + tag(16) for the largest plaintext.
export const BUS_BOX_MAX_CHARS = Math.ceil((BUS_MAX_PLAINTEXT_BYTES + 28) / 3) * 4;
export const BUS_MAX_TTL_MS = 6 * 60 * 60_000;

export const BusId = z.string().uuid();
export const BusDeviceId = z.string().uuid();
export const BusAckCode = z.string().regex(/^[A-Z][A-Z0-9_]{0,63}$/);

export const BusBlob = z.object({
  epk: RawKey32Schema,
  box: z
    .string()
    .min(40)
    .max(BUS_BOX_MAX_CHARS)
    .regex(/^[A-Za-z0-9+/]+={0,2}$/),
});

// Ed25519 signature (64 bytes) in padded base64.
export const BusAckSig = z.string().regex(/^[A-Za-z0-9+/]{86}==$/);

const codeIffRefused = (m: { outcome: "applied" | "refused"; code?: string }) =>
  (m.outcome === "refused") === (m.code !== undefined);
const CODE_IFF_REFUSED = { message: "code is required for refused and forbidden for applied", path: ["code"] };

// --- Client → Relay ---

export const BusSendMessage = z.object({
  type: z.literal("bus:send"),
  id: BusId,
  to: BusDeviceId,
  blob: BusBlob,
  ttlMs: z.number().int().min(1).max(BUS_MAX_TTL_MS),
});

export const BusAckMessage = z
  .object({
    type: z.literal("bus:ack"),
    id: BusId,
    outcome: z.enum(["applied", "refused"]),
    code: BusAckCode.optional(),
    sig: BusAckSig,
  })
  .refine(codeIffRefused, CODE_IFF_REFUSED);

export const BusDrainMessage = z.object({
  type: z.literal("bus:drain"),
});

// --- Relay → Client ---

export const BusReceiptMessage = z.object({
  type: z.literal("bus:receipt"),
  id: BusId,
  to: BusDeviceId,
  state: z.enum(["queued", "delivered-to-socket"]),
});

export const BusDeliverMessage = z.object({
  type: z.literal("bus:deliver"),
  id: BusId,
  from: BusDeviceId,
  blob: BusBlob,
});

export const BusAckedMessage = z
  .object({
    type: z.literal("bus:acked"),
    id: BusId,
    to: BusDeviceId,
    outcome: z.enum(["applied", "refused"]),
    code: BusAckCode.optional(),
    sig: BusAckSig,
  })
  .refine(codeIffRefused, CODE_IFF_REFUSED);

// The relay has no account roster, so it cannot tell an unknown recipient from
// an offline one; there is deliberately no "unknown-recipient" reason.
export const BusRefusalReason = z.enum([
  "not-agent",
  "self",
  "recipient-outdated",
  "queue-full",
  "rate-limited",
  "expired",
]);

export const BusRefusedMessage = z.object({
  type: z.literal("bus:refused"),
  id: BusId,
  to: BusDeviceId,
  reason: BusRefusalReason,
  retryable: z.boolean(),
});

export const BusClientMessage = z.discriminatedUnion("type", [
  BusSendMessage,
  BusAckMessage,
  BusDrainMessage,
]);

export const BusServerMessage = z.discriminatedUnion("type", [
  BusReceiptMessage,
  BusDeliverMessage,
  BusAckedMessage,
  BusRefusedMessage,
]);

export type BusBlob = z.infer<typeof BusBlob>;
export type BusSendMessage = z.infer<typeof BusSendMessage>;
export type BusAckMessage = z.infer<typeof BusAckMessage>;
export type BusDrainMessage = z.infer<typeof BusDrainMessage>;
export type BusReceiptMessage = z.infer<typeof BusReceiptMessage>;
export type BusDeliverMessage = z.infer<typeof BusDeliverMessage>;
export type BusAckedMessage = z.infer<typeof BusAckedMessage>;
export type BusRefusalReason = z.infer<typeof BusRefusalReason>;
export type BusRefusedMessage = z.infer<typeof BusRefusedMessage>;
export type BusClientMessage = z.infer<typeof BusClientMessage>;
export type BusServerMessage = z.infer<typeof BusServerMessage>;
