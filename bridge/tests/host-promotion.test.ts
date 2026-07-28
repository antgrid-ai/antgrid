import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostServer, type HostRemoteConfig, type RemoteRuntime } from "../src/host-server";
import { MessageBus } from "../src/message-bus";
import type { RelayClient, RelayClientOptions } from "../src/relay-client";
import type { AttachStreamOpts } from "../src/stream-mux";

// --- shared fakes (mirror control-plane-start.test.ts) ---------------------

function fakeRemoteConfig(): HostRemoteConfig {
  return {
    relayUrl: "ws://127.0.0.1:1",
    licenseApiUrl: "http://127.0.0.1:1",
    identity: { deviceId: "dev-1", deviceName: "dev-1", createdAt: "2026-01-01T00:00:00.000Z" },
    auth: { clientId: "cid", clientSecret: "secret", deviceUuid: "uuid-1" },
    onAuthRevoked: () => {},
  };
}

// The shared machine runtime is the ONLY token source on the promote path
// (promote constructs no OAuthClient). `getToken` counts consults; the factory
// is wrapped so the test can assert exactly one runtime is ever built.
let factoryCalls = 0;
function makeCountingFactory(): { factory: () => Promise<RemoteRuntime>; tokenCalls: () => number } {
  let tokenCalls = 0;
  return {
    factory: () => {
      factoryCalls++;
      return Promise.resolve({
        maint: { getToken: () => { tokenCalls++; return "tok"; }, stop: () => {} },
      });
    },
    tokenCalls: () => tokenCalls,
  };
}

// A machine-relay-client stub whose promoted stream is rejected by the relay
// gate the instant it attaches — the account is at its concurrent remote-agent
// cap. Mirrors the real relay `error{ref}` (server.ts) → StreamMux `onRejected`
// (design §7.3: a rejected stream-open leaves the socket and every other
// stream live — there is no more per-registration terminal-close outcome).
function makeSessionLimitedRelayFactory(code = "SESSION_LIMIT_EXCEEDED") {
  return (_opts: RelayClientOptions): RelayClient =>
    ({
      deviceId: "control-plane-dev",
      currentPeerPubkey: () => null,
      setBus: () => {},
      connect: () => {},
      close: () => {},
      attachStream: (_bus: MessageBus, streamOpts: AttachStreamOpts) => {
        streamOpts.onRejected?.(code, "Concurrent remote agent limit reached (0). Close another session or upgrade your plan.");
        return { streamId: "s1", detach: () => {}, sendTunnel: () => {} };
      },
      sendPushDeliver: () => {},
    }) as unknown as RelayClient;
}

// A machine-relay-client stub whose promoted stream is admitted the instant it
// attaches — the relay gate accepted the stream-open. Mirrors StreamMux firing
// `onAdmitted` on `stream-opened`, which is what flips ProjectCore's
// isRelayRegistered() true.
function makeAuthenticatingRelayFactory() {
  return (_opts: RelayClientOptions): RelayClient =>
    ({
      deviceId: "control-plane-dev",
      currentPeerPubkey: () => null,
      setBus: () => {},
      connect: () => {},
      close: () => {},
      attachStream: (_bus: MessageBus, streamOpts: AttachStreamOpts) => {
        streamOpts.onAdmitted?.("s1");
        return { streamId: "s1", detach: () => {}, sendTunnel: () => {} };
      },
      sendPushDeliver: () => {},
    }) as unknown as RelayClient;
}

let host: HostServer | null = null;
let prevAbDir: string | undefined;
let abDir: string | undefined;

function tempFolder(): string {
  const f = mkdtempSync(join(tmpdir(), "antgrid-promo-proj-"));
  writeFileSync(join(f, "antgrid.yaml"), "name: test-remote\nagent:\n  tool: claude-code\n");
  return f;
}

beforeEach(() => {
  factoryCalls = 0;
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-promo-abdir-"));
  process.env.ANTGRID_DIR = abDir;
});

afterEach(async () => {
  await host?.shutdown();
  host = null;
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR; else process.env.ANTGRID_DIR = prevAbDir;
  if (abDir) rmSync(abDir, { recursive: true, force: true });
});

test("project:start promotes an already-open LOCAL core via the ONE shared runtime", async () => {
  const { factory } = makeCountingFactory();
  host = new HostServer({ remote: fakeRemoteConfig(), remoteRuntimeFactory: factory });
  const h = host;

  // Open projX LOCAL — a local core never builds the machine remote runtime.
  const opened = await h.open("projX", tempFolder(), "local");
  expect(h.isPromoted("projX")).toBe(false);
  expect(factoryCalls).toBe(0); // local open builds NO runtime
  // Capture the loopback endpoint BEFORE promotion. Promotion adds an ADDITIVE
  // relay slot to the existing bus — it must NOT close+reopen the core, so the
  // loopback port+token must survive unchanged (regression guard for the
  // additive-not-replace invariant).
  const loopbackBefore = opened.connect;
  expect(loopbackBefore).not.toBeNull();

  // Admit the phone for projX.
  h.pairedPhones.upsert({
    phonePubkey: "pk1",
    phoneDeviceId: "d1",
    pairedAt: "x",
    lastSeenAt: "x",
    allowedProjects: ["projX"],
  });
  const bus = new MessageBus();

  const res = await h.handleControlPlaneVerb({ type: "project:start", projectId: "projX" } as any, "pk1", bus);
  expect(res.ok).toBe(true);
  expect(h.isPromoted("projX")).toBe(true);
  // The promote path's only possible token source is the shared runtime
  // (remoteDepsFor → this.remoteRuntime). Exactly one runtime was built.
  expect(factoryCalls).toBe(1);
  // The live loopback session is UNDISTURBED: same port + token after promote.
  const loopbackAfter = h.get("projX")?.connect;
  expect(loopbackAfter).not.toBeNull();
  expect(loopbackAfter?.port).toBe(loopbackBefore!.port);
  expect(loopbackAfter?.token).toBe(loopbackBefore!.token);

  // Idempotent: re-issuing project:start for the already-promoted project is a
  // no-op success and builds NO second runtime.
  const again = await h.handleControlPlaneVerb({ type: "project:start", projectId: "projX" } as any, "pk1", bus);
  expect(again.ok).toBe(true);
  expect(h.isPromoted("projX")).toBe(true);
  expect(factoryCalls).toBe(1);
});

test("project:start reports a SESSION_LIMIT_EXCEEDED register rejection to the phone and tears the slot down", async () => {
  const { factory } = makeCountingFactory();
  host = new HostServer({
    remote: fakeRemoteConfig(),
    remoteRuntimeFactory: factory,
    relayClientFactory: makeSessionLimitedRelayFactory(),
  });
  const h = host;

  await h.open("projX", tempFolder(), "local");
  h.pairedPhones.upsert({
    phonePubkey: "pk1",
    phoneDeviceId: "d1",
    pairedAt: "x",
    lastSeenAt: "x",
    allowedProjects: ["projX"],
  });

  const bus = new MessageBus();
  bus.setInboundHandler(() => {});
  const out: any[] = [];
  bus.subscribe({ deliver: (m) => out.push(m) });

  // project:start returns ok immediately — the register rejection is asynchronous
  // and pushed to the phone over the control plane once it lands.
  const res = await h.handleControlPlaneVerb({ type: "project:start", projectId: "projX" } as any, "pk1", bus);
  expect(res.ok).toBe(true);

  // Let the firstRegister rejection propagate.
  await new Promise((r) => setTimeout(r, 20));

  // (a) A structured control:result error reaches the phone — NOT a silent
  //     running:true advert that would send it dialing an empty data-plane slot.
  const err = out.find((m) => m.type === "control:result" && m.ok === false);
  expect(err).toBeDefined();
  expect(err.verb).toBe("project:start");
  expect(err.error.code).toBe("SESSION_LIMIT_EXCEEDED");
  // (b) No running:true advert was emitted for the rejected slot.
  const advert = out.find((m) => m.type === "agent:projects");
  expect(advert?.projects?.some((p: any) => p.projectId === "projX" && p.running)).not.toBe(true);
  // (c) The dead slot is torn down so a later retry (after upgrade) can re-promote.
  expect(h.isPromoted("projX")).toBe(false);
});

test("advert running=false for a warm-but-unpromoted local core; flips true after project:start registers the slot", async () => {
  const { factory } = makeCountingFactory();
  host = new HostServer({
    remote: fakeRemoteConfig(),
    remoteRuntimeFactory: factory,
    relayClientFactory: makeAuthenticatingRelayFactory(),
  });
  const h = host;

  await h.open("projX", tempFolder(), "local");
  h.pairedPhones.upsert({
    phonePubkey: "pk1",
    phoneDeviceId: "d1",
    pairedAt: "x",
    lastSeenAt: "x",
    allowedProjects: ["projX"],
  });

  // Warm on the host but never promoted → no relay slot → NOT dialable. Before
  // the deeper fix this read running:true (warm), sending the phone to dial an
  // empty data-plane slot (AGENT_OFFLINE loop).
  expect(h.buildProjectsAdvertisement("pk1").find((p) => p.projectId === "projX")?.running).toBe(false);

  const bus = new MessageBus();
  bus.setInboundHandler(() => {});
  const res = await h.handleControlPlaneVerb({ type: "project:start", projectId: "projX" } as any, "pk1", bus);
  expect(res.ok).toBe(true);

  // Let the firstRegister success propagate (reportFirstRegister re-advertises).
  await new Promise((r) => setTimeout(r, 20));

  // The promoted slot authenticated → relay-admitted → dialable → running:true.
  expect(h.isPromoted("projX")).toBe(true);
  expect(h.buildProjectsAdvertisement("pk1").find((p) => p.projectId === "projX")?.running).toBe(true);
});

test("phones:deny demotes the relay slot when no other phone allows the project", async () => {
  const { factory } = makeCountingFactory();
  host = new HostServer({ remote: fakeRemoteConfig(), remoteRuntimeFactory: factory });
  const h = host;

  // Open projX LOCAL and capture the loopback endpoint before promotion.
  const opened = await h.open("projX", tempFolder(), "local");
  const loopbackBefore = opened.connect;
  expect(loopbackBefore).not.toBeNull();

  // Admit pk1 for projX and promote.
  h.pairedPhones.upsert({
    phonePubkey: "pk1",
    phoneDeviceId: "d1",
    pairedAt: "x",
    lastSeenAt: "x",
    allowedProjects: ["projX"],
  });
  const bus = new MessageBus();
  const res = await h.handleControlPlaneVerb({ type: "project:start", projectId: "projX" } as any, "pk1", bus);
  expect(res.ok).toBe(true);
  expect(h.isPromoted("projX")).toBe(true);

  // Deny projX for pk1 — now NO phone allows projX.
  const denyRes = await h.handlePhonesVerb({ id: "req-1", type: "phones:deny", phonePubkey: "pk1", projectId: "projX" } as any);
  expect(denyRes.ok).toBe(true);

  // (a) The orphaned relay slot must be torn down.
  expect(h.isPromoted("projX")).toBe(false);

  // (b) pk1's allowlist no longer contains projX.
  const phone = h.listPairedPhones().find((p) => p.phonePubkey === "pk1");
  expect(phone?.allowedProjects).not.toContain("projX");

  // (c) The core is STILL warm/loopback-only — the loopback session is UNDISTURBED.
  const entry = h.get("projX");
  expect(entry).not.toBeNull();
  expect(entry?.connect?.port).toBe(loopbackBefore!.port);
  expect(entry?.connect?.token).toBe(loopbackBefore!.token);
});

test("phones:deny does NOT demote when another phone still allows the project", async () => {
  const { factory } = makeCountingFactory();
  host = new HostServer({ remote: fakeRemoteConfig(), remoteRuntimeFactory: factory });
  const h = host;

  // Open projX LOCAL and promote.
  await h.open("projX", tempFolder(), "local");

  // Two phones both allowed for projX.
  h.pairedPhones.upsert({ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "x", lastSeenAt: "x", allowedProjects: ["projX"] });
  h.pairedPhones.upsert({ phonePubkey: "pk2", phoneDeviceId: "d2", pairedAt: "x", lastSeenAt: "x", allowedProjects: ["projX"] });
  const bus = new MessageBus();
  const res = await h.handleControlPlaneVerb({ type: "project:start", projectId: "projX" } as any, "pk1", bus);
  expect(res.ok).toBe(true);
  expect(h.isPromoted("projX")).toBe(true);

  // Deny projX for pk1 only — pk2 still allows it.
  const denyRes = await h.handlePhonesVerb({ id: "req-2", type: "phones:deny", phonePubkey: "pk1", projectId: "projX" } as any);
  expect(denyRes.ok).toBe(true);

  // The slot must remain — pk2 still has projX allowed.
  expect(h.isPromoted("projX")).toBe(true);
});

test("phones:unpair demotes the relay slot when no other phone allows the project", async () => {
  const { factory } = makeCountingFactory();
  host = new HostServer({ remote: fakeRemoteConfig(), remoteRuntimeFactory: factory });
  const h = host;

  // Open projX LOCAL and capture the loopback endpoint before promotion.
  const opened = await h.open("projX", tempFolder(), "local");
  const loopbackBefore = opened.connect;
  expect(loopbackBefore).not.toBeNull();

  // Admit pk1 (the sole allowing phone) for projX and promote.
  h.pairedPhones.upsert({ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "x", lastSeenAt: "x", allowedProjects: ["projX"] });
  const bus = new MessageBus();
  const res = await h.handleControlPlaneVerb({ type: "project:start", projectId: "projX" } as any, "pk1", bus);
  expect(res.ok).toBe(true);
  expect(h.isPromoted("projX")).toBe(true);

  // Unpair pk1 entirely — now NO phone allows projX.
  const unpairRes = await h.handlePhonesVerb({ id: "req-3", type: "phones:unpair", phonePubkey: "pk1" } as any);
  expect(unpairRes.ok).toBe(true);

  // (a) The orphaned relay slot must be torn down.
  expect(h.isPromoted("projX")).toBe(false);

  // (b) pk1 is gone from the store.
  expect(h.listPairedPhones().find((p) => p.phonePubkey === "pk1")).toBeUndefined();

  // (c) The core is STILL warm/loopback-only — the loopback session is UNDISTURBED.
  const entry = h.get("projX");
  expect(entry).not.toBeNull();
  expect(entry?.connect?.port).toBe(loopbackBefore!.port);
  expect(entry?.connect?.token).toBe(loopbackBefore!.token);
});

test("phones:unpair does NOT demote when another phone still allows the project", async () => {
  const { factory } = makeCountingFactory();
  host = new HostServer({ remote: fakeRemoteConfig(), remoteRuntimeFactory: factory });
  const h = host;

  // Open projX LOCAL and promote.
  await h.open("projX", tempFolder(), "local");

  // Two phones both allowed for projX.
  h.pairedPhones.upsert({ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "x", lastSeenAt: "x", allowedProjects: ["projX"] });
  h.pairedPhones.upsert({ phonePubkey: "pk2", phoneDeviceId: "d2", pairedAt: "x", lastSeenAt: "x", allowedProjects: ["projX"] });
  const bus = new MessageBus();
  const res = await h.handleControlPlaneVerb({ type: "project:start", projectId: "projX" } as any, "pk1", bus);
  expect(res.ok).toBe(true);
  expect(h.isPromoted("projX")).toBe(true);

  // Unpair pk1 only — pk2 still allows projX.
  const unpairRes = await h.handlePhonesVerb({ id: "req-4", type: "phones:unpair", phonePubkey: "pk1" } as any);
  expect(unpairRes.ok).toBe(true);

  // The slot must remain — pk2 still has projX allowed.
  expect(h.isPromoted("projX")).toBe(true);
});

test("demoteAllPromoted tears down the relay slot and leaves the core warm/loopback-only", async () => {
  const { factory } = makeCountingFactory();
  host = new HostServer({ remote: fakeRemoteConfig(), remoteRuntimeFactory: factory });
  const h = host;

  // Open projX LOCAL and capture the loopback endpoint before promotion.
  const opened = await h.open("projX", tempFolder(), "local");
  const loopbackBefore = opened.connect;
  expect(loopbackBefore).not.toBeNull();

  // Admit the phone and promote.
  h.pairedPhones.upsert({
    phonePubkey: "pk1",
    phoneDeviceId: "d1",
    pairedAt: "x",
    lastSeenAt: "x",
    allowedProjects: ["projX"],
  });
  const bus = new MessageBus();
  const res = await h.handleControlPlaneVerb({ type: "project:start", projectId: "projX" } as any, "pk1", bus);
  expect(res.ok).toBe(true);
  expect(h.isPromoted("projX")).toBe(true);

  // Simulate the control-plane phone disconnect by calling demoteAllPromoted().
  h.demoteAllPromoted();

  // (a) The relay slot is gone — isPromoted must now be false.
  expect(h.isPromoted("projX")).toBe(false);

  // (b) The core is STILL warm/loopback-only: h.list() still contains projX
  //     and the loopback connect info is unchanged (the live session was NOT torn down).
  const projects = h.list();
  expect(projects.some((p) => p.projectId === "projX")).toBe(true);
  const loopbackAfter = h.get("projX")?.connect;
  expect(loopbackAfter).not.toBeNull();
  expect(loopbackAfter?.port).toBe(loopbackBefore!.port);
  expect(loopbackAfter?.token).toBe(loopbackBefore!.token);

  // (c) Calling demoteAllPromoted() again is a no-op (idempotent).
  expect(() => h.demoteAllPromoted()).not.toThrow();
  expect(h.isPromoted("projX")).toBe(false);
});
