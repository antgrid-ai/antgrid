import { logger } from "../logger.js";

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
   * Called when the web returns 401 `invalid_client` — meaning the
   * device has been revoked or the OAuth client deleted. Caller should
   * terminate the process; emit `{"event":"auth_revoked"}` to stderr first
   * so the App can observe.
   */
  onAuthRevoked?: () => void;
  fetchImpl?: typeof fetch;
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

  constructor(opts: OAuthClientOptions) {
    const base = opts.licenseApiUrl.replace(/\/+$/, "");
    this.tokenUrl = `${base}/api/auth/oauth2/token`;
    this.resource = `${base}/api/auth`;
    this.basic = `Basic ${Buffer.from(`${opts.clientId}:${opts.clientSecret}`).toString("base64")}`;
    this.onAuthRevoked = opts.onAuthRevoked;
    this.fetchImpl = opts.fetchImpl ?? fetch;
  }

  async mint(): Promise<MintedToken> {
    const body = new URLSearchParams({
      grant_type: "client_credentials",
      scope: "agent",
      resource: this.resource,
    });
    const res = await this.fetchImpl(this.tokenUrl, {
      method: "POST",
      headers: {
        authorization: this.basic,
        "content-type": "application/x-www-form-urlencoded",
      },
      body: body.toString(),
    });
    if (res.status === 401) {
      this.onAuthRevoked?.();
      throw new Error("oauth: invalid_client (device revoked)");
    }
    if (!res.ok) {
      const text = await res.text().catch(() => "");
      throw new Error(`oauth: token endpoint returned ${res.status}: ${text.slice(0, 200)}`);
    }
    const json = (await res.json()) as { access_token?: string; expires_in?: number };
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
 * synchronous `getToken` suitable for RelayClient's `getLicenseToken`. Caller
 * invokes `stop()` on shutdown to cancel the timer.
 */
export function startTokenMaintenance(
  client: OAuthClient,
  initial: MintedToken,
): { getToken: () => string; stop: () => void } {
  let current = initial;
  let timer: ReturnType<typeof setTimeout> | null = null;
  let stopped = false;

  function schedule(): void {
    if (stopped) return;
    const ttlMs = Math.max(60_000, current.expiresAt - Date.now());
    const refreshIn = Math.floor(ttlMs * 0.8);
    timer = setTimeout(async () => {
      if (stopped) return;
      try {
        current = await client.mint();
        logger.info(
          "Refreshed OAuth access token; expires_in=%ds",
          Math.round((current.expiresAt - Date.now()) / 1000),
        );
      } catch (err) {
        logger.warn("OAuth re-mint failed: %s — will retry in 30s", err);
        timer = setTimeout(() => {
          if (!stopped) schedule();
        }, 30_000);
        return;
      }
      schedule();
    }, refreshIn);
  }
  schedule();

  return {
    getToken: () => current.accessToken,
    stop() {
      stopped = true;
      if (timer) clearTimeout(timer);
    },
  };
}
