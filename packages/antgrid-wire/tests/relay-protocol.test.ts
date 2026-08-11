import { describe, it, expect } from "bun:test";
import {
  ServerMessage,
  ClientMessage,
  ErrorCode,
  HelloMessage,
  WelcomeMessage,
  StreamOpenMessage,
  StreamCloseMessage,
  StreamOpenedMessage,
  StreamClosedMessage,
  ErrorMessage,
} from "../src/index";

const b64 = (n: number) => Buffer.from(new Uint8Array(n)).toString("base64");

const validHello = {
  type: "hello",
  protocolVersion: 3,
  deviceType: "agent",
  deviceId: "agent-1.proj",
  name: "My Agent",
  publicKey: b64(32),
  epoch: 0,
  licenseToken: "test-license-token",
  ts: "2026-06-08T12:36:33.442Z",
  nonce: b64(24),
  sig: b64(64),
};

describe("HelloMessage", () => {
  it("parses a valid hello", () => {
    expect(HelloMessage.safeParse(validHello).success).toBe(true);
  });

  it("fails when licenseToken is missing", () => {
    const { licenseToken, ...rest } = validHello;
    expect(HelloMessage.safeParse(rest).success).toBe(false);
  });

  it("fails when licenseToken is empty", () => {
    expect(HelloMessage.safeParse({ ...validHello, licenseToken: "" }).success).toBe(false);
  });

  it("fails with protocolVersion 2", () => {
    expect(HelloMessage.safeParse({ ...validHello, protocolVersion: 2 }).success).toBe(false);
  });

  // '#' scopes an app's per-machine relay slot (relay-slot.ts) — see
  // relay-protocol-deviceid.test.ts for the shape that depends on it.
  it("accepts deviceId with '#'", () => {
    expect(HelloMessage.safeParse({ ...validHello, deviceId: "app-1#machine-1" }).success).toBe(true);
  });

  it("fails when deviceId contains a character outside the id charset", () => {
    expect(HelloMessage.safeParse({ ...validHello, deviceId: "agent 1" }).success).toBe(false);
    expect(HelloMessage.safeParse({ ...validHello, deviceId: "agent/1" }).success).toBe(false);
  });

  it("accepts deviceId with '.'", () => {
    expect(HelloMessage.safeParse({ ...validHello, deviceId: "agent-1.proj" }).success).toBe(true);
  });

  it("parses via the ClientMessage union", () => {
    const r = ClientMessage.safeParse(validHello);
    expect(r.success).toBe(true);
    if (r.success) expect(r.data.type).toBe("hello");
  });
});

describe("ErrorMessage", () => {
  it("fails without retryable", () => {
    expect(ErrorMessage.safeParse({ type: "error", code: "AUTH_FAILED", message: "x" }).success).toBe(
      false,
    );
  });

  it("parses with retryable", () => {
    const r = ErrorMessage.safeParse({
      type: "error",
      code: "AUTH_FAILED",
      message: "x",
      retryable: false,
    });
    expect(r.success).toBe(true);
  });

  it("parses with optional ref and serverTime", () => {
    const r = ErrorMessage.safeParse({
      type: "error",
      code: "PEER_OFFLINE",
      message: "peer gone",
      retryable: true,
      ref: "stream-1",
      serverTime: "2026-06-08T12:36:33.442Z",
    });
    expect(r.success).toBe(true);
  });

  it("parses via the ServerMessage union", () => {
    const r = ServerMessage.safeParse({
      type: "error",
      code: "SUPERSEDED",
      message: "newer connection",
      retryable: false,
    });
    expect(r.success).toBe(true);
  });
});

describe("ServerMessage", () => {
  it("parses welcome", () => {
    const r = ServerMessage.safeParse({
      type: "welcome",
      deviceId: "agent-1.proj",
      epoch: 0,
      serverTime: "2026-06-08T12:36:33.442Z",
    });
    expect(r.success).toBe(true);
  });

  it("parses stream-opened", () => {
    expect(ServerMessage.safeParse({ type: "stream-opened", streamId: "0" }).success).toBe(true);
  });

  it("parses stream-closed", () => {
    expect(ServerMessage.safeParse({ type: "stream-closed", streamId: "0" }).success).toBe(true);
  });

  it("rejects an unknown type", () => {
    expect(ServerMessage.safeParse({ type: "totally-unknown" }).success).toBe(false);
  });
});

describe("ClientMessage", () => {
  it("parses stream-open", () => {
    const r = ClientMessage.safeParse({ type: "stream-open", streamId: "0" });
    expect(r.success).toBe(true);
  });

  it("parses stream-close", () => {
    const r = ClientMessage.safeParse({ type: "stream-close", streamId: "0" });
    expect(r.success).toBe(true);
  });

  it("no longer parses a v2 'register' message", () => {
    const r = ClientMessage.safeParse({
      type: "register",
      protocolVersion: 2,
      deviceId: "agent-1",
      deviceType: "agent",
      name: "agent",
      publicKey: b64(32),
    });
    expect(r.success).toBe(false);
  });
});

describe("ErrorCode", () => {
  it("rejects removed v2 codes", () => {
    expect(ErrorCode.safeParse("AGENT_ALREADY_ACTIVE").success).toBe(false);
    expect(ErrorCode.safeParse("ALREADY_REGISTERED").success).toBe(false);
    expect(ErrorCode.safeParse("PARENT_AGENT_DISCONNECTED").success).toBe(false);
    expect(ErrorCode.safeParse("UPGRADE_REQUIRED").success).toBe(false);
    expect(ErrorCode.safeParse("UNEXPECTED_LICENSE").success).toBe(false);
    expect(ErrorCode.safeParse("ALREADY_PAIRED").success).toBe(false);
    expect(ErrorCode.safeParse("NOT_PAIRED").success).toBe(false);
    expect(ErrorCode.safeParse("PAIR_TIMEOUT").success).toBe(false);
  });

  it("accepts new v3 codes", () => {
    expect(ErrorCode.safeParse("SUPERSEDED").success).toBe(true);
    expect(ErrorCode.safeParse("PEER_OFFLINE").success).toBe(true);
    expect(ErrorCode.safeParse("PROTOCOL_VIOLATION").success).toBe(true);
    expect(ErrorCode.safeParse("LICENSE_UNAVAILABLE").success).toBe(true);
  });

  it("keeps codes carried over from v2", () => {
    expect(ErrorCode.safeParse("SESSION_LIMIT_EXCEEDED").success).toBe(true);
    expect(ErrorCode.safeParse("AUTH_FAILED").success).toBe(true);
  });

  // Pair/grant-only codes: EXPIRED and AGENT_OFFLINE were pair-request-only;
  // PAIR_RATE_LIMITED, PAIR_REJECTED and PAIRING_WINDOW_CLOSED are pair-only
  // by name; NOT_AUTHORIZED was emitted only by the grant-routing branch
  // (deleted with grants.ts); PEER_REPLACED was a grant-revoked reason with no
  // other emitter (confirmed via `npm run sym -- PEER_REPLACED`: no bridge/relay
  // usage outside relay-protocol.ts itself).
  it("rejects deleted pair/grant-only codes", () => {
    expect(ErrorCode.safeParse("EXPIRED").success).toBe(false);
    expect(ErrorCode.safeParse("AGENT_OFFLINE").success).toBe(false);
    expect(ErrorCode.safeParse("PAIR_RATE_LIMITED").success).toBe(false);
    expect(ErrorCode.safeParse("PAIR_REJECTED").success).toBe(false);
    expect(ErrorCode.safeParse("PAIRING_WINDOW_CLOSED").success).toBe(false);
    expect(ErrorCode.safeParse("NOT_AUTHORIZED").success).toBe(false);
    expect(ErrorCode.safeParse("PEER_REPLACED").success).toBe(false);
  });
});

// Pins the absence of the pairing/grant rendezvous schemas (design cutover:
// admission is account-derived trust, not a pair-request/pair-approval round
// trip — see the root `CLAUDE.md`, "gated by account membership").
// Each payload below is a FULLY VALID instance of the deleted shape — parsing
// it must fail only because the type itself is gone, not because the payload
// is incomplete (a `{ type }`-only object would fail validation regardless of
// whether the type still exists, proving nothing).
describe("deleted pair/grant message types", () => {
  it("ClientMessage no longer parses pair-request, pair-approval, pair-rejected or grant-revoke", () => {
    const pairRequest = {
      type: "pair-request",
      agentDeviceId: "agent-1.proj",
      phonePubkey: b64(32),
      phoneDeviceId: "phone-1",
      nonce: b64(24),
      requestedAt: "2026-06-08T12:36:33.442Z",
      deadline: Date.now() + 60_000,
      phoneSignature: b64(64),
    };
    const pairApproval = {
      type: "pair-approval",
      pairId: "pair-1",
      phonePubkey: b64(32),
      phoneDeviceId: "phone-1",
      nonce: b64(24),
      expiresAt: "2026-06-08T12:36:33.442Z",
      signature: b64(64),
    };
    const pairRejected = {
      type: "pair-rejected",
      pairId: "pair-1",
      phonePubkey: b64(32),
      reason: "USER_DECLINED",
    };
    const grantRevoke = { type: "grant-revoke", peerDeviceId: "phone-1" };

    for (const payload of [pairRequest, pairApproval, pairRejected, grantRevoke]) {
      expect(ClientMessage.safeParse(payload).success).toBe(false);
    }
  });

  it("ServerMessage no longer parses pair-connected or grant-revoked", () => {
    const pairConnected = {
      type: "pair-connected",
      peerId: "agent-1",
      peerName: "My Agent",
      peerType: "agent",
    };
    const grantRevoked = { type: "grant-revoked", peerDeviceId: "phone-1", reason: "REVOKED" };

    for (const payload of [pairConnected, grantRevoked]) {
      expect(ServerMessage.safeParse(payload).success).toBe(false);
    }
  });

  it("ServerMessage no longer parses a forwarded pair-request either", () => {
    const pairRequest = {
      type: "pair-request",
      agentDeviceId: "agent-1.proj",
      phonePubkey: b64(32),
      phoneDeviceId: "phone-1",
      nonce: b64(24),
      requestedAt: "2026-06-08T12:36:33.442Z",
      deadline: Date.now() + 60_000,
      phoneSignature: b64(64),
    };
    expect(ServerMessage.safeParse(pairRequest).success).toBe(false);
  });
});
