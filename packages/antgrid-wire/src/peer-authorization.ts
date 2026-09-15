import { z } from "zod";
import { MAX_HEADER_LEN } from "./frame";
import { MAX_FRAME_PAYLOAD } from "./frag";

export const PEER_ALPN = "antgrid/peer/1";
export const PEER_MAX_RECORD_BYTES = MAX_FRAME_PAYLOAD + MAX_HEADER_LEN + 4;
export const PEER_LEASE_MS = 60_000;
export const PEER_REFRESH_MS = 20_000;
export const PEER_SELECTION_MS = 5_000;
export const ENDPOINT_CHALLENGE_MS = 120_000;
export const DecimalGenerationSchema = z.string().regex(/^(0|[1-9][0-9]{0,18})$/)
  .refine((value) => /^[0-9]{1,19}$/.test(value) && BigInt(value) <= 9223372036854775807n);
export const EndpointIdSchema = z.string().regex(/^[0-9a-f]{64}$/);
const PublicKeySchema = z.string().regex(/^[A-Za-z0-9+/]{43}=$/);
const SignatureSchema = z.string().regex(/^[A-Za-z0-9+/]{86}==$/);
export const EndpointChallengeRequestSchema = z.strictObject({
  endpointId: EndpointIdSchema,
  expectedGeneration: DecimalGenerationSchema,
});
export const EndpointChallengeSchema = EndpointChallengeRequestSchema.extend({
  challengeId: z.string().uuid(),
  challenge: PublicKeySchema,
  // Transport account ownership is the device's userId, not its billing account.
  accountId: z.string().min(1).max(256),
  deviceId: z.string().uuid(),
  enrollmentId: z.string().min(1).max(256),
});
export type EndpointChallenge = z.infer<typeof EndpointChallengeSchema>;
export const EndpointRegistrationRequestSchema = z.strictObject({
  challengeId: z.string().uuid(),
  deviceSignature: SignatureSchema,
  endpointSignature: SignatureSchema,
});
export const EndpointRegistrationSchema = z.strictObject({
  endpointId: EndpointIdSchema,
  generation: DecimalGenerationSchema,
});
export const PeerAuthorizationSnapshotSchema = z.strictObject({
  accountId: z.string().min(1).max(256),
  deviceId: z.string().uuid(),
  enrollmentId: z.string().min(1).max(256),
  policyGeneration: DecimalGenerationSchema,
  registrationGeneration: DecimalGenerationSchema,
  allowed: z.boolean(),
  leaseMs: z.number().int().min(0).max(PEER_LEASE_MS),
  endpoint: EndpointRegistrationSchema.nullable(),
  peers: z.array(z.strictObject({
    deviceId: z.string().uuid(),
    ed25519Pub: PublicKeySchema,
    endpoint: EndpointRegistrationSchema.nullable(),
  })).max(1024),
  relayUrls: z.array(z.url().refine((value) => {
    const url = new URL(value);
    return url.protocol === "https:" && !url.username && !url.password &&
      !url.search && !url.hash && url.pathname === "/";
  })).max(16),
});
export type PeerAuthorizationSnapshot = z.infer<typeof PeerAuthorizationSnapshotSchema>;

export const PeerRelayAdmissionRequestSchema = z.strictObject({
  endpointId: EndpointIdSchema,
  relayUrl: PeerAuthorizationSnapshotSchema.shape.relayUrls.element,
  requestId: z.string().uuid(),
  issuedAt: z.number().int().positive().max(Number.MAX_SAFE_INTEGER),
});
export const PeerRelayAdmissionResponseSchema = z.discriminatedUnion("allowed", [
  z.strictObject({ allowed: z.literal(false), requestId: z.string().uuid() }),
  z.strictObject({
    allowed: z.literal(true),
    requestId: z.string().uuid(),
    endpointId: EndpointIdSchema,
    userId: z.string().min(1).max(256),
    deviceId: z.string().uuid(),
    enrollmentId: z.string().min(1).max(256),
    registrationGeneration: DecimalGenerationSchema,
    policyGeneration: DecimalGenerationSchema,
    leaseMs: z.number().int().positive().max(PEER_LEASE_MS),
  }),
]);
export type PeerRelayAdmissionRequest = z.infer<typeof PeerRelayAdmissionRequestSchema>;
export type PeerRelayAdmissionResponse = z.infer<typeof PeerRelayAdmissionResponseSchema>;

/** Length prefixes keep variable identifiers unambiguous across TS and Dart. */
export function endpointChallengeBytes(value: EndpointChallenge): Uint8Array {
  const parsed = EndpointChallengeSchema.parse(value);
  const fields = ["antgrid/endpoint-registration/1", parsed.challengeId,
    parsed.challenge, parsed.accountId, parsed.deviceId, parsed.enrollmentId,
    parsed.endpointId, parsed.expectedGeneration].map((field) => new TextEncoder().encode(field));
  const result = new Uint8Array(fields.reduce((sum, field) => sum + 4 + field.length, 0));
  const view = new DataView(result.buffer);
  let offset = 0;
  for (const field of fields) {
    view.setUint32(offset, field.length, false);
    result.set(field, offset + 4);
    offset += 4 + field.length;
  }
  return result;
}
