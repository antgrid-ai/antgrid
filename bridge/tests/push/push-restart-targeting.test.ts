import { test, expect, afterEach, beforeEach } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { ProjectCore } from "../../src/project-core";
import { computeProjectId } from "../../src/project-id";
import { loadPairedPhones, type PairedPhonesStore } from "../../src/paired-phones";
import { generateEphemeralKeypair } from "../../src/key-exchange";
import { createMessage } from "../../src/protocol";
import type { MessageBus } from "../../src/message-bus";

// These exercise the REAL project-core push wiring (resolveTargets/shouldFallback),
// not the dispatcher in isolation: push-dispatcher.test.ts injects both, so it
// cannot see a bug that lives in the injected functions themselves.

let cleanup: Array<() => void> = [];
let abDir: string;

beforeEach(() => {
  abDir = mkdtempSync(join(tmpdir(), "antgrid-push-restart-"));
  process.env.ANTGRID_DIR = abDir;
});

afterEach(() => {
  for (const fn of cleanup.splice(0)) try { fn(); } catch {}
  rmSync(abDir, { recursive: true, force: true });
});

interface Delivered {
  pushToken: string;
  provider: string;
}

/** A relay slot whose phone has NEVER connected during this agent lifetime —
 *  `currentPeerPubkey()` is null exactly as after a host restart. */
async function startRestartedAgent(opts: { mobileAccess: boolean }) {
  const folder = mkdtempSync(join(tmpdir(), "antgrid-push-proj-"));
  cleanup.push(() => rmSync(folder, { recursive: true, force: true }));
  writeFileSync(join(folder, "antgrid.yaml"), "");
  const projectId = computeProjectId(folder);

  const phonePush = generateEphemeralKeypair();
  const store: PairedPhonesStore = loadPairedPhones(abDir);
  store.upsert({
    phonePubkey: "PHONE_PK",
    phoneDeviceId: "phone-1",
    pairedAt: new Date().toISOString(),
    lastSeenAt: new Date().toISOString(),
    pushPubkey: phonePush.publicKey.toString("base64"),
    pushToken: "TOKEN",
    pushProvider: "fcm",
  });

  const delivered: Delivered[] = [];
  let bus: MessageBus | null = null;
  const core = new ProjectCore({
    folder,
    mode: "remote",
    identity: {
      deviceId: randomUUID(), deviceName: "machine", createdAt: new Date().toISOString(),
      ed25519PublicKey: "PK", ed25519PrivateKey: "SK",
    },
    pairedPhones: store,
    remoteAccessEnabled: () => opts.mobileAccess,
    remote: {
      // Never fires onPeerOnline: no phone has dialled this stream, which is
      // exactly the post-restart state the regression below is about.
      attachStream: (b) => {
        bus = b;
        return { streamId: "s1", detach: () => {}, sendTunnel: () => {} };
      },
      currentPeerPubkey: () => null,
      sendPushDeliver: (p) => delivered.push(p),
    },
  });
  cleanup.push(() => { void core.shutdown(); });
  await core.start();

  const notify = () =>
    bus?.publish(
      createMessage("notification:push", { notificationType: "task_complete", message: "built", projectId }),
      "control",
    );
  return { notify, delivered, projectId };
}

test("push targets the persisted phone when no peer has connected this agent lifetime", async () => {
  // Regression: after a host restart the phone may never reconnect (machine
  // rebooted, long task, phone in pocket). Targeting used to bind to LIVE peer
  // state — `connState.peerOnline` defaults TRUE, so the fallback gate read
  // "phone can receive in-band" with no phone at all, and `currentPeerPubkey()`
  // was null so no target resolved. Result: zero pushes, forever.
  const { notify, delivered } = await startRestartedAgent({ mobileAccess: true });

  notify();

  expect(delivered).toHaveLength(1);
  expect(delivered[0].pushToken).toBe("TOKEN");
  expect(delivered[0].provider).toBe("fcm");
});

test("persisted-store fallback still refuses to push from a machine with mobile access off", async () => {
  // The trust boundary is unchanged by the fallback: push carries project
  // activity OFF this machine, so a registered phone with a valid token must
  // receive nothing while the machine switch is off.
  const { notify, delivered } = await startRestartedAgent({ mobileAccess: false });

  notify();

  expect(delivered).toHaveLength(0);
});
