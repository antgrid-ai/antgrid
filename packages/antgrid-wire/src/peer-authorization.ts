import { z } from "zod";
import { MAX_TRANSFER_BYTES, STREAM_PROJECT_APP_RECORD_MAX_BYTES } from "./stream-open";

// Bump whenever native stream framing changes: an app on the old framing is
// then refused at the QUIC handshake instead of reaching a bridge that waits
// for an open frame the app never sends.
export const PEER_ALPN = "antgrid/peer/2";
/** Bridge's read cap on a session-stream record (app -> bridge): the app only
 *  ever writes small control-plane records, so its ceiling is the project
 *  stream's app-side cap, not the bridge's much larger write ceiling. A
 *  session record carries only its payload (no header), so this equals that
 *  cap exactly. */
export const PEER_MAX_RECORD_BYTES = STREAM_PROJECT_APP_RECORD_MAX_BYTES;
/** App's read cap on a session-stream record (bridge -> app): sized to the
 *  bridge's own write ceiling, `MAX_TRANSFER_BYTES`, since a control-plane
 *  reply (e.g. a large `control:result`) is always one record. Equals that
 *  ceiling exactly — no header allowance. */
export const PEER_MAX_BRIDGE_RECORD_BYTES = MAX_TRANSFER_BYTES;
export const PEER_LEASE_MS = 60_000;
export const PEER_REFRESH_MS = 20_000;
export const PEER_SELECTION_MS = 5_000;
export const ENDPOINT_CHALLENGE_MS = 120_000;
export const PEER_IDENTITY_MAX_CHARS = 256;
export const PEER_MAX_AUTHORIZED_PEERS = 1024;
export const PEER_MAX_RELAY_URLS = 16;
export const PEER_MAX_GENERATION = "9223372036854775807";
export const DecimalGenerationSchema = z.string().regex(/^(0|[1-9][0-9]{0,18})$/)
  .refine((value) => /^[0-9]{1,19}$/.test(value) && BigInt(value) <= BigInt(PEER_MAX_GENERATION));
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
  accountId: z.string().min(1).max(PEER_IDENTITY_MAX_CHARS),
  deviceId: z.string().uuid(),
  enrollmentId: z.string().min(1).max(PEER_IDENTITY_MAX_CHARS),
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
// `allowInsecureRelay` widens the approved origin to plaintext `http:` for the
// local dev stack, whose relay serves no TLS (see `aspire/peer-stack.ts`).
// Every caller passes a constant its own process configured locally, never a
// value read out of a snapshot or request — otherwise a hostile backend could
// answer with an `http:` origin and downgrade the transport it is supposed to
// be authorizing. The exported `Peer*Schema` constants stay TLS-only so that
// remains the default any new call site inherits.
//
// Cleartext is confined to a network the developer already controls: a LAN
// address is allowed because a phone or emulator has to reach the dev stack, a
// public one is not, whatever the flag says. Mirrored by `isApprovedRelayOrigin`
// in `packages/antgrid_peer_transport` and by the relay's own `Config::validate`.
const isLocalRelayHost = (hostname: string) => {
  // `URL.hostname` keeps the brackets around an IPv6 literal.
  const host = (hostname.startsWith("[") ? hostname.slice(1, -1) : hostname).toLowerCase();
  if (host === "localhost" || host === "::1") return true;
  const octets = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host)?.slice(1).map(Number);
  if (octets) {
    const [first, second] = octets;
    return octets.every((octet) => octet <= 255) &&
      (first === 127 || first === 10 || (first === 192 && second === 168) ||
        (first === 172 && second >= 16 && second <= 31) || (first === 169 && second === 254));
  }
  // Unique-local `fc00::/7` and link-local `fe80::/10`.
  return /^f[cd][0-9a-f]{0,2}:/.test(host) || /^fe[89ab][0-9a-f]:/.test(host);
};
const relayUrlsSchema = (allowInsecureRelay: boolean) => z.array(z.url().refine((value) => {
  // Zod v4 still runs this refine after z.url() rejects the value.
  if (!URL.canParse(value)) return false;
  const url = new URL(value);
  const scheme = url.protocol === "https:" ||
    (allowInsecureRelay && url.protocol === "http:" && isLocalRelayHost(url.hostname));
  return scheme && !url.username && !url.password && !url.search && !url.hash && url.pathname === "/";
})).max(PEER_MAX_RELAY_URLS);

export const peerAuthorizationSnapshotSchema = (allowInsecureRelay: boolean) => z.strictObject({
  accountId: z.string().min(1).max(PEER_IDENTITY_MAX_CHARS),
  deviceId: z.string().uuid(),
  enrollmentId: z.string().min(1).max(PEER_IDENTITY_MAX_CHARS),
  policyGeneration: DecimalGenerationSchema,
  registrationGeneration: DecimalGenerationSchema,
  allowed: z.boolean(),
  leaseMs: z.number().int().min(0).max(PEER_LEASE_MS),
  endpoint: EndpointRegistrationSchema.nullable(),
  peers: z.array(z.strictObject({
    deviceId: z.string().uuid(),
    ed25519Pub: PublicKeySchema,
    endpoint: EndpointRegistrationSchema.nullable(),
  })).max(PEER_MAX_AUTHORIZED_PEERS),
  relayUrls: relayUrlsSchema(allowInsecureRelay),
});
export const PeerAuthorizationSnapshotSchema = peerAuthorizationSnapshotSchema(false);
export type PeerAuthorizationSnapshot = z.infer<typeof PeerAuthorizationSnapshotSchema>;

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
