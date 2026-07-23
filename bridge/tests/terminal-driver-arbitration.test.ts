import { afterAll, test, expect } from "bun:test";
import { TerminalManager } from "../src/terminal-manager";
import type { AbMessage } from "../src/protocol";
import { createConnState } from "../src/conn-state";
import { __setRootForTest } from "../src/logger";

function makeManager() {
  const sent: AbMessage[] = [];
  const mgr = new TerminalManager(
    (m) => sent.push(m),
    undefined,
    createConnState(),
  );
  return { mgr, sent };
}

afterAll(() => __setRootForTest(process.stdout));

test("resize sets driver to last resizer and broadcasts terminal:size", () => {
  const { mgr, sent } = makeManager();
  mgr.spawn({ terminalId: "t1", cols: 80, rows: 24 });

  mgr.resize("t1", "deviceA", 120, 30);
  mgr.resize("t1", "deviceB", 50, 40);

  const sizes = sent.filter((m) => m.type === "terminal:size");
  const last = sizes.at(-1)!;
  expect(last.driverClientId).toBe("deviceB");
  expect(last.cols).toBe(50);
  expect(last.rows).toBe(40);

  mgr.killAll();
});

test("same-client same-size resize is ignored before touching the PTY", () => {
  const { mgr } = makeManager();
  // pino writes JSONL straight to its destination stream, bypassing
  // console.log, so capture via the test root instead.
  const lines: string[] = [];
  __setRootForTest({
    write(s: string): boolean {
      lines.push(s);
      return true;
    },
  }, "debug");

  try {
    mgr.spawn({ terminalId: "t1", cols: 80, rows: 24 });

    mgr.resize("t1", "deviceA", 120, 30);
    mgr.resize("t1", "deviceA", 120, 30);

    const resizeLogs = lines
      .map((l) => (JSON.parse(l) as { msg: string }).msg)
      .filter((msg) => msg.includes('Terminal "t1" resized to 120x30 by deviceA'));
    expect(resizeLogs).toHaveLength(1);
  } finally {
    mgr.killAll();
  }
});

test("stale resize based on a superseded driver cannot retake ownership", () => {
  const { mgr, sent } = makeManager();
  mgr.spawn({ terminalId: "t1", cols: 80, rows: 24 });

  mgr.resize("t1", "desktop", 120, 30);
  mgr.resize("t1", "mobile", 50, 40, "desktop");
  mgr.resize("t1", "desktop", 120, 30, "desktop");

  const sizes = sent.filter((m) => m.type === "terminal:size");
  const last = sizes.at(-1)!;
  expect(last.driverClientId).toBe("mobile");
  expect(last.cols).toBe(50);
  expect(last.rows).toBe(40);

  const status = mgr.getStatus().find((s) => s.terminalId === "t1")!;
  expect(status.driverClientId).toBe("mobile");
  expect(status.cols).toBe(50);
  expect(status.rows).toBe(40);

  mgr.killAll();
});
