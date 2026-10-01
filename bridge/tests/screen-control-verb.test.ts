import { test, expect, beforeEach, afterEach, spyOn } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostServer, type HostRemoteConfig, type RemoteRuntime } from "../src/host-server";
import { computeProjectId } from "../src/project-id";
import type { ProjectCore } from "../src/project-core";
import type { MessageBus } from "../src/message-bus";
import { createMessage, type AbMessage } from "../src/protocol";

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

let host: HostServer | null = null;
let prevAbDir: string | undefined;
let abDir: string | undefined;

const policyPath = () => join(abDir!, "agents", "screen-control-policy.json");

function tempFolder(): string {
  const f = mkdtempSync(join(tmpdir(), "antgrid-screen-verb-proj-"));
  writeFileSync(join(f, "antgrid.yaml"), "name: test-screen\nagent:\n  tool: claude-code\n");
  return f;
}

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-screen-verb-abdir-"));
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

const get = async (h: HostServer) =>
  (await h.handleScreenControlVerb({ id: "g", type: "screen-control:get" })) as { ok: true; enabled: boolean };
const set = async (h: HostServer, enabled: boolean) =>
  (await h.handleScreenControlVerb({ id: "s", type: "screen-control:set", enabled })) as { ok: true; enabled: boolean };

test("a fresh machine reports the switch off, and reading it writes nothing", async () => {
  const h = host!;
  expect((await get(h)).enabled).toBe(false);
  expect(existsSync(policyPath())).toBe(false);
});

test("the verb is the only way the switch is ever turned on", async () => {
  const h = host!;
  expect((await set(h, true)).enabled).toBe(true);
  expect((await get(h)).enabled).toBe(true);
  // Persisted, so the machine comes back up sharing-capable without the app
  // having to re-assert the setting on every launch.
  expect(JSON.parse(readFileSync(policyPath(), "utf8"))).toEqual({ version: 1, enabled: true });
});

test("the response reports the state the bridge landed on, not the state asked for", async () => {
  const h = host!;
  // The app renders from this rather than assuming its write took, which is
  // what lets a failed flush surface instead of leaving a lying switch on screen.
  await set(h, true);
  expect((await set(h, true)).enabled).toBe(true);
  expect((await set(h, false)).enabled).toBe(false);
});

test("screen control and remote access are separate decisions in both directions", async () => {
  const h = host!;
  // Granting the screen must not silently grant terminal/tree/git...
  await set(h, true);
  const access = (await h.handleRemoteAccessVerb({ id: "a", type: "mobile-access:get" })) as { enabled: boolean };
  expect(access.enabled).toBe(false);

  // ...and turning the machine on for remote work must not hand over the screen
  // with it. Remote screen control is the strictly larger capability, so it can
  // only ever be granted by name.
  await h.handleRemoteAccessVerb({ id: "b", type: "mobile-access:set", enabled: true });
  await set(h, false);
  expect((await get(h)).enabled).toBe(false);
  const stillOn = (await h.handleRemoteAccessVerb({ id: "c", type: "mobile-access:get" })) as { enabled: boolean };
  expect(stillOn.enabled).toBe(true);
});

test("turning remote access off leaves the screen switch as the user set it", async () => {
  const h = host!;
  await h.handleRemoteAccessVerb({ id: "a", type: "mobile-access:set", enabled: true });
  await set(h, true);

  // Off at the outer gate is enough to stop screen sharing (both are ANDed), so
  // there is nothing to fix up here — and rewriting the inner switch would
  // silently discard a preference the user never revoked. Turning remote access
  // back on must not re-grant the screen by surprise either; it doesn't, because
  // this value survived untouched.
  await h.handleRemoteAccessVerb({ id: "b", type: "mobile-access:set", enabled: false });
  expect((await get(h)).enabled).toBe(true);
});

test("the switch is machine-wide — opening or forgetting a project never moves it", async () => {
  const h = host!;
  // The host is authoritative for project identity, so an id that does not match
  // what its path resolves to is refused (PROJECT_ID_MISMATCH). Derive both.
  const folderA = tempFolder();
  const projA = computeProjectId(folderA);
  await h.open(projA, folderA, "local");
  await set(h, true);

  const folderB = tempFolder();
  await h.open(computeProjectId(folderB), folderB, "local");
  await h.forget(projA);

  expect((await get(h)).enabled).toBe(true);
});

/** Open a local project and spy on its core's screen teardown. */
async function openWithRevokeSpy(h: HostServer) {
  const folder = tempFolder();
  const projectId = computeProjectId(folder);
  await h.open(projectId, folder, "local");
  const core = (h as unknown as { cores: Map<string, { core: ProjectCore }> }).cores.get(projectId)!.core;
  return spyOn(core, "revokeScreenSharing");
}

test("turning screen control off ends the screen shares of every open core", async () => {
  const h = host!;
  await set(h, true);
  const revoke = await openWithRevokeSpy(h);

  await set(h, false);
  expect(revoke).toHaveBeenCalledTimes(1);
  expect(revoke).toHaveBeenCalledWith("screen control turned off");

  // A redundant off still tears down: the capture lives in a peer connection
  // the bridge cannot see, so "already off" is not proof nothing is live.
  await set(h, false);
  expect(revoke).toHaveBeenCalledTimes(2);
});

test("turning screen control on ends nothing", async () => {
  const h = host!;
  const revoke = await openWithRevokeSpy(h);
  await set(h, true);
  expect(revoke).not.toHaveBeenCalled();
});

const remoteAccessOn = (h: HostServer) =>
  (h as unknown as { remoteAccessPolicy: { isEnabled(): boolean } }).remoteAccessPolicy.isEnabled();

test("turning remote access off ends the screen shares of every open core, while the switch is still on", async () => {
  const h = host!;
  await h.handleRemoteAccessVerb({ id: "a", type: "mobile-access:set", enabled: true });
  const revoke = await openWithRevokeSpy(h);
  const switchAtRevoke: boolean[] = [];
  revoke.mockImplementation(async () => { switchAtRevoke.push(remoteAccessOn(h)); });

  await h.handleRemoteAccessVerb({ id: "b", type: "mobile-access:set", enabled: false });
  expect(revoke).toHaveBeenCalledWith("remote access turned off");
  expect(switchAtRevoke).toEqual([true]);
  expect(remoteAccessOn(h)).toBe(false);

  // Already off: no viewer stream is left to tell, and the bridge refused
  // every screen frame since the switch went off.
  await h.handleRemoteAccessVerb({ id: "c", type: "mobile-access:set", enabled: false });
  expect(revoke).toHaveBeenCalledTimes(1);
});

test("turning remote access off tells the viewer before its project stream is gated", async () => {
  const h = host!;
  await h.handleRemoteAccessVerb({ id: "a", type: "mobile-access:set", enabled: true });
  await set(h, true);
  const folder = tempFolder();
  const projectId = computeProjectId(folder);
  await h.open(projectId, folder, "local");
  const core = (h as unknown as { cores: Map<string, { core: ProjectCore }> }).cores.get(projectId)!.core;
  const bus = (core as unknown as { bus: MessageBus }).bus;

  // The same gate project-streams.ts applies to every outbound record.
  const delivered: AbMessage[] = [];
  bus.subscribe({ audience: "relay", deliver: (msg) => { if (remoteAccessOn(h)) delivered.push(msg); } });

  const info = core.localConnectInfo!;
  const ws = new WebSocket(`ws://127.0.0.1:${info.port}`);
  try {
    await new Promise<void>((resolve, reject) => { ws.onopen = () => resolve(); ws.onerror = (e) => reject(e); });
    const ready = new Promise<void>((resolve) => {
      ws.onmessage = (ev) => { if (JSON.parse(String(ev.data)).type === "ready") resolve(); };
    });
    ws.send(JSON.stringify({ type: "hello", token: info.token, appPid: 1, appVersion: "test" }));
    await ready;

    bus.dispatchInbound(createMessage("screen:request", { projectId }), "control", "relay", "phone-a#machine");
    await h.handleRemoteAccessVerb({ id: "b", type: "mobile-access:set", enabled: false });

    expect(delivered).toContainEqual(expect.objectContaining({
      type: "screen:state", status: "ended", reason: "remote access turned off", viewerId: "phone-a#machine",
    }));
  } finally {
    ws.close();
  }
});
