import { describe, expect, test } from "bun:test";
import { TerminalManager } from "../src/terminal-manager";
import { createConnState } from "../src/conn-state";
import type { AbMessage } from "../src/protocol";

const shellCommand = process.platform === "win32" ? "cmd.exe" : "/bin/sh";

function makeManager() {
  const sent: AbMessage[] = [];
  const manager = new TerminalManager(
    (msg) => sent.push(msg),
    undefined,
    createConnState(),
  );
  return { manager, sent };
}

function geometryOf(manager: TerminalManager, terminalId: string) {
  const row = manager.getStatus().find((s) => s.terminalId === terminalId);
  if (!row) throw new Error(`no status row for ${terminalId}`);
  return { cols: row.cols, rows: row.rows };
}

describe("TerminalManager spawn geometry", () => {
  test("falls back to 80x24 before any driver has reported", () => {
    const { manager } = makeManager();
    manager.spawn({ terminalId: "t1", command: shellCommand });
    expect(geometryOf(manager, "t1")).toEqual({ cols: 80, rows: 24 });
    manager.killAll();
  });

  test("a later terminal spawns at the size the driver last reported", () => {
    const { manager } = makeManager();
    manager.spawn({ terminalId: "t1", command: shellCommand });
    manager.resize("t1", "client-a", 132, 43);

    // A fullscreen TUI draws its first frame before any resize round-trips, so
    // this is the geometry that frame must be composed against.
    manager.spawn({ terminalId: "t2", command: shellCommand });
    expect(geometryOf(manager, "t2")).toEqual({ cols: 132, rows: 43 });
    manager.killAll();
  });

  test("an explicitly requested size still wins", () => {
    const { manager } = makeManager();
    manager.spawn({ terminalId: "t1", command: shellCommand });
    manager.resize("t1", "client-a", 132, 43);

    manager.spawn({ terminalId: "t2", command: shellCommand, cols: 100, rows: 30 });
    expect(geometryOf(manager, "t2")).toEqual({ cols: 100, rows: 30 });
    manager.killAll();
  });

  test("the remembered size survives the terminal it came from", () => {
    const { manager } = makeManager();
    manager.spawn({ terminalId: "t1", command: shellCommand });
    manager.resize("t1", "client-a", 120, 40);
    manager.kill("t1");

    manager.spawn({ terminalId: "t2", command: shellCommand });
    expect(geometryOf(manager, "t2")).toEqual({ cols: 120, rows: 40 });
    manager.killAll();
  });
});
