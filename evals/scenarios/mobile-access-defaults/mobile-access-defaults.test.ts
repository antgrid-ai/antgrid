// E2E eval: the machine-level mobile-access switch, observed from a phone.
//
// Authorization is one boolean per machine — "this machine is reachable from
// mobile, yes or no" — so both halves of this file are about the state of that
// switch AT THE MOMENT the phone connects. Neither can use `setupTestEnv`
// (which connects, handshakes AND turns the switch on in one call); each drives
// its own relay + agent + phone sequence, mirroring the harness internals but
// controlling the ordering.
//
//   1. ON before the phone connects → the phone's FIRST advert carries the
//      machine's whole catalog, including a project it was never told about
//      individually. This is the disclosure consequence of the collapse: there
//      is no per-project opt-in left to hold anything back.
//   2. OFF (the fresh-install default, asserted rather than assumed) → the
//      phone still connects and handshakes — off is authorization, not
//      presence — but the advert is empty and `project:start` is refused
//      NOT_ALLOWED, for a project that is genuinely open and running on the
//      host.
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
  setMobileAccess,
  spawnAgent,
  startFakeLicenseApi,
  startRelay,
  waitForHostFile,
  type AgentHandle,
  type FakeLicenseApi,
  type RelayHandle,
} from "../../helpers/harness";
import { createTestProject, type TestProject } from "../../helpers/fixtures";
import { computeProjectId } from "../../../bridge/src/project-id";
import { createMessage } from "../../../bridge/src/protocol";
import { RelayClient } from "../../helpers/relay-client";

/** POST a control-plane verb over the loopback control port (see host.json's
 *  `controlPort`/`token`) — the desktop's channel, used here to open a second
 *  project and to read the machine switch back. */
async function loopbackControl(abDir: string, body: object): Promise<any> {
  const hf = await waitForHostFile(abDir);
  const res = await fetch(`http://127.0.0.1:${hf.controlPort}/control`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${hf.token}` },
    body: JSON.stringify(body),
  });
  return res.json();
}

interface Machine {
  abDir: string;
  relay: RelayHandle;
  projectId: string;
  /** Connect a same-account phone and complete the pair-free E2E handshake. */
  connectPhone(name: string): Promise<RelayClient>;
}

/**
 * Stand up relay + fake account API + a real agent with one remote firstProject,
 * run `body`, and tear everything down. Handles are declared outside the try but
 * CREATED inside it so a throw mid-construction still reaches the cleanup —
 * otherwise a failure after the relay is up leaks its port for the whole run.
 */
async function withMachine(label: string, body: (m: Machine) => Promise<void>): Promise<void> {
  let abDir: string | undefined;
  let relay: RelayHandle | undefined;
  let licenseApi: FakeLicenseApi | undefined;
  let project: TestProject | undefined;
  let agent: AgentHandle | undefined;
  const phones: RelayClient[] = [];
  try {
    const relayPort = allocatePort();
    abDir = mkdtempSync(join(tmpdir(), `antgrid-${label}-`));
    const appIdentity = await generateAppIdentity();

    relay = await startRelay({ port: relayPort });
    licenseApi = startFakeLicenseApi({
      accountDevices: [{ deviceId: appIdentity.deviceId, ed25519Pub: appIdentity.publicKeyBase64 }],
    });
    const auth = generateEvalAuth();
    project = createTestProject("basic", { "__RELAY_URL__": `ws://localhost:${relayPort}` });

    agent = await spawnAgent({
      relayUrl: relay.url,
      licenseApiUrl: licenseApi.url,
      abDir,
      projectDir: project.dir,
      auth,
      env: { ANTGRID_EVAL_TEST: "1" },
    });

    const relayUrl = relay.url;
    await body({
      abDir,
      relay,
      projectId: computeProjectId(project.dir),
      async connectPhone(name) {
        const phone = await RelayClient.connectAndAuth(relayUrl, {
          deviceType: "app",
          name,
          identity: appIdentity,
          deviceId: appIdentity.deviceId,
        });
        phones.push(phone);
        await handshakeWithoutPairing(phone, auth.deviceUuid, auth.ed25519Pub);
        return phone;
      },
    });
  } finally {
    for (const phone of phones) await phone.disconnect();
    await agent?.kill();
    relay?.stop();
    licenseApi?.stop();
    project?.cleanup();
    if (abDir) {
      try { rmSync(abDir, { recursive: true, force: true }); } catch {}
    }
  }
}

test(
  "switch on before the phone connects: the first advert carries the machine's whole catalog",
  async () => {
    await withMachine("mobile-access-on", async (m) => {
      // ── Step 1: turn the machine on BEFORE any phone exists ────────────────
      await setMobileAccess(m.abDir, true);
      expect((await loopbackControl(m.abDir, { id: "get", type: "mobile-access:get" })).enabled).toBe(true);

      // ── Step 2: open a SECOND project the phone is never told about ────────
      // Under the old model this project would have needed its own opt-in. It
      // gets none here, and must still appear: one switch, whole catalog.
      const second = createTestProject("basic", { "__RELAY_URL__": m.relay.url.replace(/\/ws$/, "") });
      try {
        const secondId = computeProjectId(second.dir);
        expect((await loopbackControl(m.abDir, {
          id: "open-second", type: "project:open", projectId: secondId, projectPath: second.dir, mode: "remote",
        })).ok).toBe(true);

        // ── Step 3: connect a same-account phone (no pairing ceremony) ────────
        const phone = await m.connectPhone("eval-phone-defaults-on");

        // Pull the control-plane snapshot (which re-emits agent:projects) rather
        // than racing the de-duped live handshake push.
        await phone.pullStateSnapshot();
        const advert = await phone.waitForAbType("agent:projects", 10_000);
        const ids = advert.projects.map((p: any) => p.projectId);
        expect(ids).toContain(m.projectId);
        expect(ids).toContain(secondId);
      } finally {
        try { second.cleanup(); } catch { /* Windows EBUSY teardown race */ }
      }
    });
  },
  120_000,
);

test(
  "switch off (the fresh-install default): the phone still connects, but the catalog is empty and project:start is refused",
  async () => {
    await withMachine("mobile-access-off", async (m) => {
      // A machine nobody has enabled must not be mobile-reachable. Read it back
      // rather than assuming: this is the default the whole product leans on.
      expect((await loopbackControl(m.abDir, { id: "get", type: "mobile-access:get" })).enabled).toBe(false);

      // Off is authorization, not presence — the handshake still completes.
      const phone = await m.connectPhone("eval-phone-defaults-off");

      await phone.pullStateSnapshot();
      const advert = await phone.waitForAbType("agent:projects", 10_000);
      expect(advert.projects).toEqual([]);

      // firstProject is genuinely open and running on the host, so an empty
      // advert is the switch talking, not an empty machine — and naming the
      // project directly gets refused all the same.
      expect((await loopbackControl(m.abDir, { id: "list", type: "project:list" })).projects
        .map((p: any) => p.projectId)).toContain(m.projectId);

      phone.sendEncrypted(createMessage("project:start", { projectId: m.projectId }));
      const denied = await phone.waitForAbType("control:result", 10_000);
      expect(denied.ok).toBe(false);
      expect((denied as any).error.code).toBe("NOT_ALLOWED");
    });
  },
  120_000,
);
