import { readFileSync, mkdirSync, writeFileSync } from "node:fs";
import { randomBytes, X509Certificate, createPrivateKey, createPublicKey } from "node:crypto";
import { isIP } from "node:net";
import { resolve } from "node:path";
import { parseEnv } from "node:util";

// Port the native relay listens on behind the gateway when TLS is off. The
// production path is pinned to 443 by the relay's own config validation.
const INSECURE_NATIVE_PORT = 3443;

export function preparePeerStack(root: string, env: NodeJS.ProcessEnv, insecureHost: string) {
  const certPath = env.ANTGRID_RELAY_TLS_CERT;
  const keyPath = env.ANTGRID_RELAY_TLS_KEY;
  // Dev-only: serve the Iroh relay over cleartext so a local stack needs no DNS
  // name and no publicly trusted certificate. Every peer that dials it must opt
  // in the same way (web, bridge and app each read their own flag), so this
  // alone does not make anything accept a plaintext origin. A certificate is
  // the only other wire this stack can serve — the pinned bindings trust no
  // private CA — so naming one is what selects TLS, and the flag decides it
  // outright either way.
  const insecure = env.ANTGRID_DEV_INSECURE_RELAY?.trim()
    ? env.ANTGRID_DEV_INSECURE_RELAY.trim() === "true"
    : !certPath && !keyPath;
  // One host serves the whole stack — the lease's relayUrls, the native relay's
  // advertised origin and every target's RELAY_URL all derive from it — so it
  // has to be reachable from a phone or emulator, for which loopback resolves
  // to the handset. Cleartext to a private address is precisely what
  // isApprovedRelayOrigin, relayUrlsSchema and Config::validate allow.
  const host = env.ANTGRID_RELAY_HOST?.trim() || (insecure ? insecureHost : undefined);
  if (!host) {
    throw new Error("Local Iroh requires ANTGRID_RELAY_HOST (a hostname reachable from the app), or ANTGRID_DEV_INSECURE_RELAY=true to serve the relay over cleartext.");
  }
  if (!insecure && (!certPath || !keyPath)) {
    throw new Error("Local Iroh requires ANTGRID_RELAY_TLS_CERT and ANTGRID_RELAY_TLS_KEY. Use a publicly trusted certificate; the pinned bindings cannot trust an Aspire-generated CA. Set ANTGRID_DEV_INSECURE_RELAY=true to run without TLS instead.");
  }
  // An IP is fine without TLS — nothing has to match a certificate name.
  if (!insecure && isIP(host)) throw new Error("ANTGRID_RELAY_HOST must be a DNS hostname");
  if (!/^[a-zA-Z0-9.:[\]-]+$/.test(host)) throw new Error("ANTGRID_RELAY_HOST is not a valid host");
  let cert: string | undefined;
  let key: string | undefined;
  if (!insecure) {
    cert = resolve(certPath!);
    key = resolve(keyPath!);
    const leaf = new X509Certificate(readFileSync(cert));
    if (!leaf.checkHost(host) || Date.parse(leaf.validTo) <= Date.now() || Date.parse(leaf.validFrom) > Date.now()) {
      throw new Error("Relay certificate is expired, not yet valid, or does not cover ANTGRID_RELAY_HOST");
    }
    if (!leaf.publicKey.equals(createPublicKey(createPrivateKey(readFileSync(key))))) {
      throw new Error("Relay certificate and private key do not match");
    }
  }
  const webEnv = parseEnv(readFileSync(resolve(root, "web/.env"), "utf8"));
  const admissionSecret = env.RELAY_INTERNAL_SECRET || webEnv.RELAY_INTERNAL_SECRET;
  if (!admissionSecret || admissionSecret.length < 32) throw new Error("Run setup first: web RELAY_INTERNAL_SECRET is missing or too short");
  const adminSecret = randomBytes(32).toString("hex");
  const nativePort = insecure ? INSECURE_NATIVE_PORT : 443;
  const url = `${insecure ? "http" : "https"}://${host}:3000/`;
  const directory = resolve(root, ".tmp/aspire-iroh");
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const config = resolve(directory, "relay.json");
  writeFileSync(config, JSON.stringify({
    listen: `127.0.0.1:${nativePort}`, adminListen: "127.0.0.1:9000",
    ...(insecure ? { devInsecureHttp: true } : { tlsCert: cert, tlsKey: key }),
    relayUrl: url,
    admissionUrl: "http://127.0.0.1:8787/internal/peer-admission",
    admissionSecret, adminSecret, maxConnections: 128, maxPendingAdmissions: 16,
    maxAccounts: 128, maxAccountConnections: 32, maxEndpointConnections: 2,
    bytesPerSecond: 10485760, burstBytes: 2097152,
  }), { mode: 0o600 });
  return { url, host, insecure, nativePort, cert, key, config, admissionSecret,
    policyTargets: JSON.stringify([
      { url: "http://127.0.0.1:3001/internal/peer-policy", secret: admissionSecret },
      { url: "http://127.0.0.1:9000/internal/disconnect", secret: adminSecret },
    ]),
  };
}
