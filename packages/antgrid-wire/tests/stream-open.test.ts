import { describe, expect, test } from "bun:test";
import {
  MAX_TRANSFER_BYTES,
  PEER_MAX_BRIDGE_RECORD_BYTES,
  PEER_MAX_RECORD_BYTES,
  ProjectStreamOpen,
  STREAM_MAX_BIDI_STREAMS_PER_CONNECTION,
  STREAM_MAX_PENDING_OPENS_PER_PEER,
  STREAM_MAX_PROJECTS_PER_PEER,
  STREAM_MAX_TERMINAL_ATTACHMENTS_PER_PEER,
  STREAM_MAX_TUNNEL_STREAMS_PER_PEER,
  STREAM_MAX_UPLOAD_STREAMS_PER_PEER,
  STREAM_OPEN_MAX_BYTES,
  STREAM_OPEN_MAX_ID_LENGTH,
  STREAM_PROJECT_APP_RECORD_MAX_BYTES,
  STREAM_PROJECT_BRIDGE_RECORD_MAX_BYTES,
  STREAM_TERMINAL_APP_RECORD_MAX_BYTES,
  STREAM_TERMINAL_BRIDGE_RECORD_MAX_BYTES,
  STREAM_TUNNEL_TCP_RECORD_MAX_BYTES,
  STREAM_UPLOAD_BRIDGE_RECORD_MAX_BYTES,
  STREAM_UPLOAD_MAX_FILE_NAME_LENGTH,
  STREAM_UPLOAD_MAX_MIME_TYPE_LENGTH,
  SessionStreamOpen,
  StreamOpen,
  StreamRefused,
  StreamRefusedCode,
  TerminalStreamOpen,
  TunnelTcpStreamOpen,
  UploadStreamOpen,
  decodeStreamOpen,
  decodeStreamRefused,
  encodeStreamOpen,
  encodeStreamRefused,
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

  test("tunnel-tcp", () => {
    const value = { kind: "tunnel-tcp", projectId: "proj-1", connId: "conn-1" } as const;
    expect(StreamOpen.parse(value)).toEqual(value);
    expect(() => TunnelTcpStreamOpen.parse({ kind: "tunnel-tcp", projectId: "proj-1" })).toThrow();
    // The port rides the head record, where the checkout that authorizes it is named too.
    expect(StreamOpen.safeParse({ ...value, port: 3000 }).success).toBe(false);
  });

  test("the retired per-request tunnel kinds are rejected", () => {
    expect(StreamOpen.safeParse({ kind: "tunnel-http", projectId: "proj-1", requestId: "req-1" }).success).toBe(false);
    expect(StreamOpen.safeParse({ kind: "tunnel-ws", projectId: "proj-1", wsId: "ws-1" }).success).toBe(false);
  });

  test("an unknown kind is rejected, not silently dropped", () => {
    expect(StreamOpen.safeParse({ kind: "request", projectId: "proj-1" }).success).toBe(false);
  });

  test("upload: fileName and size are required, checkoutId and mimeType are optional", () => {
    const bare = { kind: "upload", projectId: "proj-1", requestId: "req-1", fileName: "notes.txt", size: 12 } as const;
    expect(StreamOpen.parse(bare)).toEqual(bare);
    const full = { ...bare, checkoutId: "chk-1", mimeType: "text/plain" };
    expect(StreamOpen.parse(full)).toEqual(full);
    expect(() =>
      UploadStreamOpen.parse({ kind: "upload", projectId: "proj-1", requestId: "req-1", fileName: "a" }),
    ).toThrow(); // size missing
  });
});

describe("UploadStreamOpen: size and length rejections", () => {
  const base = { kind: "upload", projectId: "proj-1", requestId: "req-1", fileName: "a.txt" } as const;

  test("size must be a non-negative integer", () => {
    expect(() => UploadStreamOpen.parse({ ...base, size: -1 })).toThrow();
    expect(() => UploadStreamOpen.parse({ ...base, size: 1.5 })).toThrow();
    expect(() => UploadStreamOpen.parse({ ...base, size: "12" })).toThrow();
    expect(UploadStreamOpen.parse({ ...base, size: 0 }).size).toBe(0);
  });

  test("fileName and mimeType are bounded", () => {
    expect(() => UploadStreamOpen.parse({ ...base, size: 1, fileName: "" })).toThrow();
    expect(
      UploadStreamOpen.parse({ ...base, size: 1, fileName: "a".repeat(STREAM_UPLOAD_MAX_FILE_NAME_LENGTH) }).fileName.length,
    ).toBe(STREAM_UPLOAD_MAX_FILE_NAME_LENGTH);
    expect(() =>
      UploadStreamOpen.parse({ ...base, size: 1, fileName: "a".repeat(STREAM_UPLOAD_MAX_FILE_NAME_LENGTH + 1) }),
    ).toThrow();
    expect(() =>
      UploadStreamOpen.parse({ ...base, size: 1, mimeType: "a".repeat(STREAM_UPLOAD_MAX_MIME_TYPE_LENGTH + 1) }),
    ).toThrow();
  });

  test("an empty checkoutId and an unknown field are rejected", () => {
    expect(() => UploadStreamOpen.parse({ ...base, size: 1, checkoutId: "" })).toThrow();
    expect(() => UploadStreamOpen.parse({ ...base, size: 1, uploadId: "u" })).toThrow();
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
    { kind: "tunnel-tcp", projectId: id, connId: id },
  ];
  for (const sample of samples) {
    expect(StreamOpen.safeParse(sample).success).toBe(true);
    expect(Buffer.byteLength(JSON.stringify(sample), "utf8")).toBeLessThanOrEqual(STREAM_OPEN_MAX_BYTES);
  }
  expect(
    StreamOpen.safeParse({ kind: "project", projectId: "p".repeat(STREAM_OPEN_MAX_ID_LENGTH + 1) }).success,
  ).toBe(false);
});

test("MAX_TRANSFER_BYTES is 33_554_432 and defined in stream-open.ts", () => {
  expect(MAX_TRANSFER_BYTES).toBe(33_554_432);
});

test("a session record carries only its payload: each cap now equals the far side's reader cap exactly", () => {
  expect(PEER_MAX_RECORD_BYTES).toBe(1_500_000);
  expect(PEER_MAX_RECORD_BYTES).toBe(STREAM_PROJECT_APP_RECORD_MAX_BYTES);
  expect(PEER_MAX_BRIDGE_RECORD_BYTES).toBe(MAX_TRANSFER_BYTES);
});

describe("encodeStreamOpen / decodeStreamOpen", () => {
  test("encodeStreamOpen round-trips every kind through decodeStreamOpen", () => {
    const samples: StreamOpen[] = [
      { kind: "session" },
      { kind: "project", projectId: "proj-1" },
      { kind: "terminal", projectId: "proj-1", requestId: "req-1" },
      { kind: "terminal", projectId: "proj-1", checkoutId: "chk-1", requestId: "req-1" },
      { kind: "tunnel-tcp", projectId: "proj-1", connId: "conn-1" },
      { kind: "upload", projectId: "proj-1", requestId: "req-1", fileName: "notes.txt", size: 12 },
      { kind: "upload", projectId: "proj-1", checkoutId: "chk-1", requestId: "req-1", fileName: "notes.txt", mimeType: "text/plain", size: 0 },
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

test("the TCP tunnel's framed prefix is capped at 4096 bytes", () => {
  expect(STREAM_TUNNEL_TCP_RECORD_MAX_BYTES).toBe(4096);
});

test("project caps are asymmetric: the app's read/send cap is 1_500_000, the bridge's is MAX_TRANSFER_BYTES", () => {
  expect(STREAM_PROJECT_APP_RECORD_MAX_BYTES).toBe(1_500_000);
  expect(STREAM_PROJECT_BRIDGE_RECORD_MAX_BYTES).toBe(MAX_TRANSFER_BYTES);
});

test("stream cap constants hold their accepted values, and stay under the QUIC bidi limit", () => {
  expect(STREAM_MAX_BIDI_STREAMS_PER_CONNECTION).toBe(256);
  expect(STREAM_MAX_PROJECTS_PER_PEER).toBe(32);
  expect(STREAM_MAX_TERMINAL_ATTACHMENTS_PER_PEER).toBe(64);
  expect(STREAM_MAX_TUNNEL_STREAMS_PER_PEER).toBe(128);
  expect(STREAM_MAX_PENDING_OPENS_PER_PEER).toBe(16);
  expect(STREAM_MAX_UPLOAD_STREAMS_PER_PEER).toBe(4);
  // One peer at every application cap at once, plus its session stream, must
  // fit the QUIC limit, or QUIC flow control stalls an open the application
  // should have refused in-band:
  // 32 + 64 + 128 + 4 + 1 (session) = 229 < 256.
  expect(
    1 +
      STREAM_MAX_PROJECTS_PER_PEER +
      STREAM_MAX_TERMINAL_ATTACHMENTS_PER_PEER +
      STREAM_MAX_TUNNEL_STREAMS_PER_PEER +
      STREAM_MAX_UPLOAD_STREAMS_PER_PEER,
  ).toBe(229);
  expect(
    1 +
      STREAM_MAX_PROJECTS_PER_PEER +
      STREAM_MAX_TERMINAL_ATTACHMENTS_PER_PEER +
      STREAM_MAX_TUNNEL_STREAMS_PER_PEER +
      STREAM_MAX_UPLOAD_STREAMS_PER_PEER +
      STREAM_MAX_PENDING_OPENS_PER_PEER,
  ).toBeLessThanOrEqual(STREAM_MAX_BIDI_STREAMS_PER_CONNECTION);
});

test("upload record and length caps hold their fixed values", () => {
  expect(STREAM_UPLOAD_BRIDGE_RECORD_MAX_BYTES).toBe(16_384);
  expect(STREAM_UPLOAD_MAX_FILE_NAME_LENGTH).toBe(255);
  expect(STREAM_UPLOAD_MAX_MIME_TYPE_LENGTH).toBe(127);
});
