// E2E eval: same-account mobile access defaults (Task 6).
//
// Proves that if `mobile-access:enable-project` is sent for projA BEFORE any
// phone connects, then a same-account phone connecting via account-trust
// (no pairing ceremony) sees projA in its FIRST `agent:projects` advertisement.
//
// Because the ordering under test ("enable BEFORE the phone connects") is the
// whole point of this eval, it can't use `setupTestEnv` (which connects+
// handshakes its app as part of the same call) — it drives its own relay +
// agent + phone sequence, mirroring `setupTestEnv`'s internals but delaying
// the phone's connection until after the enable-project call.
//
// Pair-code / manual negative assertion:
//   There is no test-only pairing-window hook left to admit a genuine
//   pair-code phone (that mechanism, and pairing itself, is gone). Instead we
//   assert the scoped negative that IS cleanly expressible: a SECOND project
//   that is genuinely opened on the host (via the loopback `project:open`
//   verb — mirrors multi-stream-coexistence.test.ts) but never passed to
//   `mobile-access:enable-project` must be absent from the same-account
//   phone's advert. `buildProjectsAdvertisement` (host-server.ts) filters
//   from `phone.allowedProjects` first, so a warm-but-unenabled project is
//   excluded regardless of catalog visibility — a made-up project id could
//   never appear either way (agent:projects only carries real opened
//   projects), so it wouldn't exercise that filter.
//
// Known Windows test noise (NOT failures): fs.watch EPERM/EBUSY on teardown,
// temp-dir cleanup races. Judge by pass/fail counts.
import { test, expect } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  allocatePort,
  generateAppIdentity,
  generateEvalAuth,
  handshakeWithoutPairing,
  spawnAgent,
  startFakeLicenseApi,
  startRelay,
  type AgentHandle,
  type FakeLicenseApi,
  type RelayHandle,
} from "../../helpers/harness";
import { createTestProject, type TestProject } from "../../helpers/fixtures";
import { computeProjectId } from "../../../bridge/src/project-id";
import { RelayClient } from "../../helpers/relay-client";

/** POST a control-plane verb over the loopback control port (see host.json's
 *  `controlPort`/`token`) — used here to open a second project remotely
 *  without going through mobile-access:enable-project, mirroring
 *  multi-stream-coexistence.test.ts's `loopbackControl`. */
async function loopbackControl(
  abDir: string,
  body: object,
): Promise<{ ok: boolean; [k: string]: unknown }> {
  const { readHostFile } = await import("@bridge/host-discovery");
  const hf = readHostFile(join(abDir, "host.json"));
  if (!hf) throw new Error("no host.json for loopback control");
  const res = await fetch(`http://127.0.0.1:${hf.controlPort}/control`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${hf.token}` },
    body: JSON.stringify(body),
  });
  return res.json();
}

/** Poll readHostFile until host.json appears (agent writes it during startup).
 *  The test sends `mobile-access:enable-project` BEFORE connecting any phone,
 *  so host.json must exist first. Cap: 5 s. */
async function waitForHostFile(
  abDir: string,
  timeoutMs = 5_000,
): Promise<import("@bridge/host-discovery").HostFile> {
  const { readHostFile } = await import("@bridge/host-discovery");
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const hf = readHostFile(join(abDir, "host.json"));
    if (hf) return hf;
    await Bun.sleep(100);
  }
  throw new Error("host.json did not appear within timeout");
}

test(
  "same-account phone receives enabled project in first agent:projects advertisement",
  async () => {
    // relay/licenseApi/project are constructed INSIDE the try (not hoisted
    // above it): a throw from either of the latter two after the relay is up
    // would otherwise skip the finally block entirely and leak the relay
    // (port + process) for the life of the test run — declare the handles
    // above the try so finally can reach them, but create them inside it.
    let abDir: string | undefined;
    let relay: RelayHandle | undefined;
    let licenseApi: FakeLicenseApi | undefined;
    let project: TestProject | undefined;
    let neverEnabledProject: TestProject | undefined;
    let agent: AgentHandle | undefined;
    let cp: RelayClient | null = null;
    try {
      const relayPort = allocatePort();
      abDir = mkdtempSync(join(tmpdir(), "antgrid-mobile-defaults-"));
      const appIdentity = await generateAppIdentity();

      relay = await startRelay({ port: relayPort });
      licenseApi = startFakeLicenseApi({
        accountDevices: [{ deviceId: appIdentity.deviceId, ed25519Pub: appIdentity.publicKeyBase64 }],
      });
      const auth = generateEvalAuth();
      project = createTestProject("basic", {
        "__RELAY_URL__": `ws://localhost:${relayPort}`,
      });
      const projectId = computeProjectId(project.dir);
      const deviceUuid = auth.deviceUuid;

      agent = await spawnAgent({
        relayUrl: relay.url,
        licenseApiUrl: licenseApi.url,
        abDir,
        projectDir: project.dir,
        auth,
        env: { ANTGRID_EVAL_TEST: "1" },
      });

      // ── Step 1: enable projA BEFORE any phone connects ────────────────────
      const hf = await waitForHostFile(abDir);

      const enableRes = await fetch(`http://127.0.0.1:${hf.controlPort}/control`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${hf.token}`,
        },
        body: JSON.stringify({
          id: "eval-enable",
          type: "mobile-access:enable-project",
          projectId,
        }),
      });
      const enableBody = (await enableRes.json()) as {
        ok: boolean;
        projectIds?: string[];
      };

      // Confirm the policy verb succeeded and stored projA.
      expect(enableBody.ok).toBe(true);
      expect(enableBody.projectIds).toContain(projectId);

      // ── Step 1b: open a SECOND project remotely, but never enable it ───────
      neverEnabledProject = createTestProject("basic", {
        "__RELAY_URL__": `ws://localhost:${relayPort}`,
      });
      const neverEnabledId = computeProjectId(neverEnabledProject.dir);
      const openRes = await loopbackControl(abDir, {
        id: "open-never-enabled",
        type: "project:open",
        projectId: neverEnabledId,
        projectPath: neverEnabledProject.dir,
        mode: "remote",
      });
      expect(openRes.ok).toBe(true);

      // ── Step 2: connect a same-account phone on the control plane ─────────
      //
      // Control-plane registration is under the bare deviceUuid (no projectId).
      // Account-trust (inventory) admission is the QR-less path — no pairing.
      cp = await RelayClient.connectAndAuth(relay.url, {
        deviceType: "app",
        name: "eval-phone-defaults",
        identity: appIdentity,
        deviceId: appIdentity.deviceId,
      });
      await handshakeWithoutPairing(cp, deviceUuid, auth.ed25519Pub);

      // ── Step 3: assert first agent:projects advert contains projA ──────────
      //
      // On handshake-complete the control plane sends `agent:projects` with the
      // phone's allowedProjects. Since enable-project ran before connecting, the
      // same-account admission seeds the phone's allowlist from the policy store
      // (relay-client.ts's inbound admission → sameAccountDefaultProjects).
      // `agent:projects` shape: { type: "agent:projects", projects: ProjectAdvertEntry[] }
      // where each entry has a `projectId` field (host-server.ts buildProjectsAdvertisement).
      // Pull the control-plane snapshot (re-emits agent:projects) rather than
      // racing the de-duped live handshake push (v3 payload-equality dedup).
      await cp.pullStateSnapshot();
      const projectsAdvert = await cp.waitForAbType("agent:projects", 10_000);

      expect(projectsAdvert.type).toBe("agent:projects");
      const projects = (projectsAdvert as any).projects as Array<{ projectId: string }>;
      expect(Array.isArray(projects)).toBe(true);

      // Primary positive: projA appears in the very first advert.
      expect(projects.map((p) => p.projectId)).toContain(projectId);

      // Scoped negative: a project that is genuinely open on the host but
      // was NEVER enable-project'd must NOT appear. This proves defaults are
      // per-project (not blanket same-account access) — buildProjectsAdvertisement
      // filters from the phone's allowedProjects first, so warmth/catalog
      // visibility alone isn't enough.
      expect(projects.map((p) => p.projectId)).not.toContain(neverEnabledId);
    } finally {
      await cp?.disconnect();
      await agent?.kill();
      relay?.stop();
      licenseApi?.stop();
      project?.cleanup();
      try { neverEnabledProject?.cleanup(); } catch { /* Windows EBUSY teardown race */ }
      if (abDir) {
        try { rmSync(abDir, { recursive: true, force: true }); } catch {}
      }
    }
  },
  120_000,
);
