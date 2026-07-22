import type { JWK } from "jose";
import { logger } from "../logger.js";

const DEFAULT_TTL_MS = 24 * 60 * 60 * 1000;

/**
 * Minimum spacing between kid-miss force-refreshes. Without it, an attacker who
 * self-signs a hello (the hello sig verifies against the attacker's OWN key, so
 * reaching the license gate proves no trusted identity) can put an ever-changing
 * `kid` in the token header and drive one relay→web JWKS fetch per distinct kid.
 * Throttling caps that to one refresh per window across ALL kids, so unknown
 * kids can't be turned into a web-backend amplification vector. Legitimate seed
 * rotation still self-heals within one window.
 */
const DEFAULT_KID_MISS_REFRESH_COOLDOWN_MS = 60 * 1000;

/**
 * The JWKS endpoint could not be reached and there is no cached copy to fall
 * back on, so the token's validity is *unknown* — distinct from a token that
 * verifiably failed. Callers map this to the retryable `LICENSE_UNAVAILABLE`;
 * misreporting it as `LICENSE_INVALID` tells every agent its credential is
 * dead over what is really a web outage.
 */
export class JwksUnavailableError extends Error {
  constructor(cause: unknown) {
    super("jwks_fetch_failed", { cause });
    this.name = "JwksUnavailableError";
  }
}

interface JwksCacheOptions {
  licenseApiUrl: string;
  /** Defaults to "/api/auth/jwks" (Better-Auth's JWKS path). */
  jwksPath?: string;
  ttlMs?: number;
  /** Min spacing between kid-miss force-refreshes; see the constant above. */
  kidMissRefreshCooldownMs?: number;
  fetchImpl?: typeof fetch;
}

interface JwksResponse {
  keys: JWK[];
}

/**
 * Caches the web JWKS for verifying device JWTs.
 *
 * - First call fetches `${licenseApiUrl}/api/auth/jwks` (configurable via `jwksPath`).
 * - Subsequent calls within `ttlMs` return the cached array.
 * - After TTL, refresh is attempted; on failure with a populated cache, the
 *   stale value is returned (stale-while-error).
 * - On initial fetch failure (no cached value), throws `JwksUnavailableError`.
 * - Concurrent calls share a single in-flight fetch (single-flight).
 * - `getKeys({ forKid })` force-refreshes when the requested kid is absent
 *   from the cached set — this is what makes seed-rotation self-healing
 *   without manual relay restarts.
 */
export class JwksCache {
  private readonly url: string;
  private readonly ttlMs: number;
  private readonly kidMissRefreshCooldownMs: number;
  private readonly fetchImpl: typeof fetch;

  private cachedKeys: JWK[] | undefined;
  private cachedAt = 0;
  private pendingFetch: Promise<JWK[]> | undefined;
  private lastKidMissRefreshAt = 0;

  constructor(options: JwksCacheOptions) {
    const base = options.licenseApiUrl.replace(/\/+$/, "");
    const path = (options.jwksPath ?? "/api/auth/jwks").replace(/^\/*/, "/");
    this.url = `${base}${path}`;
    this.ttlMs = options.ttlMs ?? DEFAULT_TTL_MS;
    this.kidMissRefreshCooldownMs =
      options.kidMissRefreshCooldownMs ?? DEFAULT_KID_MISS_REFRESH_COOLDOWN_MS;
    this.fetchImpl = options.fetchImpl ?? fetch;
  }

  async getKeys(opts: { forKid?: string } = {}): Promise<JWK[]> {
    const now = Date.now();
    const fresh =
      this.cachedKeys !== undefined && now - this.cachedAt < this.ttlMs;

    if (fresh && opts.forKid && !(this.cachedKeys as JWK[]).some((k) => k.kid === opts.forKid)) {
      // Throttle kid-miss refreshes so unknown kids can't be amplified into a
      // per-request web fetch. Inside the cooldown, serve the stale cache: the
      // caller won't find the kid and rejects the token as invalid — which is
      // the correct verdict for a kid the signer never published.
      if (now - this.lastKidMissRefreshAt < this.kidMissRefreshCooldownMs) {
        logger.debug("JWKS kid miss within cooldown; serving cached keys", {
          requestedKid: opts.forKid,
        });
        return this.cachedKeys as JWK[];
      }
      this.lastKidMissRefreshAt = now;
      logger.debug("JWKS kid miss; force-refreshing", {
        requestedKid: opts.forKid,
        cachedKids: (this.cachedKeys as JWK[]).map((k) => k.kid),
      });
      try {
        const refreshed = await this.refresh();
        if (!refreshed.some((k) => k.kid === opts.forKid)) {
          logger.warn("JWKS still missing kid after refresh", {
            requestedKid: opts.forKid,
            refreshedKids: refreshed.map((k) => k.kid),
          });
        }
        return refreshed;
      } catch (err) {
        logger.warn("JWKS refresh-on-kid-miss failed; serving stale keys", {
          kid: opts.forKid,
          error: err instanceof Error ? err.message : String(err),
        });
        return this.cachedKeys as JWK[];
      }
    }

    if (fresh) {
      return this.cachedKeys as JWK[];
    }

    try {
      return await this.refresh();
    } catch (err) {
      if (this.cachedKeys !== undefined) {
        logger.warn("JWKS refresh failed; serving stale keys", {
          error: err instanceof Error ? err.message : String(err),
        });
        return this.cachedKeys;
      }
      throw new JwksUnavailableError(err);
    }
  }

  private refresh(): Promise<JWK[]> {
    if (this.pendingFetch) {
      return this.pendingFetch;
    }

    const p = this.doFetch().finally(() => {
      this.pendingFetch = undefined;
    });
    this.pendingFetch = p;
    return p;
  }

  private async doFetch(): Promise<JWK[]> {
    const res = await this.fetchImpl(this.url);
    if (!res.ok) {
      throw new Error(`jwks request failed: ${res.status}`);
    }
    const body = (await res.json()) as JwksResponse;
    if (!body || !Array.isArray(body.keys)) {
      throw new Error("jwks response missing keys array");
    }
    this.cachedKeys = body.keys;
    this.cachedAt = Date.now();
    return body.keys;
  }
}
