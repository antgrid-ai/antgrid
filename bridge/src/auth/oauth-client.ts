import { logger } from "../logger.js";
import { decodeAccessTokenClaims, liveTier, type AccessTokenClaims } from "./access-token-claims.js";
const log = logger.child({ component: "oauth-client" });

export interface MintedToken {
  accessToken: string;
  /** Wall-clock epoch ms when the token expires. */
  expiresAt: number;
}

export interface OAuthClientOptions {
  /** Base URL of web, e.g. https://api.antgrid.example.com */
  licenseApiUrl: string;
  clientId: string;
  clientSecret: string;
  /**
   * Called when the web rejects the credentials as `invalid_client` (401, or
   * 400 when the client row is gone) — the device has been revoked or its
   * OAuth client deleted. Caller should terminate the process; emit
   * `{"event":"auth_revoked"}` to stderr first so the App can observe.
   */
  onAuthRevoked?: () => void;
  fetchImpl?: typeof fetch;
  requestTimeoutMs?: number;
}

/** True when an OAuth error body carries `error: "invalid_client"`. Falls back
 *  to a substring match so a non-JSON error page still classifies. */
function isInvalidClient(body: string): boolean {
  try {
    return (JSON.parse(body) as { error?: unknown }).error === "invalid_client";
  } catch {
    return body.includes("invalid_client");
  }
}

/**
 * Thin OAuth `client_credentials` minter. No persistence — caller holds the
 * returned [MintedToken] in memory and pushes its `accessToken` into
 * RelayClient's `getLicenseToken` callback.
 *
 * The `resource` parameter is required: Better-Auth's oauth-provider only
 * emits a JWT (vs opaque token) when `resource` matches the auth base URL.
 */
export class OAuthClient {
  private readonly tokenUrl: string;
  private readonly resource: string;
  private readonly basic: string;
  private readonly onAuthRevoked?: () => void;
  private readonly fetchImpl: typeof fetch;
  private readonly requestTimeoutMs: number;

  constructor(opts: OAuthClientOptions) {
    const base = opts.licenseApiUrl.replace(/\/+$/, "");
    this.tokenUrl = `${base}/api/auth/oauth2/token`;
    this.resource = `${base}/api/auth`;
    this.basic = `Basic ${Buffer.from(`${opts.clientId}:${opts.clientSecret}`).toString("base64")}`;
    this.onAuthRevoked = opts.onAuthRevoked;
    this.fetchImpl = opts.fetchImpl ?? fetch;
    this.requestTimeoutMs = opts.requestTimeoutMs ?? 15_000;
  }

  async mint(): Promise<MintedToken> {
    const body = new URLSearchParams({
      grant_type: "client_credentials",
      scope: "agent",
      resource: this.resource,
    });
    const abort = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;
    // Include body consumption in the deadline; headers alone do not retire
    // a stalled request. Parse and apply authorization only after the race.
    const response = (async () => {
      const res = await this.fetchImpl(this.tokenUrl, {
        method: "POST",
        headers: {
          authorization: this.basic,
          "content-type": "application/x-www-form-urlencoded",
        },
        body: body.toString(),
        signal: abort.signal,
      });
      const text = await res.text().catch((error) => {
        if (res.ok) throw error;
        return "";
      });
      return { res, text };
    })();
    const deadline = new Promise<never>((_, reject) => {
      timer = setTimeout(() => {
        const error = new Error("oauth: token request timed out");
        reject(error);
        abort.abort(error);
      }, this.requestTimeoutMs);
    });
    const { res, text } = await Promise.race([response, deadline])
      .finally(() => clearTimeout(timer));
    if (!res.ok) {
      // Better-Auth answers an unknown/deleted OAuth client with 400
      // `invalid_client` ("missing client"), NOT 401 — signing out rotates the
      // account device and drops its client row, so cached credentials die the
      // same way a revoke kills them. Keying only on 401 left that case falling
      // through to the generic branch, where the host logged a warning and gave
      // up: the machine then never reached the relay and read as permanently
      // offline, with re-authenticating in the app changing nothing.
      if (res.status === 401 || isInvalidClient(text)) {
        this.onAuthRevoked?.();
        throw new Error(`oauth: invalid_client (device revoked or client deleted): ${text.slice(0, 200)}`);
      }
      throw new Error(`oauth: token endpoint returned ${res.status}: ${text.slice(0, 200)}`);
    }
    const json = JSON.parse(text) as { access_token?: string; expires_in?: number };
    if (!json.access_token || typeof json.expires_in !== "number") {
      throw new Error("oauth: malformed token response");
    }
    return {
      accessToken: json.access_token,
      expiresAt: Date.now() + json.expires_in * 1000,
    };
  }
}

/**
 * Maintain an always-fresh access token. Re-mints at 80% of TTL. Returns a
 * synchronous `getToken` suitable for RelayClient's `getLicenseToken`, and a
 * `getTier` reading the server-signed product line off that same token. Caller
 * invokes `stop()` on shutdown to cancel the timer.
 */
export function startTokenMaintenance(
  client: OAuthClient,
  initial: MintedToken,
  opts?: {
    /** Fired after every successful RE-mint (never the caller-supplied initial
     *  token). Lets the machine RelayClient redial after a LICENSE_EXPIRED stop
     *  the instant a renewed subscription's token lands. */
    onMinted?: () => void;
  },
): { getToken: () => string; getTier: () => string | null; stop: () => void } {
  let current = initial;
  let timer: ReturnType<typeof setTimeout> | null = null;
  let stopped = false;
  // The tier lives HERE, derived from `current`, because `current` is the only
  // mutable token holder in the bridge and is assigned in exactly two places
  // (the initial token above, and each re-mint below). A claim read through the
  // getter therefore cannot outlive the token it was signed onto — there is no
  // second store to invalidate and no TTL bookkeeping of its own.
  //
  // Memoized on the token STRING (the thing it describes, so the cache key
  // cannot drift from it), but expiry is re-checked per call: a decoded payload
  // is immutable, its validity is not.
  let decodedFor = "";
  let decoded: AccessTokenClaims | null = null;
  function getTier(): string | null {
    if (current.accessToken !== decodedFor) {
      decodedFor = current.accessToken;
      decoded = decodeAccessTokenClaims(current.accessToken);
    }
    return liveTier(decoded);
  }

  function schedule(): void {
    if (stopped) return;
    const ttlMs = Math.max(60_000, current.expiresAt - Date.now());
    const refreshIn = Math.floor(ttlMs * 0.8);
    timer = setTimeout(refresh, refreshIn);
  }

  async function refresh(): Promise<void> {
    if (stopped) return;
    try {
      const next = await client.mint();
      if (stopped) return;
      current = next;
      opts?.onMinted?.();
      log.info(
        "Refreshed OAuth access token; expires_in=%ds",
        Math.round((current.expiresAt - Date.now()) / 1000),
      );
    } catch (err) {
      log.warn("OAuth re-mint failed: %s — will retry in 30s", err);
      if (!stopped) timer = setTimeout(refresh, 30_000);
      return;
    }
    schedule();
  }
  schedule();

  return {
    getToken: () => current.accessToken,
    getTier,
    stop() {
      stopped = true;
      if (timer) clearTimeout(timer);
    },
  };
}
