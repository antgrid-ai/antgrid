import { SignJWT, importPKCS8 } from "jose";

const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";
const GOOGLE_TOKEN_URI = "https://oauth2.googleapis.com/token";
const FCM_SEND_TIMEOUT_MS = 5000;

export interface TokenSource {
  getAccessToken(): Promise<string>;
}

/** Mints + caches a Google OAuth access token from a service-account key. */
export class GoogleTokenSource implements TokenSource {
  private cached: { token: string; expEpochMs: number } | null = null;
  private readonly clientEmail: string;
  private readonly privateKeyPem: string;
  private readonly tokenUri: string;
  private readonly fetchImpl: typeof fetch;

  constructor(opts: { clientEmail: string; privateKeyPem: string; tokenUri?: string; fetchImpl?: typeof fetch }) {
    this.clientEmail = opts.clientEmail;
    this.privateKeyPem = opts.privateKeyPem;
    this.tokenUri = opts.tokenUri ?? GOOGLE_TOKEN_URI;
    this.fetchImpl = opts.fetchImpl ?? fetch;
  }

  async getAccessToken(): Promise<string> {
    if (this.cached && Date.now() < this.cached.expEpochMs) return this.cached.token;
    const key = await importPKCS8(this.privateKeyPem, "RS256");
    const now = Math.floor(Date.now() / 1000);
    const assertion = await new SignJWT({ scope: FCM_SCOPE })
      .setProtectedHeader({ alg: "RS256", typ: "JWT" })
      .setIssuer(this.clientEmail)
      .setSubject(this.clientEmail)
      .setAudience(this.tokenUri)
      .setIssuedAt(now)
      .setExpirationTime(now + 3600)
      .sign(key);
    const res = await this.fetchImpl(this.tokenUri, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion,
      }).toString(),
      signal: AbortSignal.timeout(FCM_SEND_TIMEOUT_MS),
    });
    if (!res.ok) throw new Error(`google token endpoint returned ${res.status}`);
    const json = (await res.json()) as { access_token?: string; expires_in?: number };
    if (!json.access_token || typeof json.expires_in !== "number") throw new Error("malformed google token response");
    // Re-mint at 80% of TTL.
    this.cached = { token: json.access_token, expEpochMs: Date.now() + json.expires_in * 800 };
    return json.access_token;
  }
}

export class FcmSender {
  private readonly projectId: string;
  private readonly tokenSource: TokenSource;
  private readonly fetchImpl: typeof fetch;

  constructor(opts: { projectId: string; tokenSource: TokenSource; fetchImpl?: typeof fetch }) {
    this.projectId = opts.projectId;
    this.tokenSource = opts.tokenSource;
    this.fetchImpl = opts.fetchImpl ?? fetch;
  }

  async send(pushToken: string, data: Record<string, string>): Promise<"ok" | "unregistered" | "error"> {
    const accessToken = await this.tokenSource.getAccessToken();
    const res = await this.fetchImpl(
      `https://fcm.googleapis.com/v1/projects/${this.projectId}/messages:send`,
      {
        method: "POST",
        headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
        body: JSON.stringify({ message: { token: pushToken, android: { priority: "high" }, data } }),
        signal: AbortSignal.timeout(FCM_SEND_TIMEOUT_MS),
      },
    );
    if (res.ok) return "ok";
    // FCM v1 signals a permanently invalid/retired token with HTTP 404 or 410
    // Gone (and the UNREGISTERED error status). All three mean the same thing:
    // stop using the token. Map them to "unregistered" so the bridge prunes it
    // (relay-client.ts push:result handler) instead of retrying forever.
    if (res.status === 404 || res.status === 410) return "unregistered";
    const errCode = await res.json().then((j: any) => j?.error?.details?.[0]?.errorCode).catch(() => undefined);
    if (errCode === "UNREGISTERED") return "unregistered";
    return "error";
  }
}
