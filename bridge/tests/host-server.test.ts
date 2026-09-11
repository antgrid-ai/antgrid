import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostServer, type HostRemoteConfig, type RemoteRuntime } from "../src/host-server";
import { computeProjectId } from "../src/project-id";
import { createMessage, type AgentEnableRelay } from "../src/protocol";
import type { RelayClient } from "../src/relay-client";
import type { SessionBusCoordinator } from "../src/session-bus/coordinator";
import { loadHeld } from "../src/session-bus/held-store";
import { LOCAL_MACHINE_ID } from "../src/session-bus/constants";

// A remote config pointing at unreachable endpoints. The OAuth mint is never hit
// because these tests inject `remoteRuntimeFactory`; RelayClient.connect() is
// fire-and-forget so the bogus relayUrl just backs off in the background.
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
  return { maint: { getToken: () => "tok", stop: () => {} } };
}

// Inert machine relay client: keeps startRemoteControlPlane off a real socket.
function stubRelayClient(): RelayClient {
  return {
    deviceId: "control-plane-dev",
    hasEstablishedSession: () => false,
    anySessionSupportsCheckoutRouting: () => false,
    establishedPeers: () => [],
    peerSession: () => null,
    setBus: () => {},
    connect: () => {},
    close: () => {},
    attachStream: () => ({ streamId: "s1", detach: () => {}, sendTunnel: () => {} }),
    noteStreamBound: () => {},
    sendPushDeliver: () => {},
  } as unknown as RelayClient;
}

let host: HostServer | null = null;
const folders: string[] = [];

// Isolate ANTGRID_DIR so startControlPlane() writes host.json to a temp dir,
// never the real ~/.antgrid (mirrors host-discovery.test.ts).
let prevAbDir: string | undefined;
let abDir: string | undefined;

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-abdir-"));
  process.env.ANTGRID_DIR = abDir;
});

// On Windows the core's file watcher can hold a transient handle on the temp
// folder for a few ms after shutdown() resolves, making rmSync throw EBUSY.
// Retry the cleanup briefly; never let teardown fail the assertions above.
async function rmWithRetry(path: string): Promise<void> {
  for (let i = 0; i < 20; i++) {
    try { rmSync(path, { recursive: true, force: true }); return; }
    catch { await new Promise((r) => setTimeout(r, 25)); }
  }
}

afterEach(async () => {
  // shutdown() must run while ANTGRID_DIR still points at abDir so removeHostFile
  // targets the temp host.json — restore ANTGRID_DIR only afterward.
  await host?.shutdown();
  host = null;
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR; else process.env.ANTGRID_DIR = prevAbDir;
  if (abDir) rmSync(abDir, { recursive: true, force: true });
  while (folders.length) await rmWithRetry(folders.pop()!);
});

function tempFolder(): string {
  const f = mkdtempSync(join(tmpdir(), "antgrid-host-"));
  folders.push(f);
  return f;
}

// Remote mode runs an interactive antgrid.yaml setup when none exists; give the
// folder a minimal config so buildAgentCore loads non-interactively in tests.
function tempRemoteFolder(): string {
  const f = tempFolder();
  writeFileSync(join(f, "antgrid.yaml"), "name: test-remote\nagent:\n  tool: claude-code\n");
  return f;
}

test("HostServer.open starts a local core, list reflects it, get returns connect info", async () => {
  host = new HostServer({});
  const folder = tempFolder();
  const projectId = computeProjectId(folder);

  const opened = await host.open(projectId, folder, "local");
  expect(opened.running).toBe(true);
  expect(opened.connect?.port).toBeGreaterThan(0);

  const list = host.list();
  expect(list.find((p) => p.projectId === projectId)?.running).toBe(true);

  // Idempotent: opening the same project returns the same running core, no second start.
  const again = await host.open(projectId, folder, "local");
  expect(again.connect?.port).toBe(opened.connect?.port);
});

test("HostServer.open rejects an id that is not the folder's resolved project id", async () => {
  host = new HostServer({});
  const folder = tempFolder();
  // The linked-worktree case in miniature: a caller naming a folder under some
  // other id would otherwise get a second core over the same repository.
  await expect(host.open("legacy-project-id", folder, "local"))
    .rejects.toMatchObject({ code: "PROJECT_ID_MISMATCH" });
  expect(host.list()).toHaveLength(0);
});

test("HostServer.open accepts the resolved id and canonicalizes the path", async () => {
  host = new HostServer({});
  const folder = tempFolder();
  const projectId = computeProjectId(folder);
  const opened = await host.open(projectId, folder, "local");
  expect(opened.connect?.port).toBeGreaterThan(0);
  expect(host.list().map((entry) => entry.projectId)).toContain(projectId);
});

test("HostServer.open gives a user-made linked worktree its own project, not the primary's", async () => {
  const runGit = async (cwd: string, args: string[]) => {
    const proc = Bun.spawn(["git", ...args], { cwd, stdout: "ignore", stderr: "pipe" });
    if (await proc.exited !== 0) throw new Error(await new Response(proc.stderr).text());
  };
  host = new HostServer({});
  const repo = tempFolder();
  await runGit(repo, ["init"]);
  await runGit(repo, ["config", "user.email", "test@antgrid.local"]);
  await runGit(repo, ["config", "user.name", "Test"]);
  writeFileSync(join(repo, "initial.txt"), "v1\n");
  await runGit(repo, ["add", "."]);
  await runGit(repo, ["commit", "-m", "initial"]);
  const linked = join(repo, "linked");
  await runGit(repo, ["worktree", "add", "-b", "linked", linked]);

  // Named by the PRIMARY's id, this mismatches: a worktree the user made
  // outside Antgrid's own `wt/` root is not folded onto the primary, unlike a
  // managed checkout.
  await expect(host.open(computeProjectId(repo), linked, "local"))
    .rejects.toMatchObject({ code: "PROJECT_ID_MISMATCH" });

  // Named by its own id, the linked worktree opens as a project of its own —
  // its files, not the primary's.
  const opened = await host.open(computeProjectId(linked), linked, "local");
  expect(opened.connect?.port).toBeGreaterThan(0);
  expect(host.list()).toHaveLength(1);
  expect(host.list()[0].path?.toLowerCase()).toContain("linked");
});

test("concurrent open() of the same project coalesces into one core (no orphan)", async () => {
  host = new HostServer({});
  const folder = tempFolder();
  const projectId = computeProjectId(folder);

  // Fire two opens before either resolves: both miss the catalog check, so
  // without the in-flight guard the second would start (and orphan) a second core.
  const [a, b] = await Promise.all([host.open(projectId, folder, "local"), host.open(projectId, folder, "local")]);

  // Same core: same loopback port, single catalog entry.
  expect(a.connect?.port).toBe(b.connect?.port);
  expect(host.list().filter((p) => p.projectId === projectId).length).toBe(1);

  // And exactly one core is tracked overall (no orphaned, un-shutdown core left running).
  expect(host.list().length).toBe(1);
});

test("warm re-open re-stamps lastActiveAt AND persists it to projects.json", async () => {
  host = new HostServer({});
  const folder = tempFolder();
  const projectId = computeProjectId(folder);
  const projectsJson = join(abDir!, "agents", "projects.json");

  // Cold open writes projects.json with a lastActiveAt stamp.
  await host.open(projectId, folder, "local");

  // Simulate a stale on-disk stamp (e.g. left over from a prior process run).
  const before = JSON.parse(readFileSync(projectsJson, "utf8"));
  before.projects[projectId].lastActiveAt = "1970-01-01T00:00:00.000Z";
  writeFileSync(projectsJson, JSON.stringify(before));

  // Warm re-open must re-stamp AND flush — before the fix it mutated memory only,
  // leaving the stale sentinel on disk until a process restart.
  await host.open(projectId, folder, "local");

  const after = JSON.parse(readFileSync(projectsJson, "utf8"));
  expect(after.projects[projectId].lastActiveAt).not.toBe("1970-01-01T00:00:00.000Z");
});

test("HostServer.stop tears a core down and drops it from the catalog", async () => {
  host = new HostServer({});
  const folder = tempFolder();
  const projectId = computeProjectId(folder);
  await host.open(projectId, folder, "local");
  expect(host.list().some((p) => p.projectId === projectId)).toBe(true);

  await host.stop(projectId);
  expect(host.list().some((p) => p.projectId === projectId)).toBe(false);
});

test("a host with no machine config still opens a local core", async () => {
  host = new HostServer({}); // no remote config at all
  const folder = tempFolder();
  const id = computeProjectId(folder);
  const opened = await host.open(id, folder, "local");
  expect(opened.running).toBe(true);
  expect(opened.connect?.port).toBeGreaterThan(0);
});

test("opening a remote core with no machine config throws", async () => {
  host = new HostServer({}); // no remote config
  const folder = tempFolder();
  await expect(host.open(computeProjectId(folder), folder, "remote")).rejects.toThrow(/remote/i);
});

test("remote open builds the runtime once via the factory and reports mode 'remote'", async () => {
  let builds = 0;
  host = new HostServer({
    remote: fakeRemoteConfig(),
    remoteRuntimeFactory: async () => { builds++; return fakeRuntime(); },
  });
  const folder = tempRemoteFolder();
  const id = computeProjectId(folder);

  const opened = await host.open(id, folder, "remote");
  expect(opened.running).toBe(true);
  expect(host.list().find((p) => p.projectId === id)?.mode).toBe("remote");
  expect(builds).toBe(1);

  // Idempotent re-open does not rebuild the runtime.
  await host.open(id, folder, "remote");
  expect(builds).toBe(1);
});

test("concurrent first remote opens of distinct projects share one runtime build (no leaked timer)", async () => {
  let builds = 0;
  let release!: () => void;
  const gate = new Promise<void>((r) => { release = r; });
  host = new HostServer({
    remote: fakeRemoteConfig(),
    // Block inside the factory so both opens reach ensureRemoteRuntime while the
    // build is in flight — exercising the single-flight coalesce. Without it,
    // each open would build its own runtime (and start its own re-mint timer).
    remoteRuntimeFactory: async () => { builds++; await gate; return fakeRuntime(); },
  });
  const f1 = tempRemoteFolder(), f2 = tempRemoteFolder();

  const p1 = host.open(computeProjectId(f1), f1, "remote");
  const p2 = host.open(computeProjectId(f2), f2, "remote");
  release();
  await Promise.all([p1, p2]);

  expect(builds).toBe(1);
  expect(host.list().length).toBe(2);
});

test("list() reports each core's mode", async () => {
  host = new HostServer({});
  const folder = tempFolder();
  const id = computeProjectId(folder);
  await host.open(id, folder, "local");
  expect(host.list().find((p) => p.projectId === id)?.mode).toBe("local");
});

test("HostServer evicts the least-recently-opened core past the warm cap", async () => {
  host = new HostServer({ warmCap: 2 });
  const f1 = tempFolder(), f2 = tempFolder(), f3 = tempFolder();
  const id1 = computeProjectId(f1), id2 = computeProjectId(f2), id3 = computeProjectId(f3);

  await host.open(id1, f1, "local");
  await host.open(id2, f2, "local");
  await host.open(id3, f3, "local"); // exceeds cap of 2 → evicts id1 (oldest)

  const ids = host.list().map((p) => p.projectId);
  expect(ids).toContain(id2);
  expect(ids).toContain(id3);
  expect(ids).not.toContain(id1); // shut down on eviction
});

test("control plane: project:open then project:list round-trip over HTTP", async () => {
  host = new HostServer({});
  const cp = await host.startControlPlane();
  const folder = tempFolder();
  const projectId = computeProjectId(folder);

  const call = async (body: object) => {
    const res = await fetch(`http://127.0.0.1:${cp.port}/control`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${cp.token}` },
      body: JSON.stringify(body),
    });
    return { status: res.status, body: await res.json() };
  };

  const opened = await call({ id: "1", type: "project:open", projectId, projectPath: folder, mode: "local" });
  expect(opened.status).toBe(200);
  expect(opened.body.ok).toBe(true);
  expect(opened.body.connect.port).toBeGreaterThan(0);

  const listed = await call({ id: "2", type: "project:list" });
  expect(listed.body.projects.find((p: any) => p.projectId === projectId)?.running).toBe(true);

  const stopped = await call({ id: "3", type: "project:stop", projectId });
  expect(stopped.body).toEqual({ id: "3", ok: true, type: "project:stop" });

  const relisted = await call({ id: "4", type: "project:list" });
  expect(relisted.body.projects.some((p: any) => p.projectId === projectId)).toBe(false);
});

test("control plane: project:sessions peeks a warm core's live session list", async () => {
  host = new HostServer({});
  const cp = await host.startControlPlane();
  const folder = tempFolder();
  const projectId = computeProjectId(folder);

  const call = async (body: object) => {
    const res = await fetch(`http://127.0.0.1:${cp.port}/control`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${cp.token}` },
      body: JSON.stringify(body),
    });
    return { status: res.status, body: await res.json() };
  };

  // Cold: no core open, no sessions.json on disk yet → empty peek, not an error.
  const cold = await call({ id: "1", type: "project:sessions", projectId });
  expect(cold.body).toEqual({ id: "1", ok: true, type: "project:sessions", sessions: [] });

  await host.open(projectId, folder, "local");
  const warm = await call({ id: "2", type: "project:sessions", projectId });
  expect(warm.body.ok).toBe(true);
  expect(warm.body.sessions).toEqual([]); // freshly opened, no sessions started yet
});

test("control plane: project:sessions rejects a malformed projectId", async () => {
  host = new HostServer({});
  const cp = await host.startControlPlane();
  const res = await fetch(`http://127.0.0.1:${cp.port}/control`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${cp.token}` },
    body: JSON.stringify({ id: "1", type: "project:sessions", projectId: "../../etc" }),
  });
  const body = await res.json();
  expect(body).toEqual({ id: "1", ok: false, error: { code: "E_BAD_PARAMS", message: "invalid projectId" } });
});

test("shares one paired-phones store across cores", async () => {
  host = new HostServer({});
  const folderA = tempFolder();
  const folderB = tempFolder();
  const idA = computeProjectId(folderA);
  const idB = computeProjectId(folderB);
  await host.open(idA, folderA, "local");
  await host.open(idB, folderB, "local");
  // Identity, not contents: every core must read the SAME in-memory view, so a
  // concurrent `antgrid phones remove` reloaded by the watcher reaches all of
  // them at once (push targeting and phones:list read it live).
  const cores = (host as any).cores;
  expect(cores.get(idA).core.deps.pairedPhones).toBe(host.pairedPhones);
  expect(cores.get(idB).core.deps.pairedPhones).toBe(host.pairedPhones);
  host.pairedPhones.upsert({ phonePubkey: "pk1", phoneDeviceId: "d1",
    pairedAt: "x", lastSeenAt: "x", label: "pixel" });
  expect(cores.get(idB).core.deps.pairedPhones.get("pk1")?.label).toBe("pixel");
  // afterEach calls host.shutdown()
});

test("startControlPlane writes host.json with the control port + token", async () => {
  host = new HostServer({});
  const cp = await host.startControlPlane();
  const { readHostFile, hostFilePath } = await import("../src/host-discovery");
  const hf = readHostFile(hostFilePath());
  expect(hf?.controlPort).toBe(cp.port);
  expect(hf?.token).toBe(cp.token);
});

test("host:shutdown returns ok and fires onShutdownRequested (after the response)", async () => {
  let shutdownCalls = 0;
  // Mirror real usage: the entrypoint's callback tears the host down. The OK
  // still reaching the client is the deferral contract — the response flushed
  // before teardown killed the control listener. Whether the deferred callback
  // fires before or after fetch() resolves is event-loop scheduling, not
  // contract, so don't assert on that ordering.
  host = new HostServer({ onShutdownRequested: () => { shutdownCalls++; void host?.shutdown(); } });
  const cp = await host.startControlPlane();

  const res = await fetch(`http://127.0.0.1:${cp.port}/control`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${cp.token}` },
    body: JSON.stringify({ id: "1", type: "host:shutdown" }),
  });
  const body = await res.json();
  expect(res.status).toBe(200);
  expect(body).toEqual({ id: "1", ok: true, type: "host:shutdown" });
  // The complete OK above IS the deferred-teardown proof (the response
  // flushed before any teardown could kill the listener). No `=== 0` check
  // here: the server's 0ms defer timer can legitimately fire before the
  // client finishes parsing, so that assertion is a scheduling race (flaked
  // under full-suite load).
  for (let i = 0; i < 100 && shutdownCalls === 0; i++) await new Promise((r) => setTimeout(r, 5));
  expect(shutdownCalls).toBe(1);
});

// M6: pushHeartbeat() previously fired only from onAuthenticated + the
// mobile-access mutation — a stably-connected bridge never re-ran it, so
// trustedPeers.json (the E2E-admission inventory cache) never refreshed on
// its own. The design spec calls for "the existing heartbeat cadence"; this
// proves that cadence is now a real, owned, disposable timer.
test("startControlPlane's remote control plane runs pushHeartbeat on an actual cadence, and shutdown clears the timer", async () => {
  let calls = 0;
  host = new HostServer({
    remote: fakeRemoteConfig(),
    remoteRuntimeFactory: () => Promise.resolve(fakeRuntime()),
    heartbeatIntervalMs: 15,
  });
  // Stub the tick body itself (already covered elsewhere) — this test is only
  // about the timer's lifecycle: does it fire repeatedly, and does it stop.
  (host as unknown as { pushHeartbeat: () => void }).pushHeartbeat = () => { calls++; };

  await host.startControlPlane();
  expect((host as unknown as { heartbeatTimer: unknown }).heartbeatTimer).not.toBeNull();

  await new Promise((r) => setTimeout(r, 60));
  expect(calls).toBeGreaterThanOrEqual(2);

  await host.shutdown();
  expect((host as unknown as { heartbeatTimer: unknown }).heartbeatTimer).toBeNull();

  const callsAtShutdown = calls;
  await new Promise((r) => setTimeout(r, 40));
  expect(calls).toBe(callsAtShutdown); // no ticks survive shutdown
});

// A host launched local-only and promoted by the desktop wizard has no
// `opts.remote` — its machine config lives in `wizardRemote`. The heartbeat
// cadence has to answer to the SAME resolution the rest of
// startRemoteControlPlane uses, or the timer ticks into a no-op and
// trusted-peers.json (the E2E-admission inventory cache) never refreshes on
// exactly the path the wizard creates.
test("a wizard-promoted host (no opts.remote) actually pushes on the heartbeat cadence", async () => {
  host = new HostServer({
    remoteRuntimeFactory: () => Promise.resolve(fakeRuntime()),
    relayClientFactory: () => stubRelayClient(),
    heartbeatIntervalMs: 15,
  });

  await host.ensureMachineRelay({
    id: "1",
    type: "agent:enableRelay",
    relayUrl: "ws://127.0.0.1:1",
    licenseApiUrl: "http://127.0.0.1:1",
    auth: {
      deviceUuid: "11111111-2222-3333-4444-555555555555",
      ed25519Pub: "cHVi",
      ed25519Priv: "cHJpdg==",
      clientId: "cid",
      clientSecret: "secret",
    },
  } as AgentEnableRelay);

  // The tick's observable work: warming the trusted-peers cache.
  let refreshes = 0;
  (host as unknown as { trustedPeers: { refresh: () => Promise<void> } }).trustedPeers = {
    refresh: () => { refreshes++; return Promise.resolve(); },
  };

  await new Promise((r) => setTimeout(r, 80));
  expect(refreshes).toBeGreaterThanOrEqual(2);
});

test("prunes seen-catalog entries whose folder no longer exists, on load", () => {
  const liveFolder = tempFolder();
  const deadFolder = join(tmpdir(), "antgrid-host-GONE-does-not-exist");
  const agentsDir = join(abDir!, "agents");
  mkdirSync(agentsDir, { recursive: true });
  const projectsJson = join(agentsDir, "projects.json");
  writeFileSync(
    projectsJson,
    JSON.stringify({
      version: 1,
      projects: {
        live: { path: liveFolder, label: "live", lastActiveAt: "2026-01-01T00:00:00.000Z" },
        dead: { path: deadFolder, label: "dead", lastActiveAt: "2026-01-01T00:00:00.000Z" },
      },
    }),
  );

  // Construction loads + prunes + reflushes.
  host = new HostServer({});

  const after = JSON.parse(readFileSync(projectsJson, "utf8"));
  expect(after.projects.live).toBeDefined();
  expect(after.projects.dead).toBeUndefined();
});

async function waitFor(predicate: () => boolean, what: string, timeoutMs = 10_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((r) => setTimeout(r, 20));
  }
  throw new Error(`timed out waiting for ${what}`);
}

// R3: Wave 1's machine-wide sessionBus.self() started stamping the session
// index's folder-basename label instead of the project's configured name,
// silently regressing a value that goes out on the wire (session-index.ts's
// own doc named the gap). This pins the fix at the one seam that actually
// carries a name onto a frame: the loopback owner creates a real session in a
// project whose antgrid.yaml names itself, and the envelope self() stamps for
// it must carry that name, not the temp folder's random basename.
test(
  "a session-bus frame carries the project's configured antgrid.yaml name, not its folder name",
  async () => {
    host = new HostServer({
      remote: fakeRemoteConfig(),
      remoteRuntimeFactory: () => Promise.resolve(fakeRuntime()),
      relayClientFactory: () => stubRelayClient(),
    });
    const folder = tempFolder();
    writeFileSync(join(folder, "antgrid.yaml"), "name: configured-project-name\nagent:\n  tool: claude-code\n");
    const projectId = computeProjectId(folder);
    const opened = await host.open(projectId, folder, "remote");
    if (!opened.connect) throw new Error("expected a loopback connect info");

    const ws = new WebSocket(`ws://127.0.0.1:${opened.connect.port}`);
    await new Promise<void>((resolve, reject) => {
      ws.onopen = () => resolve();
      ws.onerror = (e) => reject(e);
    });
    const inbox: any[] = [];
    ws.onmessage = (ev) => inbox.push(JSON.parse(String(ev.data)));
    ws.send(JSON.stringify({ type: "hello", token: opened.connect.token, appPid: 1, appVersion: "test" }));
    await waitFor(() => inbox.some((m) => m.type === "ready"), "loopback ready");

    const requestId = crypto.randomUUID();
    ws.send(JSON.stringify(createMessage("session:create", { requestId, name: "s1" })));
    await waitFor(
      () => inbox.some((m) => m.type === "session:result" && m.requestId === requestId),
      "session:create result",
    );
    const result = inbox.find((m) => m.type === "session:result" && m.requestId === requestId);
    const sessionId = result.session.id as string;
    ws.close();

    const sessionBus = (host as unknown as { sessionBus: SessionBusCoordinator }).sessionBus;
    const res = sessionBus.message({
      sessionId,
      verb: "post",
      threadId: null,
      to: { machineId: "m-remote", projectId: "p-remote", sessionId: "s-remote" },
      summary: "hi",
      parts: [{ kind: "text", text: "hi" }],
    });
    expect("ok" in res && res.ok).toBe(true);

    const entries = sessionBus.messages(sessionId).entries;
    expect(entries).toHaveLength(1);
    const peer = entries[0]!.envelope.metadata.peer as { projectLabel?: string };
    expect(peer.projectLabel).toBe("configured-project-name");
  },
  20_000,
);

// §6.1: a send between two sessions this HOST holds must not need a
// relay, a carrier, or a route — `SessionBusCoordinator.dispatch` hands a
// same-machine target straight to `deliverLocal` (host-server.ts), which
// requires only that the target's project core is loaded here right now.
// Every case below runs a `HostServer` with no remote config, no
// `startControlPlane()` call, and a loopback owner it deliberately never
// declares `capabilities.sessionBusCarrier` for (and then closes) — the
// literal "desktop disconnected, remote access off" state the design has to
// survive, since neither one is ever wired to anything that could carry a
// frame off this machine.

// Both sessions below are opened on the SAME bare `HostServer`, so both resolve
// to this sentinel — which is what lets a send legitimately address "this
// machine" without any relay ever having started.

/** Give [host] a relay device id without standing a control plane up, so a test
 *  can cross the one boundary `self()` changes answer at. Reaching past the
 *  getter is the point: what matters is that the machine acquires a network
 *  name mid-run, which is exactly what a late `startRemoteControlPlane()` does
 *  to a bridge that had been answering locally all along. */
function withRegistration(host: HostServer, deviceId: string): void {
  (host as unknown as { controlPlaneRelay: { deviceId: string; close: () => void } | null }).controlPlaneRelay = {
    deviceId,
    close: () => {},
  };
  expect(host.controlPlaneRegistrationId).toBe(deviceId);
}

/** Opens [folder] as a local project and creates one shared session in it over
 *  the loopback WS — the same dance the "configured antgrid.yaml name" test
 *  above does — then closes the socket. `session:create` alone never starts a
 *  PTY (machine-level suite's own comment), so the returned session is
 *  registered but not "running", and the closed socket leaves no owner able
 *  to carry a bus frame anywhere. */
async function openLocalSession(
  host: HostServer,
  folder: string,
  name: string,
): Promise<{ projectId: string; sessionId: string }> {
  const projectId = computeProjectId(folder);
  const opened = await host.open(projectId, folder, "local");
  if (!opened.connect) throw new Error("expected a loopback connect info");
  const ws = new WebSocket(`ws://127.0.0.1:${opened.connect.port}`);
  await new Promise<void>((resolve, reject) => {
    ws.onopen = () => resolve();
    ws.onerror = (e) => reject(e);
  });
  const inbox: any[] = [];
  ws.onmessage = (ev) => inbox.push(JSON.parse(String(ev.data)));
  ws.send(JSON.stringify({ type: "hello", token: opened.connect.token, appPid: 1, appVersion: "test" }));
  await waitFor(() => inbox.some((m) => m.type === "ready"), `${name} loopback ready`);
  const requestId = crypto.randomUUID();
  ws.send(JSON.stringify(createMessage("session:create", { requestId, name })));
  await waitFor(
    () => inbox.some((m) => m.type === "session:result" && m.requestId === requestId),
    `${name} session:create result`,
  );
  const result = inbox.find((m) => m.type === "session:result" && m.requestId === requestId);
  const sessionId = result.session.id as string;
  ws.close();
  return { projectId, sessionId };
}

function busCoordinatorOf(host: HostServer): SessionBusCoordinator {
  return (host as unknown as { sessionBus: SessionBusCoordinator }).sessionBus;
}

test(
  "a local post reaches the target's mailbox with the desktop disconnected and remote access off",
  async () => {
    host = new HostServer({}); // no remote config at all: no relay, no control plane
    const { sessionId: sessionA } = await openLocalSession(host, tempFolder(), "session-a");
    const { projectId: projectIdB, sessionId: sessionB } = await openLocalSession(host, tempFolder(), "session-b");
    expect(host.controlPlaneRegistrationId).toBeNull();

    const sessionBus = busCoordinatorOf(host);
    const res = sessionBus.message({
      sessionId: sessionA,
      verb: "post",
      threadId: null,
      to: { machineId: LOCAL_MACHINE_ID, projectId: projectIdB, sessionId: sessionB },
      summary: "hi from a",
      parts: [{ kind: "text", text: "hi" }],
    });
    if (!("ok" in res) || !res.ok) throw new Error(`message refused: ${JSON.stringify(res)}`);
    // Delivered in process, never merely accepted: `sent: true` and `held:
    // false` are deliverLocal's own outcome — deps.send would find no carrier
    // here at all and hold it (case below proves that half).
    expect(res.sent).toBe(true);
    expect(res.held).toBe(false);

    const mailbox = sessionBus.mailbox(sessionB);
    expect(mailbox.posts).toHaveLength(1);
    expect(mailbox.posts[0]!.from.sessionId).toBe(sessionA);
    expect(mailbox.posts[0]!.summary).toBe("hi from a");
  },
  20_000,
);

test(
  "a local notify reaches the target's delivery queue with the desktop disconnected and remote access off",
  async () => {
    host = new HostServer({});
    const { sessionId: sessionA } = await openLocalSession(host, tempFolder(), "session-a");
    const { projectId: projectIdB, sessionId: sessionB } = await openLocalSession(host, tempFolder(), "session-b");

    const sessionBus = busCoordinatorOf(host);
    const res = sessionBus.message({
      sessionId: sessionA,
      verb: "notify",
      threadId: null,
      to: { machineId: LOCAL_MACHINE_ID, projectId: projectIdB, sessionId: sessionB },
      summary: "fyi from a",
      parts: [{ kind: "text", text: "fyi" }],
    });
    if (!("ok" in res) || !res.ok) throw new Error(`message refused: ${JSON.stringify(res)}`);
    expect(res.sent).toBe(true);

    // A notify never parks in the mailbox — that is a post's own path
    // (deliver-event.ts's `lineForEvent`: "a post owes none").
    expect(sessionBus.mailbox(sessionB).posts).toHaveLength(0);

    const cores = (host as unknown as {
      cores: Map<string, { core: { deliveries: { lines: readonly { sessionId: string; kind: string }[] } } }>;
    }).cores;
    const queued = cores.get(projectIdB)!.core.deliveries.lines;
    // session-b was created but never started (no PTY), so `injectBusLine`
    // finds nothing running to submit into and the rendered line stays
    // queued rather than being delivered and removed. That a notify to a
    // stopped session is REFUSED (§7.3) is the verb layer's own decision and
    // is taken above this one — what the transport owes here is a rendered
    // line parked where the session will read it when it next reaches a turn
    // boundary, which is also what a session stopped after the send gets.
    expect(queued).toHaveLength(1);
    expect(queued[0]!.sessionId).toBe(sessionB);
    expect(queued[0]!.kind).toBe("notify");
  },
  20_000,
);

test(
  "a local send never writes an entry into the carrier route table",
  async () => {
    host = new HostServer({});
    const { sessionId: sessionA } = await openLocalSession(host, tempFolder(), "session-a");
    const { projectId: projectIdB, sessionId: sessionB } = await openLocalSession(host, tempFolder(), "session-b");

    const sessionBus = busCoordinatorOf(host);
    expect(sessionBus.routeFor(sessionA)).toBeNull(); // nothing to untouch yet — the baseline
    const res = sessionBus.message({
      sessionId: sessionA,
      verb: "post",
      threadId: null,
      to: { machineId: LOCAL_MACHINE_ID, projectId: projectIdB, sessionId: sessionB },
      summary: "hi",
      parts: [{ kind: "text", text: "hi" }],
    });
    if (!("ok" in res) || !res.ok) throw new Error(`message refused: ${JSON.stringify(res)}`);
    expect(res.sent).toBe(true);

    // deliverLocal never calls noteRoute — the table exists for the carrier
    // path alone (`send`'s peer/lead branches), so a local exchange leaves it
    // exactly as empty as it started, not merely free of an error.
    expect(sessionBus.routeFor(sessionA)).toBeNull();
  },
  20_000,
);

test(
  "the E6 ack for a local post lands with no route in the table",
  async () => {
    host = new HostServer({});
    const { sessionId: sessionA } = await openLocalSession(host, tempFolder(), "session-a");
    const { projectId: projectIdB, sessionId: sessionB } = await openLocalSession(host, tempFolder(), "session-b");

    const sessionBus = busCoordinatorOf(host);
    const res = sessionBus.message({
      sessionId: sessionA,
      verb: "post",
      threadId: null,
      to: { machineId: LOCAL_MACHINE_ID, projectId: projectIdB, sessionId: sessionB },
      summary: "hi",
      parts: [{ kind: "text", text: "hi" }],
    });
    if (!("ok" in res) || !res.ok) throw new Error(`message refused: ${JSON.stringify(res)}`);
    expect(res.sent).toBe(true);

    // onMessage dispatches the receipt back through the very same `dispatch`
    // a message takes (coordinator.ts: a direct `send` would find no route
    // for this pair — sessionA's context was never carried in by anyone —
    // and drop it). The receipt's role is "peer" (roleForContext: its context
    // is sessionA, not the receiving session sessionB), which is exactly the
    // role a real carrier route lookup would have been keyed on had this gone
    // through `send` instead. Proof it still landed is the sender's own log
    // entry stamped delivered, with that same context never having earned a
    // route entry at all.
    const entries = sessionBus.messages(sessionA).entries;
    expect(entries).toHaveLength(1);
    expect(entries[0]!.deliveredAt).toBeDefined();
    expect(sessionBus.routeFor(sessionA)).toBeNull();
  },
  20_000,
);

test(
  "a send naming a different machineId is refused outright without a relay identity, never folded locally",
  async () => {
    host = new HostServer({});
    const { sessionId: sessionA } = await openLocalSession(host, tempFolder(), "session-a");
    const { projectId: projectIdB, sessionId: sessionB } = await openLocalSession(host, tempFolder(), "session-b");

    const sessionBus = busCoordinatorOf(host);
    // session-b genuinely exists on this host under its real project id, so if
    // `dispatch` placed a frame by its target's SESSION rather than by the
    // machine named on it, deliverLocal would fold this straight into a
    // mailbox the sender never addressed.
    //
    // What must happen instead is a refusal, not a hold: the sentinel this
    // host names itself by buys the local path an address, not a network, and
    // a frame held for a carrier that may attach later would reach the peer
    // stamped `from: local` — an address no reply can be routed back to.
    const res = sessionBus.message({
      sessionId: sessionA,
      verb: "post",
      threadId: null,
      to: { machineId: "some-other-machine", projectId: projectIdB, sessionId: sessionB },
      summary: "should not land locally",
      parts: [{ kind: "text", text: "should not land locally" }],
    });
    expect("ok" in res && res.ok).toBe(false);
    expect((res as { code?: string }).code).toBe("AGENT_NOT_READY");
    expect(sessionBus.mailbox(sessionB).posts).toHaveLength(0);
    // Refused before anything was stamped: no log entry, so nothing is held
    // and nothing will be retried.
    expect(sessionBus.messages(sessionA).entries).toHaveLength(0);
  },
  20_000,
);

test(
  "a send naming a different machineId goes through deps.send once this machine has a relay identity",
  async () => {
    host = new HostServer({});
    const { sessionId: sessionA } = await openLocalSession(host, tempFolder(), "session-a");
    const { projectId: projectIdB, sessionId: sessionB } = await openLocalSession(host, tempFolder(), "session-b");
    withRegistration(host, "machine-registered");

    const sessionBus = busCoordinatorOf(host);
    const res = sessionBus.message({
      sessionId: sessionA,
      verb: "post",
      threadId: null,
      to: { machineId: "some-other-machine", projectId: projectIdB, sessionId: sessionB },
      summary: "should not land locally",
      parts: [{ kind: "text", text: "should not land locally" }],
    });
    if (!("ok" in res) || !res.ok) throw new Error(`message refused: ${JSON.stringify(res)}`);
    // `send` here has no carrier at all — the loopback owner never declared
    // itself a bus carrier and its socket is closed — so the frame is held,
    // which is the outcome that proves it took the remote arm.
    expect(res.sent).toBe(false);
    expect(res.held).toBe(true);
    expect(sessionBus.mailbox(sessionB).posts).toHaveLength(0);
  },
  20_000,
);

test(
  "a pair that exchanged before this machine registered still reaches itself afterwards",
  async () => {
    host = new HostServer({});
    const { sessionId: sessionA } = await openLocalSession(host, tempFolder(), "session-a");
    const { projectId: projectIdB, sessionId: sessionB } = await openLocalSession(host, tempFolder(), "session-b");

    const sessionBus = busCoordinatorOf(host);
    const first = sessionBus.message({
      sessionId: sessionA,
      verb: "post",
      threadId: null,
      to: { machineId: LOCAL_MACHINE_ID, projectId: projectIdB, sessionId: sessionB },
      summary: "before",
      parts: [{ kind: "text", text: "before" }],
    });
    if (!("ok" in first) || !first.ok) throw new Error(`message refused: ${JSON.stringify(first)}`);
    // The sentinel is now on a DURABLE row: this is the address session-b's
    // reply reads back, and the machine is about to rename itself.
    const stored = sessionBus.mailbox(sessionB).posts[0]!.from;
    expect(stored.machineId).toBe(LOCAL_MACHINE_ID);

    withRegistration(host, "machine-registered");

    const back = sessionBus.message({
      sessionId: sessionB,
      verb: "post",
      threadId: null,
      to: stored,
      summary: "after",
      parts: [{ kind: "text", text: "after" }],
    });
    if (!("ok" in back) || !back.ok) throw new Error(`reply refused: ${JSON.stringify(back)}`);
    expect(back.sent).toBe(true);
    expect(sessionBus.mailbox(sessionA).posts).toHaveLength(1);
  },
  20_000,
);

test(
  "a send naming a local session whose project core is not loaded returns false and holds the frame",
  async () => {
    host = new HostServer({});
    const { projectId: projectIdA, sessionId: sessionA } = await openLocalSession(host, tempFolder(), "session-a");
    const folderB = tempFolder();
    const { projectId: projectIdB, sessionId: sessionB } = await openLocalSession(host, folderB, "session-b");

    // Cold project B: `stop()` snapshots it into the session index before
    // dropping it from `cores` (host-server.ts's `noteColdSnapshot`), so
    // sessionIndex.lookup still resolves it — deliverLocal's SECOND
    // condition, "and a core for it is actually loaded here right now", is
    // the one this trips.
    await host.stop(projectIdB);
    expect(host.list().some((p) => p.projectId === projectIdB)).toBe(false);

    const sessionBus = busCoordinatorOf(host);
    const res = sessionBus.message({
      sessionId: sessionA,
      verb: "post",
      threadId: null,
      to: { machineId: LOCAL_MACHINE_ID, projectId: projectIdB, sessionId: sessionB },
      summary: "hi",
      parts: [{ kind: "text", text: "hi" }],
    });
    if (!("ok" in res) || !res.ok) throw new Error(`message refused: ${JSON.stringify(res)}`);
    expect(res.sent).toBe(false);
    expect(res.held).toBe(true);

    // Held to DISK under the sender's own project, not merely reported held —
    // this is what a restart before the core comes back warm resumes from.
    const held = loadHeld(abDir!, projectIdA, sessionA);
    expect(held.held.some((h) => h.messageId === res.messageId && h.to.sessionId === sessionB)).toBe(true);

    // And the hold is a DELAY, not a loss: the retry pump takes the same send
    // decision the first attempt took, so the local arm delivers it the moment
    // the target's project is warm again. A pump that went straight to `send`
    // would keep offering a local frame to a carrier that has none until the
    // hold aged out, which is a message lost with every log line green.
    await host.open(projectIdB, folderB, "local");
    sessionBus.pump();
    expect(sessionBus.mailbox(sessionB).posts).toHaveLength(1);
    expect(loadHeld(abDir!, projectIdA, sessionA).held).toHaveLength(0);
  },
  20_000,
);

test(
  "a coordinator with no control-plane registration id at all still delivers locally (relay connection down)",
  async () => {
    // A relay identity is CONFIGURED but startControlPlane() is never called:
    // the exact "relay connection down" state 6.1 has to survive, since
    // `self()`'s LOCAL_MACHINE_ID fallback is keyed on the registration id
    // being absent, never on whether `opts.remote` itself is set.
    host = new HostServer({
      remote: fakeRemoteConfig(),
      remoteRuntimeFactory: () => Promise.resolve(fakeRuntime()),
    });
    expect(host.controlPlaneRegistrationId).toBeNull();

    const { sessionId: sessionA } = await openLocalSession(host, tempFolder(), "session-a");
    const { projectId: projectIdB, sessionId: sessionB } = await openLocalSession(host, tempFolder(), "session-b");

    const sessionBus = busCoordinatorOf(host);
    const res = sessionBus.message({
      sessionId: sessionA,
      verb: "post",
      threadId: null,
      to: { machineId: LOCAL_MACHINE_ID, projectId: projectIdB, sessionId: sessionB },
      summary: "hi",
      parts: [{ kind: "text", text: "hi" }],
    });
    if (!("ok" in res) || !res.ok) throw new Error(`message refused: ${JSON.stringify(res)}`);
    expect(res.sent).toBe(true);
    expect(sessionBus.mailbox(sessionB).posts).toHaveLength(1);
  },
  20_000,
);
