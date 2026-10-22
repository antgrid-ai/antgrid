import { createHostPolicyFixture } from "./host-policy-fixture";
import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostServer, type HostRemoteConfig, type RemoteRuntime } from "../src/host-server";

const ID = "11111111-2222-4333-8444-555555555555";

function fakeRemoteConfig(): HostRemoteConfig {
  return {
    relayUrl: "ws://127.0.0.1:1", licenseApiUrl: "http://127.0.0.1:1",
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
let abDir: string;
let checkout: string;

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = realpathSync(mkdtempSync(join(tmpdir(), "antgrid-handoff-host-")));
  checkout = realpathSync(mkdtempSync(join(tmpdir(), "antgrid-handoff-checkout-")));
  process.env.ANTGRID_DIR = abDir;
  host = createHostPolicyFixture({ remote: fakeRemoteConfig(), remoteRuntimeFactory: () => Promise.resolve(fakeRuntime()) });
});

afterEach(async () => {
  await host?.shutdown();
  host = null;
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR; else process.env.ANTGRID_DIR = prevAbDir;
  rmSync(abDir, { recursive: true, force: true });
  rmSync(checkout, { recursive: true, force: true });
});

/** A fork row whose files were already placed in `checkout`, plus the staging dir of an unlaunched one. */
function seedPlacedHandoff(projectId: string): { placed: string; staged: string } {
  const placed = join(checkout, ".antgrid", "handoff", ID);
  mkdirSync(placed, { recursive: true });
  writeFileSync(join(placed, "manifest.json"), "{}");
  const stagedId = "99999999-2222-4333-8444-555555555555";
  const staged = join(abDir, "agents", projectId, "handoff", stagedId);
  mkdirSync(staged, { recursive: true });
  writeFileSync(join(staged, "manifest.json"), "{}");
  writeFileSync(join(abDir, "agents", projectId, "sessions.json"), JSON.stringify({ version: 1, sessions: [
    { id: ID, name: "Placed", createdAt: 1, lastUsedAt: 1, archived: false, forkHandoff: { state: "materialized", sourceTool: "kimi", root: checkout } },
    { id: stagedId, name: "Staged", createdAt: 2, lastUsedAt: 2, archived: false, forkHandoff: { state: "staged", sourceTool: "kimi" } },
  ] }));
  return { placed, staged };
}

test("a cold delete removes the fork's checkout handoff dir", async () => {
  const h = host!;
  const { placed } = seedPlacedHandoff("projA");
  (h as any).seenProjects.set("projA", { path: checkout, label: "projA" });
  await h.handleRemoteAccessVerb({ id: "t", type: "mobile-access:set", enabled: true });

  const res = (await h.handleSessionsDeleteRpc({
    id: "x", timestamp: 0, type: "request", requestId: "rq1", method: "sessions.delete",
    params: { projectId: "projA", sessionId: ID },
  } as any)) as any;

  expect(res.result.deleted).toBe(true);
  expect(existsSync(placed)).toBe(false);
});

test("a cold delete of an unlaunched fork removes its staging dir", async () => {
  const h = host!;
  const { staged } = seedPlacedHandoff("projA");
  (h as any).seenProjects.set("projA", { path: checkout, label: "projA" });
  await h.handleRemoteAccessVerb({ id: "t", type: "mobile-access:set", enabled: true });

  await h.handleSessionsDeleteRpc({
    id: "x", timestamp: 0, type: "request", requestId: "rq1", method: "sessions.delete",
    params: { projectId: "projA", sessionId: "99999999-2222-4333-8444-555555555555" },
  } as any);

  expect(existsSync(staged)).toBe(false);
});

test("forgetting a project removes handoff dirs in shared checkouts", async () => {
  const h = host!;
  const { placed } = seedPlacedHandoff("projA");
  writeFileSync(join(checkout, "work.txt"), "mine");
  (h as any).seenProjects.set("projA", { path: checkout, label: "projA" });

  await h.forget("projA");

  expect(existsSync(placed)).toBe(false);
  expect(existsSync(join(checkout, "work.txt"))).toBe(true);
  expect(existsSync(join(abDir, "agents", "projA"))).toBe(false);
});
