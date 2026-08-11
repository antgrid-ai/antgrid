import { parseTrustedProxies, type Cidr } from "antgrid-wire";

export interface RelayConfig {
  port: number;
  maxConnections: number;
  rateLimitConnPerIp: number;
  rateLimitMsgPerSec: number;
  /** Sustained refill rate (msg/s) of the per-connection JSON-control bucket. */
  jsonRateLimitPerSec: number;
  /** Burst capacity of the per-connection JSON-control bucket. */
  jsonRateLimitBurst: number;
  /**
   * Structural ceiling on ONE connection's `openStreams`, not a metered quota —
   * the paid axis is the worker cap web enforces at registration. Real machines
   * hold single digits (a project each), so this sits orders of magnitude above
   * legitimate use and exists solely so an agent cannot grow the set until the
   * relay runs out of memory. Raise it freely; it is not a product limit.
   */
  maxStreamsPerConnection: number;
  /** ± window a hello `ts` may deviate from server time (step 2). */
  clockSkewMs: number;
  /** How long a `(deviceId, nonce)` hello pair is remembered (replay guard). */
  replayTtlMs: number;
  pingIntervalMs: number;
  pongTimeoutMs: number;
  /**
   * IPs/CIDRs of reverse proxies the relay sits behind (comma-separated env).
   * When the direct peer is one of these, the client IP is recovered from
   * `X-Forwarded-For` (see client-ip.ts) — otherwise the per-IP connection
   * limit collapses into one bucket shared by every client behind the proxy.
   * Empty (the default) disables XFF entirely: a directly exposed relay must
   * never honour a client-forgeable header.
   */
  trustedProxyIps: Cidr[];
  logLevel: "debug" | "info" | "warn" | "error";
  /** Base URL the relay fetches JWKS from — may be an internal address (e.g.
   *  docker-internal DNS) for network efficiency; NOT necessarily the token
   *  issuer. See `licenseIssuerUrl`. */
  licenseApiUrl: string;
  licenseApiJwksPath?: string;
  /**
   * Base URL the relay expects device tokens' `iss` claim to match — Better-Auth
   * stamps `iss` from `BETTER_AUTH_URL` (web's PUBLIC origin), which can differ
   * from `licenseApiUrl` when the latter points at an internal address. Falls
   * back to `licenseApiUrl` when unset, so single-host deployments (local dev)
   * need no extra config.
   */
  licenseIssuerUrl?: string;
  relayInternalSecret: string;
  licenseCacheMaxEntries: number;
  // Push (FCM) is optional — all three set together enables push:deliver
  // forwarding; all three unset disables it (relay replies "unconfigured"). A
  // partial or malformed triple fails fast at load (see loadFcmConfig).
  fcmProjectId?: string;
  fcmClientEmail?: string;
  fcmPrivateKey?: string;
  // Push (APNs, iOS direct) is optional — all four (key id, team id, private key,
  // bundle id) must be set together to enable direct-APNs forwarding; if any is
  // missing the relay replies "unconfigured" for provider:"apns".
  apnsKeyId?: string;
  apnsTeamId?: string;
  apnsPrivateKey?: string;
  apnsBundleId?: string;
  apnsProduction?: boolean;
}

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value || value.length === 0) {
    throw new Error(`Missing required env var: ${name}`);
  }
  return value;
}

function requireEnvMinLength(name: string, minLength: number): string {
  const value = requireEnv(name);
  if (value.length < minLength) {
    throw new Error(`Env var ${name} must be at least ${minLength} characters`);
  }
  return value;
}

/**
 * Validate the FCM push credentials as a unit at load, so a half-configured or
 * malformed relay fails fast at startup instead of either silently answering
 * every push "unconfigured" (partial config) or throwing deep in `importPKCS8`
 * on the first push under load (garbage private key). Push stays OPTIONAL: all
 * three unset is valid (push disabled). Returns the (possibly undefined) triple.
 */
function loadFcmConfig(): Pick<RelayConfig, "fcmProjectId" | "fcmClientEmail" | "fcmPrivateKey"> {
  const fcmProjectId = process.env.FCM_PROJECT_ID || undefined;
  const fcmClientEmail = process.env.FCM_CLIENT_EMAIL || undefined;
  const fcmPrivateKey = process.env.FCM_PRIVATE_KEY || undefined;

  const present = [fcmProjectId, fcmClientEmail, fcmPrivateKey].filter(Boolean).length;
  if (present === 0) return {}; // push disabled — valid
  if (present !== 3) {
    throw new Error(
      "FCM push is partially configured: FCM_PROJECT_ID, FCM_CLIENT_EMAIL and FCM_PRIVATE_KEY " +
        `must all be set together (or all unset). Got ${present}/3.`,
    );
  }
  // Env stores the PEM with literal "\n"; the same restore server-side does
  // before importing. Fail fast on a value that plainly isn't a PKCS#8 key.
  const pem = fcmPrivateKey!.replace(/\\n/g, "\n");
  if (!pem.includes("-----BEGIN PRIVATE KEY-----")) {
    throw new Error(
      "FCM_PRIVATE_KEY is not a PKCS#8 PEM (missing '-----BEGIN PRIVATE KEY-----' header).",
    );
  }
  return { fcmProjectId, fcmClientEmail, fcmPrivateKey };
}

export function loadConfig(): RelayConfig {
  const clockSkewMs = parseInt(process.env.CLOCK_SKEW_MS || "120000", 10);
  const replayTtlMs = parseInt(process.env.REPLAY_TTL_MS || "300000", 10);
  // A replayable hello is only accepted inside ±clockSkewMs of its signed `ts`,
  // so the replay cache must retain a seen nonce for at least that full window
  // on both sides. If REPLAY_TTL_MS < 2·CLOCK_SKEW_MS a nonce can TTL-expire
  // while its `ts` is still inside the accept window, re-opening plain replay.
  if (replayTtlMs < 2 * clockSkewMs) {
    throw new Error(
      `REPLAY_TTL_MS (${replayTtlMs}) must be >= 2 * CLOCK_SKEW_MS (${2 * clockSkewMs}) ` +
        `or a hello nonce can expire from the replay cache while still inside its accept window`,
    );
  }
  return {
    port: parseInt(process.env.PORT || "8080", 10),
    maxConnections: parseInt(process.env.MAX_CONNECTIONS || "10000", 10),
    rateLimitConnPerIp: parseInt(process.env.RATE_LIMIT_CONN_PER_IP || "10", 10),
    rateLimitMsgPerSec: parseInt(process.env.RATE_LIMIT_MSG_PER_SEC || "100", 10),
    jsonRateLimitPerSec: parseInt(process.env.JSON_RATE_LIMIT_PER_SEC || "10", 10),
    jsonRateLimitBurst: parseInt(process.env.JSON_RATE_LIMIT_BURST || "30", 10),
    maxStreamsPerConnection: parseInt(process.env.MAX_STREAMS_PER_CONNECTION || "1024", 10),
    clockSkewMs,
    replayTtlMs,
    pingIntervalMs: parseInt(process.env.PING_INTERVAL_MS || "30000", 10),
    pongTimeoutMs: parseInt(process.env.PONG_TIMEOUT_MS || "10000", 10),
    trustedProxyIps: parseTrustedProxies(process.env.TRUSTED_PROXY_IPS),
    logLevel: (process.env.LOG_LEVEL as RelayConfig["logLevel"]) || "info",
    licenseApiUrl: requireEnv("LICENSE_API_URL"),
    licenseApiJwksPath: process.env.LICENSE_API_JWKS_PATH || undefined,
    licenseIssuerUrl: process.env.LICENSE_ISSUER_URL || undefined,
    relayInternalSecret: requireEnvMinLength("RELAY_INTERNAL_SECRET", 16),
    licenseCacheMaxEntries: parseInt(process.env.LICENSE_CACHE_MAX_ENTRIES || "100000", 10),
    ...loadFcmConfig(),
    apnsKeyId: process.env.APNS_KEY_ID || undefined,
    apnsTeamId: process.env.APNS_TEAM_ID || undefined,
    apnsPrivateKey: process.env.APNS_PRIVATE_KEY || undefined,
    apnsBundleId: process.env.APNS_BUNDLE_ID || undefined,
    apnsProduction: process.env.APNS_PRODUCTION === "true",
  };
}
