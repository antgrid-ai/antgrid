import { expect, test } from "bun:test";
import { SendScheduler, type QueuedAppFrame } from "../src/send-scheduler";
import { MessageBus } from "../src/message-bus";
import { StreamMux } from "../src/stream-mux";
import { createMessage } from "../src/protocol";
import { TerminalFrameHub } from "../src/terminal-frames/delivery";
import { TerminalFrameSource } from "../src/terminal-frames/source";
import { TERMINAL_PROTOCOL_VERSION } from "../src/terminal-frames/protocol";
import type { TerminalFrame, TerminalDisplayStatus } from "../src/protocol";

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

test("attachment cancellation releases queued plaintext without sealing it", async () => {
  const sealed: string[] = [];
  const scheduler = new SendScheduler({ send: frame => { sealed.push(frame.plaintext); return frame.plaintextBytes; } });
  scheduler.hold = true;
  const controller = new AbortController();
  const dropped: string[] = [];
  const frames: QueuedAppFrame[] = [1, 2, 3].map(i => ({ channel: "preview", streamId: "project", plaintext: `${i}`, plaintextBytes: 1, type: "terminal:frame", signal: controller.signal, settle: value => dropped.push(value) }));
  scheduler.enqueue(frames);
  controller.abort();
  scheduler.dropAborted();
  expect(scheduler.queued("preview")).toEqual({ frames: 0, bytes: 0 });
  scheduler.hold = false;
  scheduler.drain();
  expect(sealed).toEqual([]);
  expect(dropped).toEqual(["dropped", "dropped", "dropped"]);
});

test("targeted bus delivery preserves cancellation and rechecks authorization at the transport", async () => {
  const bus = new MessageBus();
  let allowed = true;
  const controller = new AbortController();
  let received: AbortSignal | undefined;
  let gate: (() => boolean) | undefined;
  const mux = new StreamMux({
    openStream: () => {}, closeStream: () => {},
    sendEnvelope: async (_id, _msg, _channel, signal, authorized) => { received = signal; gate = authorized; return "sent"; },
  });
  const handle = mux.attach(bus, { mayDeliver: () => allowed });
  await bus.deliverTo(createMessage("terminal:display:status", { terminalId: "t", code: "ACK_TIMEOUT", message: "Reconnect" }), "control", "relay", controller.signal);
  expect(received).toBe(controller.signal);
  mux.markUnbound(handle.streamId);
  expect(gate!()).toBe(false);
  mux.markBound(handle.streamId);
  expect(gate!()).toBe(true);
  allowed = false;
  expect(gate!()).toBe(false);
  handle.detach();
});

test("muted terminal delivery fails without leaking loopback frames and resumes after rebind", async () => {
  const bus = new MessageBus();
  let sent = 0;
  const mux = new StreamMux({
    openStream: () => {}, closeStream: () => {},
    sendEnvelope: async () => { sent++; return "sent"; },
  });
  const handle = mux.attach(bus, {});
  const signal = new AbortController().signal;
  const status = createMessage("terminal:display:status", {
    terminalId: "t", code: "ACK_TIMEOUT", message: "Reconnect",
  });
  try {
    await bus.deliverTo(status, "control", "loopback", signal);
    expect(sent).toBe(0);
    mux.markUnbound(handle.streamId);
    await expect(bus.deliverTo(status, "control", "relay", signal)).rejects.toThrow("Terminal delivery gated");
    expect(sent).toBe(0);
    mux.markBound(handle.streamId);
    await bus.deliverTo(status, "control", "relay", signal);
    expect(sent).toBe(1);
  } finally {
    handle.detach();
  }
});
