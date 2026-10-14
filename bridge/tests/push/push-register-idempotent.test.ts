// The app re-sends push:register on every agent handshake, once per warm
// project, so almost every frame repeats what the phone's row already holds.
// Each upsert is a non-silent paired-phones write, which the host's watcher
// answers with a re-advertise to every connected phone — a repeat must not
// write at all, while a real change still must.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { buildAgentCore, type AgentCore } from "../../src/agent-core";
import { MessageBus } from "../../src/message-bus";
import { createMessage, type AbMessage } from "../../src/protocol";
import { loadPairedPhones, type PairedPhone, type PairedPhonesStore } from "../../src/paired-phones";
import { setLogLevel } from "../../src/logger";

setLogLevel("error");

const PHONE_PK = "PK_PHONE";
const PEER_ID = "pk_phone#machine";
const PUSH_PUBKEY = Buffer.alloc(32, 7).toString("base64");
const OTHER_PUSH_PUBKEY = Buffer.alloc(32, 9).toString("base64");

let root: string;
let previousAbDir: string | undefined;
let core: AgentCore | null;

beforeEach(() => {
  previousAbDir = process.env.ANTGRID_DIR;
  root = mkdtempSync(join(tmpdir(), "antgrid-push-register-"));
  process.env.ANTGRID_DIR = join(root, "state");
  writeFileSync(join(root, "antgrid.yaml"), "name: push-register\n");
});

// 30s for the same reason as agent-core-resync-pushes.test.ts: shutdown waits
// out a graceful PTY kill whose own budget is 5s.
afterEach(async () => {
  const dying = core;
  const dir = root;
  const restore = previousAbDir;
  core = null;
  if (restore === undefined) delete process.env.ANTGRID_DIR;
  else process.env.ANTGRID_DIR = restore;
  try {
    await dying?.shutdown();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}, 30_000);

async function waitFor(predicate: () => boolean, what: string, timeoutMs = 4000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`timed out waiting for ${what}`);
}

/** A real store whose upserts are counted: an upsert is the write in question. */
function countingStore(seed: PairedPhone): { store: PairedPhonesStore; upserts: () => number } {
  const real = loadPairedPhones(join(root, "phones"));
  real.upsert(seed);
  let count = 0;
  const store: PairedPhonesStore = {
    ...real,
    upsert: (phone) => {
      count++;
      real.upsert(phone);
    },
  };
  return { store, upserts: () => count };
}

async function boot(seed: Partial<PairedPhone>) {
  const { store, upserts } = countingStore({
    phonePubkey: PHONE_PK,
    phoneDeviceId: "pk_phone",
    pairedAt: "2026-07-01T00:00:00.000Z",
    lastSeenAt: "2026-07-01T00:00:00.000Z",
    ...seed,
  });
  core = await buildAgentCore({
    folder: root,
    mode: "local",
    identity: { deviceId: "agent", deviceName: "agent", createdAt: new Date().toISOString() },
    pairedPhones: store,
    remoteAccessEnabled: () => true,
  });
  const bus = new MessageBus();
  const sent: AbMessage[] = [];
  bus.subscribe({ deliver: (message) => sent.push(message) });
  core.attachTransport(bus);
  // push:register is dispatched behind the terminal-manager guard, and the
  // handshake is what starts the services that create the manager.
  core.onHandshakeComplete();
  await waitFor(() => sent.some((m) => m.type === "agent:status"), "agent:status");
  core.setPeerSessionProvider((peerId) => (peerId === PEER_ID ? { peerId, peerPubkey: PHONE_PK } : null));
  const register = (pushToken: string, provider: "fcm" | "apns", pushPubkey: string) =>
    bus.dispatchInbound(createMessage("push:register", { pushToken, provider, pushPubkey }), "control", "relay", PEER_ID);
  return { register, upserts, row: () => store.get(PHONE_PK) };
}

const REGISTERED = {
  pushToken: "TOKEN",
  pushProvider: "fcm" as const,
  pushPubkey: PUSH_PUBKEY,
  pushUpdatedAt: "2026-07-01T00:00:00.000Z",
};

test("a repeated identical push:register does not rewrite the store", async () => {
  const { register, upserts, row } = await boot(REGISTERED);

  register("TOKEN", "fcm", PUSH_PUBKEY);
  register("TOKEN", "fcm", PUSH_PUBKEY);

  expect(upserts()).toBe(0);
  expect(row()?.pushUpdatedAt).toBe(REGISTERED.pushUpdatedAt);
});

test("a clear on a row that holds no registration does not rewrite the store", async () => {
  const { register, upserts } = await boot({});

  register("", "fcm", "");

  expect(upserts()).toBe(0);
});

test("a changed token is written", async () => {
  const { register, upserts, row } = await boot(REGISTERED);

  register("ROTATED", "fcm", PUSH_PUBKEY);

  expect(upserts()).toBe(1);
  expect(row()?.pushToken).toBe("ROTATED");
});

test("a changed push pubkey is written", async () => {
  const { register, upserts, row } = await boot(REGISTERED);

  register("TOKEN", "fcm", OTHER_PUSH_PUBKEY);

  expect(upserts()).toBe(1);
  expect(row()?.pushPubkey).toBe(OTHER_PUSH_PUBKEY);
});

test("a changed provider is written", async () => {
  const { register, upserts, row } = await boot(REGISTERED);

  register("TOKEN", "apns", PUSH_PUBKEY);

  expect(upserts()).toBe(1);
  expect(row()?.pushProvider).toBe("apns");
});

test("a clear on a row that holds a token is written", async () => {
  const { register, upserts, row } = await boot(REGISTERED);

  register("", "fcm", "");

  expect(upserts()).toBe(1);
  expect(row()?.pushToken).toBeUndefined();
  expect(row()?.pushPubkey).toBeUndefined();
});

test("a clear on a row whose dead token was pruned still drops the kept push pubkey", async () => {
  // prunePushToken keeps pushPubkey when FCM reports the token dead; sign-out's
  // clear must still take it, so "no token" alone is not "nothing to clear".
  const { register, upserts, row } = await boot({ pushPubkey: PUSH_PUBKEY });

  register("", "fcm", "");

  expect(upserts()).toBe(1);
  expect(row()?.pushPubkey).toBeUndefined();
});
