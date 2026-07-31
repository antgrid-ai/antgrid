import { describe, expect, test } from "bun:test";
import { formatIp, parseCidr, parseIp, resolveClientIp, type Cidr, type ClientIpDegradation } from "../src/client-ip";

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

  test("rejects leading-zero octets (octal/decimal ambiguity)", () => {
    // inet_aton-derived tooling reads 010 as octal 8; parsing it as decimal 10
    // would silently trust a different subnet than the operator intended.
    expect(parseIp("010.0.0.1")).toBeNull();
    expect(parseIp("1.2.3.04")).toBeNull();
    expect(parseIp("0.0.0.0")).toEqual(new Uint8Array([0, 0, 0, 0]));
  });
});

describe("formatIp", () => {
  test("IPv4 dotted quad", () => {
    expect(formatIp(parseIp("203.0.113.7")!)).toBe("203.0.113.7");
  });

  test("IPv6 canonical: lowercase, longest zero run compressed", () => {
    expect(formatIp(parseIp("2001:0DB8:0000:0000:0000:0000:0000:0001")!)).toBe("2001:db8::1");
    expect(formatIp(parseIp("::1")!)).toBe("::1");
    expect(formatIp(parseIp("::")!)).toBe("::");
    // Single zero group is NOT compressed (RFC 5952 §4.2.2).
    expect(formatIp(parseIp("2001:db8:0:1:1:1:1:1")!)).toBe("2001:db8:0:1:1:1:1:1");
    // Longest run wins; leftmost on tie.
    expect(formatIp(parseIp("2001:0:0:1:0:0:0:1")!)).toBe("2001:0:0:1::1");
  });

  test("mapped IPv4 round-trips to the dotted quad", () => {
    expect(formatIp(parseIp("::ffff:203.0.113.7")!)).toBe("203.0.113.7");
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

  test("mapped-IPv4 CIDR collapses with its prefix", () => {
    // ::ffff:172.18.0.0/112 ≡ 172.18.0.0/16 — the form an operator copies
    // straight from relay logs must be accepted, not rejected at boot.
    expect(parseCidr("::ffff:172.18.0.0/112")).toEqual(parseCidr("172.18.0.0/16"));
    expect(parseCidr("::ffff:10.0.0.1")).toEqual(parseCidr("10.0.0.1"));
  });

  test("mapped-IPv4 CIDR with prefix < 96 is rejected, not silently unmatched", () => {
    expect(() => parseCidr("::ffff:10.0.0.0/64")).toThrow(/prefix >= 96/);
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
    // Bun reports IPv4 peers as ::ffff:a.b.c.d on a dual-stack listener — the
    // mapped form must match a plain-IPv4 trusted entry.
    expect(resolveClientIp("::ffff:172.18.0.4", "203.0.113.7", trusted)).toBe("203.0.113.7");
  });

  test("prefix boundary is exact", () => {
    const t = cidrs("10.0.0.0/9");
    expect(resolveClientIp("10.127.0.1", "203.0.113.7", t)).toBe("203.0.113.7");
    expect(resolveClientIp("10.128.0.1", "203.0.113.7", t)).toBe("10.128.0.1");
  });

  test("resolved hop is canonicalized — one bucket key per address", () => {
    expect(resolveClientIp("172.18.0.4", "::ffff:203.0.113.7", trusted)).toBe("203.0.113.7");
    expect(resolveClientIp("172.18.0.4", "2001:0DB8:0000::0001", trusted)).toBe("2001:db8::1");
  });

  test("port-suffixed hops are accepted (IIS/ARR-style XFF)", () => {
    expect(resolveClientIp("172.18.0.4", "203.0.113.7:51544", trusted)).toBe("203.0.113.7");
    expect(resolveClientIp("172.18.0.4", "[2001:db8::1]:443", trusted)).toBe("2001:db8::1");
    expect(resolveClientIp("172.18.0.4", "[2001:db8::1]", trusted)).toBe("2001:db8::1");
  });

  test("unparseable hop reports via onDegraded and falls back", () => {
    const seen: ClientIpDegradation[] = [];
    const got = resolveClientIp("172.18.0.4", "203.0.113.7, garbage", trusted, (e) => seen.push(e));
    expect(got).toBe("172.18.0.4");
    expect(seen).toEqual([{ kind: "unparseable-hop", detail: "garbage" }]);
    // No callback when resolution succeeds.
    resolveClientIp("172.18.0.4", "203.0.113.7", trusted, (e) => seen.push(e));
    expect(seen).toHaveLength(1);
  });

  test("an untrusted peer sending XFF reports too — the likelier misconfiguration", () => {
    const seen: ClientIpDegradation[] = [];
    // The subnet-mismatch case: TRUSTED_PROXY_IPS names a network the proxy
    // isn't on, so the header is (correctly) ignored — silently, before this.
    const got = resolveClientIp("192.168.5.5", "203.0.113.7", trusted, (e) => seen.push(e));
    expect(got).toBe("192.168.5.5");
    expect(seen).toEqual([{ kind: "untrusted-peer", detail: "192.168.5.5" }]);

    // No header means nothing was lost — a direct client is not a degradation.
    resolveClientIp("192.168.5.5", null, trusted, (e) => seen.push(e));
    expect(seen).toHaveLength(1);
  });

  test("fallback returns are canonical too, so one host is one bucket key", () => {
    // Bun spells an IPv4 peer in mapped form on a dual-stack listener; the
    // XFF-resolved form of the same host is plain dotted quad. They must agree.
    expect(resolveClientIp("::ffff:203.0.113.7", null, trusted)).toBe("203.0.113.7");
    expect(resolveClientIp("::ffff:203.0.113.7", "garbage", trusted)).toBe("203.0.113.7");
    expect(resolveClientIp("::ffff:192.168.5.5", "203.0.113.7", trusted)).toBe("192.168.5.5");
    expect(resolveClientIp("2001:0db8:0000::1", null, [])).toBe("2001:db8::1");
  });

  test("an IPv6 trusted range covers mapped-IPv4 peers", () => {
    // ::/0 is every address, mapped v4 included — matching on byte length
    // alone would validate at load and then trust nothing.
    expect(resolveClientIp("::ffff:172.18.0.4", "203.0.113.7", [parseCidr("::/0")])).toBe("203.0.113.7");
    expect(resolveClientIp("172.18.0.4", "203.0.113.7", [parseCidr("::/0")])).toBe("203.0.113.7");
    // A v6 peer against a v4 range stays a genuine non-match.
    expect(resolveClientIp("2001:db8::1", "203.0.113.7", [parseCidr("172.18.0.0/16")])).toBe("2001:db8::1");
  });
});
