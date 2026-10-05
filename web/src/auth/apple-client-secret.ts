// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { createPrivateKey, sign, type KeyObject } from "node:crypto";

/** Apple rejects a client secret that expires more than six months out. */
const LIFETIME_SECONDS = 180 * 24 * 60 * 60;

/** Re-mint while this much lifetime is left, so a request in flight never
 *  carries a secret that expires before Apple reads it. */
const REFRESH_MARGIN_SECONDS = 30 * 24 * 60 * 60;

export type AppleClientSecretConfig = {
  teamId: string;
  keyId: string;
  /** The Services ID the secret authenticates as (the JWT `sub`). */
  clientId: string;
  /** PKCS#8 PEM from the `.p8` file Apple issues with the key. */
  privateKey: string;
  now?: () => number;
};

/** Parses the `.p8` PEM, throwing when it is not an EC P-256 key — Apple
 *  signs nothing else, and a bad key should fail the boot, not the first
 *  sign-in. */
export function parseApplePrivateKey(pem: string): KeyObject {
  const key = createPrivateKey(pem);
  if (key.asymmetricKeyType !== "ec" || key.asymmetricKeyDetails?.namedCurve !== "prime256v1") {
    throw new Error("Apple private key must be an EC P-256 key (the .p8 file)");
  }
  return key;
}

function base64url(value: string | Buffer): string {
  return Buffer.from(value).toString("base64url");
}

/**
 * Apple's OAuth client secret is not a fixed string but an ES256 JWT signed
 * with the developer's key, valid for at most six months. Better-Auth reads
 * `clientSecret` off the provider options at every token exchange, so this
 * returns a getter that re-mints before expiry: a secret minted once at boot
 * would break Apple sign-in on any process that outlives it.
 *
 * Signing is synchronous (node:crypto rather than jose) because a property
 * getter cannot await.
 */
export function appleClientSecret(config: AppleClientSecretConfig): () => string {
  const key = parseApplePrivateKey(config.privateKey);
  const now = config.now ?? (() => Date.now());
  let cached: { token: string; expiresAt: number } | null = null;

  function mint(issuedAt: number): { token: string; expiresAt: number } {
    const expiresAt = issuedAt + LIFETIME_SECONDS;
    const header = base64url(JSON.stringify({ alg: "ES256", kid: config.keyId }));
    const payload = base64url(
      JSON.stringify({
        iss: config.teamId,
        iat: issuedAt,
        exp: expiresAt,
        aud: "https://appleid.apple.com",
        sub: config.clientId,
      }),
    );
    const signingInput = `${header}.${payload}`;
    // JWS wants the raw r||s pair, not the DER that node:crypto emits by default.
    const signature = sign("sha256", Buffer.from(signingInput), { key, dsaEncoding: "ieee-p1363" });
    return { token: `${signingInput}.${base64url(signature)}`, expiresAt };
  }

  return () => {
    const nowSeconds = Math.floor(now() / 1000);
    if (!cached || cached.expiresAt - nowSeconds < REFRESH_MARGIN_SECONDS) {
      cached = mint(nowSeconds);
    }
    return cached.token;
  };
}
