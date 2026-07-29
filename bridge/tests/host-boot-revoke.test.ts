import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostServer, type HostRemoteConfig, type RemoteRuntime } from "../src/host-server";
import type { RelayClient, RelayClientOptions } from "../src/relay-client";

// index.ts wires HostRemoteConfig.onAuthRevoked to `process.exit(4)`, so
// whether it fires at boot decides whether the host survives. These tests pin
// the arming window rather than the exit itself (a test cannot observe exit).

function remoteConfig(onAuthRevoked: () => void): HostRemoteConfig {
  return {
    relayUrl: "ws://127.0.0.1:1",
    licenseApiUrl: "http://127.0.0.1:1",
    identity: { deviceId: "dev-1", deviceName: "dev-1", createdAt: "2026-01-01T00:00:00.000Z" },
    auth: { clientId: "cid", clientSecret: "secret", deviceUuid: "uuid-1" },
    onAuthRevoked,
  };
}

function fakeRuntime(): RemoteRuntime {
  return { maint: { getToken: () => "tok", stop: () => {} } };
}

// A real RelayClient against the unreachable fake URL would leave reconnect
// timers running past shutdown, and a sibling suite that swaps globalThis.setTimeout
// captures whichever callback lands first — cross-file flake with no bearing on
// what this file asserts. Stub it out; these tests never touch the socket.
function stubRelayFactory() {
  return (_opts: RelayClientOptions): RelayClient =>
    ({
      deviceId: "dev-1",
      currentPeerPubkey: () => null,
      setBus: () => {},
      connect: () => {},
      close: () => {},
    }) as unknown as RelayClient;
}

let host: HostServer | null = null;
let prevAbDir: string | undefined;
let abDir: string | undefined;

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-boot-revoke-"));
  process.env.ANTGRID_DIR = abDir;
});

afterEach(async () => {
  await host?.shutdown();
  host = null;
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR; else process.env.ANTGRID_DIR = prevAbDir;
  if (abDir) rmSync(abDir, { recursive: true, force: true });
});

// The regression: a rotated-away OAuth client makes the boot mint fail, and a
// fatal verdict there kills the host AFTER host.json + the ready marker have
// gone out — so the app's supervisor respawns it into the same dead pair,
// forever, taking the working loopback plane down with it. Only a respawn with
// fresh credentials can help, which is not something this process can do.
test("a revoke verdict during the BOOT mint does not reach the fatal handler", async () => {
  let fatal = 0;
  host = new HostServer({
    remote: remoteConfig(() => fatal++),
    // Stands in for OAuthClient rejecting the boot mint as invalid_client.
    remoteRuntimeFactory: (cfg) => {
      cfg.onAuthRevoked();
      return Promise.reject(new Error("oauth: invalid_client"));
    },
  });
  await host.startControlPlane();
  expect(fatal).toBe(0);
});

// Same verdict once the boot window has closed IS fatal: at that point the
// credentials were good enough to come up, so the device really was revoked.
test("a revoke verdict after boot still reaches the fatal handler", async () => {
  let fatal = 0;
  let cfgSeen: HostRemoteConfig | null = null;
  host = new HostServer({
    remote: remoteConfig(() => fatal++),
    remoteRuntimeFactory: (cfg) => {
      cfgSeen = cfg;
      return Promise.resolve(fakeRuntime());
    },
    relayClientFactory: stubRelayFactory(),
  });
  await host.startControlPlane();
  expect(fatal).toBe(0);

  // What startTokenMaintenance's re-mint does on a later invalid_client.
  cfgSeen!.onAuthRevoked();
  expect(fatal).toBe(1);
});
