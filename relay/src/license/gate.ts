import type { JwksProvider } from "./verify.js";
import { deviceTokenIssuer, verifyDeviceToken } from "./verify.js";
import type { LicenseCache, LicenseCacheEntry } from "./cache.js";

export type LicenseErrorCode =
  | "LICENSE_INVALID"
  | "LICENSE_EXPIRED"
  | "LICENSE_REVOKED"
  /** The one retryable member: the relay could not check, so it did not judge. */
  | "LICENSE_UNAVAILABLE";

export type LicenseGateResult =
  | { ok: true; entry: LicenseCacheEntry }
  | { ok: false; code: LicenseErrorCode };

export interface LicenseGate {
  /**
   * @param deviceId Agent's bare machine `deviceUuid` — matched against the
   *   JWT's `deviceUuid` claim and used to key the revocation cache. v3 has no
   *   `.projectId` compound registration id, so there is nothing to split.
   */
  verify(token: string, deviceId: string, publicKeyBase64: string): Promise<LicenseGateResult>;

  /**
   * Verify an APP's (phone's) license token for same-account identification.
   */
  verifyAppToken(token: string): Promise<LicenseGateResult>;
}

export interface LicenseGateDeps {
  licenseApiUrl: string;
  jwks: JwksProvider;
  cache: LicenseCache;
}

export function createLicenseGate(deps: LicenseGateDeps): LicenseGate {
  const expectedIssuer = deviceTokenIssuer(deps.licenseApiUrl);
  return {
    async verify(token, deviceId, publicKeyBase64): Promise<LicenseGateResult> {
      // No early cache short-circuit: a stale `revoked`/`pk` entry would
      // block legitimate re-activation (new jti) or key rotation. Let
      // verifyDeviceToken run, then re-check revocation against the same
      // jti below.
      const verified = await verifyDeviceToken(token, deps.jwks, expectedIssuer);
      if (!verified.ok) return { ok: false, code: verified.code };

      const { claims } = verified;
      if (claims.deviceUuid !== deviceId) return { ok: false, code: "LICENSE_INVALID" };
      if (claims.pk !== publicKeyBase64) return { ok: false, code: "LICENSE_INVALID" };

      // Re-check revocation post-verify in case of race with /internal/revoke.
      // Note: revocation is per-jti — a re-activated device with a new jti
      // bypasses this on purpose, so user-initiated re-activation works
      // without a persistent device-level deny list.
      const post = deps.cache.get(deviceId);
      if (post?.revoked && post.jti === claims.jti) {
        return { ok: false, code: "LICENSE_REVOKED" };
      }

      const entry: LicenseCacheEntry = {
        jti: claims.jti,
        deviceId: claims.deviceUuid,
        userId: claims.uid,
        tier: claims.tier,
        sessionLimit: claims.sessionLimit,
        pk: claims.pk,
        revoked: false,
      };
      deps.cache.set(entry);
      return { ok: true, entry };
    },

    async verifyAppToken(token): Promise<LicenseGateResult> {
      // Full crypto verification (JWKS signature, pinned issuer, exp) — the
      // trust in web's signing is identical to `verify`. We deliberately skip
      // ONLY the two slot-binding equality checks (`deviceUuid` ==
      // registrationId, `pk` == register pubkey): for an app the relay slot is
      // a per-connection pairing identity, not the account device the token
      // attests, so those binds would reject every same-account phone. The
      // account identity is proven agent-side via the membership proof; here we
      // only need the verified `uid`/`tier` to stamp the session.
      const verified = await verifyDeviceToken(token, deps.jwks, expectedIssuer);
      if (!verified.ok) return { ok: false, code: verified.code };

      const { claims } = verified;

      // Revocation still applies, keyed by the token's OWN account deviceUuid
      // (not the relay slot): a revoked account device must not lend its uid.
      const post = deps.cache.get(claims.deviceUuid);
      if (post?.revoked && post.jti === claims.jti) {
        return { ok: false, code: "LICENSE_REVOKED" };
      }

      const entry: LicenseCacheEntry = {
        jti: claims.jti,
        deviceId: claims.deviceUuid,
        userId: claims.uid,
        tier: claims.tier,
        sessionLimit: claims.sessionLimit,
        pk: claims.pk,
        revoked: false,
      };
      deps.cache.set(entry);
      return { ok: true, entry };
    },
  };
}
