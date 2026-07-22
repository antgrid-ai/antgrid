import { oauthProvider } from "@better-auth/oauth-provider";
import { jwt } from "better-auth/plugins";
import { provisionProductAccountForUser, activeSubscriptionForUser, resolveEntitlement } from "../models/subscription.js";
import type { DB } from "../db/index.js";
import type { Env } from "../env.js";

/**
 * Standardized agent OAuth flow. Each Antgrid device gets one OAuth client
 * (created server-side via Better-Auth admin API by the app's session-authed
 * `POST /account/devices` call). The agent uses `client_credentials` to mint
 * access tokens that the relay verifies against `/api/auth/jwks`.
 *
 * `customAccessTokenClaims` injects the binding fields the relay reads from
 * the JWT (`uid`, `deviceUuid`, `tier`, `sessionLimit`, `email`, `pk`). The
 * `sessionLimit` claim is the account's concurrent remote-agent cap; the relay
 * enforces it at agent register. The `pk` claim is the
 * agent's Ed25519 pubkey (base64); relay's `gate.ts` compares it against the
 * pubkey presented at WS handshake — this preserves today's pubkey-binding
 * security property without any custom signing infra.
 *
 * For M2M (client_credentials) tokens, `user` in the claims hook is undefined;
 * device owner comes from `metadata.userId`.
 */
export function abOAuthProviderPlugins(deps: { db: DB; env: Env }) {
  // Default accepted audience is `${baseURL}/api/auth` (baseURL =
  // BETTER_AUTH_URL/api/auth). Passing validAudiences REPLACES that default,
  // so the base audience must be re-included alongside any EXTRA_TOKEN_AUDIENCES.
  const baseAudience = `${deps.env.BETTER_AUTH_URL.replace(/\/+$/, "")}/api/auth`;
  return [
    oauthProvider({
      loginPage: "/auth/login",
      consentPage: "/auth/consent",
      allowDynamicClientRegistration: false,
      grantTypes: ["client_credentials"],
      scopes: ["agent"],
      validAudiences: [baseAudience, ...(deps.env.EXTRA_TOKEN_AUDIENCES ?? [])],
      m2mAccessTokenExpiresIn: 3600,
      customAccessTokenClaims: async ({ metadata }) => {
        const meta = (metadata ?? {}) as {
          userId?: string;
          deviceUuid?: string;
          ed25519Pub?: string;
        };
        if (!meta.userId || !meta.deviceUuid || !meta.ed25519Pub) {
          throw new Error("oauth client missing required metadata");
        }
        await provisionProductAccountForUser(deps.db, meta.userId);
        const sub = await activeSubscriptionForUser(deps.db, meta.userId);
        if (!sub) throw new Error("no subscription for user");
        const { tier, sessionLimit } = resolveEntitlement(sub);
        const user = await deps.db.user.findUnique({
          where: { id: meta.userId },
          select: { email: true },
        });
        return {
          uid: meta.userId,
          deviceUuid: meta.deviceUuid,
          tier,
          sessionLimit,
          email: user?.email ?? null,
          pk: meta.ed25519Pub,
        };
      },
    }),
    jwt({
      jwks: { keyPairConfig: { alg: "EdDSA", crv: "Ed25519" } },
      disableSettingJwtHeader: true,
    }),
  ];
}
