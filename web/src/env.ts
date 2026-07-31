import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { parse as parseDotenv } from "dotenv";
import { parseCidr } from "antgrid-wire";
import { z } from "zod";
import { billingToEnvFields, resolveBillingConfig } from "./config/billing.js";

const EnvSchema = z
  .object({
    NODE_ENV: z
      .enum(["development", "test", "staging", "production"])
      .default("development"),
    PG_DATABASE_URL: z.string().min(1),
    BETTER_AUTH_SECRET: z.string().min(16),
    BETTER_AUTH_URL: z.url().optional(),
    GITHUB_CLIENT_ID: z.string().min(1),
    GITHUB_CLIENT_SECRET: z.string().min(1),
    GOOGLE_CLIENT_ID: z.string().min(1),
    GOOGLE_CLIENT_SECRET: z.string().min(1),
    ZEPTOMAIL_TOKEN: z.string().optional(),
    ZEPTOMAIL_WEBHOOK_SECRET: z.string().min(16).optional(),
    EMAIL_FROM: z.string().default("Antgrid <no-reply@radhaai.org>"),
    RELAY_INTERNAL_URL: z.string().url().optional(),
    RELAY_INTERNAL_SECRET: z.string().min(16).optional(),
    PADDLE_API_KEY: z.string().optional(),
    PADDLE_WEBHOOK_SECRET: z.string().optional(),
    RAZORPAY_KEY_ID: z.string().optional(),
    RAZORPAY_KEY_SECRET: z.string().optional(),
    RAZORPAY_WEBHOOK_SECRET: z.string().optional(),
    IPINFO_TOKEN: z.string().optional(),
    // Dev-only escape hatch: mounts POST /dev/billing/subscription so a
    // subscription can be set without a real payment/webhook. Hard-gated to
    // non-production in app.ts; the enum rejects typos so a bad value fails
    // loud instead of silently flipping the gate.
    DEV_BILLING_ENABLED: z
      .enum(["true", "false"])
      .optional()
      .transform((v) => v === "true"),
    CORS_ORIGINS: z
      .string()
      .transform((s) => s.split(",").map((o) => o.trim()).filter(Boolean)),
    // Extra OAuth `resource` values the token endpoint accepts, beyond the
    // default `${BETTER_AUTH_URL}/api/auth`. Dev-only: lets the app mint
    // license tokens against a LAN-IP base (so an emulator/phone can reach
    // web) while the JWT issuer stays pinned to BETTER_AUTH_URL — relay
    // verification and OAuth callbacks are unaffected. Comma-separated.
    EXTRA_TOKEN_AUDIENCES: z
      .string()
      .optional()
      .transform((s) =>
        s ? s.split(",").map((a) => a.trim()).filter(Boolean) : [],
      ),
    // Reverse proxies whose X-Forwarded-For the server may believe (comma-
    // separated IPs/CIDRs — the antgrid_edge subnet in deploy). Empty means
    // the header is ignored, so a directly exposed server fails safe. Same
    // contract as the relay's TRUSTED_PROXY_IPS; resolution lives in
    // antgrid-wire's client-ip.ts.
    TRUSTED_PROXY_IPS: z
      .string()
      .optional()
      .transform((s, ctx) => {
        const entries = s ? s.split(",").map((e) => e.trim()).filter(Boolean) : [];
        try {
          for (const entry of entries) parseCidr(entry);
        } catch (err) {
          ctx.addIssue({
            code: "custom",
            message: `TRUSTED_PROXY_IPS entry invalid: ${err instanceof Error ? err.message : String(err)}`,
          });
          return z.NEVER;
        }
        return entries;
      }),
    PORT: z.coerce.number().int().default(8787),
  })
  .transform((raw, ctx) => {
    let authUrl = raw.BETTER_AUTH_URL;
    if (!authUrl) {
      if (raw.NODE_ENV === "production" || raw.NODE_ENV === "staging") {
        ctx.addIssue({
          code: "custom",
          path: ["BETTER_AUTH_URL"],
          message: "BETTER_AUTH_URL is required in production and staging",
        });
        return z.NEVER;
      }
      authUrl = `http://localhost:${raw.PORT}`;
    }
    const billing =
      raw.NODE_ENV === "test" ? {} : billingToEnvFields(resolveBillingConfig(raw.NODE_ENV));
    return { ...raw, BETTER_AUTH_URL: authUrl, ...billing };
  });

export type Env = z.output<typeof EnvSchema> & Partial<ReturnType<typeof billingToEnvFields>>;

/**
 * Read `.env` (if present) and overlay it on top of the given source so
 * file-level config wins over ambient process/shell env. Callers can opt
 * out by passing `{ dotenvPath: null }`.
 */
function readDotenv(path: string): Record<string, string> {
  try {
    return parseDotenv(readFileSync(resolve(process.cwd(), path), "utf8"));
  } catch {
    return {};
  }
}

const DEFAULT_SOURCE: Record<string, string | undefined> = process.env;

/** Alternate env names (e.g. Windows user secrets) → canonical schema keys. */
const ENV_ALIASES: Record<string, string> = {
  PaddleApiKey: "PADDLE_API_KEY",
  RazorpayKeyId: "RAZORPAY_KEY_ID",
  RazorpayKeySecret: "RAZORPAY_KEY_SECRET",
  RazorpayWebhookSecret: "RAZORPAY_WEBHOOK_SECRET",
  IPinfoAccessToken: "IPINFO_TOKEN",
};

function applyEnvAliases(source: Record<string, string | undefined>): Record<string, string | undefined> {
  const out = { ...source };
  for (const [alias, canonical] of Object.entries(ENV_ALIASES)) {
    if (out[alias] && !out[canonical]) {
      out[canonical] = out[alias];
    }
  }
  return out;
}

export function loadEnv(
  source: Record<string, string | undefined> = DEFAULT_SOURCE,
  opts: { dotenvPath?: string | null } = {}
): Env {
  // Only overlay `.env` when reading the ambient process env — tests pass
  // explicit sources and should not be affected by a local `.env`.
  const useDotenv = source === DEFAULT_SOURCE;
  const dotenvPath = opts.dotenvPath === undefined ? ".env" : opts.dotenvPath;
  const overlay = useDotenv && dotenvPath ? readDotenv(dotenvPath) : {};
  // `.env` wins over the ambient process env — intentional so developers can
  // override what their shell/process happens to have set.
  const merged = applyEnvAliases({ ...source, ...overlay });

  // Treat empty strings as missing so `.optional()` fields with `.min(N)` or
  // `.url()` constraints don't fail on blank .env entries.
  const normalized: Record<string, string | undefined> = {};
  for (const [k, v] of Object.entries(merged)) {
    normalized[k] = v === "" ? undefined : v;
  }
  const parsed = EnvSchema.safeParse(normalized);
  if (!parsed.success) {
    const msg = parsed.error.issues
      .map((i) => `${i.path.join(".")}: ${i.message}`)
      .join("; ");
    throw new Error(`Invalid env: ${msg}`);
  }
  return parsed.data;
}
