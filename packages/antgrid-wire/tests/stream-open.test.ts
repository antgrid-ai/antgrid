import { describe, expect, test } from "bun:test";
import {
  MAX_TRANSFER_BYTES,
  PEER_MAX_RECORD_BYTES,
  ProjectStreamOpen,
  STREAM_MAX_BIDI_STREAMS_PER_CONNECTION,
  STREAM_MAX_PENDING_OPENS_PER_PEER,
  STREAM_MAX_PROJECTS_PER_PEER,
  STREAM_MAX_TERMINAL_ATTACHMENTS_PER_PEER,
  STREAM_MAX_TUNNEL_STREAMS_PER_PEER,
  STREAM_OPEN_MAX_BYTES,
  STREAM_OPEN_MAX_ID_LENGTH,
  SessionStreamOpen,
  StreamOpen,
  StreamRefused,
  StreamRefusedCode,
  TerminalStreamOpen,
  TunnelHttpStreamOpen,
  TunnelWsStreamOpen,
} from "../src/index";

describe("StreamOpen: every kind round-trips and rejects unknown fields", () => {
  test("session", () => {
    expect(StreamOpen.parse({ kind: "session" })).toEqual({ kind: "session" });
    expect(() => SessionStreamOpen.parse({ kind: "session", extra: 1 })).toThrow();
  });

  test("project carries no checkoutId", () => {
    const value = { kind: "project", projectId: "proj-1" } as const;
    expect(StreamOpen.parse(value)).toEqual(value);
    expect(() =>
      ProjectStreamOpen.parse({ ...value, checkoutId: "main" }),
    ).toThrow();
  });

  test("terminal: checkoutId is optional, requestId is required", () => {
    const bare = { kind: "terminal", projectId: "proj-1", requestId: "req-1" } as const;
    expect(StreamOpen.parse(bare)).toEqual(bare);
    const withCheckout = { ...bare, checkoutId: "chk-1" };
    expect(StreamOpen.parse(withCheckout)).toEqual(withCheckout);
    expect(() =>
      TerminalStreamOpen.parse({ kind: "terminal", projectId: "proj-1" }),
    ).toThrow();
  });

  test("tunnel-http", () => {
    const value = { kind: "tunnel-http", projectId: "proj-1", requestId: "req-1" } as const;
    expect(StreamOpen.parse(value)).toEqual(value);
    expect(() => TunnelHttpStreamOpen.parse({ kind: "tunnel-http", projectId: "proj-1" })).toThrow();
  });

  test("tunnel-ws", () => {
    const value = { kind: "tunnel-ws", projectId: "proj-1", wsId: "ws-1" } as const;
    expect(StreamOpen.parse(value)).toEqual(value);
    expect(() => TunnelWsStreamOpen.parse({ kind: "tunnel-ws", projectId: "proj-1" })).toThrow();
  });

  test("an unknown kind is rejected, not silently dropped", () => {
    expect(StreamOpen.safeParse({ kind: "request", projectId: "proj-1" }).success).toBe(false);
  });
});

describe("stream:refused", () => {
  test("every documented code parses", () => {
    for (const code of StreamRefusedCode.options) {
      expect(StreamRefused.parse({ type: "stream:refused", code, message: "x" }).code).toBe(code);
    }
  });

  test("an undocumented code is rejected", () => {
    expect(
      StreamRefused.safeParse({ type: "stream:refused", code: "EXTRA_STREAM", message: "x" }).success,
    ).toBe(false);
  });
});

test("the longest valid open frame, fully JSON-escaped, fits STREAM_OPEN_MAX_BYTES", () => {
  // U+0001 serializes as a six-byte escape, the most any UTF-16 unit costs.
  const id = "\u0001".repeat(STREAM_OPEN_MAX_ID_LENGTH);
  const samples = [
    { kind: "session" },
    { kind: "project", projectId: id },
    { kind: "terminal", projectId: id, checkoutId: id, requestId: id },
    { kind: "tunnel-http", projectId: id, requestId: id },
    { kind: "tunnel-ws", projectId: id, wsId: id },
  ];
  for (const sample of samples) {
    expect(StreamOpen.safeParse(sample).success).toBe(true);
    expect(Buffer.byteLength(JSON.stringify(sample), "utf8")).toBeLessThanOrEqual(STREAM_OPEN_MAX_BYTES);
  }
  expect(
    StreamOpen.safeParse({ kind: "project", projectId: "p".repeat(STREAM_OPEN_MAX_ID_LENGTH + 1) }).success,
  ).toBe(false);
});

test("MAX_TRANSFER_BYTES and PEER_MAX_RECORD_BYTES are the frag.ts / peer-authorization.ts values by name only", () => {
  expect(MAX_TRANSFER_BYTES).toBe(33_554_432);
  expect(PEER_MAX_RECORD_BYTES).toBeGreaterThan(0);
});

test("D7 cap constants hold the adopted owner values (docs/iroh-reduction/ledger.md)", () => {
  expect(STREAM_MAX_BIDI_STREAMS_PER_CONNECTION).toBe(256);
  expect(STREAM_MAX_PROJECTS_PER_PEER).toBe(32);
  expect(STREAM_MAX_TERMINAL_ATTACHMENTS_PER_PEER).toBe(64);
  expect(STREAM_MAX_TUNNEL_STREAMS_PER_PEER).toBe(128);
  expect(STREAM_MAX_PENDING_OPENS_PER_PEER).toBe(16);
  // One peer at every application cap at once, plus its session stream, must
  // fit the QUIC limit, or QUIC flow control stalls an open the application
  // should have refused in-band.
  expect(
    1 +
      STREAM_MAX_PROJECTS_PER_PEER +
      STREAM_MAX_TERMINAL_ATTACHMENTS_PER_PEER +
      STREAM_MAX_TUNNEL_STREAMS_PER_PEER +
      STREAM_MAX_PENDING_OPENS_PER_PEER,
  ).toBeLessThanOrEqual(STREAM_MAX_BIDI_STREAMS_PER_CONNECTION);
});
