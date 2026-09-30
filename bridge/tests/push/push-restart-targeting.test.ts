import { test, expect, afterEach, beforeEach } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createDecipheriv, hkdfSync, randomUUID } from "node:crypto";
import { ProjectCore } from "../../src/project-core";
import { computeProjectId } from "../../src/project-id";
import { loadPairedPhones, type PairedPhonesStore } from "../../src/paired-phones";
import { generateEphemeralKeypair, deriveSharedSecret } from "../../src/key-exchange";
import { createMessage } from "../../src/protocol";
import type { MessageBus } from "../../src/message-bus";
import type { AttachStreamOpts } from "../../src/project-streams";

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
  blob: { epk: string; box: string };
}

/** Opens a sealed push with the recipient's push private key, mirroring the
 *  app's decode. Deliberately independent of `sealPush` rather than sharing a
 *  helper with it, so a change to the sealing format fails here instead of
 *  being masked by both sides moving together. */
function openPush(blob: { epk: string; box: string }, privateKey: Buffer): any {
  const epk = Buffer.from(blob.epk, "base64");
  const key = Buffer.from(hkdfSync("sha256", deriveSharedSecret(privateKey, epk), epk, "antgrid-push-v1", 32));
  const raw = Buffer.from(blob.box, "base64");
  const decipher = createDecipheriv("aes-256-gcm", key, raw.subarray(0, 12));
  decipher.setAuthTag(raw.subarray(raw.length - 16));
  return JSON.parse(Buffer.concat([decipher.update(raw.subarray(12, raw.length - 16)), decipher.final()]).toString("utf8"));
}

/** A relay slot whose phone has NEVER connected during this agent lifetime —
 *  it holds no established session, exactly as after a host restart. */
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
        return {
          detach: () => {},
          sendTo: async () => "sent" as const,
          deliverableTo: () => true,
        };
      },
      establishedPeers: () => [],
      peerSession: () => null,
      machineDeviceId: () => "machine-uuid",
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
  return { notify, delivered, projectId, phonePush };
}

test("push targets the persisted phone when no peer has connected this agent lifetime", async () => {
  // Regression: after a host restart the phone may never reconnect (machine
  // rebooted, long task, phone in pocket). Targeting used to bind to LIVE peer
  // state — `connState.peerOnline` defaults TRUE, so the fallback gate read
  // "phone can receive in-band" with no phone at all, and no session named a
  // device so no target resolved. Result: zero pushes, forever.
  const { notify, delivered } = await startRestartedAgent({ mobileAccess: true });

  notify();

  expect(delivered).toHaveLength(1);
  expect(delivered[0].pushToken).toBe("TOKEN");
  expect(delivered[0].provider).toBe("fcm");
});

test("the sealed payload names the machine the phone must dial", async () => {
  // This is the only suite that drives a real ProjectCore through to deliver(),
  // so it is the only place the project-core -> dispatcher hop is proved rather
  // than injected. projectId alone is sha256(realpath(folder)) and names no
  // machine, so a payload missing machineUuid is one the phone cannot open.
  const { notify, delivered, projectId, phonePush } = await startRestartedAgent({ mobileAccess: true });

  notify();

  const opened = openPush(delivered[0].blob, phonePush.privateKey);
  expect(opened.machineUuid).toBe("machine-uuid");
  expect(opened.projectId).toBe(projectId);
});

test("persisted-store fallback still refuses to push from a machine with mobile access off", async () => {
  // The trust boundary is unchanged by the fallback: push carries project
  // activity OFF this machine, so a registered phone with a valid token must
  // receive nothing while the machine switch is off.
  const { notify, delivered } = await startRestartedAgent({ mobileAccess: false });

  notify();

  expect(delivered).toHaveLength(0);
});

/** A slot a DESKTOP app held and then left. The session inventory is empty after
 *  the disconnect, while the persistent device registry still contains both the
 *  tokenless desktop identity and the phone that should receive fallback push. */
async function startAfterDesktopLeft() {
  const folder = mkdtempSync(join(tmpdir(), "antgrid-push-proj-"));
  cleanup.push(() => rmSync(folder, { recursive: true, force: true }));
  writeFileSync(join(folder, "antgrid.yaml"), "");
  const projectId = computeProjectId(folder);

  const phonePush = generateEphemeralKeypair();
  const store: PairedPhonesStore = loadPairedPhones(abDir);
  // The tokenless desktop is registered FIRST, so `list()` order is not what
  // decides whether the phone is reached.
  store.upsert({
    phonePubkey: "DESKTOP_PK",
    phoneDeviceId: "desktop-1",
    pairedAt: new Date().toISOString(),
    lastSeenAt: new Date().toISOString(),
  });
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
  let streamOpts!: AttachStreamOpts;
  const core = new ProjectCore({
    folder,
    mode: "remote",
    identity: {
      deviceId: randomUUID(), deviceName: "machine", createdAt: new Date().toISOString(),
      ed25519PublicKey: "PK", ed25519PrivateKey: "SK",
    },
    pairedPhones: store,
    remoteAccessEnabled: () => true,
    remote: {
      attachStream: (b, o) => {
        bus = b;
        streamOpts = o;
        return {
          detach: () => {},
          sendTo: async () => "sent" as const,
          deliverableTo: () => true,
        };
      },
      establishedPeers: () => [],
      peerSession: () => null,
      machineDeviceId: () => "machine-uuid",
      sendPushDeliver: (p) => delivered.push(p),
    },
  });
  cleanup.push(() => { void core.shutdown(); });
  await core.start();

  streamOpts.onPeerOnline?.();
  streamOpts.onPeerOffline?.();

  const notify = () =>
    bus?.publish(
      createMessage("notification:push", { notificationType: "task_complete", message: "built", projectId }),
      "control",
    );
  return { notify, delivered };
}

test("push reaches the phone after a tokenless desktop peer disconnects", async () => {
  // A desktop carries no push token, so its former session must not suppress the
  // registered phone once no device can receive this notification in band.
  const { notify, delivered } = await startAfterDesktopLeft();

  notify();

  expect(delivered).toHaveLength(1);
  expect(delivered[0].pushToken).toBe("TOKEN");
});

/** Two push-capable phones with no reachable sessions. Both persistent devices
 *  are away targets; the bridge has no live session from which to choose one. */
async function startAfterPhoneLeft() {
  const folder = mkdtempSync(join(tmpdir(), "antgrid-push-proj-"));
  cleanup.push(() => rmSync(folder, { recursive: true, force: true }));
  writeFileSync(join(folder, "antgrid.yaml"), "");
  const projectId = computeProjectId(folder);

  const store: PairedPhonesStore = loadPairedPhones(abDir);
  for (const [pubkey, id, token] of [["PHONE_A_PK", "phone-a", "TOKEN_A"], ["PHONE_B_PK", "phone-b", "TOKEN_B"]]) {
    store.upsert({
      phonePubkey: pubkey,
      phoneDeviceId: id,
      pairedAt: new Date().toISOString(),
      lastSeenAt: new Date().toISOString(),
      pushPubkey: generateEphemeralKeypair().publicKey.toString("base64"),
      pushToken: token,
      pushProvider: "fcm",
    });
  }

  const delivered: Delivered[] = [];
  let bus: MessageBus | null = null;
  let streamOpts!: AttachStreamOpts;
  const core = new ProjectCore({
    folder,
    mode: "remote",
    identity: {
      deviceId: randomUUID(), deviceName: "machine", createdAt: new Date().toISOString(),
      ed25519PublicKey: "PK", ed25519PrivateKey: "SK",
    },
    pairedPhones: store,
    remoteAccessEnabled: () => true,
    remote: {
      attachStream: (b, o) => {
        bus = b;
        streamOpts = o;
        return {
          detach: () => {},
          sendTo: async () => "sent" as const,
          deliverableTo: () => true,
        };
      },
      establishedPeers: () => [],
      peerSession: () => null,
      machineDeviceId: () => "machine-uuid",
      sendPushDeliver: (p) => delivered.push(p),
    },
  });
  cleanup.push(() => { void core.shutdown(); });
  await core.start();

  streamOpts.onPeerOnline?.();
  streamOpts.onPeerOffline?.();

  const notify = () =>
    bus?.publish(
      createMessage("notification:push", { notificationType: "task_complete", message: "built", projectId }),
      "control",
    );
  return { notify, delivered };
}

test("a departed peer leaves every away phone as a push target", async () => {
  // With no reachable session, choosing whichever device disconnected last
  // would silently drop the notification on every other registered phone.
  const { notify, delivered } = await startAfterPhoneLeft();

  notify();

  expect(delivered.map((d) => d.pushToken).sort()).toEqual(["TOKEN_A", "TOKEN_B"]);
});
