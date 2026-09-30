import { afterEach, expect, test } from "bun:test";
import { MessageBus } from "../src/message-bus";
import { createMessage } from "../src/protocol";
import { TerminalFrameHub } from "../src/terminal-frames/delivery";
import { TerminalFrameSource } from "../src/terminal-frames/source";
import { TERMINAL_PROTOCOL_VERSION } from "../src/terminal-frames/protocol";
import type { TerminalFrame, TerminalDisplayStatus } from "../src/protocol";
import { TestPeerSessionOwner } from "./test-peer-session-owner";

const PROJECT = "p1";
const PEER = "peer-a";

function makeClient(): TestPeerSessionOwner {
  const client = new TestPeerSessionOwner({
    identity: { deviceId: "agent-1", deviceName: "agent", createdAt: new Date().toISOString() },
    remoteAccessEnabled: () => true,
    projectCataloged: () => true,
  });
  client.setNativeWriter(() => true);
  return client;
}

let clients: TestPeerSessionOwner[] = [];
afterEach(() => { for (const c of clients.splice(0)) try { void c.close(); } catch { /* already closed */ } });

test("a transport blocked before encryption retains only the newest unsent screen", async () => {
  let now = 0;
  const hub = new TerminalFrameHub(() => now);
  const source = new TerminalFrameSource(40, 6);
  const address = { projectId: "p", checkoutId: "main", terminalId: "t" };
  const queued = new Map<number, TerminalFrame>();
  const statuses: TerminalDisplayStatus[] = [];
  const budget = { bytes: 0 };
  hub.register(address, source, crypto.randomUUID());
  const connection = hub.connect({
    budget, authorized: () => true,
    send: (message, signal) => {
      if (message.type === "terminal:display:status") statuses.push(message);
      if (message.type !== "terminal:frame") return Promise.resolve();
      queued.set(message.sequence, message);
      return new Promise<void>((resolve) => signal.addEventListener("abort", () => {
        queued.delete(message.sequence);
        resolve();
      }, { once: true }));
    },
  });
  try {
    await connection.subscribe(address, TERMINAL_PROTOCOL_VERSION, crypto.randomUUID());
    for (let index = 0; index < 12; index++) {
      now += 50;
      source.feed(`\r\x1b[2Klatest-${index}`);
      await source.settle();
      hub.tick();
      expect(queued.size).toBe(1);
      expect([...queued.values()][0]!.ansi).toContain(`latest-${index}`);
    }
    expect(budget.bytes).toBeGreaterThan(0);
    now = 10_001;
    hub.tick();
    expect(statuses.some((status) => status.code === "ACK_TIMEOUT")).toBe(true);
    expect(queued.size).toBe(0);
    expect(budget.bytes).toBe(0);
  } finally { hub.dispose(); source.dispose(); }
});

test("targeted bus delivery reaches the project stream and rechecks mayDeliver at send time", async () => {
  const client = makeClient();
  clients.push(client);
  const bus = new MessageBus();
  let allowed = true;
  client.establish(PEER);
  client.attachStream(bus, { projectId: PROJECT, mayDeliver: () => allowed });
  const stream = await client.openProjectStream(PEER, PROJECT);
  expect(stream.refusal()).toBeUndefined();

  const controller = new AbortController();
  const status = createMessage("terminal:display:status", { terminalId: "t", code: "ACK_TIMEOUT", message: "Reconnect" });

  // Carries the signal through to the write, and lands on the wire.
  await bus.deliverTo(status, "control", "relay", controller.signal);
  expect(stream.read()).toMatchObject({ type: "terminal:display:status" });

  // mayDeliver is re-read on every frame, not just at attach/open.
  allowed = false;
  await expect(bus.deliverTo(status, "control", "relay", controller.signal)).rejects.toThrow("Project delivery gated");

  allowed = true;
  await bus.deliverTo(status, "control", "relay", controller.signal);
  expect(stream.read()).toMatchObject({ type: "terminal:display:status" });
});

test("loopback frames never reach the project stream, and an addressed send drops before the stream is open", async () => {
  // This project stream IS the relay wire for the project (project-streams.ts
  // subscribes `audience: "relay"`), so a loopback-audience publish must never
  // reach it even once a peer is bound — the mirror of what used to be
  // `StreamMux`'s "muted" gate, expressed here as an audience filter instead.
  const client = makeClient();
  clients.push(client);
  const bus = new MessageBus();
  client.establish(PEER);
  client.attachStream(bus, { projectId: PROJECT });
  const signal = new AbortController().signal;
  const status = createMessage("terminal:display:status", {
    terminalId: "t", code: "ACK_TIMEOUT", message: "Reconnect",
  });

  // Before the stream opens, an addressed relay-origin send has no binding to
  // land on — DROPPED, distinct from the mayDeliver gate above.
  await expect(bus.deliverTo(status, "control", "relay", signal, PEER))
    .rejects.toThrow("Project delivery dropped");

  const stream = await client.openProjectStream(PEER, PROJECT);
  expect(stream.refusal()).toBeUndefined();

  await bus.deliverTo(status, "control", "loopback", signal);
  expect(stream.written()).toHaveLength(1); // only the opening stream-ready record

  // The same addressed send now lands once the peer is bound.
  await bus.deliverTo(status, "control", "relay", signal, PEER);
  expect(stream.read()).toMatchObject({ type: "terminal:display:status" });
});
