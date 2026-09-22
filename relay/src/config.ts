import { parseTrustedProxies, type Cidr } from "antgrid-wire";
import { z } from "zod/v4";

export interface RelayConfig {
  port: number;
  maxConnections: number;
  rateLimitConnPerIp: number;
  /** Per-agent push-delivery budget for third-party provider fan-out. */
  pushRateLimitPerSec: number;
  /** Sustained refill rate (msg/s) of the per-connection JSON-control bucket. */
  jsonRateLimitPerSec: number;
  /** Burst capacity of the per-connection JSON-control bucket. */
  jsonRateLimitBurst: number;
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

const positiveInt = (fallback: string) => z.string()
  .regex(/^[0-9]+$/, "must be a positive integer")
  .default(fallback)
  .transform(Number)
  .pipe(z.number().int().positive());

const optionalText = z.string().min(1).optional();
const RelayEnvironment = z.object({
  PORT: positiveInt("8080").pipe(z.number().max(65535)),
  MAX_CONNECTIONS: positiveInt("10000"),
  RATE_LIMIT_CONN_PER_IP: positiveInt("10"),
  RATE_LIMIT_PUSH_PER_SEC: positiveInt("100"),
  JSON_RATE_LIMIT_PER_SEC: positiveInt("10"),
  JSON_RATE_LIMIT_BURST: positiveInt("30"),
  CLOCK_SKEW_MS: positiveInt("120000"),
  REPLAY_TTL_MS: positiveInt("300000"),
  PING_INTERVAL_MS: positiveInt("30000"),
  PONG_TIMEOUT_MS: positiveInt("10000"),
  TRUSTED_PROXY_IPS: z.string().optional().transform((value, ctx) => {
    try {
      return parseTrustedProxies(value);
    } catch (error) {
      ctx.addIssue({ code: "custom", message: `invalid trusted proxy list: ${String(error)}` });
      return z.NEVER;
    }
  }),
  LOG_LEVEL: z.enum(["debug", "info", "warn", "error"]).default("info"),
  LICENSE_API_URL: z.url(),
  LICENSE_API_JWKS_PATH: optionalText,
  LICENSE_ISSUER_URL: z.url().optional(),
  RELAY_INTERNAL_SECRET: z.string().min(16),
  LICENSE_CACHE_MAX_ENTRIES: positiveInt("100000"),
  FCM_PROJECT_ID: optionalText,
  FCM_CLIENT_EMAIL: z.email().optional(),
  FCM_PRIVATE_KEY: optionalText,
  APNS_KEY_ID: optionalText,
  APNS_TEAM_ID: optionalText,
  APNS_PRIVATE_KEY: optionalText,
  APNS_BUNDLE_ID: optionalText,
  APNS_PRODUCTION: z.enum(["true", "false"]).default("false").transform((value) => value === "true"),
}).superRefine((env, ctx) => {
  if (env.REPLAY_TTL_MS < 2 * env.CLOCK_SKEW_MS) {
    ctx.addIssue({
      code: "custom",
      path: ["REPLAY_TTL_MS"],
      message: "must be at least 2 * CLOCK_SKEW_MS",
    });
  }
  const fcm = [env.FCM_PROJECT_ID, env.FCM_CLIENT_EMAIL, env.FCM_PRIVATE_KEY];
  if (fcm.filter(Boolean).length !== 0 && fcm.filter(Boolean).length !== fcm.length) {
    ctx.addIssue({ code: "custom", path: ["FCM_PROJECT_ID"], message: "FCM credentials must all be set together" });
  }
  if (env.FCM_PRIVATE_KEY && !env.FCM_PRIVATE_KEY.replace(/\\n/g, "\n").includes("-----BEGIN PRIVATE KEY-----")) {
    ctx.addIssue({ code: "custom", path: ["FCM_PRIVATE_KEY"], message: "must be a PKCS#8 private key" });
  }
  const apns = [env.APNS_KEY_ID, env.APNS_TEAM_ID, env.APNS_PRIVATE_KEY, env.APNS_BUNDLE_ID];
  if (apns.filter(Boolean).length !== 0 && apns.filter(Boolean).length !== apns.length) {
    ctx.addIssue({ code: "custom", path: ["APNS_KEY_ID"], message: "APNs credentials must all be set together" });
  }
});

export function loadConfig(): RelayConfig {
  const env = RelayEnvironment.parse(process.env);
  return {
    port: env.PORT,
    maxConnections: env.MAX_CONNECTIONS,
    rateLimitConnPerIp: env.RATE_LIMIT_CONN_PER_IP,
    pushRateLimitPerSec: env.RATE_LIMIT_PUSH_PER_SEC,
    jsonRateLimitPerSec: env.JSON_RATE_LIMIT_PER_SEC,
    jsonRateLimitBurst: env.JSON_RATE_LIMIT_BURST,
    clockSkewMs: env.CLOCK_SKEW_MS,
    replayTtlMs: env.REPLAY_TTL_MS,
    pingIntervalMs: env.PING_INTERVAL_MS,
    pongTimeoutMs: env.PONG_TIMEOUT_MS,
    trustedProxyIps: env.TRUSTED_PROXY_IPS,
    logLevel: env.LOG_LEVEL,
    licenseApiUrl: env.LICENSE_API_URL,
    licenseApiJwksPath: env.LICENSE_API_JWKS_PATH,
    licenseIssuerUrl: env.LICENSE_ISSUER_URL,
    relayInternalSecret: env.RELAY_INTERNAL_SECRET,
    licenseCacheMaxEntries: env.LICENSE_CACHE_MAX_ENTRIES,
    fcmProjectId: env.FCM_PROJECT_ID,
    fcmClientEmail: env.FCM_CLIENT_EMAIL,
    fcmPrivateKey: env.FCM_PRIVATE_KEY,
    apnsKeyId: env.APNS_KEY_ID,
    apnsTeamId: env.APNS_TEAM_ID,
    apnsPrivateKey: env.APNS_PRIVATE_KEY,
    apnsBundleId: env.APNS_BUNDLE_ID,
    apnsProduction: env.APNS_PRODUCTION,
  };
}
