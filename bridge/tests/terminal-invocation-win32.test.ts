import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { spawn } from "bun-pty";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { resolveTerminalInvocation, type TerminalInvocation } from "../src/terminal-invocation";
import { terminalInvocationHost } from "../src/terminal-session";

// Spawns through the real bun-pty and cmd.exe: the argv the child receives is
// the only thing that proves the quoting survives both layers.
describe.skipIf(process.platform !== "win32")("terminal invocation through cmd.exe", () => {
  let dir: string;
  let out: string;
  let marker: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), "ab term "));
    out = join(dir, "argv.json");
    marker = join(dir, "injected.txt");
    writeFileSync(join(dir, "args.js"), "require(\"fs\").writeFileSync(process.env.OUT, JSON.stringify(process.argv.slice(2)))");
    writeFileSync(join(dir, "agent.cmd"), "@echo off\r\nnode \"%~dp0args.js\" %*\r\n");
  });
  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  async function run(invocation: TerminalInvocation, cwd = dir): Promise<string[]> {
    rmSync(out, { force: true });
    const env = { ...process.env, OUT: out } as Record<string, string>;
    const r = resolveTerminalInvocation(invocation, terminalInvocationHost(env));
    const pty = spawn(r.command, r.args, { cols: 200, rows: 24, cwd, name: "xterm-256color", env: { ...env, ...r.env } });
    await new Promise<void>((resolve, reject) => {
      const t = setTimeout(() => reject(new Error("timed out waiting for the child to exit")), 10_000);
      pty.onExit(() => { clearTimeout(t); resolve(); });
    });
    return JSON.parse(readFileSync(out, "utf8"));
  }

  it("delivers tricky arguments to a batch shim in a directory with a space, without injection", async () => {
    const args = [
      "a b",
      `it's 5" & echo INJECTED> "${marker}" & rem`,
      "hi %USERNAME% 100%",
      "bang! x",
      "C:\\trail\\",
      "",
      "q\\\"x",
      "notify=[\"C:\\x\\b.exe\",\"hook\"]",
    ];
    const argv = await run({ command: join(dir, "agent.cmd"), args, invocationKind: "exec" });
    expect(argv).toEqual(args);
    expect(existsSync(marker)).toBe(false);
  }, 20_000);

  // How every npm-installed agent launches: a bare name found on PATH, run from
  // the project folder. The shim finds its script through %~dp0.
  it("runs a bare-name shim found on PATH from another working directory", async () => {
    const pathKey = Object.keys(process.env).find((k) => k.toLowerCase() === "path") ?? "PATH";
    const saved = process.env[pathKey];
    process.env[pathKey] = `${dir};${saved ?? ""}`;
    try {
      const argv = await run({ command: "agent", args: ["a b", "x&y"], invocationKind: "exec" }, tmpdir());
      expect(argv).toEqual(["a b", "x&y"]);
    } finally {
      process.env[pathKey] = saved;
    }
  }, 20_000);

  it("delivers a shell line with a quoted program path and quoted argument", async () => {
    const argv = await run({
      command: `node "${join(dir, "args.js")}" --flag "a b"`,
      args: [],
      invocationKind: "shell",
    });
    expect(argv).toEqual(["--flag", "a b"]);
  }, 20_000);

  it("runs a service command written as a YAML block scalar, trailing newline and all", async () => {
    const argv = await run({ command: `node "${join(dir, "args.js")}" --flag "a b"\n`, args: [] });
    expect(argv).toEqual(["--flag", "a b"]);
  }, 20_000);

  it("runs a configured command line that also has arguments", async () => {
    const argv = await run({ command: `node "${join(dir, "args.js")}" --flag`, args: ["a b", "x&y"], invocationKind: "exec" });
    expect(argv).toEqual(["--flag", "a b", "x&y"]);
  }, 20_000);
});
