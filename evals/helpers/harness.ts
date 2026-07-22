import { type Subprocess } from "bun";
import { resolve, join } from "node:path";
import { mkdtempSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { generateKeyPairSync, randomUUID } from "node:crypto";
import { createTestProject } from "./fixtures";
import { RelayClient } from "./relay-client";
import { DartAppClient } from "./dart-app-client";
import { computeProjectId } from "../../bridge/src/project-id";
import { loadPairedPhones } from "../../bridge/src/paired-phones";

const ROOT = resolve(import.meta.dir, "../..");

/**
 * Phase B: a freshly-paired phone has an EMPTY per-project allowlist, so the
 * agent-core gate silently DROPS every project verb until the project is
 * explicitly allowed for that phone (spec: machine-level-trust-design.md
 * §28-31, §96-100, §167-168). The legacy scenario tests pair-and-drive without
 * allowlisting, so this models "a phone that has been granted access" by
 * allowing `projectId` for every paired phone in the machine store.
 *
 * The host watches paired-phones.json via fs.watch (50ms debounce) and reloads
 * its in-memory view, so we write through a store on the SAME abDir and give the
 * watcher a beat to propagate before driving verbs — mirroring machine-trust.test.ts.
 */
async function allowProjectForPairedPhones(abDir: string, projectId: string): Promise<void> {
  const store = loadPairedPhones(abDir);
  const phones = store.list();
  for (const phone of phones) {
    store.allowProject(phone.phonePubkey, projectId);
  }
  // Give the host's fs.watch debounce (50ms) time to reload the allowlist.
  await Bun.sleep(400);
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
}

export interface RelayHandle {
  port: number;
  url: string;
  httpUrl: string;
  /** Live relay connection count (past hello). X3's drill-in test asserts zero
   *  additional connections; the multi-stream test asserts one per side. */
  connectionCount(): number;
  /** Open project streams across all eval agent connections (sessionLimit
   *  denominator). */
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

/** Fixed account id every eval device shares. sessionLimit is counted per this
 *  uid across all agent streams, so the X4 cap test can drive it deterministically. */
const EVAL_USER_ID = "eval-user";

/**
 * Fake v3 LicenseGate. Accepts any non-empty token (agents and apps alike —
 * v3 requires a token for BOTH, design §4.2) and returns a fixed uid. The
 * `sessionLimit` claim is what the relay enforces at `stream-open` admission;
 * it defaults high enough that a spawned agent can attach its firstProject
 * stream, and the X4 cap test overrides it (e.g. `sessionLimit: 2`).
 */
function fakeLicenseGate(opts: { sessionLimit?: number } = {}) {
  const sessionLimit = opts.sessionLimit ?? 100;
  const entryFor = (deviceId: string) => ({
    jti: `eval-jti-${deviceId}`,
    deviceId,
    userId: EVAL_USER_ID,
    tier: "pro" as const,
    sessionLimit,
    expiresAt: Date.now() + 3600_000,
    revoked: false,
  });
  return {
    async verify(token: string, deviceId: string) {
      if (!token) return { ok: false as const, code: "LICENSE_INVALID" as const };
      return { ok: true as const, entry: entryFor(deviceId) };
    },
    // v3 apps present their own account token; the fake accepts TEST_LICENSE_TOKEN
    // and returns a fixed uid so the grant/session accounting has an account id.
    async verifyAppToken(token: string) {
      if (!token) return { ok: false as const, code: "LICENSE_INVALID" as const };
      return { ok: true as const, entry: entryFor(`app-${EVAL_USER_ID}`) };
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
}

/**
 * Minimal stand-in for `web`'s OAuth + heartbeat endpoints. The agent in
 * remote mode mints an access token (`POST /api/auth/oauth2/token`) before
 * connecting to the relay, then POSTs a heartbeat on authenticate. The relay's
 * `fakeLicenseGate` accepts any non-empty token, so we return a fixed one and
 * 200 everything else (the heartbeat is best-effort on the agent side).
 *
 * For the account-membership auto-pair path, the agent fetches its account's
 * enrolled app-device key set from `GET /account/devices/me/peers` over this
 * same Bearer channel (see `bridge/src/account-peers.ts`). Pass
 * `opts.accountPeerKeys` to seed a known key set; absent → empty set.
 */
export function startFakeLicenseApi(opts: { accountPeerKeys?: string[] } = {}): FakeLicenseApi {
  const peerKeys = opts.accountPeerKeys ?? [];
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
      // `GET /account/devices/me/peers` → `{ keys: string[] }`.
      if (url.pathname === "/account/devices/me/peers") {
        return Response.json({ keys: peerKeys });
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
  };
}

export async function startRelay(opts: {
  port: number;
  pairRequestTimeoutMs?: number;
  /** ± window a hello `ts` may deviate from server time (default 120s). The R
   *  skew forge test lands `skewTsMs` outside this. */
  clockSkewMs?: number;
  /** `(deviceId, nonce)` hello replay TTL (default 5min). */
  replayTtlMs?: number;
  /** Idle age (days) after which an unused grant is swept (default 30). */
  staleGrantDays?: number;
  /** Per-connection JSON-control message rate (default generous; the X3
   *  JSON-flood test lowers it to force MESSAGE_RATE_LIMITED). */
  jsonRateLimitPerSec?: number;
  jsonRateLimitBurst?: number;
  /** Per-pair binary/message frame rate (default generous). */
  rateLimitMsgPerSec?: number;
  /** Paid-axis cap injected into the fake license gate's `sessionLimit` claim.
   *  X4's cap test passes `2`. Default 100 (spawned agents attach streams). */
  sessionLimit?: number;
}): Promise<RelayHandle> {
  const { startServer } = await import(
    resolve(ROOT, "relay/src/server.ts")
  );
  const server = startServer(
    {
      port: opts.port,
      maxConnections: 100,
      rateLimitConnPerIp: 10,
      pairRequestTimeoutMs: opts.pairRequestTimeoutMs ?? 5_000,
      pairRateLimitPerIp: 20,
      rateLimitMsgPerSec: opts.rateLimitMsgPerSec ?? 100,
      jsonRateLimitPerSec: opts.jsonRateLimitPerSec ?? 100,
      jsonRateLimitBurst: opts.jsonRateLimitBurst ?? 200,
      clockSkewMs: opts.clockSkewMs ?? 120_000,
      replayTtlMs: opts.replayTtlMs ?? 300_000,
      staleGrantDays: opts.staleGrantDays ?? 30,
      pingIntervalMs: 30_000,
      pongTimeoutMs: 10_000,
      logLevel: "error",
      licenseApiUrl: "http://license-api.eval",
      relayInternalSecret: "x".repeat(16),
      licenseCacheMaxEntries: 1000,
    },
    { licenseGate: fakeLicenseGate({ sessionLimit: opts.sessionLimit }) },
  );

  return {
    port: opts.port,
    url: `ws://localhost:${opts.port}/ws`,
    httpUrl: `http://localhost:${opts.port}`,
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
  const portFile = join(opts.abDir, "api.port");
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

  return {
    port: 0,
    url: opts.relayUrl,
    process: proc,
    deviceUuid: opts.auth.deviceUuid,
    ed25519Pubkey: opts.auth.ed25519Pub,
    async kill() {
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
    },
  };
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

/** Raw 32-byte base64 of an Ed25519 SPKI public key (the agent's account-peer-key
 *  encoding), used to seed the QR-less account-membership pair path. */
function rawEdPubB64(pub: import("node:crypto").KeyObject): string {
  const der = pub.export({ format: "der", type: "spki" });
  return Buffer.from(der.subarray(der.length - 32)).toString("base64");
}

/**
 * Pair an app with the agent, retrying to absorb the startup race: the agent
 * writes `api.port` BEFORE it finishes authenticating to the relay, so an early
 * `pair-request` targets an agent the relay hasn't seen yet → typed
 * `error{AGENT_OFFLINE, retryable}` (v3 keeps the socket open; a bare close is
 * the fallback). `PairAgentOfflineError` marks the retryable miss; `reconnect`
 * re-arms the socket only if the fallback close fired.
 */
async function pairWithRetry(
  abDir: string,
  agentDeviceId: string,
  pair: () => Promise<void>,
  opts: { attempts?: number; gapMs?: number; reconnect?: () => Promise<void> } = {},
): Promise<void> {
  const attempts = opts.attempts ?? 8;
  let lastErr: unknown;
  for (let i = 0; i < attempts; i++) {
    try {
      // Re-arm a live socket before every retry (a prior AGENT_OFFLINE may have
      // closed it as a fallback). No-op before the first attempt.
      if (i > 0 && opts.reconnect) await opts.reconnect();
      await pair();
      return;
    } catch (err) {
      lastErr = err;
      await Bun.sleep(opts.gapMs ?? 300);
    }
  }
  throw new Error(`pairing ${agentDeviceId} failed after ${attempts} attempts: ${String(lastErr)}`);
}

export interface TestEnv {
  relay: RelayHandle;
  agent: AgentHandle;
  app: RelayClient;
  abDir: string;
  projectId: string;
  /** Absolute path to the temp project dir — lets a scenario write/read files the
   *  agent serves (e.g. seeding an oversize file for the fragmentation test). */
  projectDir: string;
  /** Bare machine `deviceUuid` — the id the app pairs/handshakes against in v3
   *  (one machine socket; projects are streams). */
  agentDeviceId: string;
  teardown(): Promise<void>;
}

export interface DartTestEnv {
  relay: RelayHandle;
  agent: AgentHandle;
  app: DartAppClient;
  abDir: string;
  projectDir: string;
  projectId: string;
  agentDeviceId: string;
  teardown(): Promise<void>;
}

export async function setupTestEnv(opts: {
  fixtureName: string;
  replacements?: Record<string, string>;
}): Promise<TestEnv> {
  const relayPort = allocatePort();
  const abDir = mkdtempSync(join(tmpdir(), "antgrid-eval-home-"));

  // v3 pairs the ONE machine socket (bare deviceUuid) on the control plane; the
  // control plane has no test pairing-window hook, so admit via the QR-less
  // account-membership proof (design §5.1) — seed the fake account peer set.
  const accountKp = generateKeyPairSync("ed25519");
  const accountPubB64 = rawEdPubB64(accountKp.publicKey);

  const relay = await startRelay({ port: relayPort, pairRequestTimeoutMs: 15_000 });
  const licenseApi = startFakeLicenseApi({ accountPeerKeys: [accountPubB64] });
  const auth = generateEvalAuth();

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

  const app = await RelayClient.connectAndAuth(relay.url, { deviceType: "app", name: "eval-app" });
  await pairWithRetry(
    abDir,
    deviceUuid,
    async () => {
      const pairResult = await app.pairWith(deviceUuid, {
        timeoutMs: 8_000,
        accountKey: { pubB64: accountPubB64, privateKey: accountKp.privateKey },
      });
      app.setPeerId(pairResult.peerId);
    },
    { reconnect: () => (app.isClosed ? app.reconnectAndAuth(relay.url) : Promise.resolve()) },
  );

  await app.performE2EHandshake(deviceUuid, 10_000, {
    agentEd25519Pub: auth.ed25519Pub,
  });

  // Phase B: grant the just-paired phone access to this project (see helper).
  await allowProjectForPairedPhones(abDir, projectId);

  // Welcome-replay: pull the cached snapshot (agent:status/tree:full/git:status)
  // like the production app, instead of racing the agent's de-duped live burst.
  await app.pullStateSnapshot();

  return {
    relay,
    agent,
    app,
    abDir,
    projectId,
    projectDir: project.dir,
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
  const accountKp = generateKeyPairSync("ed25519");
  const accountPubB64 = rawEdPubB64(accountKp.publicKey);
  const licenseApi = startFakeLicenseApi({ accountPeerKeys: [accountPubB64] });
  const auth = generateEvalAuth();

  // Dart VM cold-start is slow (~3-10s). Spawn it in parallel with the relay
  // startup since the two are independent until `app.connect(relay.url)`.
  const [relay, app] = await Promise.all([
    startRelay({ port: relayPort, pairRequestTimeoutMs: 15_000 }),
    DartAppClient.create(opts.clientName ?? "eval-dart-app"),
  ]);

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

  // v3: app hello now carries a mandatory license token (design §4.2); the Dart
  // eval CLI forwards it to RelayService.connect. NOTE: the Dart CLI's `pair`
  // action does not yet support the account-membership proof, so pairing against
  // the bare-deviceUuid control plane is not yet reachable from the Dart client
  // (an eval-CLI gap, not a relay/bridge one).
  await app.connect(relay.url, TEST_LICENSE_TOKEN);
  await pairWithRetry(abDir, deviceUuid, () => app.pairWith(deviceUuid, { timeoutMs: 8_000 }));
  await app.performHandshake(auth.ed25519Pub);

  // Phase B: grant the just-paired phone access to this project (see helper).
  await allowProjectForPairedPhones(abDir, projectId);

  // Welcome-replay: pull the cached snapshot like the production app.
  await app.pullStateSnapshot();

  return {
    relay,
    agent,
    app,
    abDir,
    projectDir: project.dir,
    projectId,
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
