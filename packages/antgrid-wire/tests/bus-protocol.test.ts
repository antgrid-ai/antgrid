import { describe, it, expect } from "bun:test";
import {
  BUS_BOX_MAX_CHARS,
  BUS_MAX_PLAINTEXT_BYTES,
  BUS_MAX_TTL_MS,
  RELAY_MAX_CONTROL_FRAME_BYTES,
  BusAckedMessage,
  BusAckMessage,
  BusDeliverMessage,
  BusDrainMessage,
  BusReceiptMessage,
  BusRefusalReason,
  BusRefusedMessage,
  BusSendMessage,
  ClientMessage,
  ServerMessage,
} from "../src/index";

const ID = "44444444-4444-4444-8444-444444444444";
const TO = "33333333-3333-4333-8333-333333333333";
const EPK = Buffer.alloc(32, 7).toString("base64");
const SIG = Buffer.alloc(64, 9).toString("base64");
const box = (n: number) => "A".repeat(n);

const send = (over: Record<string, unknown> = {}) => ({
  type: "bus:send",
  id: ID,
  to: TO,
  blob: { epk: EPK, box: box(44) },
  ttlMs: 1000,
  ...over,
});
const deliver = (over: Record<string, unknown> = {}) => ({
  type: "bus:deliver",
  id: ID,
  from: TO,
  blob: { epk: EPK, box: box(44) },
  ...over,
});
const ack = (over: Record<string, unknown> = {}) => ({
  type: "bus:ack",
  id: ID,
  outcome: "applied",
  sig: SIG,
  ...over,
});

describe("bus constants", () => {
  it("derives the box bound from the plaintext bound", () => {
    expect(BUS_BOX_MAX_CHARS).toBe(122_920);
    expect(BUS_MAX_PLAINTEXT_BYTES).toBe(92_160);
    expect(BUS_MAX_TTL_MS).toBe(21_600_000);
    expect(RELAY_MAX_CONTROL_FRAME_BYTES).toBe(131_072);
  });
});

describe("BusSendMessage", () => {
  it("accepts a valid send", () => {
    expect(BusSendMessage.safeParse(send()).success).toBe(true);
  });

  it("bounds ttlMs to 1..BUS_MAX_TTL_MS and whole numbers", () => {
    expect(BusSendMessage.safeParse(send({ ttlMs: 1 })).success).toBe(true);
    expect(BusSendMessage.safeParse(send({ ttlMs: BUS_MAX_TTL_MS })).success).toBe(true);
    expect(BusSendMessage.safeParse(send({ ttlMs: 0 })).success).toBe(false);
    expect(BusSendMessage.safeParse(send({ ttlMs: BUS_MAX_TTL_MS + 1 })).success).toBe(false);
    expect(BusSendMessage.safeParse(send({ ttlMs: 1.5 })).success).toBe(false);
  });

  it("rejects a non-UUID to or id", () => {
    expect(BusSendMessage.safeParse(send({ to: "agent-1" })).success).toBe(false);
    expect(BusSendMessage.safeParse(send({ to: "11111111-1111-4111-8111-111111111111#22222222-2222-4222-8222-222222222222" })).success).toBe(false);
    expect(BusSendMessage.safeParse(send({ id: "not-a-uuid" })).success).toBe(false);
  });

  it("bounds box at 40..BUS_BOX_MAX_CHARS", () => {
    const at = (n: number) => BusSendMessage.safeParse(send({ blob: { epk: EPK, box: box(n) } })).success;
    expect(at(39)).toBe(false);
    expect(at(40)).toBe(true);
    expect(at(BUS_BOX_MAX_CHARS)).toBe(true);
    expect(at(BUS_BOX_MAX_CHARS + 1)).toBe(false);
  });

  it("rejects a malformed epk or box alphabet", () => {
    expect(BusSendMessage.safeParse(send({ blob: { epk: "short", box: box(44) } })).success).toBe(false);
    expect(BusSendMessage.safeParse(send({ blob: { epk: EPK, box: box(43) + "!" } })).success).toBe(false);
  });
});

describe("BusAckMessage", () => {
  it("accepts applied without a code and refused with one", () => {
    expect(BusAckMessage.safeParse(ack()).success).toBe(true);
    expect(BusAckMessage.safeParse(ack({ outcome: "refused", code: "STALE" })).success).toBe(true);
  });

  it("rejects refused without a code and applied with one", () => {
    expect(BusAckMessage.safeParse(ack({ outcome: "refused" })).success).toBe(false);
    expect(BusAckMessage.safeParse(ack({ code: "STALE" })).success).toBe(false);
  });

  it("bounds the code shape", () => {
    const refused = (code: string) => BusAckMessage.safeParse(ack({ outcome: "refused", code })).success;
    expect(refused("A" + "B".repeat(63))).toBe(true);
    expect(refused("A" + "B".repeat(64))).toBe(false);
    expect(refused("lower")).toBe(false);
    expect(refused("1ABC")).toBe(false);
    expect(refused("")).toBe(false);
  });

  it("requires a 64-byte signature", () => {
    expect(BusAckMessage.safeParse(ack({ sig: Buffer.alloc(63, 9).toString("base64") })).success).toBe(false);
    expect(BusAckMessage.safeParse(ack({ sig: Buffer.alloc(65, 9).toString("base64") })).success).toBe(false);
    expect(BusAckMessage.safeParse(ack({ sig: undefined })).success).toBe(false);
  });
});

describe("BusDrainMessage", () => {
  it("accepts the bare frame", () => {
    expect(BusDrainMessage.safeParse({ type: "bus:drain" }).success).toBe(true);
  });
});

describe("server frames", () => {
  it("bus:receipt accepts both states only", () => {
    const r = (state: string) => BusReceiptMessage.safeParse({ type: "bus:receipt", id: ID, to: TO, state }).success;
    expect(r("queued")).toBe(true);
    expect(r("delivered-to-socket")).toBe(true);
    expect(r("delivered")).toBe(false);
  });

  it("bus:deliver requires a UUID from", () => {
    expect(BusDeliverMessage.safeParse(deliver()).success).toBe(true);
    expect(BusDeliverMessage.safeParse(deliver({ from: "nope" })).success).toBe(false);
    expect(
      BusDeliverMessage.safeParse(deliver({ blob: { epk: EPK, box: box(BUS_BOX_MAX_CHARS + 1) } })).success,
    ).toBe(false);
  });

  it("bus:acked mirrors the ack code rule", () => {
    const acked = (over: Record<string, unknown>) =>
      BusAckedMessage.safeParse({ type: "bus:acked", id: ID, to: TO, outcome: "applied", sig: SIG, ...over }).success;
    expect(acked({})).toBe(true);
    expect(acked({ outcome: "refused", code: "STALE" })).toBe(true);
    expect(acked({ outcome: "refused" })).toBe(false);
    expect(acked({ code: "STALE" })).toBe(false);
  });

  it("bus:refused accepts exactly the relay reasons", () => {
    expect([...BusRefusalReason.options].map(String).sort()).toEqual(
      ["expired", "not-agent", "queue-full", "rate-limited", "recipient-outdated", "self"].sort(),
    );
    const refused = (reason: string) =>
      BusRefusedMessage.safeParse({ type: "bus:refused", id: ID, to: TO, reason, retryable: false }).success;
    expect(refused("queue-full")).toBe(true);
    expect(refused("unknown-recipient")).toBe(false);
  });
});

describe("unions", () => {
  it("ClientMessage carries the three client frames", () => {
    expect(ClientMessage.safeParse(send()).success).toBe(true);
    expect(ClientMessage.safeParse(ack()).success).toBe(true);
    expect(ClientMessage.safeParse({ type: "bus:drain" }).success).toBe(true);
    expect(ClientMessage.safeParse(ack({ outcome: "refused" })).success).toBe(false);
  });

  it("ServerMessage carries the four server frames", () => {
    expect(ServerMessage.safeParse(deliver()).success).toBe(true);
    expect(ServerMessage.safeParse({ type: "bus:receipt", id: ID, to: TO, state: "queued" }).success).toBe(true);
    expect(ServerMessage.safeParse({ type: "bus:refused", id: ID, to: TO, reason: "self", retryable: false }).success).toBe(true);
    expect(ServerMessage.safeParse({ type: "bus:acked", id: ID, to: TO, outcome: "applied", sig: SIG }).success).toBe(true);
  });
});

describe("maximal frames fit the control cap", () => {
  const max = { epk: EPK, box: box(BUS_BOX_MAX_CHARS) };
  const budget = RELAY_MAX_CONTROL_FRAME_BYTES - 4096;

  it("bus:send", () => {
    const frame = send({ blob: max, ttlMs: BUS_MAX_TTL_MS });
    expect(BusSendMessage.safeParse(frame).success).toBe(true);
    expect(Buffer.byteLength(JSON.stringify(frame))).toBeLessThanOrEqual(budget);
  });

  it("bus:deliver", () => {
    const frame = deliver({ blob: max });
    expect(BusDeliverMessage.safeParse(frame).success).toBe(true);
    expect(Buffer.byteLength(JSON.stringify(frame))).toBeLessThanOrEqual(budget);
  });
});
