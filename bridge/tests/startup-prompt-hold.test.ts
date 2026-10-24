// A submit into an agent that opens on a folder-trust dialog. Every such
// dialog measured enables bracketed paste and paints, so the submit gate took
// it for the composer and the line's CR answered it with whatever option was
// highlighted: trust (saved, for Codex and Kimi) or exit (Claude Code).
import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createConnState } from "../src/conn-state";
import { setLogLevel } from "../src/logger";
import { TerminalManager } from "../src/terminal-manager";

setLogLevel("error");

async function waitFor(what: string, ready: () => boolean, timeoutMs = 15_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (ready()) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`timed out after ${timeoutMs}ms waiting for ${what}`);
}

// Records every read as "<screen>:<bytes>", so a test can tell which screen a
// write landed on. "y" answers the dialog and swaps in the composer. With
// "composer-first" it opens the way Codex does: composer, then the dialog over
// it.
const FAKE_AGENT = `
const { appendFileSync } = require("node:fs");
const log = process.argv[2];
let screen = "dialog";
process.stdin.setRawMode?.(true);
process.stdin.resume();
const dialog = () => {
  screen = "dialog";
  process.stdout.write("\\x1b[?2004h\\x1b[2J\\x1b[H Trust this folder?\\r\\n > Trust\\r\\n   Exit\\r\\n");
  appendFileSync(log, "drawn\\n");
};
if (process.argv[3] === "composer-first") {
  screen = "early";
  process.stdout.write("\\x1b[?2004h\\x1b[2J\\x1b[H > ask anything\\r\\n");
  appendFileSync(log, "composer\\n");
  setTimeout(dialog, 600);
} else {
  dialog();
}
process.stdin.on("data", (data) => {
  appendFileSync(log, screen + ":" + JSON.stringify(data.toString()) + "\\n");
  if (screen === "dialog" && data.toString().includes("y")) {
    screen = "composer";
    process.stdout.write("\\x1b[2J\\x1b[H > ask anything\\r\\n");
  }
});
`;

const dirs: string[] = [];
const managers: TerminalManager[] = [];
afterEach(() => {
  for (const manager of managers.splice(0)) manager.killAll();
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function startFakeAgent(startupPrompts?: string[], opening = "dialog"): { manager: TerminalManager; reads: () => string[] } {
  const dir = mkdtempSync(join(tmpdir(), "antgrid-startup-prompt-"));
  dirs.push(dir);
  const script = join(dir, "agent.js");
  const log = join(dir, "reads.log");
  writeFileSync(script, FAKE_AGENT);
  writeFileSync(log, "");
  const manager = new TerminalManager(() => {}, undefined, createConnState());
  managers.push(manager);
  manager.spawn({
    terminalId: "t1",
    command: process.execPath,
    args: [script, log, opening],
    type: "agent",
    startupPrompts,
  });
  const reads = () => readFileSync(log, "utf8").split("\n").filter(Boolean);
  return { manager, reads };
}

test("a submit waits behind a trust dialog and reaches the composer once the user answers", async () => {
  const { manager, reads } = startFakeAgent(["Trust this folder?"]);
  await waitFor("the dialog", () => reads().includes("drawn"));

  manager.submit("t1", "continue the task");
  // Well past the screen check's settle time: long enough for a release into
  // the dialog to have happened if the hold were missing.
  await new Promise((resolve) => setTimeout(resolve, 1_500));
  expect(reads().filter((read) => read.startsWith("dialog:"))).toEqual([]);

  manager.write("t1", "y");
  await waitFor("the submit", () => reads().some((read) => read.startsWith("composer:") && read.includes("continue the task")));
  expect(reads().filter((read) => read.startsWith("dialog:"))).toEqual(['dialog:"y"']);
}, 30_000);

// The same run with nothing declared is the defect itself: the line and its CR
// land in the dialog.
test("without declared startup prompts the submit answers the dialog", async () => {
  const { manager, reads } = startFakeAgent();
  await waitFor("the dialog", () => reads().includes("drawn"));

  manager.submit("t1", "continue the task");

  await waitFor("the submit", () => reads().some((read) => read.startsWith("dialog:") && read.includes("\\r")));
}, 30_000);

test("a composer painted before the dialog does not let a submit go", async () => {
  const { manager, reads } = startFakeAgent(["Trust this folder?"], "composer-first");
  await waitFor("the early composer", () => reads().includes("composer"));

  manager.submit("t1", "continue the task");
  await waitFor("the dialog", () => reads().includes("drawn"));
  await new Promise((resolve) => setTimeout(resolve, 1_500));
  expect(reads().filter((read) => read.startsWith("early:") || read.startsWith("dialog:"))).toEqual([]);

  manager.write("t1", "y");
  await waitFor("the submit", () => reads().some((read) => read.startsWith("composer:") && read.includes("continue the task")));
}, 30_000);
