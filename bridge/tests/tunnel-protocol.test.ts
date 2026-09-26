// The tunnel record schemas: what a request/head/end/ws-open/ws-close record
// parses to, and what it defaults or rejects. A record's body rides as binary
// tagged slices on a dedicated QUIC stream, never as a JSON `data` field.
import { describe, expect, it } from "bun:test";
import {
  TUNNEL_BODY_REPLAY_MAX_BYTES,
  TUNNEL_BODY_SLICE_BYTES,
  TUNNEL_CHUNK_FLUSH_MS,
  TunnelHttpHead,
  TunnelHttpRequest,
  TunnelWsClose,
  TunnelWsOpen,
} from "../src/tunnel-protocol";

describe("TunnelHttpRequest", () => {
  const base = {
    type: "tunnel:http-request" as const,
    requestId: "r1",
    port: 3000,
    method: "GET",
    path: "/",
  };

  it("defaults bodyLength to 0 and checkoutId to main", () => {
    expect(TunnelHttpRequest.parse(base)).toEqual({
      ...base,
      bodyLength: 0,
      checkoutId: "main",
    });
  });

  it("accepts an explicit bodyLength and checkoutId", () => {
    expect(TunnelHttpRequest.parse({ ...base, bodyLength: 1024, checkoutId: "wt-1" })).toMatchObject({
      bodyLength: 1024,
      checkoutId: "wt-1",
    });
  });

  it("rejects a negative bodyLength", () => {
    expect(TunnelHttpRequest.safeParse({ ...base, bodyLength: -1 }).success).toBe(false);
  });

  it("strips a legacy body field rather than carrying it through", () => {
    // The record carries no body of its own — it rides as tagged
    // binary slices on the stream. A stale `body` key must not survive parse,
    // or a caller reading it back would believe it round-tripped.
    const parsed = TunnelHttpRequest.parse({ ...base, body: "hi" });
    expect(parsed).not.toHaveProperty("body");
  });

  it("strips a legacy acceptEncodings field: bodies travel raw now, with nothing to negotiate", () => {
    const parsed = TunnelHttpRequest.parse({ ...base, acceptEncodings: ["gzip"] });
    expect(parsed).not.toHaveProperty("acceptEncodings");
  });
});

describe("TunnelHttpHead", () => {
  const base = {
    type: "tunnel:http-head" as const,
    requestId: "r1",
    status: 200,
    headers: { "content-type": "text/plain" },
  };

  it("parses and defaults checkoutId to main", () => {
    expect(TunnelHttpHead.parse(base)).toEqual({ ...base, checkoutId: "main" });
  });

  it("carries setCookies and a non-main checkoutId", () => {
    expect(
      TunnelHttpHead.parse({ ...base, setCookies: ["a=1"], checkoutId: "wt-1" }),
    ).toMatchObject({ setCookies: ["a=1"], checkoutId: "wt-1" });
  });
});

describe("TunnelWsOpen / TunnelWsClose", () => {
  it("TunnelWsOpen defaults checkoutId to main and carries the browser's handshake headers", () => {
    const base = {
      type: "tunnel:ws-open" as const,
      tunnelId: "w1",
      port: 3000,
      path: "/ws",
      headers: { cookie: "session=1" },
    };
    expect(TunnelWsOpen.parse(base)).toEqual({ ...base, checkoutId: "main" });
  });

  it("TunnelWsClose parses with and without a code/reason, defaulting checkoutId", () => {
    expect(TunnelWsClose.parse({ type: "tunnel:ws-close", tunnelId: "w1" })).toEqual({
      type: "tunnel:ws-close",
      tunnelId: "w1",
      checkoutId: "main",
    });
    expect(
      TunnelWsClose.parse({ type: "tunnel:ws-close", tunnelId: "w1", code: 1001, reason: "bye", checkoutId: "wt-1" }),
    ).toMatchObject({ code: 1001, reason: "bye", checkoutId: "wt-1" });
  });
});

describe("wire constants", () => {
  it("TUNNEL_BODY_SLICE_BYTES matches the app's own upload slicing", () => {
    expect(TUNNEL_BODY_SLICE_BYTES).toBe(262_144);
  });

  it("TUNNEL_CHUNK_FLUSH_MS is the flush window measured from the first pending byte", () => {
    expect(TUNNEL_CHUNK_FLUSH_MS).toBe(50);
  });

  it("TUNNEL_BODY_REPLAY_MAX_BYTES bounds a scheme-guess retry's replayed request body", () => {
    expect(TUNNEL_BODY_REPLAY_MAX_BYTES).toBe(262_144);
  });
});
