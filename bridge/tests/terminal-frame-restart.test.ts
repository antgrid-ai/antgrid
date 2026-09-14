import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TerminalHistoryStore } from "../src/terminal-frames/history";
import { TerminalFrameSource } from "../src/terminal-frames/source";
import { TerminalManager, closeTerminalHistoryStore } from "../src/terminal-manager";
import { resolveTerminalHistoryPath } from "../src/antgrid-dir";
import { createConnState } from "../src/conn-state";

const previous = { dir: process.env.ANTGRID_DIR, enabled: process.env.ANTGRID_TERMINAL_HISTORY_TEST };
let root: string | undefined;
const managers: TerminalManager[] = [];
afterEach(() => {
  for (const manager of managers.splice(0)) manager.killAll();
  closeTerminalHistoryStore();
  if (previous.dir === undefined) delete process.env.ANTGRID_DIR; else process.env.ANTGRID_DIR = previous.dir;
  if (previous.enabled === undefined) delete process.env.ANTGRID_TERMINAL_HISTORY_TEST; else process.env.ANTGRID_TERMINAL_HISTORY_TEST = previous.enabled;
  if (root) rmSync(root, { recursive: true, force: true });
  root = undefined;
});

test("restart restores the last screen and rows only to their owning project and terminal", async () => {
  root = mkdtempSync(join(tmpdir(), "antgrid-frame-restart-"));
  process.env.ANTGRID_DIR = root;
  process.env.ANTGRID_TERMINAL_HISTORY_TEST = "1";
  const store = new TerminalHistoryStore(resolveTerminalHistoryPath());
  const runId = crypto.randomUUID();
  const history = store.openRun(runId);
  store.bindRun(runId, "project-a", "terminal");
  const source = new TerminalFrameSource(20, 3, history);
  source.feed("first\r\nsecond\r\nthird\r\nfinal");
  await source.settle();
  store.saveFinal(runId, source.capture(0, { final: true })!);
  source.dispose();
  store.close();

  let restored: TerminalFrameSource | undefined;
  const owner = new TerminalManager(() => {}, { onRunStarted: (_id, _run, screen) => { restored = screen; } }, createConnState(), undefined, "project-a");
  const stranger = new TerminalManager(() => {}, undefined, createConnState(), undefined, "project-b");
  managers.push(owner, stranger);
  expect(owner.getStatus()).toContainEqual(expect.objectContaining({ terminalId: "terminal", running: false }));
  expect(stranger.getStatus()).toEqual([]);
  await stranger.restoreArchivedTerminal("terminal");
  expect(stranger.runId("terminal")).toBeUndefined();
  await owner.restoreArchivedTerminal("terminal");
  expect(owner.runId("terminal")).toBe(runId);
  expect(restored!.visibleLines()).toEqual(["second", "third", "final"]);
  const boundary = restored!.capture(0)!.history;
  expect(boundary.nextRowId).toBe(1);
  expect(owner.historyPage(runId, boundary.epoch, boundary.nextRowId)!.rows[0]!.spans.map(s => s.text).join("").trimEnd()).toBe("first");
  expect(stranger.ownsHistoryRun("terminal", runId)).toBe(false);
  expect(owner.ownsHistoryRun("different-terminal", runId)).toBe(false);
  owner.forget("terminal");
  expect(owner.ownsHistoryRun("terminal", runId)).toBe(false);
  expect(owner.historyPage(runId, 0, 1)).toBeUndefined();
});
