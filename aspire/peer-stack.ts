import { readFileSync, mkdirSync, writeFileSync } from "node:fs";
import { randomBytes, X509Certificate, createPrivateKey, createPublicKey } from "node:crypto";
import { isIP } from "node:net";
import { resolve } from "node:path";
import { parseEnv } from "node:util";

// Port the native relay listens on behind the gateway when TLS is off.
const INSECURE_NATIVE_PORT = 3443;
// With a [tls] table the stock relay serves /relay, /ping and /healthz on
// `https_bind_addr` and keeps `http_bind_addr` as a plain captive-portal
// listener (`iroh-relay 1.2.0 src/server.rs:795-827`) whose default is `[::]:80`, so it
// needs its own loopback port.
const TLS_CAPTIVE_PORTAL_PORT = 3080;
// The metrics listener otherwise lands on port 9090 of the http bind address
// (`iroh-relay 1.2.0 src/main.rs:344-347`); pin it explicitly so it stays loopback-only.
const METRICS_PORT = 9091;
// web's `irohAccessRoutes` path; it matches `?relay=` against IROH_RELAY_URLS.
const ACCESS_URL = "http://127.0.0.1:8787/internal/iroh-access";

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
  // isApprovedRelayOrigin and relayUrlsSchema allow.
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
  // Web and the central relay's shared secret, which also signs the
  // peer-policy outbox push. Distinct from the relay access token below.
  const internalSecret = env.RELAY_INTERNAL_SECRET || webEnv.RELAY_INTERNAL_SECRET;
  if (!internalSecret || internalSecret.length < 32) throw new Error("Run setup first: web RELAY_INTERNAL_SECRET is missing or too short");
  // Bearer for the relay's access.http callback. It travels only through env
  // (IROH_RELAY_HTTP_BEARER_TOKEN on the relay, PEER_RELAY_ACCESS_TOKEN on web)
  // so the config file on disk never holds a credential.
  const accessToken = randomBytes(32).toString("hex");
  const nativePort = insecure ? INSECURE_NATIVE_PORT : 443;
  const url = `${insecure ? "http" : "https"}://${host}:3000/`;
  const directory = resolve(root, ".tmp/aspire-iroh");
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const config = resolve(directory, "relay.toml");
  writeFileSync(config, relayToml(insecure ? { url } : { url, tls: { cert: cert!, key: key! } }), { mode: 0o600 });
  return { url, host, insecure, nativePort, cert, key, config, internalSecret, accessToken,
    policyTargets: JSON.stringify([
      { url: "http://127.0.0.1:3001/internal/peer-policy", secret: internalSecret },
    ]),
  };
}

// The stock relay has no `deny_unknown_fields` and falls back to
// `access = Everyone` when a key is missing (`iroh-relay 1.2.0 src/main.rs:91,537-549`), so
// every mistake in this text fails open. peer-stack.test.ts is the only guard.
export function relayToml(opts: { url: string; tls?: { cert: string; key: string } }): string {
  const accessUrl = new URL(ACCESS_URL);
  // URLSearchParams percent-encodes, so the advertised origin round-trips
  // byte-for-byte into web's comparison.
  accessUrl.searchParams.set("relay", opts.url);
  const httpPort = opts.tls ? TLS_CAPTIVE_PORTAL_PORT : INSECURE_NATIVE_PORT;
  // Root keys must precede the first [table]: TOML files a later bare key
  // under the table above it, where serde silently ignores it.
  const lines = [
    `http_bind_addr = "127.0.0.1:${httpPort}"`,
    `enable_quic_addr_discovery = false`,
    `metrics_bind_addr = "127.0.0.1:${METRICS_PORT}"`,
    ``,
    `[limits]`,
    `accept_conn_limit = 32.0`,
    `accept_conn_burst = 64`,
    ``,
    `[limits.client.rx]`,
    `bytes_per_second = 10485760`,
    `max_burst_bytes = 2097152`,
    ``,
    `[access.http]`,
    `url = ${JSON.stringify(accessUrl.href)}`,
  ];
  if (opts.tls) {
    lines.push(
      ``,
      `[tls]`,
      `cert_mode = "Manual"`,
      `https_bind_addr = "127.0.0.1:443"`,
      `manual_cert_path = ${JSON.stringify(opts.tls.cert)}`,
      `manual_key_path = ${JSON.stringify(opts.tls.key)}`,
    );
  }
  return `${lines.join("\n")}\n`;
}
