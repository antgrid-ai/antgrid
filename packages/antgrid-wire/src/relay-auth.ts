// Canonical relay-auth signature body for the v3 `hello` message.
// Both clients sign it, the relay verifies it, evals forge it — this is the
// single TS implementation. Byte-for-byte mirror of
// packages/antgrid_relay_client/lib/src/relay_auth.dart; the shared vector
// fixture (evals/fixtures/relay-hello-vector.json) pins both.
// Spec: relay/CLAUDE.md (`server.ts` — hello verification order).

import { createHash } from "node:crypto";

export const RELAY_AUTH_DOMAIN = "antgrid.relay-auth.v3";
const VERSION_BYTE = 0x03;
const NUL = Buffer.from([0x00]);

export interface HelloSigFields {
  /** Normalized host the client dialed — see `normalizeRelayHost`. The relay
   *  compares against the Host header of its upgrade request, same
   *  normalization; mismatch = AUTH_FAILED (host mismatch). */
  relayHost: string;
  deviceType: "agent" | "app";
  deviceId: string;
  publicKey: string; // base64, verbatim as sent in hello
  epoch: number;
  licenseToken: string;
  ts: string; // ISO-8601, verbatim as sent
  nonce: string; // base64, verbatim as sent
}

/**
 * Canonical byte string signed in `hello.sig`, fields joined with a single
 * 0x00 byte, no trailing separator. The licenseToken enters as its raw
 * SHA-256 digest (fixed 32 bytes) so the body stays small and the token —
 * which may contain 0x00-free but long base64url — cannot shift field
 * boundaries. Length-unambiguous because every field is either fixed-length
 * or excludes 0x00 (same argument as the E2E transcript builder).
 */
export function buildHelloSigBody(f: HelloSigFields): Uint8Array {
  return Buffer.concat([
    Buffer.from(RELAY_AUTH_DOMAIN, "utf8"), NUL,
    Buffer.from([VERSION_BYTE]), NUL,
    Buffer.from(f.relayHost, "utf8"), NUL,
    Buffer.from(f.deviceType, "utf8"), NUL,
    Buffer.from(f.deviceId, "utf8"), NUL,
    Buffer.from(f.publicKey, "utf8"), NUL,
    Buffer.from(String(f.epoch), "utf8"), NUL,
    createHash("sha256").update(f.licenseToken, "utf8").digest(), NUL,
    Buffer.from(f.ts, "utf8"), NUL,
    Buffer.from(f.nonce, "utf8"),
  ]);
}

/**
 * Normalizes a relay WS URL to the `relayHost` signed above: lowercase
 * `host` when the port is the scheme default (443 for wss/https, 80 for
 * ws/http), else lowercase `host:port`. The relay applies the SAME rules to
 * the upgrade request's Host header before comparing.
 */
export function normalizeRelayHost(relayUrl: string): string {
  const u = new URL(relayUrl);
  // WHATWG URL already drops the port when it equals the scheme default for
  // ws/wss/http/https, so `u.port` is non-empty only for non-default ports.
  const host = u.hostname.toLowerCase();
  return u.port ? `${host}:${u.port}` : host;
}
