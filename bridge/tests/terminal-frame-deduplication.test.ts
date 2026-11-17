import { afterEach, expect, spyOn, test } from "bun:test";
import type { TerminalDisplayStatus, TerminalFrame } from "../src/protocol";
import { TerminalFrameHub, type TerminalViewerTransport } from "../src/terminal-frames/delivery";
import { TerminalFrameSource } from "../src/terminal-frames/source";
import {
  TERMINAL_ACK_TIMEOUT_MS, TERMINAL_CONNECTION_MAX_BYTES, TERMINAL_FRAME_INTERVAL_MS,
  TERMINAL_PROTOCOL_VERSION, TERMINAL_VIEWER_MAX_BYTES,
  type TerminalScreenFrame,
} from "../src/terminal-frames/protocol";

const address = { projectId: "p", checkoutId: "main", terminalId: "t" };
const cleanups: (() => void)[] = [];
afterEach(() => { for (const cleanup of cleanups.splice(0).reverse()) cleanup(); });

async function setup(blocked = false) {
  let now = 1000;
  let allowed = true;
  const source = new TerminalFrameSource(40, 6);
  source.feed("same screen");
  await source.settle();
  const hub = new TerminalFrameHub(() => now);
  cleanups.push(() => { hub.dispose(); source.dispose(); });
  const runId = crypto.randomUUID();
  hub.register(address, source, runId);
  const frames: TerminalFrame[] = [];
  const statuses: TerminalDisplayStatus[] = [];
  const signals: AbortSignal[] = [];
  const budget = { bytes: 0 };
  const transport: TerminalViewerTransport = {
    budget,
    authorized: () => allowed,
    send(message, signal) {
      if (message.type === "terminal:display:status") statuses.push(message);
      if (message.type === "terminal:frame") {
        frames.push(message);
        signals.push(signal);
        if (blocked) return new Promise<void>(() => {});
      }
      return Promise.resolve();
    },
  };
  const connection = hub.connect(transport);
  const subscribe = () => connection.subscribe(address, TERMINAL_PROTOCOL_VERSION, crypto.randomUUID());
  const attachmentId = (await subscribe())!;
  const tick = (milliseconds = TERMINAL_FRAME_INTERVAL_MS) => { now += milliseconds; hub.tick(); };
  return {
    source, hub, runId, connection, frames, statuses, signals, budget, subscribe, tick,
    authorize(value: boolean) { allowed = value; hub.tick(); },
    ack() {
      const frame = frames.at(-1)!;
      return connection.acknowledge(address, { runId, attachmentId, sequence: frame.sequence });
    },
    async paint(text = "\x1b[0m") {
      source.feed(text);
      await source.settle();
      tick();
    },
  };
}

test("identical complete frames consume no sequence or credit; a changed screen still follows", async () => {
  const h = await setup();
  h.ack();
  for (let i = 0; i < 20; i++) await h.paint("\x1b[Hsame screen");
  expect(h.frames).toHaveLength(1);
  expect(h.budget.bytes).toBe(0);
  expect(h.connection.unacknowledgedBytes).toBe(0);
  await h.paint("changed");
  expect(h.frames).toHaveLength(2);
  expect(h.frames[1]!.sequence).toBe(h.frames[0]!.sequence + 1);
  expect(h.frames[1]!.revision).toBe(h.source.revision);
  expect(h.frames[1]!.ansi).toContain("changed");
});

test("an identical frame preserves the queued original and its ACK timeout", async () => {
  const h = await setup(true);
  const bytes = h.budget.bytes;
  for (let i = 0; i < 5; i++) await h.paint();
  expect(h.frames).toHaveLength(1);
  expect(h.signals[0]!.aborted).toBe(false);
  expect(h.budget.bytes).toBe(bytes);
  h.tick(TERMINAL_ACK_TIMEOUT_MS - 5 * TERMINAL_FRAME_INTERVAL_MS);
  expect(h.statuses.at(-1)?.code).toBe("ACK_TIMEOUT");
  expect(h.signals[0]!.aborted).toBe(true);
  expect(h.budget.bytes).toBe(0);
});

test("a changed screen replaces an identical queued frame without leaking credits", async () => {
  const h = await setup(true);
  await h.paint();
  await h.paint("new content");
  expect(h.frames).toHaveLength(2);
  expect(h.signals.map((signal) => signal.aborted)).toEqual([true, false]);
  expect(h.frames[1]!.ansi).toContain("new content");
  expect(h.budget.bytes).toBe(h.connection.unacknowledgedBytes);
  expect(h.budget.bytes).toBeGreaterThan(0);
});

test("a new attachment receives the complete screen even after duplicates were suppressed", async () => {
  const h = await setup();
  h.ack();
  await h.paint();
  expect(h.frames).toHaveLength(1);
  const next = await h.subscribe();
  expect(h.frames).toHaveLength(2);
  expect(h.frames[1]!.attachmentId).toBe(next!);
  expect(h.frames[1]!.sequence).toBe(1);
  expect(h.frames[1]!.ansi).toBe(h.frames[0]!.ansi);
});

test("a viewer catching up receives a screen already suppressed for another viewer", async () => {
  const h = await setup();
  h.ack();
  const behind: TerminalFrame[] = [];
  const budget = { bytes: 0 };
  const connection = h.hub.connect({
    budget, authorized: () => true,
    async send(message) { if (message.type === "terminal:frame") behind.push(message); },
  });
  const attachmentId = (await connection.subscribe(address, TERMINAL_PROTOCOL_VERSION, crypto.randomUUID()))!;
  connection.acknowledge(address, { runId: h.runId, attachmentId, sequence: behind[0]!.sequence });
  budget.bytes = TERMINAL_CONNECTION_MAX_BYTES;
  await h.paint("changed");
  h.ack();
  await h.paint();
  expect(h.frames).toHaveLength(2);
  expect(behind).toHaveLength(1);
  budget.bytes = 0;
  h.tick();
  expect(behind).toHaveLength(2);
  expect(behind[1]!.ansi).toBe(h.frames[1]!.ansi);
});

test("a pause discards the duplicate baseline when its queued screen is aborted", async () => {
  const h = await setup(true);
  await h.paint();
  h.authorize(false);
  expect(h.signals[0]!.aborted).toBe(true);
  h.authorize(true);
  h.tick();
  expect(h.frames).toHaveLength(2);
  expect(h.frames[1]!.ansi).toBe(h.frames[0]!.ansi);
  expect(h.signals[1]!.aborted).toBe(false);
});

test("a replacement emulator sends its screen even when its content matches", async () => {
  const h = await setup();
  h.ack();
  await h.paint();
  const replacement = new TerminalFrameSource(40, 6);
  cleanups.push(() => replacement.dispose());
  replacement.feed("same screen");
  await replacement.settle();
  h.hub.register(address, replacement, h.runId);
  h.tick();
  expect(h.frames).toHaveLength(2);
  expect(h.frames[1]!.ansi).toBe(h.frames[0]!.ansi);
});

test("recovering from an oversized screen resends even an identical display", async () => {
  const h = await setup();
  h.ack();
  const capture = h.source.capture.bind(h.source);
  const spy = spyOn(h.source, "capture").mockImplementation((...args) => ({
    ...capture(...args)!, ansi: "x".repeat(TERMINAL_VIEWER_MAX_BYTES),
  }));
  try {
    await h.paint();
    expect(h.frames).toHaveLength(1);
    expect(h.statuses.at(-1)?.code).toBe("DISPLAY_FAILED");
  } finally { spy.mockRestore(); }
  await h.paint();
  expect(h.frames).toHaveLength(2);
  expect(h.frames[1]!.ansi).toBe(h.frames[0]!.ansi);
  h.ack();
  await h.paint();
  expect(h.frames).toHaveLength(2);
});

test("a cancelled frame is not a duplicate baseline when shared credit delays its replacement", async () => {
  const h = await setup(true);
  const originalBytes = h.connection.unacknowledgedBytes;
  const otherViewerBytes = TERMINAL_CONNECTION_MAX_BYTES - originalBytes;
  h.budget.bytes = TERMINAL_CONNECTION_MAX_BYTES;
  await h.paint("a larger screen");
  expect(h.signals[0]!.aborted).toBe(true);
  expect(h.frames).toHaveLength(1);
  expect(h.connection.unacknowledgedBytes).toBe(0);
  expect(h.budget.bytes).toBe(otherViewerBytes);
  h.budget.bytes = TERMINAL_CONNECTION_MAX_BYTES;
  await h.paint("\x1bc" + "same screen");
  h.budget.bytes = 0;
  h.tick();
  expect(h.frames).toHaveLength(2);
  expect(h.frames[1]!.ansi).toBe(h.frames[0]!.ansi);
  expect(h.signals[1]!.aborted).toBe(false);
});

for (const acknowledged of [true, false]) {
  test(`an identical final screen ends only after consumption (already acknowledged: ${acknowledged})`, async () => {
    const h = await setup();
    if (acknowledged) h.ack();
    await h.paint();
    await h.hub.finish(address, h.runId, 7);
    h.tick();
    expect(h.frames).toHaveLength(1);
    expect(h.statuses.some((status) => status.code === "ENDED")).toBe(acknowledged);
    if (!acknowledged) { h.ack(); h.tick(); }
    expect(h.statuses.at(-1)).toMatchObject({ code: "ENDED", finalSequence: 1, exitCode: 7 });
    expect(h.connection.size).toBe(0);
  });
}

const changes: [string, (frame: TerminalScreenFrame) => TerminalScreenFrame][] = [
  ["columns", (frame) => ({ ...frame, cols: frame.cols + 1 })],
  ["rows", (frame) => ({ ...frame, rows: frame.rows + 1 })],
  ["synchronized output status", (frame) => ({ ...frame, syncTimedOut: !frame.syncTimedOut })],
  ["history epoch", (frame) => ({ ...frame, history: { ...frame.history, epoch: frame.history.epoch + 1 } })],
  ["history start", (frame) => ({ ...frame, history: { ...frame.history, firstRowId: frame.history.firstRowId + 1 } })],
  ["history end", (frame) => ({ ...frame, history: { ...frame.history, nextRowId: frame.history.nextRowId + 1 } })],
  ["history status", (frame) => ({ ...frame, history: { ...frame.history, status: frame.history.status === "recording" ? "disabled" : "recording" } })],
  ["history gap", (frame) => ({ ...frame, history: { ...frame.history, gapped: !frame.history.gapped } })],
];
for (const [name, change] of changes) {
  test(`equal ANSI with changed ${name} is delivered`, async () => {
    const h = await setup();
    h.ack();
    const capture = h.source.capture.bind(h.source);
    const spy = spyOn(h.source, "capture").mockImplementation((...args) => change(capture(...args)!));
    try {
      await h.paint();
      expect(h.frames).toHaveLength(2);
      expect(h.frames[1]!.ansi).toBe(h.frames[0]!.ansi);
    } finally { spy.mockRestore(); }
  });
}

for (const [name, output] of [
  ["cursor", "\x1b[2;3H"],
  ["input mode", "\x1b[?2004h"],
  ["style", "\x1b[H\x1b[31msame screen"],
  ["hyperlink", "\x1b[H\x1b]8;;https://example.com\x1b\\same screen\x1b]8;;\x1b\\"],
] as const) {
  test(`a ${name} change with unchanged text is delivered`, async () => {
    const h = await setup();
    h.ack();
    await h.paint(output);
    expect(h.frames).toHaveLength(2);
    expect(h.frames[1]!.ansi).not.toBe(h.frames[0]!.ansi);
  });
}
