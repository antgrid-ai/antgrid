type GeoCacheEntry = { country: string | null; expiresAt: number };

const cache = new Map<string, GeoCacheEntry>();
const TTL_MS = 24 * 60 * 60 * 1000;
const MAX_CACHE_KEYS = 10_000;

export function clientIpFromHeaders(headers: {
  get(name: string): string | null | undefined;
}): string | null {
  const forwarded = headers.get("x-forwarded-for");
  if (forwarded) {
    const first = forwarded.split(",")[0]?.trim();
    if (first) return first;
  }
  const realIp = headers.get("x-real-ip");
  return realIp?.trim() || null;
}

function isPrivateIp(ip: string): boolean {
  if (ip === "::1" || ip === "127.0.0.1") return true;
  if (ip.startsWith("10.") || ip.startsWith("192.168.")) return true;
  if (/^172\.(1[6-9]|2\d|3[01])\./.test(ip)) return true;
  return false;
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
