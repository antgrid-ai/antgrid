import { describe, test, expect, beforeEach } from "bun:test";
import { TerminalManager } from "../src/terminal-manager";
import { TerminalSession } from "../src/terminal-session";
import { createConnState, type ConnState } from "../src/conn-state";
import type { AbMessage } from "../src/protocol";

describe("TerminalManager", () => {
  let manager: TerminalManager;
  let messages: AbMessage[];
  let connState: ConnState;

  beforeEach(() => {
    messages = [];
    connState = createConnState();
    manager = new TerminalManager((msg) => messages.push(msg), undefined, connState);
  });

  test("spawn terminal emits terminal:started", async () => {
    const id = manager.spawn({ terminalId: "t1" });
    expect(id).toBe("t1");

    // Wait for the started message to arrive
    await new Promise((r) => setTimeout(r, 100));
    const started = messages.find((m) => m.type === "terminal:started");
    expect(started).toBeDefined();
    expect(started!.type).toBe("terminal:started");
    if (started!.type === "terminal:started") {
      expect(started!.terminalId).toBe("t1");
    }

    manager.killAll();
  });

  test("replay snapshot extends the raw scrollback, never replaces it", async () => {
    manager.spawn({ terminalId: "t1" });
    await new Promise((r) => setTimeout(r, 800));

    // Taken replay-first: anything the shell emits between the two calls would
    // grow `raw` past `replay` and fail the suffix check rather than pass it.
    const replay = manager.getReplaySnapshot("t1");
    const raw = manager.getScrollback("t1");
    expect(replay).not.toBeNull();
    expect(raw).not.toBeNull();
    expect(replay!.text.endsWith(raw!.text)).toBe(true);
    expect(replay!.seq).toBe(raw!.seq);

    manager.killAll();
  });

  test("replay snapshot is null for an unknown terminal", () => {
    expect(manager.getReplaySnapshot("nope")).toBeNull();
  });

  test("kill terminal emits terminal:exited", async () => {
    manager.spawn({ terminalId: "t1" });
    await new Promise((r) => setTimeout(r, 100));

    // Fire-and-forget: callers signal from message handlers and must not be
    // made to wait on the reaping. Also the proof that the deferred handle
    // kill still lands — the PTY exits without anyone awaiting anything.
    expect(manager.kill("t1")).toBeUndefined();
    await new Promise((r) => setTimeout(r, 500));

    const exited = messages.find((m) => m.type === "terminal:exited");
    expect(exited).toBeDefined();
  });

  test("killAndAwaitTree is a no-op for an unknown terminal", async () => {
    await expect(manager.killAndAwaitTree("nope")).resolves.toBeUndefined();
  });

  test("a killed session's exit cannot evict its same-id replacement", async () => {
    manager.spawn({ terminalId: "t1" });
    await new Promise((r) => setTimeout(r, 100));

    manager.kill("t1");
    manager.spawn({ terminalId: "t1" });
    // Long enough for the dead PTY's exit to land on the new session's slot.
    await new Promise((r) => setTimeout(r, 800));

    expect(manager.has("t1")).toBe(true);
    manager.killAll();
  });

  test("multiple terminals run independently", async () => {
    manager.spawn({ terminalId: "t1" });
    manager.spawn({ terminalId: "t2" });
    await new Promise((r) => setTimeout(r, 100));

    expect(manager.size).toBe(2);
    expect(manager.has("t1")).toBe(true);
    expect(manager.has("t2")).toBe(true);

    manager.killAll();
  });

  test("scrollback stores output and returns it", async () => {
    manager.spawn({ terminalId: "t1" });
    await new Promise((r) => setTimeout(r, 100));

    // Send a command to generate output
    manager.write("t1", "echo hello\n");
    await new Promise((r) => setTimeout(r, 300));

    const scrollback = manager.getScrollback("t1");
    expect(scrollback).not.toBeNull();
    // Scrollback should contain at least something (prompt or echo output)
    expect(typeof scrollback?.text).toBe("string");
    expect(typeof scrollback?.seq).toBe("number");

    manager.killAll();
  });

  test("scrollback returns null for unknown terminal", () => {
    expect(manager.getScrollback("nonexistent")).toBeNull();
  });

  test("killAll stops all sessions", async () => {
    manager.spawn({ terminalId: "t1" });
    manager.spawn({ terminalId: "t2" });
    await new Promise((r) => setTimeout(r, 100));

    expect(manager.size).toBe(2);
    manager.killAll();
    expect(manager.size).toBe(0);
  });


  test("spawn generates UUID if no terminalId provided", async () => {
    const id = manager.spawn({});
    expect(id).toMatch(/^[0-9a-f]{8}-/); // UUID format
    manager.killAll();
  });

  test("invokes registered output observer on PTY data", async () => {
    const isWin = process.platform === "win32";
    const session = new TerminalSession({
      terminalId: "obs1",
      name: "obs1",
      command: isWin ? "cmd.exe" : "sh",
      args: isWin ? ["/c", "echo hello-observer"] : ["-c", "echo hello-observer"],
      cols: 80,
      rows: 24,
      onMessage: () => {},
    });

    const chunks: string[] = [];
    session.onOutput((s) => chunks.push(s));
    // Ensure observer errors are swallowed and don't break the stream
    session.onOutput(() => {
      throw new Error("observer error should be swallowed");
    });

    await new Promise<void>((resolve) => {
      const originalOnMessage = (session as unknown as { onMessage: (m: AbMessage) => void }).onMessage;
      (session as unknown as { onMessage: (m: AbMessage) => void }).onMessage = (msg: AbMessage) => {
        originalOnMessage(msg);
        if (msg.type === "terminal:exited") resolve();
      };
      session.spawn();
    });

    expect(chunks.join("")).toContain("hello-observer");
  });

  test("does not forward terminal:output while paused but keeps scrollback", async () => {
    manager.spawn({ terminalId: "t1" });
    await new Promise((r) => setTimeout(r, 100));

    // Drain any startup output emitted before pausing.
    const baselineOutputs = messages.filter((m) => m.type === "terminal:output").length;

    connState.appFocusPaused = true;
    manager.write("t1", "echo paused-output\n");
    await new Promise((r) => setTimeout(r, 300));

    const outputsAfterPause = messages.filter((m) => m.type === "terminal:output").length;
    expect(outputsAfterPause).toBe(baselineOutputs);

    const snap = manager.getScrollback("t1");
    expect(snap).not.toBeNull();
    expect(snap!.text.length).toBeGreaterThan(0);
    // seq advanced even while paused
    expect(snap!.seq).toBeGreaterThan(0);

    manager.killAll();
  });

  test("emits terminal:output with monotonic seq when unpaused", async () => {
    manager.spawn({ terminalId: "t1" });
    await new Promise((r) => setTimeout(r, 100));

    manager.write("t1", "echo one\n");
    await new Promise((r) => setTimeout(r, 200));
    manager.write("t1", "echo two\n");
    await new Promise((r) => setTimeout(r, 200));

    const seqs = messages
      .filter((m) => m.type === "terminal:output")
      .map((m) => (m as { seq?: number }).seq)
      .filter((s): s is number => typeof s === "number");

    expect(seqs.length).toBeGreaterThan(0);
    for (let i = 1; i < seqs.length; i++) {
      expect(seqs[i]).toBeGreaterThan(seqs[i - 1]!);
    }

    manager.killAll();
  });

  test("spawn stamps ANTGRID_API_PORT from getApiPort into the session env", async () => {
    const outputs: string[] = [];
    const mgr = new TerminalManager(
      (msg) => { if (msg.type === "terminal:output") outputs.push(msg.data); },
      undefined,
      createConnState(),
      () => 54321, // getApiPort
    );
    const isWin = process.platform === "win32";
    const id = mgr.spawn(isWin
      ? { command: "cmd.exe", args: ["/d", "/s", "/c", "echo %ANTGRID_API_PORT%"] }
      : { command: "/bin/sh", args: ["-c", "echo $ANTGRID_API_PORT"] });
    // Give the PTY a moment to emit + exit.
    await new Promise((r) => setTimeout(r, 800));
    mgr.kill(id);
    expect(outputs.join("")).toContain("54321");
  });

  test("resize updates terminal dimensions", async () => {
    manager.spawn({ terminalId: "t1" });
    await new Promise((r) => setTimeout(r, 100));

    manager.resize("t1", "test-client", 120, 40);
    const status = manager.getStatus();
    const t1 = status.find((s) => s.terminalId === "t1");
    expect(t1?.cols).toBe(120);
    expect(t1?.rows).toBe(40);

    manager.killAll();
  });
});
