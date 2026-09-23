import { describe, it, expect } from "bun:test";
import {
  CHANNEL_WINDOW_BYTES,
  SOCKET_INFLIGHT_BYTES,
  CREDIT_BATCH_BYTES,
  MAX_SEND_QUEUE_BYTES,
  WINDOW_RESYNC_AGE_MS,
  WINDOW_STALL_WARN_MS,
  MAX_FRAME_PAYLOAD,
  MAX_TRANSFER_BYTES,
} from "../src/index";

describe("flow-control constants", () => {
  it("leaves the sender at least three quarters of a window between credits", () => {
    expect(CREDIT_BATCH_BYTES * 2).toBeLessThanOrEqual(CHANNEL_WINDOW_BYTES);
  });

  it("holds one maximal fragment, so a lone big frame never deadlocks a channel", () => {
    expect(CHANNEL_WINDOW_BYTES).toBeGreaterThanOrEqual(MAX_FRAME_PAYLOAD);
  });

  it("leaves headroom for control while one channel's window is full", () => {
    expect(SOCKET_INFLIGHT_BYTES).toBeGreaterThan(CHANNEL_WINDOW_BYTES);
  });

  it("queues at least one maximal transfer before dropping messages whole", () => {
    expect(MAX_SEND_QUEUE_BYTES).toBeGreaterThanOrEqual(MAX_TRANSFER_BYTES);
  });

  it("pins the values the Dart client mirrors by hand", () => {
    expect(CHANNEL_WINDOW_BYTES).toBe(2_097_152);
    expect(SOCKET_INFLIGHT_BYTES).toBe(3_145_728);
    expect(CREDIT_BATCH_BYTES).toBe(524_288);
    expect(WINDOW_RESYNC_AGE_MS).toBe(40_000);
    expect(MAX_SEND_QUEUE_BYTES).toBe(67_108_864);
    expect(WINDOW_STALL_WARN_MS).toBe(5_000);
  });
});
