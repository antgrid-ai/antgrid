import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { prepareKimiTerminal, parseKimiForkId } from "../src/agents/kimi/terminal";
import { withAgentHost, type AgentHostServices, type AgentLogger } from "../src/host";
import { createAgentRunScope } from "../src/run-scope";
import type { TerminalLaunchRequest } from "../src/agents/terminal-launch";

function request(conversation: TerminalLaunchRequest["conversation"]): TerminalLaunchRequest {
  const scope = createAgentRunScope({ runId: "test", isCurrent: () => true, emit() {} });
  return { tool: "kimi", configured: { command: "kimi", name: "kimi" }, conversation,
    cwd: "/checkout", storeDir: "/store", approvalPolicy: "default", signal: scope.signal, scope };
}

test("Kimi defers provider mutation until dispatch, then resumes only the reported new session", async () => {
  const calls: string[][] = [];
  const launch = await prepareKimiTerminal(request({ kind: "fork", sourceSessionId: "source" }), async args => {
    calls.push(args);
    return args[0] === "session" ? '[{"id":"source"}]' : 'Forked to child ("A title") in 14ms\n';
  });
  expect(calls).toEqual([["session", "list", "--cwd", "/checkout", "--archived", "--json"]]);
  const result = await launch.createNativeFork!();
  expect(calls[1]).toEqual(["fork", "--yes", "source"]);
  expect(result.nativeId).toBe("child");
  expect(result.launch.args).toContain("child");
  expect(result.launch.args).not.toContain("source");
  expect(result.launch.resumed).toBe(true);
  expect(result.launch.createNativeFork).toBeUndefined();
});

test("Kimi starts fresh, with no provider mutation, when the conversation is not in its store for this directory", async () => {
  for (const conversation of [{ kind: "fork", sourceSessionId: "source" }, { kind: "resume", sessionId: "source" }] as const) {
    let calls = 0;
    const launch = await prepareKimiTerminal(request(conversation), async () => { calls++; return '[]'; });
    expect(calls).toBe(1);
    expect(launch.resumed).toBe(false);
    expect(launch.createNativeFork).toBeUndefined();
    expect(launch.args).not.toContain("--session");
    expect(launch.args).not.toContain("source");
  }
});

test("Kimi rejects missing, ambiguous, and source fork identities", () => {
  expect(parseKimiForkId("Forked to ses-child in 1ms\r\n", "source")).toBe("ses-child");
  for (const output of ["Fork cancelled.", "Forked to source in 1ms\n", "Forked to one in 1ms\nForked to two in 2ms\n", "Forked to --bad in 1ms\n"]) {
    expect(() => parseKimiForkId(output, "source")).toThrow("independent fork ID");
  }
});

test("Kimi preserves approval bypass on the resumed fork and refuses opening prompts", async () => {
  const req = { ...request({ kind: "fork", sourceSessionId: "source" }), approvalPolicy: "bypass" as const };
  const launch = await prepareKimiTerminal(req, async args => args[0] === "session" ? '[{"id":"source"}]' : "Forked to child in 1ms\n");
  expect((await launch.createNativeFork!()).launch.args).toEqual(["--auto", "--session", "child"]);
  await expect(prepareKimiTerminal({ ...req, initialPrompt: "hello" }, async () => { throw new Error("must not execute"); })).rejects.toThrow("after the Kimi fork");
});

test.skipIf(process.platform !== "win32")("Kimi's session lookup reaches an npm .cmd install verbatim, whatever the workspace path holds", async () => {
  const root = mkdtempSync(join(tmpdir(), "kimi-npm-"));
  const logger: AgentLogger = { child: () => logger, debug() {}, info() {}, warn() {}, error() {} };
  const host: AgentHostServices = { logger, stateDirectory: () => root, hookCommand: () => ({ binary: "bridge", preargs: [] }),
    killChildTree: async () => {}, stripInheritedCertOverrides: (env) => env };
  try {
    const bin = join(root, "npm bin");
    mkdirSync(bin);
    const record = join(root, "argv.json");
    writeFileSync(join(bin, "kimi.js"), `require("fs").writeFileSync(${JSON.stringify(record)}, JSON.stringify(process.argv.slice(2))); process.stdout.write('[{"id":"source"}]');`);
    // npm's shim shape: interpreter, script, then `%*`, which cmd parses a second time.
    writeFileSync(join(bin, "kimi.cmd"), `@"${process.execPath}" "%~dp0kimi.js" %*\r\n`);
    for (const name of ["R&D", "x %USERNAME% !y! (1)"]) {
      const cwd = join(root, name);
      mkdirSync(cwd);
      const scope = createAgentRunScope({ runId: "test", isCurrent: () => true, emit() {} });
      const launch = await withAgentHost(host, () => prepareKimiTerminal({
        configured: { command: join(bin, "kimi.cmd"), name: "kimi" }, conversation: { kind: "resume", sessionId: "source" },
        cwd, storeDir: root, approvalPolicy: "default", adapterOptions: { kimiHome: join(root, "kimi-home") }, signal: scope.signal, scope,
      }));
      expect(JSON.parse(readFileSync(record, "utf8"))).toEqual(["session", "list", "--cwd", cwd, "--archived", "--json"]);
      expect(launch.resumed).toBe(true);
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}, 30_000);
