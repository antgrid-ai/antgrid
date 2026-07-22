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
  GrantRevokeMessage,
  GrantRevokedMessage,
  ErrorMessage,
  PairRequestMessage,
  PairApprovalMessage,
  PairRejectedMessage,
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

  it("fails when deviceId contains '#'", () => {
    expect(HelloMessage.safeParse({ ...validHello, deviceId: "agent#1" }).success).toBe(false);
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

describe("PairRequestMessage", () => {
  const base = {
    type: "pair-request",
    agentDeviceId: "agent-1.proj",
    phonePubkey: b64(32),
    phoneDeviceId: "phone-1",
    nonce: b64(24),
    requestedAt: "2026-06-08T12:36:33.442Z",
    phoneSignature: b64(64),
  };

  it("fails without deadline", () => {
    expect(PairRequestMessage.safeParse(base).success).toBe(false);
  });

  it("parses with deadline", () => {
    const r = PairRequestMessage.safeParse({ ...base, deadline: Date.now() + 60_000 });
    expect(r.success).toBe(true);
  });

  it("accepts an optional pairId", () => {
    const r = PairRequestMessage.safeParse({
      ...base,
      deadline: Date.now() + 60_000,
      pairId: "pair-1",
    });
    expect(r.success).toBe(true);
  });
});

describe("PairApprovalMessage", () => {
  const base = {
    type: "pair-approval",
    phonePubkey: b64(32),
    phoneDeviceId: "phone-1",
    nonce: b64(24),
    expiresAt: "2026-06-08T12:36:33.442Z",
    signature: b64(64),
  };

  it("fails without pairId", () => {
    expect(PairApprovalMessage.safeParse(base).success).toBe(false);
  });

  it("parses with pairId", () => {
    expect(PairApprovalMessage.safeParse({ ...base, pairId: "pair-1" }).success).toBe(true);
  });
});

describe("PairRejectedMessage", () => {
  const base = {
    type: "pair-rejected",
    phonePubkey: b64(32),
    reason: "USER_DECLINED",
  };

  it("fails without pairId", () => {
    expect(PairRejectedMessage.safeParse(base).success).toBe(false);
  });

  it("parses with pairId", () => {
    expect(PairRejectedMessage.safeParse({ ...base, pairId: "pair-1" }).success).toBe(true);
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

  it("parses grant-revoked", () => {
    const r = ServerMessage.safeParse({
      type: "grant-revoked",
      peerDeviceId: "phone-1",
      reason: "REVOKED",
    });
    expect(r.success).toBe(true);
  });

  it("rejects grant-revoked with an unknown reason", () => {
    const r = ServerMessage.safeParse({
      type: "grant-revoked",
      peerDeviceId: "phone-1",
      reason: "MADE_UP",
    });
    expect(r.success).toBe(false);
  });

  it("accepts a forwarded pair-request", () => {
    const r = ServerMessage.safeParse({
      type: "pair-request",
      agentDeviceId: "agent-1.proj",
      phonePubkey: b64(32),
      phoneDeviceId: "phone-1",
      nonce: b64(24),
      requestedAt: "2026-06-08T12:36:33.442Z",
      deadline: Date.now() + 60_000,
      phoneSignature: b64(64),
    });
    expect(r.success).toBe(true);
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

  it("parses grant-revoke", () => {
    const r = ClientMessage.safeParse({ type: "grant-revoke", peerDeviceId: "phone-1" });
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
    expect(ErrorCode.safeParse("EXPIRED").success).toBe(true);
    expect(ErrorCode.safeParse("NOT_AUTHORIZED").success).toBe(true);
    expect(ErrorCode.safeParse("LICENSE_UNAVAILABLE").success).toBe(true);
  });

  it("keeps codes carried over from v2", () => {
    expect(ErrorCode.safeParse("SESSION_LIMIT_EXCEEDED").success).toBe(true);
    expect(ErrorCode.safeParse("AUTH_FAILED").success).toBe(true);
  });
});
