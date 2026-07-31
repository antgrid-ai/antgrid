import { type Subprocess } from "bun";
import { resolve, join } from "node:path";
import { mkdtempSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { generateKeyPairSync, randomUUID, createHmac } from "node:crypto";
import { createTestProject } from "./fixtures";
import { RelayClient, type PhoneIdentity } from "./relay-client";
import { DartAppClient } from "./dart-app-client";
import { computeProjectId } from "../../bridge/src/project-id";
import { loadPairedPhones, type PairedPhone } from "../../bridge/src/paired-phones";
import { readHostFile, type HostFile } from "../../bridge/src/host-discovery";
import type { TrustedPeer } from "../../bridge/src/trusted-peers";
import type { RelayConfig } from "../../relay/src/config";
import type { LicenseGate } from "../../relay/src/license/gate";
import type { LicenseCacheEntry } from "../../relay/src/license/cache";

const ROOT = resolve(import.meta.dir, "../..");

/** Poll `<abDir>/host.json` for the loopback control port + token. The host
 *  publishes it in `startControlPlane()`, before the first project opens, so it
 *  is already on disk by the time `spawnAgent` resolves — the poll only covers
 *  a slow start. */
export async function waitForHostFile(abDir: string, timeoutMs = 5_000): Promise<HostFile> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const hf = readHostFile(join(abDir, "host.json"));
    if (hf) return hf;
    await Bun.sleep(100);
  }
  throw new Error(`host.json did not appear in ${abDir} within ${timeoutMs}ms`);
}

/**
 * Flip the machine-level mobile-access switch through the loopback
 * `mobile-access:set` verb — the same path the desktop toggle drives.
 *
 * A fresh machine is OFF, and that one boolean is the whole authorization gate
 * for an account-trusted phone, so every eval that drives a project verb has to
 * turn it on. It MUST go through the verb rather than writing
 * `mobile-access-policy.json` directly: the policy store is read once at
 * construction and deliberately has no fs watcher, so a file written after the
 * host is up would never be observed.
 */
export async function setMobileAccess(abDir: string, enabled: boolean): Promise<void> {
  const hf = await waitForHostFile(abDir);
  const res = await fetch(`http://127.0.0.1:${hf.controlPort}/control`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${hf.token}` },
    body: JSON.stringify({ id: `eval-mobile-access-${enabled}`, type: "mobile-access:set", enabled }),
  });
  const body = (await res.json()) as { ok?: boolean; enabled?: boolean };
  if (!body.ok || body.enabled !== enabled) {
    throw new Error(`mobile-access:set ${enabled} failed: ${JSON.stringify(body)}`);
  }
}

/** Generate a fresh Ed25519 app identity: a `deviceId` + the `PhoneIdentity`
 *  keypair `RelayClient.connectAndAuth({ identity })` reuses across connections.
 *  Registering `{deviceId, ed25519Pub: publicKeyBase64}` with the fake account
 *  inventory (`startFakeLicenseApi({ accountDevices })`) is what admits it —
 *  the bridge's `TrustedPeersProvider` is deviceId-keyed (see
 *  `bridge/src/relay-client.ts`'s `resolvePhoneEd25519PubB64`), so a never-
 *  registered identity cannot be admitted on any attempt, retried or not.
 *  Shared with `gate-account-trust.test.ts` (imported, not duplicated). */
export async function generateAppIdentity(): Promise<PhoneIdentity & { deviceId: string }> {
  const deviceId = randomUUID();
  const keyPair = await crypto.subtle.generateKey("Ed25519", true, ["sign", "verify"]);
  const pubRaw = await crypto.subtle.exportKey("raw", keyPair.publicKey as CryptoKey);
  const publicKeyBase64 = Buffer.from(pubRaw).toString("base64");
  const pkcs8Der = Buffer.from(await crypto.subtle.exportKey("pkcs8", keyPair.privateKey as CryptoKey));
  const privateKeySeed = Buffer.from(pkcs8Der.subarray(pkcs8Der.length - 32));
  return { deviceId, publicKeyBase64, privateKey: keyPair.privateKey as CryptoKey, privateKeySeed };
}

export interface AgentHandle {
  port: number;
  url: string;
  process: Subprocess;
  /** The deviceUuid the agent was spawned with (its relay-auth identity). */
  deviceUuid: string;
  /** The agent's stable Ed25519 public key (base64) — its relay-auth pubkey. */
  ed25519Pubkey: string;
  kill(): Promise<void>;
  /** Kill the current process and respawn a fresh one against the SAME
   *  abDir/auth/projectDir — deviceId/pubkey, the paired-phones row and the
   *  machine's mobile-access switch all survive on disk; only the process (and
   *  its relay epoch) is new. Mutates this
   *  SAME handle's `process` field in place, so a caller holding this
   *  reference (e.g. `env.agent`) observes the fresh process without
   *  needing a new handle. Mirrors the pre-Task-1 `setupPairFlowTestEnv`'s
   *  `restartAgent` (recovered from git history at fe6de19a^). */
  restart(): Promise<void>;
  /** Fresh read of this agent's `<abDir>/agents/paired-phones.json` — the
   *  per-phone identity/push/last-seen rows. Not an authorization record:
   *  a phone's access is the machine switch (`setMobileAccess`). */
  pairedPhones(): PairedPhone[];
}

/** One sealed notification the relay forwarded to FCM/APNs. The relay is
 *  zero-knowledge, so the ciphertext is all an eval can see — presence and
 *  target token are the assertable facts. */
export interface PushDelivery {
  pushToken: string;
  epk: string;
  box: string;
}

export interface RelayHandle {
  port: number;
  url: string;
  httpUrl: string;
  /** Sealed pushes the relay forwarded, oldest first. Snapshot — call it again
   *  for later deliveries. */
  pushDeliveries(): PushDelivery[];
  /** Live relay connection count (past hello). X3's drill-in test asserts zero
   *  additional connections; the multi-stream test asserts one per side. */
  connectionCount(): number;
  /** Open project streams across all eval agent connections. */
  streamCount(): number;
  stop(): void;
}

// Start in a random range (19000-19999) to avoid conflicts with stale
// test-relay servers from previous runs (Windows doesn't always clean up ports
// quickly after process exit) and other local dev services.
let nextPort = 19_000 + Math.floor(Math.random() * 1_000);

export function allocatePort(): number {
  return nextPort++;
}

export const TEST_LICENSE_TOKEN = "eval-license-token";

/** Sentinel app token `FakeLicenseApi.mintAppToken()` returns exactly once
 *  after `expireNextToken()` arms it — `fakeLicenseGate.verifyAppToken`
 *  recognizes this exact string and answers `LICENSE_EXPIRED`, letting the
 *  token-expiry gate suite drive a real relay rejection without a real JWT. */
const EXPIRED_APP_TOKEN = "eval-license-token-EXPIRED";

/** Shared relay-internal HMAC secret every eval relay config uses (16+ chars,
 *  the relay's minimum) — a single source so a divergent copy never surfaces
 *  as an opaque 401 on `/internal/*` routes in a file that hand-rolls its own
 *  relay config instead of `startRelay`. */
export const RELAY_INTERNAL_SECRET = "x".repeat(16);

/** Fixed account id every eval device shares — `streamCount()` and routing
 *  authorization both key off it. */
const EVAL_USER_ID = "eval-user";

/**
 * Fake v3 LicenseGate. Accepts any non-empty token (agents and apps alike —
 * v3 requires a token for BOTH, design §4.2) and returns a fixed uid.
 */
function fakeLicenseGate(): LicenseGate {
  // `pk` mirrors the real gate's `claims.pk` (the pubkey the token attests).
  // The relay stamps sessions from userId/tier/jti only, so the value is inert
  // here — echoing the presented key keeps it from reading as a meaningful
  // assertion.
  const entryFor = (deviceId: string, pk: string): LicenseCacheEntry => ({
    jti: `eval-jti-${deviceId}`,
    deviceId,
    userId: EVAL_USER_ID,
    tier: "pro",
    pk,
    revoked: false,
  });
  return {
    async verify(token, deviceId, publicKeyBase64) {
      if (!token) return { ok: false, code: "LICENSE_INVALID" };
      return { ok: true, entry: entryFor(deviceId, publicKeyBase64) };
    },
    // v3 apps present their own account token; the fake accepts TEST_LICENSE_TOKEN
    // and returns a fixed uid so the grant/session accounting has an account id.
    async verifyAppToken(token) {
      if (!token) return { ok: false, code: "LICENSE_INVALID" };
      if (token === EXPIRED_APP_TOKEN) return { ok: false, code: "LICENSE_EXPIRED" };
      // No pubkey is presented to this path (the real gate deliberately skips
      // the slot bind for apps), so there is nothing to echo.
      return { ok: true, entry: entryFor(`app-${EVAL_USER_ID}`, "") };
    },
  };
}

/**
 * Synthetic OAuth credentials + device keypairs for the stdin bootstrap
 * payload. In production these are minted by `web` and handed to the agent
 * by the app on spawn (see `bridge/src/auth/credentials.ts`). In evals we
 * generate them locally; the agent uses `ed25519*` for relay device-auth and
 * mints an access token from the fake license API (below).
 */
export interface EvalAuth {
  clientId: string;
  clientSecret: string;
  deviceUuid: string;
  ed25519Pub: string;
  ed25519Priv: string;
  x25519Pub: string;
  x25519Priv: string;
}

function b64Raw(key: import("node:crypto").KeyObject, type: "spki" | "pkcs8"): string {
  // Strip the DER prefix to the raw 32-byte key, matching the encoding the
  // agent's credentials schema expects.
  return Buffer.from(key.export({ format: "der", type }).subarray(-32)).toString("base64");
}

export function generateEvalAuth(): EvalAuth {
  const ed = generateKeyPairSync("ed25519");
  const x = generateKeyPairSync("x25519");
  return {
    clientId: `eval-client-${randomUUID()}`,
    clientSecret: "eval-secret",
    deviceUuid: randomUUID(),
    ed25519Pub: b64Raw(ed.publicKey, "spki"),
    ed25519Priv: b64Raw(ed.privateKey, "pkcs8"),
    x25519Pub: b64Raw(x.publicKey, "spki"),
    x25519Priv: b64Raw(x.privateKey, "pkcs8"),
  };
}

export interface FakeLicenseApi {
  url: string;
  stop(): void;
  /** Arm the NEXT `mintAppToken()` call to return an already-expired app
   *  token — the relay's `fakeLicenseGate.verifyAppToken` recognizes the
   *  sentinel and answers `LICENSE_EXPIRED`. Consumed on that one mint; the
   *  mint after it is a normal token again. */
  expireNextToken(): void;
  /** Mint the current app token — normal, unless a prior `expireNextToken()`
   *  armed this exact call, in which case it returns (and consumes) the
   *  expired sentinel. `TestApp.reconnect()` calls this before each redial,
   *  mirroring the real app re-minting its account token on every connect. */
  mintAppToken(): string;
  /** Register a fresh account device AFTER construction — visible to a
   *  bridge only on its NEXT `/account/devices/me/peers` poll, not whatever
   *  it already cached at startup (the inventory-miss row's whole point).
   *  `deviceId`/`identity` let a caller pin a SPECIFIC device id and/or reuse
   *  an existing Ed25519 keypair (e.g. one account device registered across
   *  two separate `FakeLicenseApi`s for the multi-machine-slots row);
   *  omitted, both are freshly generated. */
  addAccountDevice(opts?: {
    kind?: "app" | "agent";
    deviceId?: string;
    identity?: PhoneIdentity;
  }): Promise<PhoneIdentity & { deviceId: string }>;
  /** POST /internal/revoke on the relay (HMAC-signed over `RELAY_INTERNAL_SECRET`,
   *  mirroring `relay-cascade.test.ts`'s hand-rolled version) for `deviceId`.
   *  Requires `startFakeLicenseApi({ relayInternalUrl })` to have been set —
   *  `setupTestEnv` wires this to `relay.httpUrl` automatically. */
  revokeDevice(deviceId: string): Promise<void>;
}

/**
 * Minimal stand-in for `web`'s OAuth + heartbeat endpoints. The agent in
 * remote mode mints an access token (`POST /api/auth/oauth2/token`) before
 * connecting to the relay, then POSTs a heartbeat on authenticate. The relay's
 * `fakeLicenseGate` accepts any non-empty token, so we return a fixed one and
 * 200 everything else (the heartbeat is best-effort on the agent side).
 *
 * For account-trust admission, the agent fetches its account's enrolled
 * app-device set from `GET /account/devices/me/peers` over this same Bearer
 * channel (see `bridge/src/trusted-peers.ts`'s `TrustedPeersProvider`). Pass
 * `opts.accountDevices` to seed known peers; absent → empty set.
 */
export function startFakeLicenseApi(
  opts: {
    accountPeerKeys?: string[];
    accountDevices?: TrustedPeer[];
    /** Relay HTTP base (`RelayHandle.httpUrl`) — required for `revokeDevice`.
     *  `setupTestEnv` wires this automatically since it always has a relay. */
    relayInternalUrl?: string;
  } = {},
): FakeLicenseApi {
  const peerKeys = opts.accountPeerKeys ?? [];
  // Mutable: addAccountDevice pushes onto this SAME array, so the next
  // /account/devices/me/peers poll (closure reads it live) sees the addition.
  const devices: TrustedPeer[] = opts.accountDevices ? [...opts.accountDevices] : [];
  let expireNext = false;
  const server = Bun.serve({
    port: 0,
    fetch(req) {
      const url = new URL(req.url);
      if (url.pathname === "/api/auth/oauth2/token") {
        return Response.json({
          access_token: TEST_LICENSE_TOKEN,
          token_type: "Bearer",
          expires_in: 3600,
        });
      }
      // Account-membership peer-key set (Bearer-gated in prod; the fake accepts
      // any token, matching the relay's fakeLicenseGate). Mirrors web's
      // `GET /account/devices/me/peers` → `{ keys: string[], devices: [{deviceId, ed25519Pub}] }`
      // (Task 4: `devices[]` is the enabling delta for the bridge's
      // TrustedPeersProvider — `{keys}` alone has no deviceId to key off).
      if (url.pathname === "/account/devices/me/peers") {
        return Response.json({ keys: peerKeys, devices });
      }
      // Heartbeat + anything else — agent treats non-2xx as a soft warning.
      return Response.json({ ok: true });
    },
  });
  return {
    url: `http://localhost:${server.port}`,
    stop() {
      server.stop(true);
    },
    expireNextToken() {
      expireNext = true;
    },
    mintAppToken() {
      if (expireNext) {
        expireNext = false;
        return EXPIRED_APP_TOKEN;
      }
      return TEST_LICENSE_TOKEN;
    },
    async addAccountDevice(o = {}) {
      const generated = o.identity ? null : await generateAppIdentity();
      const identity: PhoneIdentity = o.identity ?? generated!;
      const deviceId = o.deviceId ?? generated!.deviceId;
      devices.push({ deviceId, ed25519Pub: identity.publicKeyBase64 });
      return { ...identity, deviceId };
    },
    async revokeDevice(deviceId: string): Promise<void> {
      if (!opts.relayInternalUrl) {
        throw new Error(
          "FakeLicenseApi.revokeDevice requires relayInternalUrl (setupTestEnv wires this automatically)",
        );
      }
      const body = JSON.stringify({ deviceId });
      const sig = createHmac("sha256", RELAY_INTERNAL_SECRET).update(body).digest("hex");
      const res = await fetch(`${opts.relayInternalUrl}/internal/revoke`, {
        method: "POST",
        headers: { "content-type": "application/json", "x-antgrid-signature": sig },
        body,
      });
      if (!res.ok) {
        throw new Error(`/internal/revoke failed: ${res.status} ${await res.text()}`);
      }
    },
  };
}

export async function startRelay(opts: {
  port: number;
  /** ± window a hello `ts` may deviate from server time (default 120s). The R
   *  skew forge test lands `skewTsMs` outside this. */
  clockSkewMs?: number;
  /** `(deviceId, nonce)` hello replay TTL (default 5min). */
  replayTtlMs?: number;
  /** Per-connection JSON-control message rate (default generous; the X3
   *  JSON-flood test lowers it to force MESSAGE_RATE_LIMITED). */
  jsonRateLimitPerSec?: number;
  jsonRateLimitBurst?: number;
  /** Per-pair binary/message frame rate (default generous). */
  rateLimitMsgPerSec?: number;
}): Promise<RelayHandle> {
  // Static specifier, not `import(resolve(ROOT, ...))`: a computed specifier
  // types `startServer` as `any`, which silently stops type-checking BOTH the
  // config literal below (missing/renamed relay keys) and every property read
  // off the returned server — the exact way a relay change slips past the evals.
  const { startServer } = await import("../../relay/src/server");
  const cfg: RelayConfig = {
    port: opts.port,
    maxConnections: 100,
    rateLimitConnPerIp: 10,
    rateLimitMsgPerSec: opts.rateLimitMsgPerSec ?? 100,
    jsonRateLimitPerSec: opts.jsonRateLimitPerSec ?? 100,
    jsonRateLimitBurst: opts.jsonRateLimitBurst ?? 200,
    maxStreamsPerConnection: 1024,
    clockSkewMs: opts.clockSkewMs ?? 120_000,
    replayTtlMs: opts.replayTtlMs ?? 300_000,
    pingIntervalMs: 30_000,
    pongTimeoutMs: 10_000,
    trustedProxyIps: [],
    logLevel: "error",
    licenseApiUrl: "http://license-api.eval",
    relayInternalSecret: RELAY_INTERNAL_SECRET,
    licenseCacheMaxEntries: 1000,
  };
  // Recording stand-in for FCM/APNs. Installed unconditionally: without a
  // sender the relay answers `push:deliver` with `unconfigured` and drops it, so
  // there is no way to tell "the bridge never sent one" from "the relay had
  // nowhere to put it" — which is exactly the distinction a push gate test rests
  // on. Inert for every eval that never registers a push token.
  const pushDeliveries: PushDelivery[] = [];
  const recordingSender = {
    async send(pushToken: string, data: Record<string, string>): Promise<"ok"> {
      pushDeliveries.push({ pushToken, epk: data.epk ?? "", box: data.box ?? "" });
      return "ok";
    },
  };

  const server = startServer(cfg, {
    licenseGate: fakeLicenseGate(),
    fcmSender: recordingSender,
    apnsSender: recordingSender,
  });

  return {
    port: opts.port,
    url: `ws://localhost:${opts.port}/ws`,
    httpUrl: `http://localhost:${opts.port}`,
    pushDeliveries() {
      return [...pushDeliveries];
    },
    connectionCount() {
      return server.connections.getConnectionCount();
    },
    streamCount() {
      // All eval devices share one account id, so counting that user's open
      // agent streams is the whole open-stream count.
      return server.connections.countOpenStreamsForUser(EVAL_USER_ID);
    },
    stop() {
      server.stop();
    },
  };
}

/**
 * Spawn an agent in **remote mode** by piping a `BootstrapPayload` to its
 * stdin (the contract in `bridge/src/index.ts`). The agent mints a token from
 * `licenseApiUrl`, then connects to `relayUrl` using `auth`'s Ed25519 keypair.
 * Polls for the API port file to confirm the agent is ready.
 */
export async function spawnAgent(opts: {
  relayUrl: string;
  licenseApiUrl: string;
  abDir: string;
  projectDir: string;
  auth: EvalAuth;
  /** Extra env vars (e.g. ANTGRID_EVAL_TEST=1 for pair-flow test hooks). */
  env?: Record<string, string>;
}): Promise<AgentHandle> {
  const payload = {
    machine: {
      relayUrl: opts.relayUrl,
      licenseApiUrl: opts.licenseApiUrl,
      auth: {
        clientId: opts.auth.clientId,
        clientSecret: opts.auth.clientSecret,
        ed25519Pub: opts.auth.ed25519Pub,
        ed25519Priv: opts.auth.ed25519Priv,
        x25519Pub: opts.auth.x25519Pub,
        x25519Priv: opts.auth.x25519Priv,
        deviceUuid: opts.auth.deviceUuid,
      },
    },
    firstProject: {
      projectId: computeProjectId(opts.projectDir),
      projectPath: opts.projectDir,
      mode: "remote" as const,
    },
  };

  const portFile = join(opts.abDir, "api.port");

  async function launch(): Promise<Subprocess> {
    const proc = Bun.spawn(
      ["bun", "run", resolve(ROOT, "bridge/src/index.ts")],
      {
        cwd: opts.projectDir,
        stdin: "pipe",
        stdout: "ignore",
        stderr: "ignore",
        env: {
          ...process.env,
          LOG_LEVEL: "error",
          ANTGRID_DIR: opts.abDir,
          ...opts.env,
        },
      },
    );

    // Hand the agent its bootstrap payload, then close stdin so
    // `readBootstrapPayload` (which reads until EOF) resolves.
    proc.stdin.write(JSON.stringify(payload) + "\n");
    await proc.stdin.end();

    // Poll for API port file — written by api-server.ts when agent is ready
    const deadline = Date.now() + 10_000;
    while (Date.now() < deadline) {
      if (proc.exitCode !== null) {
        throw new Error(`Agent process exited early with code ${proc.exitCode}`);
      }
      if (existsSync(portFile)) break;
      await Bun.sleep(100);
    }
    if (!existsSync(portFile)) {
      throw new Error("Timed out waiting for agent API port file");
    }
    return proc;
  }

  async function killProc(proc: Subprocess): Promise<void> {
    // On Windows `proc.kill()` doesn't reap the agent's PTY children (node
    // REPLs / echo terminals) — they orphan and accumulate across suites,
    // starving later agents until their pairing windows time out. Kill the
    // whole tree via taskkill before awaiting exit.
    if (process.platform === "win32") {
      const taskkill = `${process.env.SystemRoot ?? "C:\\Windows"}\\System32\\taskkill.exe`;
      try {
        Bun.spawnSync([taskkill, "/PID", String(proc.pid), "/T", "/F"]);
      } catch { /* best-effort */ }
    }
    proc.kill();
    await proc.exited;
  }

  const initialProc = await launch();

  const handle: AgentHandle = {
    port: 0,
    url: opts.relayUrl,
    process: initialProc,
    deviceUuid: opts.auth.deviceUuid,
    ed25519Pubkey: opts.auth.ed25519Pub,
    async kill() {
      await killProc(handle.process);
    },
    async restart() {
      await killProc(handle.process);
      // Drop the stale port file so `launch()`'s poll waits for the FRESH
      // process rather than racing the old value still on disk.
      try { rmSync(portFile, { force: true }); } catch { /* ignore */ }
      handle.process = await launch();
    },
    pairedPhones() {
      return loadPairedPhones(opts.abDir).list();
    },
  };
  return handle;
}

/** @deprecated Use spawnAgent instead */
export const spawnAgentForRelay = spawnAgent;

/**
 * Legacy compound relay registration id (`${deviceUuid}.${projectId}`). v3 has
 * no compound registration — the agent registers ONE socket as the bare
 * `deviceUuid` and projects are streams (design §7). Retained only for scenarios
 * still on the v2 per-project-socket shape (their migration to streams is X3).
 */
export function agentRegistrationId(deviceUuid: string, projectDir: string): string {
  return `${deviceUuid}.${computeProjectId(projectDir)}`;
}

/**
 * Retry the E2E handshake to absorb two startup races that have no ceremony
 * left to paper over them: the bridge's `TrustedPeersProvider` cache is empty
 * on the first unknown identity (a throttled background refresh warms it —
 * `noteMiss()`), and the relay's same-account presence fan-out (`peer-online`)
 * must reach the agent before its `client-hello` does. Both self-heal within a
 * few hundred ms, so a short retry loop on the ALREADY-authenticated socket
 * (no reconnect needed — unlike the old pair-request path, a failed handshake
 * attempt never closes the socket) is enough. Shared with
 * `gate-account-trust.test.ts` (imported, not duplicated) — keep the retry
 * constants in lockstep, since drift here shows up as intermittent eval flake.
 */
export async function handshakeWithoutPairing(
  app: RelayClient,
  agentDeviceId: string,
  agentEd25519Pub: string,
  opts: { attempts?: number; perAttemptTimeoutMs?: number; gapMs?: number } = {},
): Promise<void> {
  // `setupTestEnv` calls this with the default before its own STREAM_ADVERT_*
  // retry loop (~20 lines below), and gate-harness-pairfree wraps the whole
  // `setupTestEnv` call in a 30s bun:test timeout — so the two loops' worst
  // cases must fit together under that budget with room for the rest of
  // setup. STREAM_ADVERT's 12s worst case already assumes this loop is fast;
  // 6 * (2_000ms + 300ms) = 13.8s worst case leaves the remaining ~4s for
  // agent spawn, connect, and the test body itself.
  const attempts = opts.attempts ?? 6;
  const perAttemptTimeoutMs = opts.perAttemptTimeoutMs ?? 2_000;
  const gapMs = opts.gapMs ?? 300;
  let lastErr: unknown;
  for (let i = 0; i < attempts; i++) {
    try {
      app.setPeerId(agentDeviceId);
      await app.performE2EHandshake(agentDeviceId, perAttemptTimeoutMs, { agentEd25519Pub });
      return;
    } catch (err) {
      lastErr = err;
      await Bun.sleep(gapMs);
    }
  }
  throw new Error(
    `pair-free handshake with ${agentDeviceId} failed after ${attempts} attempts: ${String(lastErr)}`,
  );
}

export interface TestEnv {
  relay: RelayHandle;
  agent: AgentHandle;
  app: RelayClient;
  /** The account identity `app` connected with, registered with the fake
   *  account inventory (`startFakeLicenseApi({ accountDevices })`) — reuse it
   *  (via `TestApp.connect(env)`) to open additional admitted app connections
   *  against this same env. A different, never-registered identity cannot be
   *  admitted (the bridge's trust source is deviceId-keyed). */
  appIdentity: PhoneIdentity & { deviceId: string };
  /** This env's fake account/license API — `expireNextToken`/`addAccountDevice`/
   *  `revokeDevice` for the failure-matrix suites (token expiry, inventory
   *  miss, multi-machine revoke). */
  license: FakeLicenseApi;
  abDir: string;
  projectId: string;
  /** Absolute path to the temp project dir — lets a scenario write/read files the
   *  agent serves (e.g. seeding an oversize file for the fragmentation test). */
  projectDir: string;
  /** Bare machine `deviceUuid` — the id the app handshakes against (one machine
   *  socket; projects are streams). */
  agentDeviceId: string;
  /** Kill the current agent process and respawn a fresh one reusing the SAME
   *  `abDir`/`auth`/`projectDir` — the on-disk paired-phones row, the machine's
   *  mobile-access switch and the agent's deviceId/pubkey survive; only the
   *  process (and its relay epoch)
   *  is new. `env.agent` is NOT replaced in place (its deviceId/ed25519Pubkey
   *  are stable across a restart, so existing references stay valid); a
   *  caller that needs the fresh process handle's other fields should not
   *  rely on this method for that. */
  restartAgent(): Promise<void>;
  teardown(): Promise<void>;
}

export interface DartTestEnv {
  relay: RelayHandle;
  agent: AgentHandle;
  app: DartAppClient;
  abDir: string;
  projectDir: string;
  projectId: string;
  streamId: string;
  agentDeviceId: string;
  teardown(): Promise<void>;
}

export async function setupTestEnv(opts: {
  fixtureName: string;
  replacements?: Record<string, string>;
  /** Reuse an already-running relay instead of starting a fresh one — the
   *  multi-machine-slots row needs TWO real bridges live against the SAME
   *  relay (the pre-fix bug was specifically about the relay conflating two
   *  same-account connections). The owning env's `teardown()` stops the
   *  relay; a caller passing this must not also let the owning env's
   *  teardown race a still-in-use relay (tear this env down first). */
  relay?: RelayHandle;
  /** Extra agent env (e.g. the judge-script override for Task 16's Handler eval). */
  env?: Record<string, string>;
}): Promise<TestEnv> {
  const abDir = mkdtempSync(join(tmpdir(), "antgrid-eval-home-"));

  // Account trust (Phases A+B): the app admits with NO pairing ceremony, as
  // long as its identity is in the account's device inventory — seed the fake
  // license API with the SAME identity `app` connects as below.
  const appIdentity = await generateAppIdentity();

  const relay = opts.relay ?? (await startRelay({ port: allocatePort() }));
  const licenseApi = startFakeLicenseApi({
    accountDevices: [{ deviceId: appIdentity.deviceId, ed25519Pub: appIdentity.publicKeyBase64 }],
    relayInternalUrl: relay.httpUrl,
  });
  const auth = generateEvalAuth();

  const project = createTestProject(opts.fixtureName, {
    "__RELAY_URL__": relay.url.replace(/\/ws$/, ""),
    ...opts.replacements,
  });

  const agent = await spawnAgent({
    relayUrl: relay.url,
    licenseApiUrl: licenseApi.url,
    abDir,
    projectDir: project.dir,
    auth,
    env: { ANTGRID_EVAL_TEST: "1", ...opts.env },
  });

  const projectId = computeProjectId(project.dir);
  const deviceUuid = auth.deviceUuid;

  // A fresh machine is not mobile-reachable, and that switch is the only gate on
  // every project verb — flip it BEFORE the app connects, so the phone's first
  // advert already carries the catalog. Same ordering a real user gets: turn the
  // desktop switch on, then pick the machine up on the phone.
  await setMobileAccess(abDir, true);

  const app = await RelayClient.connectAndAuth(relay.url, {
    deviceType: "app",
    name: "eval-app",
    identity: appIdentity,
    deviceId: appIdentity.deviceId,
  });
  app.setPeerId(deviceUuid);
  await handshakeWithoutPairing(app, deviceUuid, auth.ed25519Pub);

  // Welcome-replay: pull the cached snapshot (agent:status/tree:full/git:status)
  // like the production app, instead of racing the agent's de-duped live burst.
  //
  // `state.snapshot` recomputes `agent:projects` fresh (host-server.ts's
  // `dispatchControlPlaneInbound`), but firstProject's auto-start (making its
  // core a registered relay stream, which is what makes it "dialable" and
  // gives it a streamId) is asynchronous and can still be in flight for a beat
  // after the E2E handshake establishes. The old pair-request round trip (and
  // its own AGENT_OFFLINE retries) incidentally absorbed this; the pair-free
  // path is fast enough to win the race and land before the project registers
  // — so poll until the advert actually carries a streamId for it. Once
  // dialable, it stays dialable for the rest of the test, so the final pull
  // below leaves a genuinely fresh advert queued for callers like
  // `firstProjectStream`.
  // Bounded well under the tightest caller timeout: gate-harness-pairfree's
  // guard test wraps setupTestEnv in a 30s bun:test timeout, and 20 attempts *
  // (2_000ms wait + 200ms gap) was a ~44s worst case — already past that
  // budget before the rest of setup/the test body runs a step. A fresh advert
  // lands within "a beat" of the E2E handshake (see the comment above), so a
  // much shorter per-attempt wait is enough; 15 * (700ms + 100ms) = 12s worst
  // case leaves ~18s of headroom under the 30s callers use.
  const STREAM_ADVERT_ATTEMPTS = 15;
  const STREAM_ADVERT_WAIT_MS = 700;
  const STREAM_ADVERT_GAP_MS = 100;
  let advertised = false;
  for (let i = 0; i < STREAM_ADVERT_ATTEMPTS; i++) {
    app.drainQueued("agent:projects");
    await app.pullStateSnapshot();
    const advert = await app.waitForAbType("agent:projects", STREAM_ADVERT_WAIT_MS).catch(() => null);
    if (advert?.projects.some((p) => p.projectId === projectId && p.streamId)) {
      advertised = true;
      break;
    }
    await Bun.sleep(STREAM_ADVERT_GAP_MS);
  }
  if (!advertised) {
    throw new Error(
      `no streamId advertised for project ${projectId} after ${STREAM_ADVERT_ATTEMPTS} attempts ` +
        `(~${STREAM_ADVERT_ATTEMPTS * (STREAM_ADVERT_WAIT_MS + STREAM_ADVERT_GAP_MS)}ms) — the agent's ` +
        `project stream never registered as dialable`,
    );
  }
  app.drainQueued("agent:projects");
  await app.pullStateSnapshot();

  return {
    relay,
    agent,
    app,
    appIdentity,
    license: licenseApi,
    abDir,
    projectId,
    projectDir: project.dir,
    agentDeviceId: deviceUuid,
    // Delegates to AgentHandle.restart() rather than re-spawning here: that
    // mutates `agent.process` in place instead of rebinding the closure-local
    // `agent` variable, so the `agent` this env object already captured stays
    // live instead of going stale after a restart.
    restartAgent() {
      return agent.restart();
    },
    async teardown() {
      await app.disconnect();
      await agent.kill();
      // A caller-supplied relay (opts.relay) is owned by whoever started it —
      // stopping it here would pull it out from under that env's own agent.
      if (!opts.relay) relay.stop();
      licenseApi.stop();
      project.cleanup();
      try { rmSync(abDir, { recursive: true, force: true }); } catch {}
    },
  };
}

/**
 * Same as setupTestEnv but spawns a DartAppClient (real Dart code via
 * `antgrid_eval_client` subprocess) instead of the in-process RelayClient.
 * Used to catch protocol drift between Dart and TS implementations.
 */
export async function setupDartTestEnv(opts: {
  fixtureName: string;
  replacements?: Record<string, string>;
  clientName?: string;
}): Promise<DartTestEnv> {
  const relayPort = allocatePort();
  const abDir = mkdtempSync(join(tmpdir(), "antgrid-eval-dart-"));
  const auth = generateEvalAuth();

  // Dart VM cold-start is slow (~3-10s). Spawn it in parallel with the relay
  // startup — the two are independent until `app.connect(relay.url)` — but the
  // fake license API needs the Dart client's OWN identity (learned only once
  // `create()` resolves) to admit it without pairing, so it starts after.
  const [relay, app] = await Promise.all([
    startRelay({ port: relayPort }),
    DartAppClient.create(opts.clientName ?? "eval-dart-app"),
  ]);
  const licenseApi = startFakeLicenseApi({
    accountDevices: [{ deviceId: app.deviceId, ed25519Pub: app.ed25519PublicKey }],
  });

  const project = createTestProject(opts.fixtureName, {
    "__RELAY_URL__": `ws://localhost:${relayPort}`,
    ...opts.replacements,
  });

  const agent = await spawnAgent({
    relayUrl: relay.url,
    licenseApiUrl: licenseApi.url,
    abDir,
    projectDir: project.dir,
    auth,
    env: { ANTGRID_EVAL_TEST: "1" },
  });

  const projectId = computeProjectId(project.dir);
  const deviceUuid = auth.deviceUuid;

  // The machine switch gates every project verb and starts off — flip it before
  // the Dart client connects (see setupTestEnv for the ordering rationale).
  await setMobileAccess(abDir, true);

  // v3: app hello now carries a mandatory license token (design §4.2); the Dart
  // eval CLI forwards it to RelayService.connect.
  await app.connect(relay.url, TEST_LICENSE_TOKEN);
  // Pair-free: the phone addresses the agent by the coordinates it already
  // holds (bare machine deviceUuid + pinned Ed25519 pub), because nothing hands
  // it a peer id any more.
  //
  // Retried for the same two startup races `handshakeWithoutPairing` documents
  // (cold TrustedPeersProvider cache, `peer-online` fan-out not yet delivered)
  // — both self-heal in a few hundred ms. The Dart driver runs exactly ONE
  // attempt per call and delegates give-up to the caller's supervisor, which
  // the eval CLI has none of, so without this loop a slow agent start is a
  // hard failure rather than a retryable one. Keep the budget in step with
  // `handshakeWithoutPairing`: 6 * (2_000 + 300) = 13.8s worst case.
  const HANDSHAKE_ATTEMPTS = 6;
  const HANDSHAKE_ATTEMPT_TIMEOUT_MS = 2_000;
  const HANDSHAKE_GAP_MS = 300;
  let handshakeErr: unknown;
  let established = false;
  for (let i = 0; i < HANDSHAKE_ATTEMPTS; i++) {
    try {
      await app.performHandshake(auth.ed25519Pub, deviceUuid, HANDSHAKE_ATTEMPT_TIMEOUT_MS);
      established = true;
      break;
    } catch (err) {
      handshakeErr = err;
      await Bun.sleep(HANDSHAKE_GAP_MS);
    }
  }
  if (!established) {
    throw new Error(
      `pair-free Dart handshake with ${deviceUuid} failed after ` +
        `${HANDSHAKE_ATTEMPTS} attempts: ${String(handshakeErr)}`,
    );
  }

  // Welcome-replay: pull the control-plane snapshot (the `agent:projects`
  // catalog) like the production app.
  await app.pullStateSnapshot();

  // v3: bind the firstProject stream every project verb rides. `project:start`
  // is also the promote trigger, so retry it — firstProject's auto-start can
  // still be in flight for a beat after the handshake establishes (same race
  // setupTestEnv polls the advert for; here bindProject's own `stream-ready`
  // wait absorbs it, and an UNKNOWN_PROJECT rejection — the catalog hint not
  // yet recorded — is what needs the outer retry).
  const STREAM_BIND_ATTEMPTS = 8;
  let streamId: string | undefined;
  let lastBindErr: unknown;
  for (let i = 0; i < STREAM_BIND_ATTEMPTS; i++) {
    try {
      streamId = await app.openProjectStream(projectId, 5_000);
      break;
    } catch (err) {
      lastBindErr = err;
      await Bun.sleep(500);
      app.drainQueued("agent:projects");
      await app.pullStateSnapshot();
    }
  }
  if (!streamId) {
    throw new Error(
      `Dart client never bound a stream for project ${projectId} after ` +
        `${STREAM_BIND_ATTEMPTS} attempts: ${String(lastBindErr)}`,
    );
  }
  // Per-project durable state (agent:status / tree:full / git:status) lives on
  // the stream, not the control plane — pull it the way a ProjectSession does.
  await app.pullStateSnapshot(streamId);

  return {
    relay,
    agent,
    app,
    abDir,
    projectDir: project.dir,
    projectId,
    streamId,
    agentDeviceId: deviceUuid,
    async teardown() {
      await app.disconnect();
      await agent.kill();
      relay.stop();
      licenseApi.stop();
      project.cleanup();
      try { rmSync(abDir, { recursive: true, force: true }); } catch {}
    },
  };
}
