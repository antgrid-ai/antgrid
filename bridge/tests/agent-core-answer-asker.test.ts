// D-10 regression: an RPC response belongs to the one asker who sent the
// request, never to every device attached to the project (agent-core.ts's
// `answerAsker`, inside `attachTransport`). These tests drive that seam
// directly at the bus: a fake "wire" is just a `TransportSubscriber` whose
// `deliver` records what it was handed, the same shape a real per-peer
// project-stream binding or the loopback socket would be — see
// project-streams.ts's own `audience: "relay"` subscriber for the production
// shape this fakes.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { MessageBus, type Channel } from "../src/message-bus";
import { createMessage, type AbMessage } from "../src/protocol";
import { setLogLevel } from "../src/logger";

setLogLevel("error");

let root: string;
let previousAbDir: string | undefined;
let core: AgentCore | null;

beforeEach(() => {
  previousAbDir = process.env.ANTGRID_DIR;
  root = mkdtempSync(join(tmpdir(), "antgrid-answer-asker-"));
  process.env.ANTGRID_DIR = join(root, "state");
  writeFileSync(join(root, "antgrid.yaml"), "name: answer-asker\nagent:\n  tool: claude-code\n");
});

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

async function waitFor(sent: AbMessage[], predicate: (message: AbMessage) => boolean, what: string, timeoutMs = 5000): Promise<AbMessage> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const found = sent.find(predicate);
    if (found) return found;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`timed out waiting for ${what}`);
}

/** A fake wire for ONE relay peer, with the production per-peer filter (the
 *  project stream's `audience: "relay"` subscriber): an untargeted publish
 *  reaches every bound peer, a `peerId`-targeted one only the peer it names.
 *  Counting untargeted publishes is what makes a broadcast reply visible. */
function relayWire(peerId: string, received: AbMessage[]) {
  return {
    audience: "relay" as const,
    deliver: (msg: AbMessage, _channel: Channel, _signal?: AbortSignal, targetPeerId?: string) => {
      if (targetPeerId === undefined || targetPeerId === peerId) received.push(msg);
    },
  };
}

function loopbackWire(received: AbMessage[]) {
  return {
    audience: "loopback" as const,
    deliver: (msg: AbMessage) => { received.push(msg); },
  };
}

/** Background chatter (git:sync-state, agent:status, ...) reaches every
 *  audience the same way a real broadcast would — asserting these tests'
 *  wires are silent means silent of RESPONSES, not of that ambient noise. */
function responses(received: AbMessage[]): AbMessage[] {
  return received.filter((m) => m.type === "response");
}

function request(requestId: string): AbMessage {
  // An unregistered method still round-trips through `dispatchRpc` to an
  // `E_UNKNOWN_METHOD` response — sufficient to exercise routing, and lighter
  // than standing up a real RPC method's own preconditions.
  return createMessage("request", { requestId, method: "no-such-method", params: {} });
}

async function boot(): Promise<MessageBus> {
  core = await buildAgentCore({
    folder: root,
    mode: "local",
    identity: { deviceId: "agent", deviceName: "agent", createdAt: new Date().toISOString() },
  });
  const bus = new MessageBus();
  const booted: AbMessage[] = [];
  bus.subscribe({ deliver: (message) => booted.push(message) });
  core.attachTransport(bus);
  core.onHandshakeComplete();
  await waitFor(booted, (m) => m.type === "agent:status", "agent:status");
  return bus;
}

test("Q1: a loopback asker's RPC reply reaches the loopback subscriber only", async () => {
  const bus = await boot();
  const loopback: AbMessage[] = [];
  const relay: AbMessage[] = [];
  bus.subscribe(loopbackWire(loopback));
  bus.subscribe(relayWire("phone-a", relay));

  const requestId = crypto.randomUUID();
  bus.dispatchInbound(request(requestId), "control", "loopback");

  await waitFor(loopback, (m) => m.type === "response", "loopback response");
  expect(responses(loopback)).toHaveLength(1);
  expect(responses(loopback)[0]).toMatchObject({ type: "response", requestId, ok: false });
  expect(responses(relay)).toEqual([]);
});

test("Q2: a relay asker's reply reaches that peer only", async () => {
  const bus = await boot();
  const loopback: AbMessage[] = [];
  const fromA: AbMessage[] = [];
  const fromB: AbMessage[] = [];
  bus.subscribe(loopbackWire(loopback));
  bus.subscribe(relayWire("phone-a", fromA));
  bus.subscribe(relayWire("phone-b", fromB));

  const requestId = crypto.randomUUID();
  bus.dispatchInbound(request(requestId), "control", "relay", "phone-a");

  await waitFor(fromA, (m) => m.type === "response", "phone-a's response");
  expect(responses(fromA)).toHaveLength(1);
  expect(responses(fromA)[0]).toMatchObject({ type: "response", requestId, ok: false });
  expect(responses(fromB)).toEqual([]);
  expect(responses(loopback)).toEqual([]);
});

test("Q3: a relay-origin request with no peerId is answered to no one", async () => {
  const bus = await boot();
  const loopback: AbMessage[] = [];
  const relay: AbMessage[] = [];
  bus.subscribe(loopbackWire(loopback));
  bus.subscribe(relayWire("phone-a", relay));

  const requestId = crypto.randomUUID();
  bus.dispatchInbound(request(requestId), "control", "relay");

  // Nothing to wait for: an unaddressable reply is dropped, not delayed, so
  // this asserts silence rather than racing a reply that never comes.
  await new Promise((resolve) => setTimeout(resolve, 100));
  expect(responses(relay)).toEqual([]);
  expect(responses(loopback)).toEqual([]);
});
