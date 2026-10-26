// A connected device reports its own RAM/storage beside push:register, and the
// desktop device roster shows the latest report. The numbers must land on the
// SENDING device's row only, and never on a device this machine doesn't know.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { createDeviceStatsStore, type DeviceStatsStore } from "../src/device-stats";
import { MessageBus } from "../src/message-bus";
import { createMessage, parseMessage, type AbMessage } from "../src/protocol";
import { loadPairedPhones } from "../src/paired-phones";
import { setLogLevel } from "../src/logger";

setLogLevel("error");

const PHONE_PK = "PK_PHONE";
const PEER_ID = "pk_phone#machine";
const STRANGER_PEER_ID = "pk_stranger#machine";

let root: string;
let previousAbDir: string | undefined;
let core: AgentCore | null;

beforeEach(() => {
  previousAbDir = process.env.ANTGRID_DIR;
  root = mkdtempSync(join(tmpdir(), "antgrid-device-stats-"));
  process.env.ANTGRID_DIR = join(root, "state");
  writeFileSync(join(root, "antgrid.yaml"), "name: device-stats\n");
});

// 30s: shutdown waits out a graceful PTY kill whose own budget is 5s.
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

async function boot(): Promise<{
  stats: DeviceStatsStore;
  sent: AbMessage[];
  send: (peerId: string, fields: Record<string, unknown>) => void;
}> {
  const phones = loadPairedPhones(join(root, "phones"));
  phones.upsert({
    phonePubkey: PHONE_PK,
    phoneDeviceId: "pk_phone",
    pairedAt: "2026-07-01T00:00:00.000Z",
    lastSeenAt: "2026-07-01T00:00:00.000Z",
  });
  const stats = createDeviceStatsStore();
  core = await buildAgentCore({
    folder: root,
    mode: "local",
    identity: { deviceId: "agent", deviceName: "agent", createdAt: new Date().toISOString() },
    pairedPhones: phones,
    deviceStats: stats,
    remoteAccessEnabled: () => true,
  });
  const bus = new MessageBus();
  const sent: AbMessage[] = [];
  bus.subscribe({ deliver: (message) => sent.push(message) });
  core.attachTransport(bus);
  core.onHandshakeComplete();
  await waitFor(() => sent.some((m) => m.type === "agent:status"), "agent:status");
  core.setPeerSessionProvider((peerId) => {
    if (peerId === PEER_ID) return { peerId, peerPubkey: PHONE_PK };
    if (peerId === STRANGER_PEER_ID) return { peerId, peerPubkey: "PK_STRANGER" };
    return null;
  });
  const send = (peerId: string, fields: Record<string, unknown>) =>
    bus.dispatchInbound(createMessage("device:stats", fields), "control", "relay", peerId);
  return { stats, sent, send };
}

test("a handshake tells the app this machine's RAM", async () => {
  const { sent } = await boot();

  const msg = sent.find((m) => m.type === "machine:stats");
  expect(msg).toBeDefined();
  const { ramTotalBytes, ramAvailableBytes } = msg as { ramTotalBytes?: number; ramAvailableBytes?: number };
  expect(ramTotalBytes).toBeGreaterThan(0);
  expect(ramAvailableBytes).toBeLessThanOrEqual(ramTotalBytes!);
});

test("a remote app that attaches after the handshake is told this machine's RAM", async () => {
  const { sent, send } = await boot();
  sent.length = 0;

  send(PEER_ID, {});
  await waitFor(() => sent.some((m) => m.type === "machine:stats"), "machine:stats for the new remote client");

  // Only a NEW remote client triggers it; its later frames do not.
  sent.length = 0;
  send(PEER_ID, {});
  await new Promise((resolve) => setTimeout(resolve, 100));
  expect(sent.some((m) => m.type === "machine:stats")).toBe(false);
});

test("device:stats from a known device is recorded on its row", async () => {
  const { stats, send } = await boot();

  send(PEER_ID, { model: "Pixel 9", ramTotalBytes: 12e9, ramAvailableBytes: 4e9, storageTotalBytes: 256e9, storageFreeBytes: 100e9 });

  await waitFor(() => stats.get(PHONE_PK) !== undefined, "recorded stats");
  expect(stats.get(PHONE_PK)).toMatchObject({
    model: "Pixel 9",
    ramTotalBytes: 12e9,
    ramAvailableBytes: 4e9,
    storageTotalBytes: 256e9,
    storageFreeBytes: 100e9,
  });
});

test("device:stats from a device with no paired-phones row is dropped", async () => {
  const { stats, send } = await boot();

  send(STRANGER_PEER_ID, { model: "Nope", ramTotalBytes: 1 });
  send(PEER_ID, { model: "Pixel 9" });

  await waitFor(() => stats.get(PHONE_PK) !== undefined, "known device recorded");
  expect(stats.get("PK_STRANGER")).toBeUndefined();
});

test("device:stats rejects negative and fractional byte counts", () => {
  const base = { type: "device:stats", id: crypto.randomUUID(), timestamp: 1 };
  expect(parseMessage(JSON.stringify({ ...base, ramTotalBytes: -1 }))).toBeNull();
  expect(parseMessage(JSON.stringify({ ...base, ramTotalBytes: 1.5 }))).toBeNull();
  expect(parseMessage(JSON.stringify({ ...base, model: "Pixel" }))).not.toBeNull();
});
