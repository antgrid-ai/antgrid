import { z } from "zod/v4";
import { PushDeliverMessage, PushResultMessage } from "./push-protocol";

// An AGENT's device id is its bare machine `deviceUuid` (no compound
// `deviceUuid.projectId` registrations, though '.' remains a legal character).
// An APP's is a per-machine relay slot, `<accountDeviceUuid>#<machineDeviceUuid>`
// — see relay-slot.ts — so '#' is legal here and in a route header's `to`.
// 128 leaves room for two UUIDs and the separator.
const DEVICE_ID = z.string().min(1).max(128).regex(/^[a-zA-Z0-9_.#-]+$/);

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

// App-layer liveness probe: protocol-level WS pongs are unobservable from
// browser-style client APIs, so clients probe here (see bridge watchdog).
export const PingMessage = z.object({
  type: z.literal("ping"),
});

export const ClientMessage = z.discriminatedUnion("type", [
  HelloMessage,
  StreamOpenMessage,
  StreamCloseMessage,
  PushDeliverMessage,
  PingMessage,
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

export const ErrorCode = z.enum([
  "AUTH_FAILED",
  "MAX_CONNECTIONS",
  "RATE_LIMITED",
  "INVALID_MESSAGE",
  "NOT_AUTHENTICATED",
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
  // RETIRED: the relay no longer meters open streams and never emits this.
  // Reserved (not removed) because bridge and app still decode it from relays
  // predating the worker-limit change, and because reusing the name for a new
  // meaning would silently mis-handle those older relays' rejections.
  "SESSION_LIMIT_EXCEEDED",
  "UNKNOWN_PHONE",
  "NONCE_MISMATCH",
  "APPROVAL_EXPIRED",
  "SUPERSEDED", // epoch arbitration lost to a newer connection; retryable: false
  "PEER_OFFLINE", // routed frame, peer not connected; retryable: true
  "PROTOCOL_VIOLATION", // malformed/unexpected frame incl. non-hello first frame; retryable: false
]);

export const ErrorMessage = z.object({
  type: z.literal("error"),
  code: ErrorCode,
  message: z.string(),
  // The error contract is law (design §3.3): every error states whether the
  // client may retry the same action unchanged. Terminal-vs-retryable
  // classification lives HERE, not in per-client code lists.
  retryable: z.boolean(),
  ref: z.string().optional(), // echoes the rejected streamId
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

export const PongMessage = z.object({
  type: z.literal("pong"),
});

// Relay → Client discriminated union. Used by clients (e.g. the bridge) to
// validate inbound relay-control messages before dispatching.
export const ServerMessage = z.discriminatedUnion("type", [
  WelcomeMessage,
  StreamOpenedMessage,
  StreamClosedMessage,
  ErrorMessage,
  PeerOnlineMessage,
  PeerOfflineMessage,
  PushResultMessage,
  PongMessage,
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
export type PingMessage = z.infer<typeof PingMessage>;
export type RouteHeader = z.infer<typeof RouteHeader>;
export type RouteHeaderOutbound = z.infer<typeof RouteHeaderOutbound>;
export type ClientMessage = z.infer<typeof ClientMessage>;
export type WelcomeMessage = z.infer<typeof WelcomeMessage>;
export type StreamOpenedMessage = z.infer<typeof StreamOpenedMessage>;
export type StreamClosedMessage = z.infer<typeof StreamClosedMessage>;
export type ErrorMessage = z.infer<typeof ErrorMessage>;
export type ErrorCode = z.infer<typeof ErrorCode>;
export type PeerOfflineMessage = z.infer<typeof PeerOfflineMessage>;
export type PeerOnlineMessage = z.infer<typeof PeerOnlineMessage>;
export type PongMessage = z.infer<typeof PongMessage>;
export type ServerMessage = z.infer<typeof ServerMessage>;
