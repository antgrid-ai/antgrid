import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostServer, type HostRemoteConfig, type RemoteRuntime } from "../src/host-server";
import { computeProjectId } from "../src/project-id";
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
// (a rejected stream-open leaves the socket and every other
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

// Project ids are host-resolved: `open` rejects any id that is not
// computeProjectId(folder) (PROJECT_ID_MISMATCH). These helpers keep the
// readable "projX" aliases while using the real id on the wire.
const projectIds = new Map<string, string>();
function proj(alias: string): string {
  const id = projectIds.get(alias);
  if (!id) throw new Error(`project alias not opened: ${alias}`);
  return id;
}
async function openAs(h: HostServer, alias: string, mode: "local" | "remote"): Promise<OpenResultLike> {
  const folder = tempFolder();
  const projectId = computeProjectId(folder);
  projectIds.set(alias, projectId);
  return h.open(projectId, folder, mode);
}
type OpenResultLike = Awaited<ReturnType<HostServer["open"]>>;

/** Flip the machine switch through its only mutation path, the loopback verb. */
async function setMobileAccess(h: HostServer, enabled: boolean): Promise<void> {
  await h.handleRemoteAccessVerb({ id: "t", type: "mobile-access:set", enabled });
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
  const opened = await openAs(h, "projX", "local");
  expect(h.isPromoted(proj("projX"))).toBe(false);
  expect(factoryCalls).toBe(0); // local open builds NO runtime
  // Capture the loopback endpoint BEFORE promotion. Promotion adds an ADDITIVE
  // relay slot to the existing bus — it must NOT close+reopen the core, so the
  // loopback port+token must survive unchanged (regression guard for the
  // additive-not-replace invariant).
  const loopbackBefore = opened.connect;
  expect(loopbackBefore).not.toBeNull();

  // Make the machine mobile-reachable.
  await setMobileAccess(h, true);
  const bus = new MessageBus();

  const res = await h.handleControlPlaneVerb({ type: "project:start", projectId: proj("projX") } as any, bus);
  expect(res.ok).toBe(true);
  expect(h.isPromoted(proj("projX"))).toBe(true);
  // The promote path's only possible token source is the shared runtime
  // (remoteDepsFor → this.remoteRuntime). Exactly one runtime was built.
  expect(factoryCalls).toBe(1);
  // The live loopback session is UNDISTURBED: same port + token after promote.
  const loopbackAfter = h.get(proj("projX"))?.connect;
  expect(loopbackAfter).not.toBeNull();
  expect(loopbackAfter?.port).toBe(loopbackBefore!.port);
  expect(loopbackAfter?.token).toBe(loopbackBefore!.token);

  // Idempotent: re-issuing project:start for the already-promoted project is a
  // no-op success and builds NO second runtime.
  const again = await h.handleControlPlaneVerb({ type: "project:start", projectId: proj("projX") } as any, bus);
  expect(again.ok).toBe(true);
  expect(h.isPromoted(proj("projX"))).toBe(true);
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

  await openAs(h, "projX", "local");
  await setMobileAccess(h, true);

  const bus = new MessageBus();
  bus.setInboundHandler(() => {});
  const out: any[] = [];
  bus.subscribe({ deliver: (m) => out.push(m) });

  // project:start returns ok immediately — the register rejection is asynchronous
  // and pushed to the phone over the control plane once it lands.
  const res = await h.handleControlPlaneVerb({ type: "project:start", projectId: proj("projX") } as any, bus);
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
  expect(advert?.projects?.some((p: any) => p.projectId === proj("projX") && p.running)).not.toBe(true);
  // (c) The dead slot is torn down so a later retry (after upgrade) can re-promote.
  expect(h.isPromoted(proj("projX"))).toBe(false);
});

test("advert running=false for a warm-but-unpromoted local core; flips true after project:start registers the slot", async () => {
  const { factory } = makeCountingFactory();
  host = new HostServer({
    remote: fakeRemoteConfig(),
    remoteRuntimeFactory: factory,
    relayClientFactory: makeAuthenticatingRelayFactory(),
  });
  const h = host;

  await openAs(h, "projX", "local");
  await setMobileAccess(h, true);

  // Warm on the host but never promoted → no relay slot → NOT dialable. Before
  // the deeper fix this read running:true (warm), sending the phone to dial an
  // empty data-plane slot (AGENT_OFFLINE loop).
  expect(h.buildProjectsAdvertisement().find((p) => p.projectId === proj("projX"))?.running).toBe(false);

  const bus = new MessageBus();
  bus.setInboundHandler(() => {});
  const res = await h.handleControlPlaneVerb({ type: "project:start", projectId: proj("projX") } as any, bus);
  expect(res.ok).toBe(true);

  // Let the firstRegister success propagate (reportFirstRegister re-advertises).
  await new Promise((r) => setTimeout(r, 20));

  // The promoted slot authenticated → relay-admitted → dialable → running:true.
  expect(h.isPromoted(proj("projX"))).toBe(true);
  expect(h.buildProjectsAdvertisement().find((p) => p.projectId === proj("projX"))?.running).toBe(true);
});

test("turning mobile access OFF tears down EVERY promoted slot, leaving loopback sessions alive", async () => {
  const { factory } = makeCountingFactory();
  host = new HostServer({ remote: fakeRemoteConfig(), remoteRuntimeFactory: factory });
  const h = host;

  // Two projects open LOCAL and both promoted — the switch is machine-wide, so
  // one project's teardown is not enough.
  const openedX = await openAs(h, "projX", "local");
  const openedY = await openAs(h, "projY", "local");
  await setMobileAccess(h, true);
  const bus = new MessageBus();
  expect((await h.handleControlPlaneVerb({ type: "project:start", projectId: proj("projX") } as any, bus)).ok).toBe(true);
  expect((await h.handleControlPlaneVerb({ type: "project:start", projectId: proj("projY") } as any, bus)).ok).toBe(true);
  expect(h.isPromoted(proj("projX"))).toBe(true);
  expect(h.isPromoted(proj("projY"))).toBe(true);

  const off = (await h.handleRemoteAccessVerb({ id: "off", type: "mobile-access:set", enabled: false })) as any;
  expect(off.ok).toBe(true);
  expect(off.enabled).toBe(false);

  // (a) No project is left dialable — every relay slot is gone.
  expect(h.isPromoted(proj("projX"))).toBe(false);
  expect(h.isPromoted(proj("projY"))).toBe(false);
  expect(h.buildProjectsAdvertisement()).toEqual([]);

  // (b) The desktop's own loopback sessions are UNTOUCHED: same cores, same
  //     port+token. Only the additive relay slot was stopped.
  expect(h.list().map((p) => p.projectId).sort()).toEqual([proj("projX"), proj("projY")].sort());
  expect(h.get(proj("projX"))?.connect?.port).toBe(openedX.connect!.port);
  expect(h.get(proj("projX"))?.connect?.token).toBe(openedX.connect!.token);
  expect(h.get(proj("projY"))?.connect?.port).toBe(openedY.connect!.port);
  expect(h.get(proj("projY"))?.connect?.token).toBe(openedY.connect!.token);
});

test("phones:unpair drops the row without demoting — it is not a revocation", async () => {
  const { factory } = makeCountingFactory();
  host = new HostServer({ remote: fakeRemoteConfig(), remoteRuntimeFactory: factory });
  const h = host;

  await openAs(h, "projX", "local");
  h.pairedPhones.upsert({ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "x", lastSeenAt: "x" });
  await setMobileAccess(h, true);
  const bus = new MessageBus();
  expect((await h.handleControlPlaneVerb({ type: "project:start", projectId: proj("projX") } as any, bus)).ok).toBe(true);
  expect(h.isPromoted(proj("projX"))).toBe(true);

  const unpairRes = await h.handlePhonesVerb({ id: "req-3", type: "phones:unpair", phonePubkey: "pk1" } as any);
  expect(unpairRes.ok).toBe(true);

  // The row (identity/push/last-seen) is gone...
  expect(h.listPairedPhones().find((p) => p.phonePubkey === "pk1")).toBeUndefined();
  // ...but reachability is the machine switch, and it is still on: unpairing one
  // device must not tear down slots other account-trusted phones are using.
  expect(h.isPromoted(proj("projX"))).toBe(true);
});

test("demoteAllPromoted tears down the relay slot and leaves the core warm/loopback-only", async () => {
  const { factory } = makeCountingFactory();
  host = new HostServer({ remote: fakeRemoteConfig(), remoteRuntimeFactory: factory });
  const h = host;

  // Open projX LOCAL and capture the loopback endpoint before promotion.
  const opened = await openAs(h, "projX", "local");
  const loopbackBefore = opened.connect;
  expect(loopbackBefore).not.toBeNull();

  // Make the machine mobile-reachable and promote.
  await setMobileAccess(h, true);
  const bus = new MessageBus();
  const res = await h.handleControlPlaneVerb({ type: "project:start", projectId: proj("projX") } as any, bus);
  expect(res.ok).toBe(true);
  expect(h.isPromoted(proj("projX"))).toBe(true);

  h.demoteAllPromoted();

  // (a) The relay slot is gone — isPromoted must now be false.
  expect(h.isPromoted(proj("projX"))).toBe(false);

  // (b) The core is STILL warm/loopback-only: h.list() still contains projX
  //     and the loopback connect info is unchanged (the live session was NOT torn down).
  const projects = h.list();
  expect(projects.some((p) => p.projectId === proj("projX"))).toBe(true);
  const loopbackAfter = h.get(proj("projX"))?.connect;
  expect(loopbackAfter).not.toBeNull();
  expect(loopbackAfter?.port).toBe(loopbackBefore!.port);
  expect(loopbackAfter?.token).toBe(loopbackBefore!.token);

  // (c) Calling demoteAllPromoted() again is a no-op (idempotent).
  expect(() => h.demoteAllPromoted()).not.toThrow();
  expect(h.isPromoted(proj("projX"))).toBe(false);
});
