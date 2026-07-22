export interface AccountPeersArgs {
  licenseApiUrl: string;
  getToken: () => string;
  fetchFn?: typeof fetch;
}

/** Fetch the caller account's enrolled app-device Ed25519 keys (base64). */
export async function fetchAccountPeerKeys(args: AccountPeersArgs): Promise<Set<string>> {
  const f = args.fetchFn ?? fetch;
  const res = await f(`${args.licenseApiUrl}/account/devices/me/peers`, {
    headers: { authorization: `Bearer ${args.getToken()}` },
  });
  if (!res.ok) throw new Error(`peers fetch failed: ${res.status}`);
  const body = (await res.json()) as { keys: string[] };
  return new Set(body.keys);
}

/**
 * Short-TTL cached wrapper so each pair-request doesn't re-hit web.
 *
 * Single-flight: while a fetch is in progress, concurrent callers share the same
 * in-flight promise instead of each firing their own request (a burst of
 * pair-requests against a cold/expired cache would otherwise stampede web). The
 * result is only committed to the cache on success, so a failed fetch doesn't
 * poison the cache — the next call retries.
 */
export function cachedAccountPeerKeys(
  args: AccountPeersArgs,
  ttlMs = 60_000,
): () => Promise<Set<string>> {
  let cache: { at: number; keys: Set<string> } | null = null;
  let inflight: Promise<Set<string>> | null = null;
  return async () => {
    const now = Date.now();
    if (cache && now - cache.at < ttlMs) return cache.keys;
    if (inflight) return inflight;
    inflight = fetchAccountPeerKeys(args)
      .then((keys) => {
        cache = { at: Date.now(), keys };
        return keys;
      })
      .finally(() => {
        inflight = null;
      });
    return inflight;
  };
}
