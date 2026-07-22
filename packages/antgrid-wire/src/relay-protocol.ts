import { z } from "zod/v4";
import { PushDeliverMessage, PushResultMessage } from "./push-protocol";

// v3 device ids are bare machine/phone ids — no '#' (sub-deviceIds are gone)
// and no compound `deviceUuid.projectId` registrations, though '.' remains a
// legal id character.
const DEVICE_ID = z.string().min(1).max(128).regex(/^[a-zA-Z0-9_.-]+$/);

// --- Client → Relay ---

// First (and only) auth frame: proof-of-possession over buildHelloSigBody
// (see relay-auth.ts). Replaces the v2 register/challenge/challenge-response
// round trips — the relay verifies and answers `welcome` or a typed error.
export const HelloMessage = z.object({
  type: z.literal("hello"),
  protocolVersion: z.literal(3),
  deviceType: z.enum(["agent", "app"]),
  deviceId: DEVICE_ID,
  name: z.string().min(1).max(256),
  publicKey: z.string().min(1).max(256), // base64-encoded Ed25519 public key
  // Connection-instance arbitration: highest epoch wins, loser gets SUPERSEDED.
  epoch: z.number().int().nonnegative(),
  // REQUIRED for both device types — apps authenticate with their own account
  // token; the tokenless legacy-QR path no longer exists (design §4.2).
  licenseToken: z.string().min(1).max(8192),
  ts: z.string().datetime(),
  nonce: z.string().min(20).max(64), // base64, ≥16 random bytes
  sig: z.string().min(1).max(256), // base64 Ed25519 over buildHelloSigBody
});

export const StreamOpenMessage = z.object({
  type: z.literal("stream-open"),
  streamId: z.string().min(1).max(64),
});

export const StreamCloseMessage = z.object({
  type: z.literal("stream-close"),
  streamId: z.string().min(1).max(64),
});

// Sent by either grant party to sever the grant (replaces v2 `unpair`).
export const GrantRevokeMessage = z.object({
  type: z.literal("grant-revoke"),
  peerDeviceId: DEVICE_ID,
});

export const PairRequestMessage = z.object({
  type: z.literal("pair-request"),
  agentDeviceId: DEVICE_ID,
  phonePubkey: z.string().min(1).max(256),
  phoneDeviceId: DEVICE_ID,
  nonce: z.string().min(20).max(64),
  requestedAt: z.string().datetime(),
  // Epoch ms; set by the phone from its own timeout. The relay expires the
  // pending pair (error EXPIRED, ref=nonce) once past it.
  deadline: z.number().int().positive(),
  // Clients never set this: the relay stamps it when forwarding to the agent
  // (its handler overwrites any client-supplied value) and it becomes the
  // approval-routing key.
  pairId: z.string().min(1).max(64).optional(),
  phoneSignature: z.string().min(1).max(256),
  pairCode: z.string().min(1).max(64).optional(),
  label: z.string().min(1).max(64).optional(),
  // Deprecated trust flag. The relay strips this field and forwards NO trust
  // signal to the agent (a relay-controlled flag would be a confused-deputy
  // footgun); the agent admits same-account auto-pair only via the verified
  // account-membership proof below. Kept in the schema solely so the relay's
  // strip step is explicit rather than relying on Zod's default strip.
  sameAccount: z.boolean().optional(),
  // Account-membership proof for QR-less auto-pair. The relay is a zero-knowledge
  // router: it forwards these opaque fields verbatim to the agent, which verifies
  // the signature against its account's live peer-key set (the relay never reads
  // them). Without them in the schema, Zod's default strip mode would drop the
  // proof and the agent would reject the request as UNKNOWN_PHONE.
  accountDevicePubkey: z.string().min(1).max(256).optional(),
  accountMembershipSig: z.string().min(1).max(256).optional(),
});

export const PairApprovalMessage = z.object({
  type: z.literal("pair-approval"),
  // Echo of the relay-stamped id from the forwarded pair-request; the relay
  // routes the approval to the requesting phone by it.
  pairId: z.string().min(1).max(64),
  phonePubkey: z.string().min(1).max(256),
  phoneDeviceId: DEVICE_ID,
  nonce: z.string().min(20).max(64),
  expiresAt: z.string().datetime(),
  signature: z.string().min(1).max(256),
});

export const PairRejectedMessage = z.object({
  type: z.literal("pair-rejected"),
  pairId: z.string().min(1).max(64),
  phonePubkey: z.string().min(1).max(256),
  reason: z.enum([
    "UNKNOWN_PHONE",
    "PAIRING_WINDOW_CLOSED",
    "USER_DECLINED",
    "BAD_SIGNATURE",
    "STALE_REQUEST",
  ]),
});

export const RouteHeader = z.object({
  type: z.literal("message"),
  to: DEVICE_ID,
  channel: z.enum(["control", "preview"]),
});

export const RouteHeaderOutbound = z.object({
  type: z.literal("message"),
  from: z.string().min(1).max(128),
  channel: z.enum(["control", "preview"]),
  ts: z.number().int(),
});

export const ClientMessage = z.discriminatedUnion("type", [
  HelloMessage,
  StreamOpenMessage,
  StreamCloseMessage,
  GrantRevokeMessage,
  PairRequestMessage,
  PairApprovalMessage,
  PairRejectedMessage,
  PushDeliverMessage,
]);

// --- Relay → Client ---

export const WelcomeMessage = z.object({
  type: z.literal("welcome"),
  deviceId: z.string(),
  epoch: z.number().int().nonnegative(),
  serverTime: z.string().datetime(),
});

export const StreamOpenedMessage = z.object({
  type: z.literal("stream-opened"),
  streamId: z.string(),
});

export const StreamClosedMessage = z.object({
  type: z.literal("stream-closed"),
  streamId: z.string(),
});

export const GrantRevokedMessage = z.object({
  type: z.literal("grant-revoked"),
  peerDeviceId: z.string(),
  reason: z.enum(["PEER_REPLACED", "REVOKED", "STALE"]),
});

export const ErrorCode = z.enum([
  "AUTH_FAILED",
  "MAX_CONNECTIONS",
  "RATE_LIMITED",
  "INVALID_MESSAGE",
  "NOT_AUTHENTICATED",
  "PAIR_RATE_LIMITED",
  "WRONG_DEVICE_TYPE",
  "ROUTE_FAILED",
  "MESSAGE_RATE_LIMITED",
  "LICENSE_INVALID",
  "LICENSE_EXPIRED",
  "LICENSE_REVOKED",
  "LICENSE_REQUIRED",
  // License verification infrastructure (JWKS) unreachable — the client's
  // credentials may be fine; retryable, unlike the LICENSE_* verdicts above.
  "LICENSE_UNAVAILABLE",
  // Account is at its concurrent remote-running-agent cap (the paid axis).
  // Distinct from LICENSE_* (auth is valid) — enforced at stream-open
  // admission, with `ref` echoing the rejected streamId.
  "SESSION_LIMIT_EXCEEDED",
  // Pair-request target not connected. Distinct from PEER_OFFLINE (routed
  // traffic) so pairing UX and routing retry loops stay separately tunable.
  "AGENT_OFFLINE",
  "PAIR_REJECTED",
  "UNKNOWN_PHONE",
  "PAIRING_WINDOW_CLOSED",
  "NONCE_MISMATCH",
  "APPROVAL_EXPIRED",
  // Grant displaced by a newer pairing; also a grant-revoked reason — this
  // code covers the error-frame variant on subsequent routed sends.
  "PEER_REPLACED",
  "SUPERSEDED", // epoch arbitration lost to a newer connection; retryable: false
  "PEER_OFFLINE", // routed frame, peer not connected; retryable: true
  "PROTOCOL_VIOLATION", // malformed/unexpected frame incl. non-hello first frame; retryable: false
  "EXPIRED", // pair-request past its deadline; retryable: true
  "NOT_AUTHORIZED", // routed frame with no grant linking sender and target; retryable: false
]);

export const ErrorMessage = z.object({
  type: z.literal("error"),
  code: ErrorCode,
  message: z.string(),
  // The error contract is law (design §3.3): every error states whether the
  // client may retry the same action unchanged. Terminal-vs-retryable
  // classification lives HERE, not in per-client code lists.
  retryable: z.boolean(),
  ref: z.string().optional(), // echoes pair-request nonce / streamId
  serverTime: z.string().datetime().optional(), // clock-skew AUTH_FAILED only (design §4.1)
});

export const PeerOfflineMessage = z.object({
  type: z.literal("peer-offline"),
  peerId: z.string(),
});

export const PeerOnlineMessage = z.object({
  type: z.literal("peer-online"),
  peerId: z.string(),
});

// Grant-created notification (kept from v2; fires when a grant links the
// two devices, not per-socket).
export const PairConnectedMessage = z.object({
  type: z.literal("pair-connected"),
  peerId: z.string(),
  peerName: z.string(),
  peerType: z.enum(["agent", "app"]),
});

// Relay → Client discriminated union. Used by clients (e.g. the bridge) to
// validate inbound relay-control messages before dispatching. `pair-request`
// appears here as well as in `ClientMessage` because a phone sends it and the
// relay forwards it (pairId-stamped) to the agent.
export const ServerMessage = z.discriminatedUnion("type", [
  WelcomeMessage,
  StreamOpenedMessage,
  StreamClosedMessage,
  GrantRevokedMessage,
  ErrorMessage,
  PeerOnlineMessage,
  PeerOfflineMessage,
  PairConnectedMessage,
  PairRequestMessage,
  PushResultMessage,
]);

// --- Sealed stream envelope (endpoint-internal; design §7.1) ---
//
// Wraps every sealed payload as `{ s?, m }` so one machine socket multiplexes
// project streams. The relay NEVER sees this — it lives inside the ciphertext.
// `m` is an AbMessage (bridge/src/protocol.ts), which antgrid-wire must not
// depend on; only the field names are shared here.

/** Sealed-payload stream envelope. `s` absent or "0" = machine control plane. */
export interface StreamEnvelope {
  s?: string;
  m: unknown;
}

export const CONTROL_STREAM_ID = "0";

// --- Type exports ---

export type HelloMessage = z.infer<typeof HelloMessage>;
export type StreamOpenMessage = z.infer<typeof StreamOpenMessage>;
export type StreamCloseMessage = z.infer<typeof StreamCloseMessage>;
export type GrantRevokeMessage = z.infer<typeof GrantRevokeMessage>;
export type PairRequestMessage = z.infer<typeof PairRequestMessage>;
export type PairApprovalMessage = z.infer<typeof PairApprovalMessage>;
export type PairRejectedMessage = z.infer<typeof PairRejectedMessage>;
export type RouteHeader = z.infer<typeof RouteHeader>;
export type RouteHeaderOutbound = z.infer<typeof RouteHeaderOutbound>;
export type ClientMessage = z.infer<typeof ClientMessage>;
export type WelcomeMessage = z.infer<typeof WelcomeMessage>;
export type StreamOpenedMessage = z.infer<typeof StreamOpenedMessage>;
export type StreamClosedMessage = z.infer<typeof StreamClosedMessage>;
export type GrantRevokedMessage = z.infer<typeof GrantRevokedMessage>;
export type ErrorMessage = z.infer<typeof ErrorMessage>;
export type ErrorCode = z.infer<typeof ErrorCode>;
export type PeerOfflineMessage = z.infer<typeof PeerOfflineMessage>;
export type PeerOnlineMessage = z.infer<typeof PeerOnlineMessage>;
export type PairConnectedMessage = z.infer<typeof PairConnectedMessage>;
export type ServerMessage = z.infer<typeof ServerMessage>;
