/**
 * Client-IP resolution behind a reverse proxy. Shared by the relay and web:
 * both key per-IP rate limits (and logs) on the peer address, which behind a
 * proxy is the proxy's address for every client — the limit collapses into
 * one global bucket and the logs lose the caller. When a trusted-proxy set is
 * configured (TRUSTED_PROXY_IPS) and the direct peer is one of those proxies,
 * the client address is recovered from `X-Forwarded-For` instead.
 *
 * XFF is walked right-to-left, skipping trusted hops: the rightmost entries
 * were appended by our own proxies and are the only ones they vouch for;
 * anything further left arrived in the request and is client-forgeable. With
 * no trusted proxies configured the header is ignored entirely — a directly
 * exposed service must never honour a spoofable header.
 *
 * Keep the trust set as narrow as possible (ideally the proxy's own address):
 * any non-proxy HOST inside a trusted range that can reach the service gets
 * its self-supplied XFF honoured, i.e. it picks its own bucket key and log
 * identity. Trusting a whole docker subnet is acceptable only when every
 * container on it is first-party.
 *
 * Hand-rolled rather than node:net's BlockList on purpose: on Bun 1.3.14,
 * BlockList.check() panics the process (native crash, not a throw) when an
 * IPv4 address is checked against a v6-family subnet holding a mapped-IPv4
 * address — a state a legal TRUSTED_PROXY_IPS entry plus a normal IPv4 peer
 * would reach. The byte-level mapped-form normalization here avoids it.
 */

/** A parsed CIDR: address bytes (4 for IPv4, 16 for IPv6) + prefix length. */
export interface Cidr {
  bytes: Uint8Array;
  prefixBits: number;
}

// Leading-zero octets are rejected, not read as decimal: inet_aton-derived
// tooling reads 010 as octal (8), so silently parsing it as 10 would make
// this parser and the operator's other systems disagree about which subnet
// an entry covers.
const IPV4_OCTET = /^(0|[1-9]\d{0,2})$/;
const IPV6_GROUP = /^[0-9a-fA-F]{1,4}$/;

function parseIpv4(s: string): Uint8Array | null {
  const parts = s.split(".");
  if (parts.length !== 4) return null;
  const out = new Uint8Array(4);
  for (let i = 0; i < 4; i++) {
    if (!IPV4_OCTET.test(parts[i])) return null;
    const n = Number(parts[i]);
    if (n > 255) return null;
    out[i] = n;
  }
  return out;
}

function parseIpv6(input: string): Uint8Array | null {
  // Zone ids (fe80::1%eth0) never appear in forwarded headers; strip defensively.
  const zone = input.indexOf("%");
  const s = zone === -1 ? input : input.slice(0, zone);
  const halves = s.split("::");
  if (halves.length > 2) return null;

  const groups = (part: string, v4TailAllowed: boolean): number[] | null => {
    if (part === "") return [];
    const out: number[] = [];
    const gs = part.split(":");
    for (let i = 0; i < gs.length; i++) {
      if (IPV6_GROUP.test(gs[i])) {
        out.push(parseInt(gs[i], 16));
      } else {
        // An embedded IPv4 tail (::ffff:1.2.3.4) is only valid as the final
        // group of the whole address — never in the half before a "::".
        const v4 = parseIpv4(gs[i]);
        if (!v4 || !v4TailAllowed || i !== gs.length - 1) return null;
        out.push((v4[0] << 8) | v4[1], (v4[2] << 8) | v4[3]);
      }
    }
    return out;
  };

  const head = groups(halves[0], halves.length === 1);
  const tail = halves.length === 2 ? groups(halves[1], true) : [];
  if (!head || !tail) return null;
  const total = head.length + tail.length;
  if (halves.length === 2 ? total > 7 : total !== 8) return null;

  const words = [...head, ...Array(8 - total).fill(0), ...tail];
  const out = new Uint8Array(16);
  for (let i = 0; i < 8; i++) {
    out[i * 2] = words[i] >> 8;
    out[i * 2 + 1] = words[i] & 0xff;
  }
  return out;
}

function isMappedV4(bytes: Uint8Array): boolean {
  if (bytes.length !== 16) return false;
  for (let i = 0; i < 10; i++) if (bytes[i] !== 0) return false;
  return bytes[10] === 0xff && bytes[11] === 0xff;
}

/** Raw parse: 4 bytes for IPv4, 16 for IPv6 — mapped forms NOT collapsed. */
function parseIpBytes(input: string): Uint8Array | null {
  const s = input.trim();
  return s.includes(":") ? parseIpv6(s) : parseIpv4(s);
}

/**
 * Parse an IP literal to bytes. IPv4-mapped IPv6 (`::ffff:1.2.3.4` — how Bun
 * reports IPv4 peers on a dual-stack listener) normalizes to the 4-byte IPv4
 * so the same address matches regardless of which form a config or header used.
 */
export function parseIp(input: string): Uint8Array | null {
  const bytes = parseIpBytes(input);
  if (!bytes) return null;
  return isMappedV4(bytes) ? bytes.slice(12) : bytes;
}

/**
 * Canonical text form of a parsed address: dotted quad for IPv4; for IPv6 the
 * RFC 5952 shape — lowercase hex, longest zero run (≥2 groups, leftmost on
 * tie) compressed to `::`. Distinct spellings of one address must map to ONE
 * bucket key, or per-IP limits split across textual variants.
 */
export function formatIp(bytes: Uint8Array): string {
  if (bytes.length === 4) return bytes.join(".");
  const words: number[] = [];
  for (let i = 0; i < 8; i++) words.push((bytes[i * 2] << 8) | bytes[i * 2 + 1]);
  let bestStart = -1;
  let bestLen = 0;
  let runStart = -1;
  for (let i = 0; i <= 8; i++) {
    if (i < 8 && words[i] === 0) {
      if (runStart === -1) runStart = i;
    } else if (runStart !== -1) {
      const len = i - runStart;
      if (len > bestLen) {
        bestLen = len;
        bestStart = runStart;
      }
      runStart = -1;
    }
  }
  const hex = (ws: number[]) => ws.map((w) => w.toString(16)).join(":");
  if (bestLen < 2) return hex(words);
  return `${hex(words.slice(0, bestStart))}::${hex(words.slice(bestStart + bestLen))}`;
}

/** Parse `addr` or `addr/prefix`. Throws on malformed input — config fails fast. */
export function parseCidr(input: string): Cidr {
  const s = input.trim();
  const slash = s.indexOf("/");
  const addr = slash === -1 ? s : s.slice(0, slash);
  let bytes = parseIpBytes(addr);
  if (!bytes) throw new Error(`not an IP address: "${input}"`);
  let prefixBits = bytes.length * 8;
  if (slash !== -1) {
    const prefixStr = s.slice(slash + 1);
    if (!/^\d{1,3}$/.test(prefixStr)) throw new Error(`bad CIDR prefix: "${input}"`);
    prefixBits = Number(prefixStr);
    if (prefixBits > bytes.length * 8) throw new Error(`CIDR prefix exceeds address length: "${input}"`);
  }
  // Mapped-IPv4 CIDRs collapse with their prefix (::ffff:a.b.0.0/112 ≡
  // a.b.0.0/16) so they match the collapsed addresses parseIp produces. A
  // mapped prefix shorter than /96 spans beyond the mapped range and cannot
  // collapse — reject it rather than silently matching nothing.
  if (isMappedV4(bytes)) {
    if (prefixBits < 96) {
      throw new Error(`mapped-IPv4 CIDR needs prefix >= 96 (or use the plain IPv4 form): "${input}"`);
    }
    bytes = bytes.slice(12);
    prefixBits -= 96;
  }
  return { bytes, prefixBits };
}

/**
 * Parse a comma-separated `TRUSTED_PROXY_IPS` value. Empty (or whitespace) is
 * valid and means "no trusted proxies" — the header is then ignored entirely.
 * Both the relay and web load the var through this so the two services cannot
 * drift on syntax, error wording, or the parsed shape they hold at runtime.
 * Throws on a malformed entry — a trust set that quietly loses an entry is
 * worse than a startup failure.
 */
export function parseTrustedProxies(raw: string | undefined): Cidr[] {
  const entries = (raw ?? "").split(",").map((s) => s.trim()).filter((s) => s.length > 0);
  try {
    return entries.map(parseCidr);
  } catch (e) {
    throw new Error(`TRUSTED_PROXY_IPS entry invalid: ${e instanceof Error ? e.message : e}`);
  }
}

/** `a.b.c.d` as the 16 bytes of `::ffff:a.b.c.d`. */
function toMappedV6(ip: Uint8Array): Uint8Array {
  const out = new Uint8Array(16);
  out[10] = 0xff;
  out[11] = 0xff;
  out.set(ip, 12);
  return out;
}

/** Does [ip] (as returned by `parseIp`) fall inside [cidr]? */
export function inCidr(ip: Uint8Array, cidr: Cidr): boolean {
  // An IPv6 range covers the mapped-IPv4 space, so a v4 peer (parseIp collapses
  // mapped form to 4 bytes) must be re-expanded before comparing rather than
  // missing on length. Without this a legal entry like `::/0` validates at
  // config load and then silently matches no IPv4 peer at all — trust quietly
  // does nothing. The reverse (v6 address, v4 range) is a genuine non-match.
  if (ip.length === 4 && cidr.bytes.length === 16) ip = toMappedV6(ip);
  if (ip.length !== cidr.bytes.length) return false;
  const fullBytes = cidr.prefixBits >> 3;
  for (let i = 0; i < fullBytes; i++) {
    if (ip[i] !== cidr.bytes[i]) return false;
  }
  const remBits = cidr.prefixBits & 7;
  if (remBits === 0) return true;
  const mask = 0xff << (8 - remBits);
  return (ip[fullBytes] & mask) === (cidr.bytes[fullBytes] & mask);
}

/**
 * Strip the port decorations some proxies write into XFF hops: IIS/ARR-style
 * `1.2.3.4:5678` and bracketed `[2001:db8::1]:443`. Without this, one such
 * proxy makes every hop unparseable and silently re-collapses all clients
 * into the proxy's bucket — the exact failure this module exists to fix.
 */
function stripHopPort(hop: string): string {
  if (hop.startsWith("[")) {
    const end = hop.indexOf("]");
    return end === -1 ? hop : hop.slice(1, end);
  }
  const colon = hop.indexOf(":");
  // Exactly one colon plus dots = v4:port; real IPv6 always has ≥2 colons.
  if (colon !== -1 && colon === hop.lastIndexOf(":") && hop.includes(".")) {
    return hop.slice(0, colon);
  }
  return hop;
}

/**
 * Why a resolution fell back to the direct peer while a header was present.
 * Both mean per-IP limits have silently re-collapsed into the proxy's single
 * bucket, so both are worth surfacing — `untrusted-peer` is the likelier one
 * in practice (TRUSTED_PROXY_IPS not matching the network the proxy actually
 * sits on), and it is invisible without this.
 */
export interface ClientIpDegradation {
  kind: "untrusted-peer" | "unparseable-hop";
  /** The direct peer for `untrusted-peer`, the offending hop otherwise. */
  detail: string;
}

/** Canonicalize when parseable so one address is one bucket key on every path. */
function canonical(ip: string): string {
  const bytes = parseIp(ip);
  return bytes ? formatIp(bytes) : ip;
}

/**
 * Resolve the client address for a connection whose direct peer is [peerIp].
 *
 * Returns [peerIp] unless trusted proxies are configured AND the peer is one
 * of them; then walks `X-Forwarded-For` right-to-left and returns the first
 * hop not itself a trusted proxy. If every hop is trusted (a proxy originated
 * the request), the leftmost stands. A malformed hop aborts the walk back to
 * the peer — a chain we can't parse is a chain we don't trust.
 *
 * Every return is canonical text (§`formatIp`), including the fallbacks: the
 * same host reaching us directly and through the proxy must not land in two
 * buckets because Bun spelled one `::ffff:a.b.c.d`.
 *
 * [onDegraded] reports a fallback taken while a header WAS present, which is
 * always a misconfiguration worth logging.
 */
export function resolveClientIp(
  peerIp: string,
  xff: string | null,
  trusted: Cidr[],
  onDegraded?: (event: ClientIpDegradation) => void,
): string {
  if (trusted.length === 0 || !xff) return canonical(peerIp);
  const peer = parseIp(peerIp);
  if (!peer || !trusted.some((c) => inCidr(peer, c))) {
    onDegraded?.({ kind: "untrusted-peer", detail: peerIp });
    return canonical(peerIp);
  }
  const hops = xff.split(",").map((h) => h.trim()).filter((h) => h.length > 0);
  // A header that is truthy but holds no usable hop (`,` or all-whitespace) is
  // as much a proxy misconfiguration as an unparseable one, and would otherwise
  // fall through the loop to the peer without a word.
  if (hops.length === 0) {
    onDegraded?.({ kind: "unparseable-hop", detail: xff });
    return formatIp(peer);
  }
  for (let i = hops.length - 1; i >= 0; i--) {
    const ip = parseIp(stripHopPort(hops[i]));
    if (!ip) {
      onDegraded?.({ kind: "unparseable-hop", detail: hops[i] });
      return formatIp(peer);
    }
    // The leftmost hop stands even if it is itself trusted — a proxy of ours
    // originated the request, and there is nothing further left to prefer.
    if (i === 0 || !trusted.some((c) => inCidr(ip, c))) return formatIp(ip);
  }
  return formatIp(peer);
}
