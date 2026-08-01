import { inCidr, parseCidr, parseIp } from "antgrid-wire";

type GeoCacheEntry = { country: string | null; expiresAt: number };

const cache = new Map<string, GeoCacheEntry>();
const TTL_MS = 24 * 60 * 60 * 1000;
const MAX_CACHE_KEYS = 10_000;

// Addresses ipinfo.io can never resolve. Matched by CIDR rather than string
// prefix so non-canonical spellings (and the IPv4-mapped form Bun reports for
// v4 peers) land the same way the client-IP resolver already treats them.
const NON_ROUTABLE = [
  "0.0.0.0/8",
  "10.0.0.0/8",
  "100.64.0.0/10", // CGNAT
  "127.0.0.0/8",
  "169.254.0.0/16", // link-local
  "172.16.0.0/12",
  "192.168.0.0/16",
  "::1/128",
  "fc00::/7", // unique-local
  "fe80::/10", // link-local
].map(parseCidr);

/** Unparseable counts as non-routable: there is nothing to look up either way. */
function isPrivateIp(ip: string): boolean {
  const bytes = parseIp(ip);
  if (!bytes) return true;
  return NON_ROUTABLE.some((c) => inCidr(bytes, c));
}

function cacheCountry(ip: string, country: string | null): void {
  if (cache.size >= MAX_CACHE_KEYS) {
    const oldest = cache.keys().next().value;
    if (oldest) cache.delete(oldest);
  }
  cache.set(ip, { country, expiresAt: Date.now() + TTL_MS });
}

export async function detectCountryFromIp(
  ip: string | null,
  token: string | undefined,
  fetchImpl: typeof fetch = fetch
): Promise<string | null> {
  if (!ip || isPrivateIp(ip)) return null;
  if (!token) return null;

  const cached = cache.get(ip);
  if (cached && cached.expiresAt > Date.now()) return cached.country;

  try {
    const res = await fetchImpl(`https://ipinfo.io/${encodeURIComponent(ip)}/country?token=${token}`);
    if (!res.ok) return null;
    const text = (await res.text()).trim();
    const country = text.length === 2 ? text.toUpperCase() : null;
    cacheCountry(ip, country);
    return country;
  } catch {
    return null;
  }
}
