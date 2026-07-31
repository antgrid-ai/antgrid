/**
 * Client-IP resolution behind a reverse proxy.
 *
 * The relay's per-IP connection limit and connection logs key on the peer
 * address, which behind a proxy is the proxy's address for every client —
 * the limit collapses into one global bucket and the logs lose the caller.
 * When TRUSTED_PROXY_IPS is configured and the direct peer is one of those
 * proxies, the client address is recovered from `X-Forwarded-For` instead.
 *
 * XFF is walked right-to-left, skipping trusted hops: the rightmost entries
 * were appended by our own proxies and are the only ones they vouch for;
 * anything further left arrived in the request and is client-forgeable. With
 * no trusted proxies configured the header is ignored entirely — a directly
 * exposed relay must never honour a spoofable header.
 */

/** A parsed CIDR: address bytes (4 for IPv4, 16 for IPv6) + prefix length. */
export interface Cidr {
  bytes: Uint8Array;
  prefixBits: number;
}

function parseIpv4(s: string): Uint8Array | null {
  const parts = s.split(".");
  if (parts.length !== 4) return null;
  const out = new Uint8Array(4);
  for (let i = 0; i < 4; i++) {
    if (!/^\d{1,3}$/.test(parts[i])) return null;
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
      if (/^[0-9a-fA-F]{1,4}$/.test(gs[i])) {
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

/**
 * Parse an IP literal to bytes. IPv4-mapped IPv6 (`::ffff:1.2.3.4` — how Bun
 * reports IPv4 peers on a dual-stack listener) normalizes to the 4-byte IPv4
 * so the same address matches regardless of which form a config or header used.
 */
export function parseIp(input: string): Uint8Array | null {
  const s = input.trim();
  const bytes = s.includes(":") ? parseIpv6(s) : parseIpv4(s);
  if (!bytes) return null;
  if (bytes.length === 16) {
    const mapped = bytes.slice(0, 10).every((b) => b === 0) && bytes[10] === 0xff && bytes[11] === 0xff;
    if (mapped) return bytes.slice(12);
  }
  return bytes;
}

/** Parse `addr` or `addr/prefix`. Throws on malformed input — config fails fast. */
export function parseCidr(input: string): Cidr {
  const s = input.trim();
  const slash = s.indexOf("/");
  const addr = slash === -1 ? s : s.slice(0, slash);
  const bytes = parseIp(addr);
  if (!bytes) throw new Error(`not an IP address: "${input}"`);
  const maxBits = bytes.length * 8;
  if (slash === -1) return { bytes, prefixBits: maxBits };
  const prefixStr = s.slice(slash + 1);
  if (!/^\d{1,3}$/.test(prefixStr)) throw new Error(`bad CIDR prefix: "${input}"`);
  const prefixBits = Number(prefixStr);
  if (prefixBits > maxBits) throw new Error(`CIDR prefix exceeds address length: "${input}"`);
  return { bytes, prefixBits };
}

function inCidr(ip: Uint8Array, cidr: Cidr): boolean {
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

function isTrusted(ipStr: string, trusted: Cidr[]): boolean {
  const ip = parseIp(ipStr);
  if (!ip) return false;
  return trusted.some((c) => inCidr(ip, c));
}

/**
 * Resolve the client address for a connection whose direct peer is [peerIp].
 *
 * Returns [peerIp] unchanged unless trusted proxies are configured AND the
 * peer is one of them; then walks `X-Forwarded-For` right-to-left and returns
 * the first hop not itself a trusted proxy. A malformed hop aborts the walk
 * back to [peerIp] — a chain we can't parse is a chain we don't trust. If
 * every hop is trusted (a proxy originated the request), the leftmost stands.
 */
export function resolveClientIp(peerIp: string, xff: string | null, trusted: Cidr[]): string {
  if (trusted.length === 0 || !isTrusted(peerIp, trusted)) return peerIp;
  if (!xff) return peerIp;
  const hops = xff.split(",").map((h) => h.trim()).filter((h) => h.length > 0);
  for (let i = hops.length - 1; i >= 0; i--) {
    if (!parseIp(hops[i])) return peerIp;
    if (!isTrusted(hops[i], trusted)) return hops[i];
  }
  return hops[0] ?? peerIp;
}
