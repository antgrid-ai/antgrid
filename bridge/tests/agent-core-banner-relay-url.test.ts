import { test, expect, beforeEach, afterEach, afterAll, spyOn } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildAgentCore, type AgentCore } from "../src/agent-core";

// Regression: `relayBase` was read from `config.relayUrl` alone — which only a
// standalone agent with an explicit antgrid.yaml `relayUrl:` ever has — so a
// host-spawned remote core resolved no relay at all and reported itself
// unconfigured while the host was in fact dialing one.

let prevAbDir: string | undefined;
let abDir: string;
let prevIsTTY: PropertyDescriptor | undefined;
let logSpy: ReturnType<typeof spyOn>;
const folders: string[] = [];

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-banner-relay-"));
  process.env.ANTGRID_DIR = abDir;
  prevIsTTY = Object.getOwnPropertyDescriptor(process.stdin, "isTTY");
  Object.defineProperty(process.stdin, "isTTY", { value: false, configurable: true });
  logSpy = spyOn(console, "log").mockImplementation(() => {});
});

let core: AgentCore | null = null;
afterEach(async () => {
  try { await core?.shutdown(); } catch {}
  core = null;
  logSpy.mockRestore();
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

function tempFolder(): string {
  const f = mkdtempSync(join(tmpdir(), "antgrid-banner-proj-"));
  folders.push(f);
  return f;
}

function bannerOutput(): string {
  return logSpy.mock.calls.map((c: unknown[]) => String(c[0] ?? "")).join("\n");
}

const identity = {
  deviceId: "agent-dev",
  deviceName: "agent-dev",
  createdAt: new Date().toISOString(),
  ed25519PublicKey: Buffer.alloc(32, 7).toString("base64"),
};

test("host-supplied relayUrl reaches the banner", async () => {
  core = await buildAgentCore({
    folder: tempFolder(),
    mode: "remote",
    identity,
    relayUrl: "wss://relay.example.test",
  });

  const output = bannerOutput();
  expect(output).toContain("wss://relay.example.test");
  expect(output).not.toContain("(not configured)");
}, 15_000);

test("a remote core with no relay URL reports itself unconfigured", async () => {
  core = await buildAgentCore({
    folder: tempFolder(),
    mode: "remote",
    identity,
  });

  expect(bannerOutput()).toContain("(not configured)");
}, 15_000);
