import { test, expect, beforeEach, afterEach, spyOn } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  generateKeyPairSync,
  sign,
  type KeyObject,
} from "node:crypto";
import { HostServer, type HostRemoteConfig, type RemoteRuntime } from "../src/host-server";
import { MessageBus } from "../src/message-bus";
import { createMessage } from "../src/protocol";
import { handleInboundPairRequest } from "../src/relay-client";
import { loadPairedPhones } from "../src/paired-phones";
import { createPairingWindow } from "../src/pairing-window";
import { buildPairRequestSigBody } from "../src/pair-request-verify";
// The REAL relay-side verifier. Imported at runtime via a specifier tsc cannot
// statically resolve, so bridge's `tsc --noEmit` (rootDir = bridge) does not try
// to pull relay sources under its rootDir — while the test still exercises the
// production verifier. This is the load-bearing security assertion: the approval
// bytes signed over a bare deviceUuid must verify with the real relay verifier.
type PairApprovalVerifier = (args: {
  agentEd25519Pubkey: string;
  agentDeviceId: string;
  approval: { phonePubkey: string; phoneDeviceId: string; nonce: string; expiresAt: string; signature: string };
  expectedNonce: string;
}) => { ok: boolean };
const relayVerifyPath = ["..", "..", "relay", "src", "pair-verify"].join("/");
const verifyPairApproval = (
  (await import(relayVerifyPath)) as { verifyPairApproval: PairApprovalVerifier }
).verifyPairApproval;

// --- shared fakes (mirror host-server.test.ts) -----------------------------

function fakeRemoteConfig(): HostRemoteConfig {
  return {
    relayUrl: "ws://127.0.0.1:1",
    licenseApiUrl: "http://127.0.0.1:1",
    identity: { deviceId: "dev-1", deviceName: "dev-1", createdAt: "2026-01-01T00:00:00.000Z" },
    auth: { clientId: "cid", clientSecret: "secret", deviceUuid: "uuid-1" },
    onAuthRevoked: () => {},
  };
}

function fakeRuntime(): RemoteRuntime {
  return { maint: { getToken: () => "tok", stop: () => {} }, getAccountPeerKeys: async () => new Set<string>() };
}

let host: HostServer | null = null;

// Isolate ANTGRID_DIR so startControlPlane() / paired-phones store write to a
// temp dir, never the real ~/.antgrid (mirrors host-server.test.ts).
let prevAbDir: string | undefined;
let abDir: string | undefined;

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-cp-abdir-"));
  process.env.ANTGRID_DIR = abDir;
});

afterEach(async () => {
  await host?.shutdown();
  host = null;
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR; else process.env.ANTGRID_DIR = prevAbDir;
  if (abDir) rmSync(abDir, { recursive: true, force: true });
});

test("opens one control-plane registration equal to the bare deviceUuid", async () => {
  host = new HostServer({
    remote: fakeRemoteConfig(),
    remoteRuntimeFactory: () => Promise.resolve(fakeRuntime()),
  });
  await host.startControlPlane();
  // The control-plane relay registers with the BARE deviceUuid — no projectId
  // suffix — so its registrationId is exactly the deviceUuid.
  expect(host.controlPlaneRegistrationId).toBe("uuid-1");
  await host.shutdown();
  host = null;
  expect(true).toBe(true);
});

test("control plane heartbeats the current relayUrl on authenticate (keeps inventory fresh)", async () => {
  // The always-on control plane is the registration a phone's autoOpen dials, so
  // it must publish the CURRENT relay_url to the account inventory — else a
  // machine whose LAN IP changed keeps advertising a dead address and the phone
  // can never reach it (the bug this guards). RelayClient fires onAuthenticated
  // on every (re)connect; here we invoke that wired closure directly (no live
  // relay) and assert the heartbeat POST carries the configured relayUrl.
  const calls: Array<{ url: string; body: any }> = [];
  const fetchSpy = spyOn(globalThis, "fetch").mockImplementation((async (
    input: any,
    init: any,
  ) => {
    calls.push({ url: String(input), body: JSON.parse(init?.body ?? "{}") });
    return new Response(null, { status: 200 });
  }) as unknown as typeof fetch);
  try {
    host = new HostServer({
      remote: fakeRemoteConfig(),
      remoteRuntimeFactory: () => Promise.resolve(fakeRuntime()),
    });
    await host.startControlPlane();

    // Invoke the onAuthenticated closure built in startRemoteControlPlane.
    const client = (host as any).controlPlaneRelay;
    expect(client).not.toBeNull();
    await client.opts.onAuthenticated();

    const hb = calls.find((c) => c.url.endsWith("/account/devices/me/heartbeat"));
    expect(hb).toBeDefined();
    expect(hb!.body.deviceUuid).toBe("uuid-1");
    expect(hb!.body.relayUrl).toBe(fakeRemoteConfig().relayUrl);
    // Fresh ANTGRID_DIR → no project has been enabled for mobile access yet, so
    // the reported flag must be false (not the old hardcoded-true).
    expect(hb!.body.mobileAccessEnabled).toBe(false);
  } finally {
    fetchSpy.mockRestore();
  }
});

test("mobile-access:enable-project immediately pushes a heartbeat reflecting the new state", async () => {
  // Regression test: toggling mobile access on used to only mutate local state
  // (mobile-access-policy.json) and never told the account inventory — the DB's
  // relayUrl/mobileAccessEnabled stayed stale until an unrelated relay reconnect.
  const calls: Array<{ url: string; body: any }> = [];
  const fetchSpy = spyOn(globalThis, "fetch").mockImplementation((async (
    input: any,
    init: any,
  ) => {
    calls.push({ url: String(input), body: JSON.parse(init?.body ?? "{}") });
    return new Response(null, { status: 200 });
  }) as unknown as typeof fetch);
  try {
    host = new HostServer({
      remote: fakeRemoteConfig(),
      remoteRuntimeFactory: () => Promise.resolve(fakeRuntime()),
    });
    await host.startControlPlane();
    calls.length = 0; // drop the connect-time heartbeat; only the toggle-driven one matters

    const res = await host.handleMobileAccessVerb({
      id: "req-1",
      type: "mobile-access:enable-project",
      projectId: "proj-1",
    } as any);
    expect(res.ok).toBe(true);

    const hb = calls.find((c) => c.url.endsWith("/account/devices/me/heartbeat"));
    expect(hb).toBeDefined();
    expect(hb!.body.mobileAccessEnabled).toBe(true);
  } finally {
    fetchSpy.mockRestore();
  }
});

test("onPeerOnline re-advertises to the recovered peer (bridge-side reconnect, phone never dropped)", async () => {
  // Regression test: a bridge-side reconnect to the RELAY (heartbeat lapse,
  // network blip on THIS machine) clears RelayClient's internal peerId for the
  // gap, with no visible disconnect on the phone's side (it never resends
  // client-hello, so onHandshakeComplete doesn't re-fire either). Any
  // readvertiseToControlPlane() call that raced that gap (e.g. a desktop
  // mobile-access toggle) used to silently no-op on the then-null peer id,
  // with nothing to correct it until an unrelated project:start forced a full
  // recompute. onPeerOnline now re-advertises the moment the peer id is
  // restored, closing that window.
  host = new HostServer({
    remote: fakeRemoteConfig(),
    remoteRuntimeFactory: () => Promise.resolve(fakeRuntime()),
  });
  await host.startControlPlane();

  const client = (host as any).controlPlaneRelay;
  const bus = (host as any).controlPlaneBus as MessageBus;
  expect(client).not.toBeNull();

  host.pairedPhones.upsert({
    phonePubkey: "pub-1",
    phoneDeviceId: "phone-1",
    pairedAt: "x",
    lastSeenAt: "x",
    admission: "same-account",
    allowedProjects: ["proj-1"],
  });

  const delivered: any[] = [];
  bus.subscribe({ deliver: (msg) => delivered.push(msg) });

  // Simulate what relay-client.ts's `peer-online` handler does before invoking
  // the callback: restore _peerId (→ phonePubkey via phoneEd25519ByDeviceId),
  // THEN fire onPeerOnline — mirrors relay-client.ts:557-571.
  (client as any)._peerId = "phone-1";
  (client as any).phoneEd25519ByDeviceId.set("phone-1", "pub-1");
  client.opts.onPeerOnline?.("phone-1");

  const advert = delivered.find((m) => m.type === "agent:projects");
  expect(advert).toBeDefined();
});

test("no remote config → no control-plane relay opened", async () => {
  host = new HostServer({}); // local-only
  await host.startControlPlane();
  expect(host.controlPlaneRegistrationId).toBeNull();
});

// Build a standalone HostServer with just the fields the control-plane advert
// recompute reads — no live relay/runtime. `phone` is the paired-phone record
// `pairedPhonesStore.get(pk)` returns (undefined → unknown phone → empty advert).
function standaloneForSnapshot(opts: {
  phone?: { allowedProjects: string[] } | undefined;
  seen?: Array<[string, { path: string; label: string; lastActiveAt: string }]>;
}): HostServer {
  const standalone = Object.create(HostServer.prototype) as HostServer;
  (standalone as any).pairedPhonesStore = { get: () => opts.phone };
  (standalone as any).seenProjects = new Map(opts.seen ?? []);
  (standalone as any).cores = new Map();
  // sendProjectsAdvertisement reads the same-account defaults (for its debug log
  // and the advert); stub it so the advert recompute doesn't deref undefined.
  (standalone as any).mobileAccessPolicy = { listSameAccountDefaultProjects: () => [] };
  return standalone;
}

// The app's RelayTransport.connect() fires a `state.snapshot` RPC to seed its
// replay cache. The control-plane bus must answer it (like the data plane) or
// the durable handshake adverts (agent:tools / agent:projects) never reach a
// late-subscribing ControlPlaneClient and the first picker render shows no tools.
test("control-plane state.snapshot answers with both advert types (welcome-replay)", async () => {
  const standalone = standaloneForSnapshot({ phone: undefined });
  const bus = new MessageBus();
  // A stale empty projects frame from the handshake push (REPLAY_TYPES → cached).
  bus.publish(createMessage("agent:projects", { projects: [] }), "control");

  const delivered: any[] = [];
  bus.subscribe({ deliver: (m) => delivered.push(m) });

  const req = createMessage("request", {
    requestId: "r0",
    method: "state.snapshot",
    params: { types: ["*"] },
  });
  standalone.dispatchControlPlaneInbound(req as any, "control", "phone-pub", bus);
  await new Promise((r) => setTimeout(r, 0)); // flush dispatchRpc microtask

  const res = delivered.find((m) => m.type === "response") as any;
  expect(res?.ok).toBe(true);
  expect(res.requestId).toBe("r0");
  const types = (res.result.frames as any[]).map((f) => f.type).sort();
  expect(types).toEqual(["agent:projects", "agent:tools"]);
});

// The bug: the handshake push can run before this phone's allowlist/catalog is
// ready, caching an empty `agent:projects`. The snapshot pull must RECOMPUTE so
// a project that became visible after the push still reaches the phone — replay
// alone (plus the bus's payload-dedup) would echo the empty frame forever.
test("control-plane state.snapshot RECOMPUTES projects (project visible after the empty handshake push appears)", async () => {
  const standalone = standaloneForSnapshot({
    phone: { allowedProjects: ["proj-1"] },
    seen: [["proj-1", { path: "/p/proj-1", label: "proj-1", lastActiveAt: "2026-01-01T00:00:00.000Z" }]],
  });
  const bus = new MessageBus();
  // Simulate the empty handshake push that the replay-only path would be stuck on.
  bus.publish(createMessage("agent:projects", { projects: [] }), "control");

  const delivered: any[] = [];
  bus.subscribe({ deliver: (m) => delivered.push(m) });

  const req = createMessage("request", {
    requestId: "r1",
    method: "state.snapshot",
    params: { types: ["agent:projects"] },
  });
  standalone.dispatchControlPlaneInbound(req as any, "control", "phone-pub", bus);
  await new Promise((r) => setTimeout(r, 0));

  const res = delivered.find((m) => m.type === "response") as any;
  expect(res?.ok).toBe(true);
  const projectsFrame = (res.result.frames as any[]).find((f) => f.type === "agent:projects");
  expect(projectsFrame.projects.map((p: any) => p.projectId)).toEqual(["proj-1"]);
});

// --- pair-approval over the bare deviceUuid round-trip ---------------------
// Proves the trust bytes round-trip with agentDeviceId = a BARE deviceUuid:
// the real relay verifier accepts the approval, and rejects it under a
// different agentDeviceId (negative control). No relay/host is stood up — only
// the pure signing + verify helpers are exercised.

const ED25519_PKCS8_PREFIX = Buffer.from("302e020100300506032b657004220420", "hex");

function makePhoneKp() {
  const kp = generateKeyPairSync("ed25519");
  const spki = kp.publicKey.export({ type: "spki", format: "der" }) as Buffer;
  const phonePubkey = spki.subarray(spki.length - 32).toString("base64");
  return { kp, phonePubkey };
}

/** A real agent Ed25519 keypair, exposed as the raw 32-byte seed (what
 *  handleInboundPairRequest signs with) and the raw 32-byte public key (what
 *  verifyPairApproval checks against). */
function makeAgentKp() {
  const kp = generateKeyPairSync("ed25519");
  const pkcs8 = kp.privateKey.export({ type: "pkcs8", format: "der" }) as Buffer;
  const seed = pkcs8.subarray(pkcs8.length - 32); // raw 32-byte Ed25519 seed
  const spki = kp.publicKey.export({ type: "spki", format: "der" }) as Buffer;
  const pubB64 = spki.subarray(spki.length - 32).toString("base64");
  return { seed, pubB64 };
}

function signRequest(opts: {
  kp: { publicKey: KeyObject; privateKey: KeyObject };
  phonePubkey: string;
  agentDeviceId: string;
  phoneDeviceId: string;
  nonce: string;
}): { requestedAt: string; phoneSignature: string } {
  const requestedAt = new Date().toISOString();
  const body = buildPairRequestSigBody({
    agentDeviceId: opts.agentDeviceId,
    phonePubkey: opts.phonePubkey,
    phoneDeviceId: opts.phoneDeviceId,
    nonce: opts.nonce,
    requestedAt,
  });
  const phoneSignature = sign(null, body, opts.kp.privateKey).toString("base64");
  return { requestedAt, phoneSignature };
}

test("pair-approval signed over the bare deviceUuid verifies (and fails for a different id)", async () => {
  const dir = mkdtempSync(join(tmpdir(), "antgrid-cp-pair-"));
  try {
    const deviceUuid = "uuid-1"; // bare control-plane registration id
    const phones = loadPairedPhones(dir);
    const win = createPairingWindow();
    const { code } = win.open();
    const { kp, phonePubkey } = makePhoneKp();
    const agent = makeAgentKp();
    const nonce = Buffer.alloc(16, 7).toString("base64");
    const sig = signRequest({
      kp,
      phonePubkey,
      agentDeviceId: deviceUuid,
      phoneDeviceId: "phone-1",
      nonce,
    });

    const sent: any[] = [];
    await handleInboundPairRequest({
      msg: {
        type: "pair-request",
        agentDeviceId: deviceUuid,
        pairId: "pair-test",
        phonePubkey,
        phoneDeviceId: "phone-1",
        nonce,
        requestedAt: sig.requestedAt,
        phoneSignature: sig.phoneSignature,
        pairCode: code,
        label: "iPhone",
      },
      pairedPhones: phones,
      pairingWindow: win,
      agentDeviceId: deviceUuid,
      agentEd25519Priv: agent.seed,
      send: (m) => sent.push(m),
    });

    expect(sent.length).toBe(1);
    expect(sent[0].type).toBe("pair-approval");
    const approval = sent[0];

    // REAL relay verifier accepts the approval bound to the bare deviceUuid.
    const good = verifyPairApproval({
      agentEd25519Pubkey: agent.pubB64,
      agentDeviceId: deviceUuid,
      approval,
      expectedNonce: nonce,
    });
    expect(good.ok).toBe(true);

    // Negative control: a different agentDeviceId must NOT verify.
    const bad = verifyPairApproval({
      agentEd25519Pubkey: agent.pubB64,
      agentDeviceId: "uuid-DIFFERENT",
      approval,
      expectedNonce: nonce,
    });
    expect(bad.ok).toBe(false);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
