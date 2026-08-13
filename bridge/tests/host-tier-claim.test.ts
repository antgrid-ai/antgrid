import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostServer, type HostRemoteConfig, type RemoteRuntime } from "../src/host-server";
import type { TierClaim } from "../src/entitlement";

// The claim the entitlement gate reads, at the seam where it is assembled.
// bridge/tests/entitlement.test.ts owns the predicate and
// agent-core-entitlement.test.ts owns the delivery into the engine; both inject
// a claim source directly, so THIS expression — the only place the two halves
// are read off the host — is the one part of the path neither covers.

function fakeRemoteConfig(): HostRemoteConfig {
  return {
    relayUrl: "ws://127.0.0.1:1",
    licenseApiUrl: "http://127.0.0.1:1",
    identity: { deviceId: "dev-1", deviceName: "dev-1", createdAt: "2026-01-01T00:00:00.000Z" },
    auth: { clientId: "cid", clientSecret: "secret", deviceUuid: "uuid-1" },
    onAuthRevoked: () => {},
  };
}

let prevAbDir: string | undefined;
let abDir: string;
const hosts: HostServer[] = [];

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-tier-claim-"));
  process.env.ANTGRID_DIR = abDir;
});

afterEach(async () => {
  // The constructor opens an fs.watch on the phones file; only shutdown() closes
  // it. Runs before ANTGRID_DIR is restored, so it unwatches the dir removed below.
  while (hosts.length) await hosts.pop()!.shutdown();
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR;
  else process.env.ANTGRID_DIR = prevAbDir;
  rmSync(abDir, { recursive: true, force: true });
});

/** Never started: the claim is assembled from constructor state and the injected
 *  runtime, so a socket, a control listener and a host.json would all be props. */
function newHost(remote?: HostRemoteConfig): HostServer {
  const host = new HostServer({ ...(remote ? { remote } : {}) });
  hosts.push(host);
  return host;
}

function claimFrom(args: {
  remote?: HostRemoteConfig;
  runtime?: RemoteRuntime | null;
}): TierClaim {
  const host = newHost(args.remote);
  if (args.runtime !== undefined) {
    (host as unknown as { remoteRuntime: RemoteRuntime | null }).remoteRuntime = args.runtime;
  }
  return (host as unknown as { tierClaimNow: () => TierClaim }).tierClaimNow();
}

function runtimeWithTier(tier: string | null): RemoteRuntime {
  return { maint: { getToken: () => "tok", getTier: () => tier, stop: () => {} } };
}

test("reports the tier the live token carries", () => {
  const claim = claimFrom({ remote: fakeRemoteConfig(), runtime: runtimeWithTier("pro") });
  expect(claim).toEqual({ credentialed: true, tier: "pro" });
});

test("a machine with no remote config is uncredentialed, which is what keeps local work working", () => {
  // The signed-out desktop and the bare agent. Nothing to fail closed on, so the
  // gate's unwired pass is the right answer and this is the field that grants it.
  expect(claimFrom({})).toEqual({ credentialed: false, tier: null });
});

test("credentials come from the CONFIG, so a failed boot mint fails closed rather than open", () => {
  // The boot-time mint is deliberately non-fatal (fatalRevokeArmed), so this
  // state is reachable on any machine that starts up offline: config present,
  // runtime never built. Reading `credentialed` off the runtime instead would
  // report `false` here — the unwired pass — and every machine could reproduce
  // it on purpose by starting with the network down.
  expect(claimFrom({ remote: fakeRemoteConfig(), runtime: null })).toEqual({
    credentialed: true,
    tier: null,
  });
});

test("a runtime that cannot report a tier is an unreadable claim, not an absent credential", () => {
  // `getTier` is optional on RemoteRuntime purely so a test fake can decline it;
  // a fake that does must not thereby hand itself the unwired pass.
  const legacy: RemoteRuntime = { maint: { getToken: () => "tok", stop: () => {} } };
  expect(claimFrom({ remote: fakeRemoteConfig(), runtime: legacy })).toEqual({
    credentialed: true,
    tier: null,
  });
  // Same verdict when the token itself carried no usable tier.
  expect(claimFrom({ remote: fakeRemoteConfig(), runtime: runtimeWithTier(null) })).toEqual({
    credentialed: true,
    tier: null,
  });
});

test("the tier is re-read on every call, never captured", () => {
  // A token is re-minted at 80% of a 3600s TTL, and bounding the downgrade lag
  // to one token lifetime is the whole point of the gate reading live.
  let tier = "pro";
  const host = newHost(fakeRemoteConfig());
  (host as unknown as { remoteRuntime: RemoteRuntime }).remoteRuntime = {
    maint: { getToken: () => "tok", getTier: () => tier, stop: () => {} },
  };
  const read = () => (host as unknown as { tierClaimNow: () => TierClaim }).tierClaimNow();

  expect(read().tier).toBe("pro");
  tier = "free";
  expect(read().tier).toBe("free");
});
