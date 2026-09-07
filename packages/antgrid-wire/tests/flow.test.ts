import { describe, it, expect } from "bun:test";
import {
  CHANNEL_WINDOW_BYTES,
  SOCKET_INFLIGHT_BYTES,
  CREDIT_BATCH_BYTES,
  MAX_SEND_QUEUE_BYTES,
  SEAL_OVERHEAD_BYTES,
  WINDOW_RESYNC_CREDITS,
  WINDOW_STALL_WARN_MS,
  MAX_FRAME_PAYLOAD,
  MAX_TRANSFER_BYTES,
  ErrorMessage,
} from "../src/index";

describe("flow-control constants", () => {
  it("leaves the sender at least three quarters of a window between credits", () => {
    expect(CREDIT_BATCH_BYTES * 2).toBeLessThanOrEqual(CHANNEL_WINDOW_BYTES);
  });

  it("holds one maximal sealed fragment, so a lone big frame never deadlocks a channel", () => {
    expect(CHANNEL_WINDOW_BYTES).toBeGreaterThanOrEqual(MAX_FRAME_PAYLOAD + SEAL_OVERHEAD_BYTES);
  });

  it("leaves headroom for control while one channel's window is full", () => {
    expect(SOCKET_INFLIGHT_BYTES).toBeGreaterThan(CHANNEL_WINDOW_BYTES);
  });

  it("queues at least one maximal transfer before dropping messages whole", () => {
    expect(MAX_SEND_QUEUE_BYTES).toBeGreaterThanOrEqual(MAX_TRANSFER_BYTES);
  });

  it("states the AES-GCM seal overhead a sender adds to plaintext length", () => {
    expect(SEAL_OVERHEAD_BYTES).toBe(28);
  });

  it("pins the values the Dart client mirrors by hand", () => {
    expect(CHANNEL_WINDOW_BYTES).toBe(2_097_152);
    expect(SOCKET_INFLIGHT_BYTES).toBe(3_145_728);
    expect(CREDIT_BATCH_BYTES).toBe(524_288);
    expect(WINDOW_RESYNC_CREDITS).toBe(2);
    expect(MAX_SEND_QUEUE_BYTES).toBe(67_108_864);
    expect(WINDOW_STALL_WARN_MS).toBe(5_000);
  });

  it("carries the channel and length a sender un-charges a relay drop from", () => {
    const drop = ErrorMessage.parse({
      type: "error",
      code: "MESSAGE_RATE_LIMITED",
      message: "Message rate limit exceeded",
      retryable: true,
      channel: "preview",
      bytes: 4096,
    });

    expect(drop.channel).toBe("preview");
    expect(drop.bytes).toBe(4096);
  });

  it("parses an error that names no discarded frame", () => {
    const plain = ErrorMessage.parse({
      type: "error",
      code: "AUTH_FAILED",
      message: "bad signature",
      retryable: false,
    });

    expect(plain.channel).toBeUndefined();
    expect(plain.bytes).toBeUndefined();
  });
});
