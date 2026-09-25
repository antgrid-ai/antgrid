import { describe, expect, test } from "bun:test";
import {
  MAX_FRAME_PAYLOAD,
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
  STREAM_PROJECT_RECORD_MAX_BYTES,
  STREAM_TERMINAL_APP_RECORD_MAX_BYTES,
  STREAM_TERMINAL_BRIDGE_RECORD_MAX_BYTES,
  STREAM_TUNNEL_DATA_MAX_BYTES,
  STREAM_TUNNEL_RECORD_MAX_BYTES,
  STREAM_TUNNEL_REQUEST_BODY_MAX_BYTES,
  SessionStreamOpen,
  StreamOpen,
  StreamRefused,
  StreamRefusedCode,
  TUNNEL_RECORD_TAG_BODY,
  TUNNEL_RECORD_TAG_BODY_GZIP,
  TUNNEL_RECORD_TAG_WS_BINARY,
  TUNNEL_RECORD_TAG_WS_TEXT,
  TerminalStreamOpen,
  TunnelHttpStreamOpen,
  TunnelWsStreamOpen,
  decodeStreamOpen,
  decodeStreamRefused,
  decodeTunnelRecord,
  encodeStreamOpen,
  encodeStreamRefused,
  encodeTunnelDataRecord,
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

describe("encodeStreamOpen / decodeStreamOpen", () => {
  test("encodeStreamOpen round-trips every kind through decodeStreamOpen", () => {
    const samples: StreamOpen[] = [
      { kind: "session" },
      { kind: "project", projectId: "proj-1" },
      { kind: "terminal", projectId: "proj-1", requestId: "req-1" },
      { kind: "terminal", projectId: "proj-1", checkoutId: "chk-1", requestId: "req-1" },
      { kind: "tunnel-http", projectId: "proj-1", requestId: "req-1" },
      { kind: "tunnel-ws", projectId: "proj-1", wsId: "ws-1" },
    ];
    for (const open of samples) {
      expect(decodeStreamOpen(encodeStreamOpen(open))).toEqual(open);
    }
  });

  test("encodeStreamOpen throws on schema-invalid input", () => {
    expect(() => encodeStreamOpen({ kind: "request", projectId: "p" } as unknown as StreamOpen)).toThrow();
    expect(() => encodeStreamOpen({ kind: "project" } as unknown as StreamOpen)).toThrow();
  });

  test("decodeStreamOpen returns null for oversize, bad UTF-8, bad JSON, unknown kind and extra keys", () => {
    expect(decodeStreamOpen(new Uint8Array(STREAM_OPEN_MAX_BYTES + 1).fill(0x61))).toBeNull();

    expect(decodeStreamOpen(new Uint8Array([0xff, 0xfe, 0xfd]))).toBeNull();
    expect(decodeStreamOpen(new TextEncoder().encode("{not json"))).toBeNull();
    expect(decodeStreamOpen(new TextEncoder().encode(JSON.stringify({ kind: "request", projectId: "p" })))).toBeNull();
    expect(decodeStreamOpen(new TextEncoder().encode(JSON.stringify({ kind: "project", projectId: "p", extra: 1 })))).toBeNull();
  });
});

describe("encodeStreamRefused / decodeStreamRefused", () => {
  test("round-trip every documented code", () => {
    for (const code of StreamRefusedCode.options) {
      const refused = { type: "stream:refused" as const, code, message: "x" };
      expect(decodeStreamRefused(encodeStreamRefused(refused))).toEqual(refused);
    }
  });

  test("decode rejects an unknown code", () => {
    const bytes = new TextEncoder().encode(JSON.stringify({ type: "stream:refused", code: "EXTRA_STREAM", message: "x" }));
    expect(decodeStreamRefused(bytes)).toBeNull();
  });

  test("decode rejects bad UTF-8, bad JSON and a non-map", () => {
    expect(decodeStreamRefused(new Uint8Array([0xff, 0xfe, 0xfd]))).toBeNull();
    expect(decodeStreamRefused(new TextEncoder().encode("{not json"))).toBeNull();
    expect(decodeStreamRefused(new TextEncoder().encode(JSON.stringify(["stream:refused"])))).toBeNull();
  });
});

test("terminal record caps are exported from the package root as 16384 and 2097152", () => {
  expect(STREAM_TERMINAL_APP_RECORD_MAX_BYTES).toBe(16_384);
  expect(STREAM_TERMINAL_BRIDGE_RECORD_MAX_BYTES).toBe(2_097_152);
});

test("tunnel record caps are exported from the package root", () => {
  expect(STREAM_TUNNEL_DATA_MAX_BYTES).toBe(1_048_576);
  expect(STREAM_TUNNEL_RECORD_MAX_BYTES).toBe(STREAM_TUNNEL_DATA_MAX_BYTES + 1);
  expect(STREAM_TUNNEL_REQUEST_BODY_MAX_BYTES).toBe(MAX_TRANSFER_BYTES);
});

describe("encodeTunnelDataRecord / decodeTunnelRecord", () => {
  const tags = [
    TUNNEL_RECORD_TAG_BODY,
    TUNNEL_RECORD_TAG_BODY_GZIP,
    TUNNEL_RECORD_TAG_WS_TEXT,
    TUNNEL_RECORD_TAG_WS_BINARY,
  ] as const;

  test("round-trips every tag, including a zero-length payload", () => {
    for (const tag of tags) {
      for (const payload of [new Uint8Array(0), new Uint8Array([1, 2, 3, 4])]) {
        const record = encodeTunnelDataRecord(tag, payload);
        const decoded = decodeTunnelRecord(record);
        expect(decoded).toEqual({ kind: "data", tag, payload });
      }
    }
  });

  test("a 0x7B-led record decodes as JSON, never as tagged data, even though 0x7B is not a data tag", () => {
    const json = JSON.stringify({ type: "tunnel:http-head", requestId: "r1" });
    const bytes = new TextEncoder().encode(json);
    expect(bytes[0]).toBe(0x7b);
    expect(decodeTunnelRecord(bytes)).toEqual({ kind: "json", text: json });
  });

  test("decodeTunnelRecord returns null for an empty record, an unrecognized tag, and undecodable JSON", () => {
    expect(decodeTunnelRecord(new Uint8Array(0))).toBeNull();
    expect(decodeTunnelRecord(new Uint8Array([0x04]))).toBeNull(); // no tag is assigned to 0x04
    expect(decodeTunnelRecord(new Uint8Array([0x7b, 0xff, 0xfe]))).toBeNull(); // "{" but not valid UTF-8 JSON
  });

  test("encodeTunnelDataRecord throws RangeError on an unknown tag or a payload over the cap", () => {
    expect(() => encodeTunnelDataRecord(0x04 as never, new Uint8Array(0))).toThrow(RangeError);
    expect(() =>
      encodeTunnelDataRecord(TUNNEL_RECORD_TAG_BODY, new Uint8Array(STREAM_TUNNEL_DATA_MAX_BYTES + 1)),
    ).toThrow(RangeError);
    // Exactly at the cap must still succeed.
    expect(() =>
      encodeTunnelDataRecord(TUNNEL_RECORD_TAG_BODY, new Uint8Array(STREAM_TUNNEL_DATA_MAX_BYTES)),
    ).not.toThrow();
  });
});

test("STREAM_PROJECT_RECORD_MAX_BYTES is MAX_FRAME_PAYLOAD by name only (A4)", () => {
  // A project-stream record carries the same bare AbMessage JSON the session
  // path fragmented at this threshold, so the two caps must never drift apart.
  expect(STREAM_PROJECT_RECORD_MAX_BYTES).toBe(MAX_FRAME_PAYLOAD);
  expect(STREAM_PROJECT_RECORD_MAX_BYTES).toBe(1_500_000);
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
