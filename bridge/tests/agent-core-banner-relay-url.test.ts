import { test, expect, beforeEach, afterEach, afterAll, spyOn } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildAgentCore, type AgentCore } from "../src/agent-core";

// Regression: the banner prints ONLY in remote mode, but `relayBase` was read
// from `config.relayUrl` alone — which only a standalone agent with an explicit
// antgrid.yaml `relayUrl:` ever has. A host-spawned remote core therefore baked
// the literal placeholder "(local mode)" into the connect URI's `r=`, and the
// app adopts `r=` verbatim whenever it is present (QrPayload.parse), so the
// fallback relay never kicked in and the machine could not be connected.

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

function connectUris(output: string): string[] {
  return output
    .split("\n")
    .filter((l) => l.startsWith("Connect URI"))
    .map((l) => l.slice(l.indexOf(":") + 1).trim());
}

const identity = {
  deviceId: "agent-dev",
  deviceName: "agent-dev",
  createdAt: new Date().toISOString(),
  ed25519PublicKey: Buffer.alloc(32, 7).toString("base64"),
};

test("host-supplied relayUrl lands in every connect URI's r=", async () => {
  core = await buildAgentCore({
    folder: tempFolder(),
    mode: "remote",
    identity,
    relayUrl: "wss://relay.example.test",
  });

  const uris = connectUris(bannerOutput());
  expect(uris.length).toBeGreaterThan(0);
  for (const uri of uris) {
    const r = new URL(uri).searchParams.get("r");
    const decoded = Buffer.from(r!, "base64url").toString("utf8");
    expect(() => new URL(decoded)).not.toThrow();
  }
  expect(
    uris.some((u) => {
      const r = new URL(u).searchParams.get("r");
      return Buffer.from(r!, "base64url").toString("utf8") === "wss://relay.example.test";
    }),
  ).toBe(true);
}, 15_000);

test("a remote core with no relay URL prints no connect URI at all", async () => {
  core = await buildAgentCore({
    folder: tempFolder(),
    mode: "remote",
    identity,
  });

  const output = bannerOutput();
  expect(connectUris(output)).toEqual([]);
  expect(output).not.toContain("(local mode)");
}, 15_000);
