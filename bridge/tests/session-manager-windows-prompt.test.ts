import { afterEach, beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import { delimiter, join } from "node:path";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { createAgentRunScope } from "antgrid-agents/contracts";
import { prepareTerminalLaunch } from "../src/agent-runtime";
import * as pathProbe from "../src/path-probe";
import { SessionManager } from "../src/session-manager";

const realPlatform = Object.getOwnPropertyDescriptor(process, "platform")!;
const realPath = process.env.PATH;
const dirs: string[] = [];

beforeEach(() => {
  Object.defineProperty(process, "platform", { ...realPlatform, value: "win32" });
});
afterEach(() => {
  mock.restore();
  Object.defineProperty(process, "platform", realPlatform);
  process.env.PATH = realPath;
  for (const d of dirs.splice(0)) try { rmSync(d, { recursive: true, force: true }); } catch {}
});

function tempDir(prefix: string) {
  const d = mkdtempSync(join(tmpdir(), prefix));
  dirs.push(d);
  return d;
}

/** Puts a fake `opencode<ext>` first on PATH so the spawn resolves to a shim or a real binary. */
function installOpencode(ext: ".cmd" | ".exe") {
  const bin = tempDir("ab-win-prompt-bin-");
  const installed = join(bin, `opencode${ext}`);
  writeFileSync(installed, "");
  process.env.PATH = `${bin}${delimiter}${realPath ?? ""}`;
  // findOnPath appends PATHEXT only when os.platform() says win32, which the
  // faked process.platform does not change, so off Windows it would miss the file.
  const findOnPath = pathProbe.findOnPath;
  spyOn(pathProbe, "findOnPath").mockImplementation((name, dirs, exts) => name === "opencode" ? installed : findOnPath(name, dirs, exts));
}

function captureTm() {
  const spawns: any[] = [];
  const submits: Array<{ id: string; text: string }> = [];
  const tm = {
    spawns, submits, has: () => false, kill: () => {}, forget: () => {}, treeKilled: () => Promise.resolve(),
    spawn: (cfg: any) => { spawns.push(cfg); return cfg.terminalId; },
    submit: (id: string, text: string) => { submits.push({ id, text }); },
  } as any;
  return tm;
}

async function startWithPrompt(prompt: string) {
  const tm = captureTm();
  const sm = new SessionManager({
    projectId: "p1", storeDir: tempDir("ab-win-prompt-"), projectPath: tmpdir(),
    terminalManager: tm, agentSpec: { command: "claude", name: "claude" }, sendMessage: () => {},
  });
  const s = sm.create(undefined, { tool: "opencode" });
  await sm.start(s.id, prompt);
  return tm;
}

describe("opening prompt on a Windows cmd.exe shim", () => {
  test("a multi-line prompt is typed once, not passed in argv", async () => {
    installOpencode(".cmd");
    const prompt = "first line\nsecond line\n\nthird";
    const tm = await startWithPrompt(prompt);
    expect(tm.spawns).toHaveLength(1);
    expect(tm.spawns[0].args).not.toContain("--prompt");
    expect(tm.spawns[0].args.some((a: string) => a.includes("first line"))).toBe(false);
    expect(tm.submits).toEqual([{ id: tm.spawns[0].terminalId, text: prompt }]);
  });

  test("a single-line prompt stays in argv", async () => {
    installOpencode(".cmd");
    const tm = await startWithPrompt("just one line");
    expect(tm.spawns[0].args.slice(-2)).toEqual(["--prompt", "just one line"]);
    expect(tm.submits).toEqual([]);
  });

  test("a prompt longer than the cmd.exe line limit is typed", async () => {
    installOpencode(".cmd");
    const prompt = "x".repeat(9000);
    const tm = await startWithPrompt(prompt);
    expect(tm.spawns[0].args).not.toContain(prompt);
    expect(tm.submits.map((s: { text: string }) => s.text)).toEqual([prompt]);
  });
});

describe("opening prompt on a directly executed binary", () => {
  test("a multi-line prompt stays in argv", async () => {
    installOpencode(".exe");
    const prompt = "first line\nsecond line";
    const tm = await startWithPrompt(prompt);
    expect(tm.spawns[0].args.slice(-2)).toEqual(["--prompt", prompt]);
    expect(tm.submits).toEqual([]);
  });

  test("a prompt longer than CreateProcess can hold is typed", async () => {
    installOpencode(".exe");
    const prompt = "x".repeat(40_000);
    const tm = await startWithPrompt(prompt);
    expect(tm.spawns[0].args).not.toContain(prompt);
    expect(tm.submits.map((s: { text: string }) => s.text)).toEqual([prompt]);
  });

  test("a prompt carrying a NUL is typed", async () => {
    installOpencode(".exe");
    const prompt = "fix it\0NODE_OPTIONS=--require=x.js";
    const tm = await startWithPrompt(prompt);
    expect(tm.spawns[0].args).not.toContain(prompt);
    expect(tm.submits.map((s: { text: string }) => s.text)).toEqual([prompt]);
  });
});

describe("promptArgCount", () => {
  async function prepare(initialPrompt: string | undefined, rawArgs?: string) {
    const storeDir = tempDir("ab-win-prompt-store-");
    const scope = createAgentRunScope({ runId: "run", isCurrent: () => true, emit: () => {} });
    return prepareTerminalLaunch({
      tool: "opencode",
      configured: { name: "opencode", command: "opencode" },
      rawArgs,
      conversation: { kind: "fresh" },
      initialPrompt,
      approvalPolicy: "default",
      storeDir,
      cwd: storeDir,
      signal: scope.signal,
      scope,
    });
  }

  test("counts the trailing prompt args", async () => {
    const launch = await prepare("hello");
    expect(launch.promptDelivery).toBe("included");
    expect(launch.promptArgCount).toBe(2);
    expect(launch.args.slice(-launch.promptArgCount!)).toEqual(["--prompt", "hello"]);
  });

  test("is unset without a prompt", async () => {
    const launch = await prepare(undefined);
    expect(launch.promptDelivery).toBe("none");
    expect(launch.promptArgCount).toBeUndefined();
  });

  test("counts the prompt when raw args ride as argv", async () => {
    const launch = await prepare("hi", "--model x");
    expect(launch.promptArgCount).toBe(2);
    expect(launch.args.slice(-2)).toEqual(["--prompt", "hi"]);
  });
});
