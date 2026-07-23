import { SignJWT, importPKCS8 } from "jose";
import http2 from "node:http2";

const APNS_HOST_PROD = "https://api.push.apple.com";
const APNS_HOST_SANDBOX = "https://api.sandbox.push.apple.com";
const APNS_SEND_TIMEOUT_MS = 5000;
// APNs provider tokens are valid up to 60 min; re-mint well before to be safe.
const TOKEN_TTL_MS = 50 * 60 * 1000;

export interface ApnsTransport {
  post(deviceToken: string, headers: Record<string, string>, body: string): Promise<{ status: number; body: string }>;
}

/** Mints + caches an APNs ES256 provider JWT from a .p8 auth key. */
export class ApnsProviderToken {
  private cached: { token: string; mintedAtMs: number } | null = null;
  private readonly keyId: string;
  private readonly teamId: string;
  private readonly privateKeyPem: string;

  constructor(opts: { keyId: string; teamId: string; privateKeyPem: string }) {
    this.keyId = opts.keyId;
    this.teamId = opts.teamId;
    this.privateKeyPem = opts.privateKeyPem;
  }

  async get(): Promise<string> {
    if (this.cached && Date.now() - this.cached.mintedAtMs < TOKEN_TTL_MS) return this.cached.token;
    const key = await importPKCS8(this.privateKeyPem, "ES256");
    const now = Math.floor(Date.now() / 1000);
    // APNs provider token: header {alg,kid}, claims {iss=teamId, iat}. No exp.
    const token = await new SignJWT({})
      .setProtectedHeader({ alg: "ES256", kid: this.keyId })
      .setIssuer(this.teamId)
      .setIssuedAt(now)
      .sign(key);
    this.cached = { token, mintedAtMs: Date.now() };
    return token;
  }
}

/** Real HTTP/2 transport. Requires Bun >=1.3.14 (1.3.10 fails APNs sandbox TLS). */
export class Http2ApnsTransport implements ApnsTransport {
  private readonly host: string;
  constructor(opts: { production: boolean; host?: string }) {
    // host override exists only as a test seam (point at a closed port to
    // exercise the session-error path); production callers pass no host.
    this.host = opts.host ?? (opts.production ? APNS_HOST_PROD : APNS_HOST_SANDBOX);
  }
  post(deviceToken: string, headers: Record<string, string>, body: string): Promise<{ status: number; body: string }> {
    return new Promise((resolve, reject) => {
      const client = http2.connect(this.host);
      // Connection/TLS/ALPN-level failures surface on the session, not the
      // request stream. Without this listener an unhandled 'error' becomes an
      // uncaughtException that crashes the whole relay (it's emitted async, so
      // the caller's try/catch and .catch() never see it).
      client.on("error", (e) => { client.close(); reject(e); });
      const req = client.request({ ":method": "POST", ":path": `/3/device/${deviceToken}`, ...headers });
      let status = 0;
      let buf = "";
      req.on("response", (h) => { status = Number(h[":status"]); });
      req.on("data", (c: Buffer) => (buf += c.toString()));
      req.on("end", () => { client.close(); resolve({ status, body: buf }); });
      req.on("error", (e) => { client.close(); reject(e); });
      req.setTimeout(APNS_SEND_TIMEOUT_MS, () => { req.close(); client.close(); reject(new Error("apns timeout")); });
      req.end(body);
    });
  }
}

export class ApnsSender {
  private readonly bundleId: string;
  private readonly providerToken: { get(): Promise<string> };
  private readonly transport: ApnsTransport;

  constructor(opts: { bundleId: string; providerToken: { get(): Promise<string> }; transport: ApnsTransport }) {
    this.bundleId = opts.bundleId;
    this.providerToken = opts.providerToken;
    this.transport = opts.transport;
  }

  async send(deviceToken: string, data: Record<string, string>): Promise<"ok" | "unregistered" | "error"> {
    const jwt = await this.providerToken.get();
    // Content-blind: the relay writes only a generic placeholder. The NSE
    // replaces title/body after decrypting epk/box. mutable-content=1 is what
    // causes iOS to invoke the NSE; without it the placeholder shows as-is.
    const payload = JSON.stringify({
      aps: { alert: { title: "Antgrid", body: "New activity" }, "mutable-content": 1, sound: "default" },
      ...data,
    });
    const headers = {
      authorization: `bearer ${jwt}`,
      "apns-topic": this.bundleId,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    };
    let res: { status: number; body: string };
    try {
      res = await this.transport.post(deviceToken, headers, payload);
    } catch {
      return "error";
    }
    if (res.status === 200) return "ok";
    // Parse defensively: a 410 must still map to "unregistered" via the status
    // check even if its body is empty or not JSON (parse throwing here would
    // wrongly downgrade it to "error" and the dead token would never be pruned).
    let reason: string | undefined;
    try {
      reason = res.body ? JSON.parse(res.body)?.reason : undefined;
    } catch {
      reason = undefined;
    }
    // 410 Unregistered = app uninstalled; 400 BadDeviceToken = token invalid for
    // this environment. Both mean: stop using the token (bridge prunes it).
    if (res.status === 410 || reason === "Unregistered" || reason === "BadDeviceToken") return "unregistered";
    return "error";
  }
}
