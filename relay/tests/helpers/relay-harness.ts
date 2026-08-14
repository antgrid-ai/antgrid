import { sign as edSign } from "node:crypto";
import { startServer as startServerReal, type RelayServer, type RelayServerDeps } from "../../src/server.js";
import { buildHelloSigBody, normalizeRelayHost, decodeRouteFrame } from "antgrid-wire";
import type { RelayConfig } from "../../src/config.js";
import type { LicenseGate } from "../../src/license/gate.js";

const ED25519_PKCS8_PREFIX = Buffer.from("302e020100300506032b657004220420", "hex");

export function rawSeedToPkcs8(seed: Uint8Array): Buffer {
  return Buffer.concat([ED25519_PKCS8_PREFIX, Buffer.from(seed)]);
}

// Per-deviceId stable jti so reconnects look the same.
const fakeJtiByDevice = new Map<string, string>();

export interface FakeLicenseGateOptions {
  /** Derive the account uid an agent's token carries — lets tests put two agent
   *  connections under one account (same-account routing, cross-connection
   *  stream counting). */
  agentUid?: (deviceId: string) => string;
}

/** Parameterized fake gate. `fakeLicenseGate` below is the opts-less default. */
export function makeFakeLicenseGate(opts: FakeLicenseGateOptions = {}): LicenseGate {
  const uidFor = opts.agentUid ?? ((deviceId: string) => `user-${deviceId}`);
  return {
    async verify(_token, deviceId, publicKeyBase64) {
      let jti = fakeJtiByDevice.get(deviceId);
      if (!jti) {
        jti = `jti-${deviceId}-${Math.random().toString(36).slice(2, 10)}`;
        fakeJtiByDevice.set(deviceId, jti);
      }
      return {
        ok: true,
        entry: {
          jti,
          deviceId,
          userId: uidFor(deviceId),
          tier: "pro",
          pk: publicKeyBase64,
          revoked: false,
        },
      };
    },
    // App path: token-only, no slot bind. Yields a stable userId per token so
    // same-account tests are deterministic.
    async verifyAppToken(token) {
      return {
        ok: true,
        entry: {
          jti: `jti-app-${token}`,
          deviceId: `app-${token}`,
          userId: `user-app-${token}`,
          tier: "pro",
          pk: "",
          revoked: false,
        },
      };
    },
  };
}

export const fakeLicenseGate: LicenseGate = makeFakeLicenseGate();

export function startServer(cfg: RelayConfig, deps: RelayServerDeps = {}): RelayServer {
  return startServerReal(cfg, { licenseGate: fakeLicenseGate, ...deps });
}

export const defaultConfig: RelayConfig = {
  port: 0,
  maxConnections: 100,
  rateLimitConnPerIp: 10,
  rateLimitMsgPerSec: 100,
  rateLimitMsgBurst: 100,
  pushRateLimitPerSec: 100,
  jsonRateLimitPerSec: 10,
  jsonRateLimitBurst: 30,
  maxStreamsPerConnection: 1024,
  clockSkewMs: 120000,
  replayTtlMs: 300000,
  pingIntervalMs: 0, // disabled in tests
  pongTimeoutMs: 10000,
  trustedProxyIps: [],
  logLevel: "error" as const,
  licenseApiUrl: "http://localhost:8787",
  relayInternalSecret: "x".repeat(16),
  licenseCacheMaxEntries: 100000,
};

export function wsUrl(relay: RelayServer): string {
  return `ws://localhost:${relay.server.port}/ws`;
}

/** The `relayHost` the client must sign — the relay compares its own Host header. */
export function relayHostFor(relay: RelayServer): string {
  return normalizeRelayHost(wsUrl(relay));
}

export async function connect(relay: RelayServer): Promise<WebSocket> {
  const ws = new WebSocket(wsUrl(relay));
  await new Promise<void>((resolve, reject) => {
    ws.onopen = () => resolve();
    ws.onerror = () => reject(new Error("WebSocket connection failed"));
  });
  return ws;
}

export function decodeMessage(data: unknown): Record<string, unknown> {
  if (typeof data === "string") {
    return JSON.parse(data);
  }
  const buf = data instanceof Buffer ? data : Buffer.from(data as ArrayBuffer);
  const decoded = decodeRouteFrame(buf);
  const header = decoded.header as Record<string, unknown>;
  return {
    ...header,
    kind: decoded.kind,
    payload: new TextDecoder().decode(decoded.payload),
  };
}

export function waitForMessage(ws: WebSocket): Promise<Record<string, unknown>> {
  return new Promise((resolve) => {
    ws.onmessage = (e) => resolve(decodeMessage(e.data));
  });
}

export function waitForMessages(ws: WebSocket, n: number): Promise<Record<string, unknown>[]> {
  return new Promise((resolve) => {
    const messages: Record<string, unknown>[] = [];
    ws.onmessage = (e) => {
      messages.push(decodeMessage(e.data));
      if (messages.length >= n) resolve(messages);
    };
  });
}

/**
 * Wait for the next message of a specific `type`, ignoring anything else that
 * arrives first (e.g. a `peer-online` fan-out interleaved with the reply a
 * test actually cares about). Uses `addEventListener` so it composes with
 * other concurrent waiters instead of clobbering `ws.onmessage`.
 */
export function waitForType(ws: WebSocket, type: string): Promise<Record<string, unknown>> {
  return new Promise((resolve) => {
    const handler = (e: MessageEvent) => {
      const m = decodeMessage(e.data);
      if (m.type === type) {
        ws.removeEventListener("message", handler as never);
        resolve(m);
      }
    };
    ws.addEventListener("message", handler as never);
  });
}

/** Wait for the socket's close event; resolves with the close code. */
export function waitForClose(ws: WebSocket): Promise<number> {
  return new Promise((resolve) => {
    ws.onclose = (e) => resolve(e.code);
  });
}

export async function generateKeyPair(): Promise<{
  keyPair: CryptoKeyPair;
  publicKeyBase64: string;
  privateSeed: Uint8Array;
}> {
  const keyPair = await crypto.subtle.generateKey("Ed25519", true, ["sign", "verify"]);
  const publicKeyRaw = await crypto.subtle.exportKey("raw", keyPair.publicKey);
  const jwk = (await crypto.subtle.exportKey("jwk", keyPair.privateKey)) as { d?: string };
  const dB64Url = jwk.d ?? "";
  const dB64 = dB64Url.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(dB64Url.length / 4) * 4, "=");
  const privateSeed = new Uint8Array(Buffer.from(dB64, "base64"));
  return {
    keyPair,
    publicKeyBase64: Buffer.from(publicKeyRaw).toString("base64"),
    privateSeed,
  };
}

export interface HelloOptions {
  deviceId: string;
  deviceType?: "agent" | "app";
  name?: string;
  epoch?: number;
  licenseToken?: string;
  ts?: string;
  nonce?: string;
  /** Override the signed host — for host-mismatch tests. */
  relayHost?: string;
  /** Reuse an identity (e.g. a reconnect / epoch test) instead of a fresh key. */
  publicKeyBase64?: string;
  privateSeed?: Uint8Array;
}

/**
 * Build a fully-signed v3 `hello` (defaults fill in a valid keypair, current
 * `ts`, random nonce, and the relay's own host). Return the keypair so callers
 * can reuse it across a reconnect or sign further agent-side messages.
 */
export async function makeHello(
  relay: RelayServer,
  opts: HelloOptions,
): Promise<{ hello: Record<string, unknown>; publicKeyBase64: string; privateSeed: Uint8Array }> {
  const deviceType = opts.deviceType ?? "agent";
  let publicKeyBase64: string;
  let privateSeed: Uint8Array;
  if (opts.publicKeyBase64 && opts.privateSeed) {
    publicKeyBase64 = opts.publicKeyBase64;
    privateSeed = opts.privateSeed;
  } else {
    const kp = await generateKeyPair();
    publicKeyBase64 = kp.publicKeyBase64;
    privateSeed = kp.privateSeed;
  }
  const epoch = opts.epoch ?? Math.floor(Date.now() / 1000);
  const ts = opts.ts ?? new Date().toISOString();
  const nonce = opts.nonce ?? Buffer.from(crypto.getRandomValues(new Uint8Array(16))).toString("base64");
  const licenseToken = opts.licenseToken ?? "test-token";
  const relayHost = opts.relayHost ?? relayHostFor(relay);

  const sigBody = buildHelloSigBody({
    relayHost,
    deviceType,
    deviceId: opts.deviceId,
    publicKey: publicKeyBase64,
    epoch,
    licenseToken,
    ts,
    nonce,
  });
  const sig = edSign(null, Buffer.from(sigBody), { key: rawSeedToPkcs8(privateSeed), format: "der", type: "pkcs8" }).toString("base64");

  const hello: Record<string, unknown> = {
    type: "hello",
    protocolVersion: 3,
    deviceType,
    deviceId: opts.deviceId,
    name: opts.name ?? opts.deviceId,
    publicKey: publicKeyBase64,
    epoch,
    licenseToken,
    ts,
    nonce,
    sig,
  };
  return { hello, publicKeyBase64, privateSeed };
}

/** Connect, send a valid `hello`, and await the first relay reply (welcome or error). */
export async function connectHello(
  relay: RelayServer,
  opts: HelloOptions,
): Promise<{ ws: WebSocket; publicKeyBase64: string; privateSeed: Uint8Array; welcome: Record<string, unknown> }> {
  const { hello, publicKeyBase64, privateSeed } = await makeHello(relay, opts);
  const ws = await connect(relay);
  const first = waitForMessage(ws);
  ws.send(JSON.stringify(hello));
  const welcome = await first;
  return { ws, publicKeyBase64, privateSeed, welcome };
}

export type { RelayServer, RelayServerDeps };
