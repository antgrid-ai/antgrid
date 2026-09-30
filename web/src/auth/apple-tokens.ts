// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { decodeJwt } from "jose";
import { z } from "zod";
import type { Env } from "../env.js";
import { appleClientSecret } from "./apple-client-secret.js";
import { appleSignInConfigured } from "./better-auth.js";

const TOKEN_ENDPOINT = "https://appleid.apple.com/auth/token";
const REVOKE_ENDPOINT = "https://appleid.apple.com/auth/revoke";

/** Both calls sit on a user-facing response path (sign-in completion and
 *  account deletion), so Apple being slow must not become the user's wait. */
const REQUEST_TIMEOUT_MS = 5_000;

const TokenResponse = z.object({
  refresh_token: z.string().min(1),
  id_token: z.string().min(1),
  access_token: z.string().optional(),
  expires_in: z.number().optional(),
});

export type AppleNativeTokens = {
  refreshToken: string;
  idToken: string;
  accessToken?: string;
  accessTokenExpiresAt?: Date;
  /** The Apple user the tokens belong to (the id token's `sub`). */
  appleUserId: string;
};

export class AppleTokenError extends Error {
  constructor(
    /** Apple's `error` code, or `http_<status>` when the body carried none. */
    readonly code: string,
  ) {
    super(`Apple token endpoint refused the request: ${code}`);
  }
}

export type AppleTokenClient = {
  /** Trade an authorization code from the native app for its refresh token. */
  exchangeNativeCode(code: string): Promise<AppleNativeTokens>;
  /** Revoke a refresh token, with the client that obtained it. */
  revoke(args: { refreshToken: string; clientId: string }): Promise<void>;
  /** Which of our clients an Apple id token was issued to, or null when it
   *  names none of them. */
  clientIdOf(idToken: string | null | undefined): string | null;
};

/**
 * Server-side calls to Apple's token and revoke endpoints, beyond what
 * Better-Auth does itself: it keeps no refresh token for a native id-token
 * sign-in, and it never revokes, while App Review requires revoking the user's
 * Apple tokens when they delete their account.
 *
 * Apple matches `client_id` against the client that authorized the user, so
 * the native apps' tokens are exchanged and revoked as the bundle ID and the
 * web flow's as the Services ID. Each needs its own client secret, because the
 * secret's `sub` must equal that `client_id`; one key signs both.
 */
export function createAppleTokenClient(
  env: Env,
  fetchImpl: typeof fetch = fetch,
): AppleTokenClient | undefined {
  if (!appleSignInConfigured(env)) return undefined;
  const { APPLE_TEAM_ID, APPLE_KEY_ID, APPLE_PRIVATE_KEY, APPLE_CLIENT_ID, APPLE_APP_BUNDLE_ID } =
    env;
  const secrets = new Map(
    [APPLE_CLIENT_ID!, APPLE_APP_BUNDLE_ID].map((clientId) => [
      clientId,
      appleClientSecret({
        teamId: APPLE_TEAM_ID!,
        keyId: APPLE_KEY_ID!,
        clientId,
        privateKey: APPLE_PRIVATE_KEY!,
      }),
    ]),
  );

  async function post(url: string, clientId: string, params: Record<string, string>) {
    return fetchImpl(url, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        client_id: clientId,
        client_secret: secrets.get(clientId)!(),
        ...params,
      }),
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
  }

  async function refusal(res: Response): Promise<AppleTokenError> {
    const body = (await res.json().catch(() => null)) as { error?: unknown } | null;
    return new AppleTokenError(
      typeof body?.error === "string" ? body.error : `http_${res.status}`,
    );
  }

  return {
    async exchangeNativeCode(code) {
      // No redirect_uri: Apple wants one only when the authorization request
      // carried one, and the native flow's does not.
      const res = await post(TOKEN_ENDPOINT, APPLE_APP_BUNDLE_ID, {
        grant_type: "authorization_code",
        code,
      });
      if (!res.ok) throw await refusal(res);
      const parsed = TokenResponse.safeParse(await res.json());
      if (!parsed.success) throw new AppleTokenError("malformed_response");
      const tokens = parsed.data;
      // Read without verifying: it came straight from Apple's token endpoint
      // over TLS in answer to our own authenticated request.
      const sub = decodeJwt(tokens.id_token).sub;
      if (!sub) throw new AppleTokenError("malformed_response");
      return {
        refreshToken: tokens.refresh_token,
        idToken: tokens.id_token,
        accessToken: tokens.access_token,
        accessTokenExpiresAt:
          tokens.expires_in === undefined
            ? undefined
            : new Date(Date.now() + tokens.expires_in * 1000),
        appleUserId: sub,
      };
    },

    async revoke({ refreshToken, clientId }) {
      const res = await post(REVOKE_ENDPOINT, clientId, {
        token: refreshToken,
        token_type_hint: "refresh_token",
      });
      // 200 also answers a token that was already invalid, so a retry after a
      // partial failure is harmless.
      if (!res.ok) throw await refusal(res);
    },

    clientIdOf(idToken) {
      if (!idToken) return null;
      let aud: string | string[] | undefined;
      try {
        aud = decodeJwt(idToken).aud;
      } catch {
        return null;
      }
      const candidates = Array.isArray(aud) ? aud : aud ? [aud] : [];
      return candidates.find((id) => secrets.has(id)) ?? null;
    },
  };
}
