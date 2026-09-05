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
import type { PeerSessionView } from "../../src/stream-mux";

// A machine holds one E2E session per attached app device, so "the connected
// phone" no longer names anyone. These drive the REAL project-core push wiring
// (resolveTargets/shouldFallback), which is where the singular assumption lived
// — push-dispatcher.test.ts injects both and cannot see a bug inside them.

let cleanup: Array<() => void> = [];
let abDir: string;

beforeEach(() => {
  abDir = mkdtempSync(join(tmpdir(), "antgrid-push-multi-"));
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

function registerPhone(store: PairedPhonesStore, phonePubkey: string, pushToken: string, provider: "fcm" | "apns") {
  store.upsert({
    phonePubkey,
    phoneDeviceId: phonePubkey.toLowerCase(),
    pairedAt: new Date().toISOString(),
    lastSeenAt: new Date().toISOString(),
    pushPubkey: generateEphemeralKeypair().publicKey.toString("base64"),
    pushToken,
    pushProvider: provider,
  });
}

function session(peerPubkey: string): PeerSessionView {
  // Unreachable: the sessions survive a relay presence drop with their keys, which
  // is exactly the window push exists to cover.
  return { peerId: `${peerPubkey.toLowerCase()}#machine`, peerPubkey, checkoutRouting: true, reachable: false };
}

/** A remote core whose transport reports [peers] as established. onPeerOnline is
 *  never fired, so nobody can receive in band and the dispatcher falls back — the
 *  state a bridge is in whenever the relay presence has dropped under it. */
async function startCore(peers: PeerSessionView[], register: (store: PairedPhonesStore) => void) {
  const folder = mkdtempSync(join(tmpdir(), "antgrid-push-multi-proj-"));
  cleanup.push(() => rmSync(folder, { recursive: true, force: true }));
  writeFileSync(join(folder, "antgrid.yaml"), "");
  const projectId = computeProjectId(folder);

  const store: PairedPhonesStore = loadPairedPhones(abDir);
  register(store);

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
    remoteAccessEnabled: () => true,
    remote: {
      attachStream: (b) => {
        bus = b;
        return { streamId: "s1", detach: () => {}, sendTunnel: () => {}, sendTo: () => true };
      },
      establishedPeers: () => peers,
      peerSession: (peerId) => peers.find((p) => p.peerId === peerId) ?? null,
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
  /** What one device says it can render, as the app sends it. Keyed by the
   *  session's route id, which is the client key a relay frame carries. */
  const focus = (peerId: string, paused: boolean) =>
    bus?.dispatchInbound(createMessage("client:focus-state", { paused }), "control", "relay", peerId);

  return { notify, delivered, focus };
}

test("push reaches BOTH established devices, not whichever one spoke last", async () => {
  // Regression: targeting filtered the phone registry down to the single
  // `currentPeerPubkey()`, so on a two-device fleet the notification landed on
  // one phone and the other never heard about the turn at all.
  const { notify, delivered } = await startCore(
    [session("PK_A"), session("PK_B")],
    (store) => {
      registerPhone(store, "PK_A", "TOKEN_A", "fcm");
      registerPhone(store, "PK_B", "TOKEN_B", "apns");
    },
  );

  notify();

  expect(delivered.map((d) => d.pushToken).sort()).toEqual(["TOKEN_A", "TOKEN_B"]);
  // Each row's own transport, not the first one found.
  expect(delivered.find((d) => d.pushToken === "TOKEN_A")?.provider).toBe("fcm");
  expect(delivered.find((d) => d.pushToken === "TOKEN_B")?.provider).toBe("apns");
});

test("a paired phone with no session at all is still a push target", () => {
  // The registry is how a device that is AWAY is reached — it is precisely the
  // one that holds no session. Filtering targets down to devices that DO hold a
  // session inverted that: the phone in the user's pocket, whose session the TTL
  // reap already collected, became unreachable by both paths at once.
  return startCore(
    [session("PK_A")],
    (store) => {
      registerPhone(store, "PK_A", "TOKEN_A", "fcm");
      registerPhone(store, "PK_AWAY", "TOKEN_AWAY", "fcm");
    },
  ).then(({ notify, delivered }) => {
    notify();
    expect(delivered.map((d) => d.pushToken).sort()).toEqual(["TOKEN_A", "TOKEN_AWAY"]);
  });
});

test("a push-incapable sibling holding a live session does not suppress the away phone's push", async () => {
  // Regression: a desktop app establishes a session exactly like a phone but
  // registers no push token, so "some session is established" silenced the
  // fallback entirely — the desktop is backgrounded, the phone's session was
  // reaped, and nothing reached the user at all.
  const desktop: PeerSessionView = {
    peerId: "desktop#machine", peerPubkey: "PK_DESKTOP", checkoutRouting: true, reachable: true,
  };
  const { notify, delivered, focus } = await startCore(
    [desktop],
    (store) => registerPhone(store, "PK_PHONE", "TOKEN_PHONE", "fcm"),
  );

  // The desktop backgrounds: it is the only client with a declared focus state,
  // so nothing can receive in band and the fallback fires.
  focus(desktop.peerId, true);
  notify();

  expect(delivered.map((d) => d.pushToken)).toEqual(["TOKEN_PHONE"]);
});

test("a phone whose own session is reachable and unpaused is not pushed to while a backgrounded sibling opens the fallback", async () => {
  // The per-device half of the same question: the fallback is machine-wide, but
  // a device that can read the frame on its live stream must not also be buzzed.
  const held: PeerSessionView = {
    peerId: "pk_held#machine", peerPubkey: "PK_HELD", checkoutRouting: true, reachable: true,
  };
  const pocketed: PeerSessionView = {
    peerId: "pk_pocket#machine", peerPubkey: "PK_POCKET", checkoutRouting: true, reachable: true,
  };
  const { notify, delivered, focus } = await startCore(
    [held, pocketed],
    (store) => {
      registerPhone(store, "PK_HELD", "TOKEN_HELD", "fcm");
      registerPhone(store, "PK_POCKET", "TOKEN_POCKET", "fcm");
    },
  );

  focus(pocketed.peerId, true);
  notify();

  expect(delivered.map((d) => d.pushToken)).toEqual(["TOKEN_POCKET"]);
});
