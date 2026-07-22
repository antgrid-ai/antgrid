import { test, expect, beforeEach, afterEach, afterAll } from "bun:test";
import { mkdtempSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildAgentCore, type AgentCore } from "../src/agent-core";

// Regression: a host-spawned REMOTE project with no antgrid.yaml used to drop
// into the interactive `consoleBootstrapIO` ("Which coding agent?") bootstrap,
// which reads stdin. Host-spawned agents are headless (no TTY), so the prompt
// blocked forever — core.start() never returned and the app's project:start
// timed out at 30s ("Could not start project"). The fix gates the interactive
// bootstrap on `process.stdin.isTTY`; headless → DEFAULT_CONFIG, like local mode.

let prevAbDir: string | undefined;
let abDir: string;
const folders: string[] = [];
let prevIsTTY: PropertyDescriptor | undefined;

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-headless-cfg-"));
  process.env.ANTGRID_DIR = abDir;
  // Force a non-TTY stdin so the assertion holds even when the suite is run
  // from an interactive terminal. Restored in afterEach.
  prevIsTTY = Object.getOwnPropertyDescriptor(process.stdin, "isTTY");
  Object.defineProperty(process.stdin, "isTTY", { value: false, configurable: true });
});

let core: AgentCore | null = null;
afterEach(async () => {
  try { await core?.shutdown(); } catch {}
  core = null;
  if (prevIsTTY) Object.defineProperty(process.stdin, "isTTY", prevIsTTY);
  else delete (process.stdin as { isTTY?: unknown }).isTTY;
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR;
  else process.env.ANTGRID_DIR = prevAbDir;
  try { rmSync(abDir, { recursive: true, force: true }); } catch {}
});

afterAll(() => {
  while (folders.length) {
    try { rmSync(folders.pop()!, { recursive: true, force: true }); } catch {}
  }
});

function tempFolderNoConfig(): string {
  const f = mkdtempSync(join(tmpdir(), "antgrid-headless-proj-"));
  folders.push(f);
  return f; // intentionally NO antgrid.yaml
}

test("remote-mode buildAgentCore with no antgrid.yaml resolves headlessly (no interactive prompt)", async () => {
  const folder = tempFolderNoConfig();

  // Before the fix this awaits forever on the inquirer select(); the test
  // timeout is the regression guard. After the fix it resolves via defaults.
  core = await buildAgentCore({
    folder,
    mode: "remote",
    identity: { deviceId: "agent-dev", deviceName: "agent-dev", createdAt: new Date().toISOString() },
  });

  expect(core).toBeTruthy();
  expect(core.projectId.length).toBeGreaterThan(0);
  // Headless defaults must NOT write an antgrid.yaml (the interactive path's
  // confirmSave would); the file stays absent until the user configures it.
  expect(existsSync(join(folder, "antgrid.yaml"))).toBe(false);
}, 10_000);
