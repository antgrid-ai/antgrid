import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostServer, type HostRemoteConfig, type RemoteRuntime } from "../src/host-server";
import { MessageBus } from "../src/message-bus";
import { ProjectStartMessage, parseMessage } from "../src/protocol";
import type { RelayClient, RelayClientOptions } from "../src/relay-client";
import type { AttachStreamOpts } from "../src/stream-mux";

// --- shared fakes (mirror host-control-plane.test.ts) ----------------------

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

// A machine-relay-client stub whose promoted stream is admitted the instant it
// attaches (mirrors host-promotion.test.ts) — flips isRelayRegistered() true
// and records the streamId in host.streamIds via remoteDepsFor's wrapper.
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

// Remote mode runs an interactive antgrid.yaml setup when none exists; seed one
// so open() doesn't block on a prompt (mirrors host-server.test.ts).
function tempFolder(): string {
  const f = mkdtempSync(join(tmpdir(), "antgrid-cp-start-proj-"));
  writeFileSync(join(f, "antgrid.yaml"), "name: test-remote\nagent:\n  tool: claude-code\n");
  return f;
}

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-cp-start-abdir-"));
  process.env.ANTGRID_DIR = abDir;
  host = new HostServer({
    remote: fakeRemoteConfig(),
    remoteRuntimeFactory: () => Promise.resolve(fakeRuntime()),
  });
});

afterEach(async () => {
  await host?.shutdown();
  host = null;
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR; else process.env.ANTGRID_DIR = prevAbDir;
  if (abDir) rmSync(abDir, { recursive: true, force: true });
});

test("starts an allowed stopped project; rejects a non-allowed one", async () => {
  const h = host!;
  // Seed projA known-but-stopped: open then stop (now in seenProjects, not warm).
  await h.open("projA", tempFolder(), "remote");
  await h.stop("projA");
  expect(h.get("projA")).toBeNull(); // stopped, not warm

  h.pairedPhones.upsert({
    phonePubkey: "pk1",
    phoneDeviceId: "d1",
    pairedAt: "x",
    lastSeenAt: "x",
    admission: "pair-code",
    allowedProjects: ["projA"],
  });
  const bus = new MessageBus();

  const ok = await h.handleControlPlaneVerb({ type: "project:start", projectId: "projA" } as any, "pk1", bus);
  expect(ok.ok).toBe(true);
  expect(h.get("projA")?.running).toBe(true);

  // SECURITY: projB is NOT in the phone allowlist → rejected, NO core created.
  const denied = await h.handleControlPlaneVerb({ type: "project:start", projectId: "projB" } as any, "pk1", bus);
  expect(denied.ok).toBe(false);
  if (!denied.ok) expect(denied.error.code).toBe("NOT_ALLOWED");
  expect(h.get("projB")).toBeNull();
});

test("rejects an allowed projectId with no path on record (UNKNOWN_PROJECT, no core)", async () => {
  const h = host!;
  h.pairedPhones.upsert({
    phonePubkey: "pk1",
    phoneDeviceId: "d1",
    pairedAt: "x",
    lastSeenAt: "x",
    admission: "pair-code",
    allowedProjects: ["ghost"],
  });
  const bus = new MessageBus();

  // "ghost" is allowed but was never opened → absent from seenProjects.
  const res = await h.handleControlPlaneVerb({ type: "project:start", projectId: "ghost" } as any, "pk1", bus);
  expect(res.ok).toBe(false);
  if (!res.ok) expect(res.error.code).toBe("UNKNOWN_PROJECT");
  expect(h.get("ghost")).toBeNull(); // SECURITY: no core created, no guessed path.
});

test("open() throwing resolves to OPEN_FAILED (never rejects into the void caller)", async () => {
  // Tear down the beforeEach host; this case needs a host whose remote runtime
  // ALWAYS fails to mint, so open() throws deterministically.
  await host?.shutdown();
  // Pre-seed projects.json so "boom" is allowed+known WITHOUT a prior successful
  // open (which would cache a working runtime and defeat the failure injection).
  const agentsDir = join(abDir!, "agents");
  mkdirSync(agentsDir, { recursive: true });
  writeFileSync(
    join(agentsDir, "projects.json"),
    JSON.stringify({ version: 1, projects: { boom: { path: tempFolder(), label: "boom" } } }),
  );

  host = new HostServer({
    remote: fakeRemoteConfig(),
    remoteRuntimeFactory: () => Promise.reject(new Error("mint failed")),
  });
  const h = host;
  h.pairedPhones.upsert({
    phonePubkey: "pk1",
    phoneDeviceId: "d1",
    pairedAt: "x",
    lastSeenAt: "x",
    admission: "pair-code",
    allowedProjects: ["boom"],
  });
  const bus = new MessageBus();

  // Crucially: the call RESOLVES (no unhandled rejection) with a structured error.
  const res = await h.handleControlPlaneVerb({ type: "project:start", projectId: "boom" } as any, "pk1", bus);
  expect(res.ok).toBe(false);
  if (!res.ok) expect(res.error.code).toBe("OPEN_FAILED");
  expect(h.get("boom")).toBeNull(); // no warm core left behind
});

test("idempotent project:start on an already-promoted, relay-registered core re-publishes stream-ready", async () => {
  // The reconnect repro: the app killed+reopened sends project:start as its
  // stream-binding question. The core is already promoted, so the idempotent
  // branch runs — and its re-advert can be legally suppressed by the bus's
  // payload dedup (byte-identical catalog). stream-ready is dedup-immune (not
  // in REPLAY_TYPES), so the idempotent branch MUST publish it: a verb that
  // returns ok must emit the frame its caller awaits.
  await host?.shutdown();
  host = new HostServer({
    remote: fakeRemoteConfig(),
    remoteRuntimeFactory: () => Promise.resolve(fakeRuntime()),
    relayClientFactory: makeAuthenticatingRelayFactory(),
  });
  const h = host;

  await h.open("projX", tempFolder(), "local");
  h.pairedPhones.upsert({
    phonePubkey: "pk1",
    phoneDeviceId: "d1",
    pairedAt: "x",
    lastSeenAt: "x",
    admission: "pair-code",
    allowedProjects: ["projX"],
  });

  const bus = new MessageBus();
  bus.setInboundHandler(() => {});
  const out: any[] = [];
  bus.subscribe({ deliver: (m) => out.push(m) });

  // First start: promote + register (instant-admit stub).
  const first = await h.handleControlPlaneVerb({ type: "project:start", projectId: "projX" } as any, "pk1", bus);
  expect(first.ok).toBe(true);
  await new Promise((r) => setTimeout(r, 20));
  expect(out.some((m) => m.type === "stream-ready" && m.projectId === "projX" && m.streamId === "s1")).toBe(true);

  // Reconnect scenario: a SECOND project:start hits the idempotent branch.
  out.length = 0;
  const again = await h.handleControlPlaneVerb({ type: "project:start", projectId: "projX" } as any, "pk1", bus);
  expect(again.ok).toBe(true);
  const ready = out.find((m) => m.type === "stream-ready");
  expect(ready).toBeDefined();
  expect(ready.projectId).toBe("projX");
  expect(ready.streamId).toBe("s1");
});

test("a rejected verb's control:result carries projectId so the phone can correlate it", async () => {
  const h = host!;
  const bus = new MessageBus();
  bus.setInboundHandler(() => {});
  const out: any[] = [];
  bus.subscribe({ deliver: (m) => out.push(m) });

  // pk1 has NO allowlist entry → NOT_ALLOWED via the async dispatch path (the
  // one the phone actually exercises).
  h.dispatchControlPlaneInbound(
    { type: "project:start", projectId: "projB" } as any,
    "control",
    "pk1",
    bus,
  );
  await new Promise((r) => setTimeout(r, 20));

  const res = out.find((m) => m.type === "control:result" && m.ok === false);
  expect(res).toBeDefined();
  expect(res.verb).toBe("project:start");
  expect(res.error.code).toBe("NOT_ALLOWED");
  // Without projectId the phone can only guess which pending bind failed.
  expect(res.projectId).toBe("projB");
});

test("an unknown verb type is rejected without effect", async () => {
  const h = host!;
  const bus = new MessageBus();
  const res = await h.handleControlPlaneVerb({ type: "ping" } as any, "pk1", bus);
  expect(res.ok).toBe(false);
  if (!res.ok) expect(res.error.code).toBe("UNKNOWN_VERB");
});

test("schema carries projectId ONLY — a smuggled path is stripped", () => {
  // SECURITY invariant #1: the message MUST NOT carry a path/folder. Zod objects
  // strip unknown keys by default, so a smuggled `path` never reaches the host.
  const parsed = ProjectStartMessage.safeParse({
    id: crypto.randomUUID(),
    timestamp: Date.now(),
    type: "project:start",
    projectId: "x",
    path: "/etc",
    folder: "/tmp",
  });
  expect(parsed.success).toBe(true);
  if (parsed.success) {
    expect(parsed.data.projectId).toBe("x");
    expect("path" in parsed.data).toBe(false);
    expect("folder" in parsed.data).toBe(false);
  }
});

test("parseMessage accepts project:start (in union + KNOWN_TYPES) and strips path", () => {
  const raw = JSON.stringify({
    id: crypto.randomUUID(),
    timestamp: Date.now(),
    type: "project:start",
    projectId: "x",
    path: "/etc",
  });
  const msg = parseMessage(raw);
  expect(msg).not.toBeNull();
  expect(msg?.type).toBe("project:start");
  expect("path" in (msg as object)).toBe(false);
});
