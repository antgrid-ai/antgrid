import { describe, expect, test } from "bun:test";
import { parseCidr, parseIp, resolveClientIp, type Cidr } from "../src/client-ip";

function cidrs(...specs: string[]): Cidr[] {
  return specs.map(parseCidr);
}

describe("parseIp", () => {
  test("parses IPv4", () => {
    expect(parseIp("192.168.31.3")).toEqual(new Uint8Array([192, 168, 31, 3]));
  });

  test("rejects malformed IPv4", () => {
    expect(parseIp("192.168.31")).toBeNull();
    expect(parseIp("192.168.31.256")).toBeNull();
    expect(parseIp("192.168.31.3.4")).toBeNull();
    expect(parseIp("a.b.c.d")).toBeNull();
    expect(parseIp("")).toBeNull();
  });

  test("parses full and compressed IPv6", () => {
    expect(parseIp("2001:db8::1")).toEqual(
      new Uint8Array([0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]),
    );
    expect(parseIp("::1")).toEqual(new Uint8Array([...Array(15).fill(0), 1]));
    expect(parseIp("2001:0db8:0000:0000:0000:0000:0000:0001")).toEqual(parseIp("2001:db8::1"));
  });

  test("normalizes IPv4-mapped IPv6 to IPv4 bytes", () => {
    // Bun reports IPv4 peers as ::ffff:a.b.c.d on a dual-stack listener; the
    // normalized form must compare equal to the plain IPv4 literal.
    expect(parseIp("::ffff:172.18.0.4")).toEqual(parseIp("172.18.0.4"));
    expect(parseIp("::ffff:ac12:4")).toEqual(parseIp("172.18.0.4"));
  });

  test("rejects malformed IPv6", () => {
    expect(parseIp("2001:db8::1::2")).toBeNull();
    expect(parseIp("1:2:3:4:5:6:7:8:9")).toBeNull();
    expect(parseIp("1:2:3:4:5:6:7")).toBeNull();
    expect(parseIp("2001:zzzz::1")).toBeNull();
    // IPv4 tail only valid as the final group of the whole address
    expect(parseIp("1.2.3.4::1")).toBeNull();
    expect(parseIp("::1.2.3.4:1")).toBeNull();
  });

  test("strips zone ids", () => {
    expect(parseIp("fe80::1%eth0")).toEqual(parseIp("fe80::1"));
  });
});

describe("parseCidr", () => {
  test("bare IP gets a full-length prefix", () => {
    expect(parseCidr("10.0.0.1").prefixBits).toBe(32);
    expect(parseCidr("::1").prefixBits).toBe(128);
  });

  test("throws on malformed input", () => {
    expect(() => parseCidr("not-an-ip")).toThrow(/not an IP/);
    expect(() => parseCidr("10.0.0.0/33")).toThrow(/prefix/);
    expect(() => parseCidr("10.0.0.0/x")).toThrow(/prefix/);
  });
});

describe("resolveClientIp", () => {
  const trusted = cidrs("172.18.0.0/16");

  test("no trusted proxies configured — XFF ignored", () => {
    expect(resolveClientIp("172.18.0.4", "1.2.3.4", [])).toBe("172.18.0.4");
  });

  test("peer not a trusted proxy — XFF ignored (spoof guard)", () => {
    expect(resolveClientIp("9.9.9.9", "1.2.3.4", trusted)).toBe("9.9.9.9");
  });

  test("trusted peer, no XFF header — falls back to peer", () => {
    expect(resolveClientIp("172.18.0.4", null, trusted)).toBe("172.18.0.4");
  });

  test("trusted peer takes the rightmost untrusted XFF hop", () => {
    expect(resolveClientIp("172.18.0.4", "203.0.113.7", trusted)).toBe("203.0.113.7");
    // Client-supplied fake entry on the left must NOT win.
    expect(resolveClientIp("172.18.0.4", "6.6.6.6, 203.0.113.7", trusted)).toBe("203.0.113.7");
  });

  test("walks past chained trusted proxies", () => {
    expect(resolveClientIp("172.18.0.4", "203.0.113.7, 172.18.0.9", trusted)).toBe("203.0.113.7");
  });

  test("all hops trusted — leftmost stands", () => {
    expect(resolveClientIp("172.18.0.4", "172.18.0.9", trusted)).toBe("172.18.0.9");
  });

  test("malformed hop aborts the walk back to the peer", () => {
    expect(resolveClientIp("172.18.0.4", "203.0.113.7, garbage", trusted)).toBe("172.18.0.4");
    expect(resolveClientIp("172.18.0.4", "", trusted)).toBe("172.18.0.4");
  });

  test("IPv4-mapped peer matches an IPv4 CIDR", () => {
    // The incident logs showed peers as ::ffff:172.18.0.4 — the mapped form
    // must be recognized as the trusted docker-network proxy.
    expect(resolveClientIp("::ffff:172.18.0.4", "203.0.113.7", trusted)).toBe("203.0.113.7");
  });

  test("prefix boundary is exact", () => {
    const t = cidrs("10.0.0.0/9");
    expect(resolveClientIp("10.127.0.1", "203.0.113.7", t)).toBe("203.0.113.7");
    expect(resolveClientIp("10.128.0.1", "203.0.113.7", t)).toBe("10.128.0.1");
  });
});
