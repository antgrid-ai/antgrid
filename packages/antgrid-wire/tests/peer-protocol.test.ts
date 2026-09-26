import { describe, expect, test } from "bun:test";
import {
  SESSION_FRAME_TYPES,
  SessionFrameTypeSchema,
  SessionPingFrame,
  SessionPongFrame,
  SessionTakeoverFrame,
  isSessionFrameType,
} from "../src/index";

describe("isSessionFrameType", () => {
  test("accepts every name in SESSION_FRAME_TYPES", () => {
    for (const type of SESSION_FRAME_TYPES) {
      expect(isSessionFrameType(type)).toBe(true);
      expect(SessionFrameTypeSchema.safeParse(type).success).toBe(true);
    }
  });

  test("rejects old envelope names, an unrelated session-shaped name, and non-strings", () => {
    for (const value of [
      "ping",
      "pong",
      "established",
      "session-takeover",
      "session:list",
      undefined,
      42,
    ]) {
      expect(isSessionFrameType(value)).toBe(false);
    }
  });
});

describe("session frame body schemas are non-strict", () => {
  // An extra key on a ping must never cost a pong: these schemas exist only
  // for the vectors generator to validate its samples against, not as a
  // runtime gate on dispatch.
  test("ping/pong/takeover accept an unknown extra field", () => {
    expect(SessionPingFrame.safeParse({ type: "session:ping", extra: 1 }).success).toBe(true);
    expect(SessionPongFrame.safeParse({ type: "session:pong", extra: 1 }).success).toBe(true);
    expect(SessionTakeoverFrame.safeParse({ type: "session:takeover", extra: 1 }).success).toBe(true);
  });

  test("each schema rejects the wrong literal type", () => {
    expect(SessionPingFrame.safeParse({ type: "session:pong" }).success).toBe(false);
    expect(SessionPongFrame.safeParse({ type: "session:ping" }).success).toBe(false);
    expect(SessionTakeoverFrame.safeParse({ type: "session:ping" }).success).toBe(false);
  });
});
