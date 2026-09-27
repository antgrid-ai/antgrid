import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";
import { TerminalManager } from "../src/terminal-manager";
import { TerminalFrameSource } from "../src/terminal-frames/source";
import * as SourceModule from "../src/terminal-frames/source";
import { TerminalFrameHub, type TerminalViewerTransport } from "../src/terminal-frames/delivery";
import { TERMINAL_PROTOCOL_VERSION } from "../src/terminal-frames/protocol";
import { createConnState } from "../src/conn-state";
import type { AbMessage } from "../src/protocol";

// Bun module mocks persist across test files; the wrapper delegates every
// construction except the single explicitly armed failure.
const RealTerminalFrameSource = SourceModule.TerminalFrameSource;
let failNextConstruction = false;
mock.module("../src/terminal-frames/source", () => ({
  ...SourceModule,
  TerminalFrameSource: class extends RealTerminalFrameSource {
    constructor(...args: ConstructorParameters<typeof RealTerminalFrameSource>) {
      if (failNextConstruction) {
        failNextConstruction = false;
        throw new Error("unsupported xterm build");
      }
      super(...args);
    }
  },
}));

describe("terminal frame manager wiring", () => {
  let manager: TerminalManager;
  let messages: AbMessage[];

  beforeEach(() => {
    messages = [];
    manager = new TerminalManager((message) => messages.push(message), undefined, createConnState());
  });
  afterEach(() => manager.killAll());

  function spawn(terminalId = "t1"): TerminalFrameSource {
    manager.spawn({
      terminalId, command: process.execPath,
      args: ["-e", "setTimeout(() => {}, 120000)"], cols: 80, rows: 24,
    });
    return (manager as unknown as { screens: Map<string, TerminalFrameSource> }).screens.get(terminalId)!;
  }

  function session(): { write(data: string): void; respondToCapabilityQueries(data: string): void } {
    return (manager as unknown as { sessions: Map<string, ReturnType<typeof session>> }).sessions.get("t1")!;
  }

  /** Puts a source into its one latching state. A backlog is NOT one — `feed()`
   *  drops the chunk and carries on — so the trigger is a resize that throws,
   *  which is what the latch is for: a resize rewrites the grid and the row
   *  archive's geometry together, and a throw inside one leaves neither
   *  describing the guest. */
  async function latch(screen: TerminalFrameSource): Promise<void> {
    (screen as unknown as { term: { resize(cols: number, rows: number): void } }).term.resize = () => {
      throw new Error("resize: grid gone");
    };
    screen.resize(100, 40);
    await screen.settle();
  }

  test("a same-id respawn gets a new run and authoritative emulator", () => {
    const first = spawn();
    const firstRun = manager.runId("t1");
    const second = spawn();
    expect(second).not.toBe(first);
    expect(manager.runId("t1")).not.toBe(firstRun);
    expect(first.isDisposed).toBe(true);
  });

  test("a constructor error refuses PTY startup and cleans the terminal slot", () => {
    failNextConstruction = true;
    expect(() => spawn()).toThrow("unsupported xterm build");
    expect(manager.has("t1")).toBe(false);
    expect(manager.runId("t1")).toBeUndefined();
    expect(manager.getScrollback("t1")).toBeNull();
    expect(messages.some((message) => message.type === "terminal:started")).toBe(false);
    expect(spawn()).toBeInstanceOf(TerminalFrameSource);
  });

  test("a latched parser stays failed across snapshot attempts and further output", async () => {
    const screen = spawn();
    const runId = manager.runId("t1");
    await latch(screen);
    const failure = screen.failure;
    expect(failure).toBeDefined();
    for (let attempt = 0; attempt < 5; attempt++) {
      expect(() => screen.capture(performance.now())).toThrow("resize");
      screen.feed("new output");
    }
    expect(screen.failure).toBe(failure);
    expect(manager.runId("t1")).toBe(runId);
    expect((manager as unknown as { screens: Map<string, TerminalFrameSource> }).screens.get("t1")).toBe(screen);
    expect(() => screen.capture(performance.now())).toThrow("resize");
    expect(manager.has("t1")).toBe(true);
  });

  test("a backlog costs the chunk and not the run's display", async () => {
    const screen = spawn();
    const runId = manager.runId("t1");
    screen.feed("x".repeat(16_000_001));
    expect(screen.failure).toBeUndefined();
    expect(() => screen.capture(performance.now())).not.toThrow();
    // The same slot, the same run, still attached — and the next thing the
    // guest paints is on screen.
    screen.feed("after the drop");
    await screen.settle();
    expect(screen.capture(performance.now())?.ansi).toContain("after the drop");
    expect(manager.runId("t1")).toBe(runId);
    expect((manager as unknown as { screens: Map<string, TerminalFrameSource> }).screens.get("t1")).toBe(screen);
  });

  test("a viewer is told DISPLAY_FAILED when an already-painted source latches", async () => {
    const screen = spawn();
    await screen.settle();
    let now = 100;
    const sent: AbMessage[] = [];
    const transport: TerminalViewerTransport = {
      authorized: () => true,
      send: async (message) => { sent.push(message); },
    };
    const hub = new TerminalFrameHub(() => now);
    const address = { projectId: "project", checkoutId: "main", terminalId: "t1" };
    hub.register(address, screen, manager.runId("t1")!);
    const connection = hub.connect(transport);
    try {
      await connection.subscribe(address, TERMINAL_PROTOCOL_VERSION, crypto.randomUUID());
      hub.tick();
      expect(sent.some((message) => message.type === "terminal:frame")).toBe(true);
      now += 100;
      await latch(screen);
      hub.tick();
      await Promise.resolve();
      expect(sent.some((message) => message.type === "terminal:display:status" && message.code === "DISPLAY_FAILED")).toBe(true);
    } finally {
      connection.close();
    }
  });

  test("a failed source does not enable an unordered byte-level query responder", async () => {
    const screen = spawn();
    const target = session();
    const writes: string[] = [];
    target.write = (data) => { writes.push(data); };
    await latch(screen);
    expect(() => screen.capture(performance.now())).toThrow();
    const burst = "\x1b[c\x1b[6n\x1b[?25$p";
    target.respondToCapabilityQueries(burst);
    screen.feed(burst);
    expect(writes).toEqual([]);
  });

  test("state-dependent queries answer once at their position in the parsed output", async () => {
    const screen = spawn();
    const target = session();
    const writes: string[] = [];
    target.write = (data) => { writes.push(data); };
    // Absolute cursor and mode changes remove shell/ConPTY startup state from
    // the fixture while testing parser ordering within the same write.
    const burst = "\x1b[?6l\x1b[4;7H\x1b[?25h\x1b]11;?\x07\x1b[c\x1b[6n\x1b[?25$p\x1b[9;2H\x1b[6n";
    target.respondToCapabilityQueries(burst);
    screen.feed(burst);
    await screen.settle();
    expect(writes).toEqual([
      "\x1b]11;rgb:0909/0909/0b0b\x07",
      "\x1b[?64;1;2;6;9;15;18;21;22c",
      "\x1b[4;7R",
      "\x1b[?25;1$y",
      "\x1b[9;2R",
    ]);
  });

  test("a later OSC query does not overtake a preceding parser query", async () => {
    const screen = spawn();
    const target = session();
    const writes: string[] = [];
    target.write = (data) => { writes.push(data); };
    const burst = "\x1b[c\x1b]11;?\x07";
    target.respondToCapabilityQueries(burst);
    screen.feed(burst);
    await screen.settle();
    expect(writes).toEqual(["\x1b[?64;1;2;6;9;15;18;21;22c", "\x1b]11;rgb:0909/0909/0b0b\x07"]);
  });

  test("a resize settles at the new geometry", async () => {
    const screen = spawn();
    manager.resize("t1", "viewer", 100, 30);
    await screen.settle();
    const frame = screen.capture(performance.now(), { final: true });
    expect(frame?.cols).toBe(100);
    expect(frame?.rows).toBe(30);
  });

  test("a throwing dispose does not prevent other screens from being released", () => {
    const first = spawn();
    const second = spawn("t2");
    const disposeFirst = first.dispose.bind(first);
    first.dispose = () => { disposeFirst(); throw new Error("dispose failure"); };
    manager.killAll();
    expect(second.isDisposed).toBe(true);
    expect(manager.runId("t1")).toBeUndefined();
    expect(manager.runId("t2")).toBeUndefined();
  });
});
