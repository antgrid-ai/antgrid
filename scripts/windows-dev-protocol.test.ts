import { afterAll, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

const repoRoot = resolve(import.meta.dir, "..");
const scriptPath = resolve(import.meta.dir, "windows-dev-protocol.ps1");
const tempRoot = mkdtempSync(join(tmpdir(), "antgrid protocol test "));
const testOnWindows = process.platform === "win32" ? test : test.skip;
let protocolSequence = 0;

type CommandResult = {
  status: number | null;
  stdout: string;
  stderr: string;
};

type Registration = {
  description: string;
  hasUrlProtocol: boolean;
  urlProtocol: string;
  command: string;
};

afterAll(() => {
  rmSync(tempRoot, { recursive: true, force: true });
});

function nextProtocol(): string {
  protocolSequence += 1;
  return `antgrid-test-${process.pid}-${protocolSequence}`;
}

function protocolKey(protocol: string): string {
  return `Registry::HKEY_CURRENT_USER\\Software\\Classes\\${protocol}`;
}

function executablePath(name: string, create = true): string {
  const path = join(tempRoot, name, "antgrid.exe");
  if (create) {
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, "test executable");
  }
  return path;
}

function runScript(
  action: "Add" | "Remove",
  protocol: string,
  executable: string,
): CommandResult {
  const result = spawnSync(
    "powershell.exe",
    [
      "-NoProfile",
      "-NonInteractive",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      scriptPath,
      "-Action",
      action,
      "-Protocol",
      protocol,
      "-ExecutablePath",
      executable,
    ],
    { encoding: "utf8" },
  );

  return {
    status: result.status,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
  };
}

function runPowerShell(command: string, env: Record<string, string>): CommandResult {
  const result = spawnSync(
    "powershell.exe",
    ["-NoProfile", "-NonInteractive", "-Command", command],
    { encoding: "utf8", env: { ...process.env, ...env } },
  );

  return {
    status: result.status,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
  };
}

function expectSuccess(result: CommandResult): void {
  if (result.status !== 0) {
    throw new Error(
      `Command failed with exit ${result.status}:\n${result.stdout}\n${result.stderr}`,
    );
  }
}

function readRegistration(protocol: string): Registration {
  const result = runPowerShell(
    `
$root = Get-Item -LiteralPath $env:TEST_PROTOCOL_KEY
$command = Get-Item -LiteralPath "$($env:TEST_PROTOCOL_KEY)\\shell\\open\\command"
[pscustomobject]@{
  description = [string]$root.GetValue('')
  hasUrlProtocol = $root.GetValueNames() -contains 'URL Protocol'
  urlProtocol = [string]$root.GetValue('URL Protocol')
  command = [string]$command.GetValue('')
} | ConvertTo-Json -Compress
`,
    { TEST_PROTOCOL_KEY: protocolKey(protocol) },
  );
  expectSuccess(result);
  return JSON.parse(result.stdout.trim()) as Registration;
}

function registrationExists(protocol: string): boolean {
  const result = runPowerShell(
    "if (Test-Path -LiteralPath $env:TEST_PROTOCOL_KEY) { exit 0 } else { exit 3 }",
    { TEST_PROTOCOL_KEY: protocolKey(protocol) },
  );
  return result.status === 0;
}

function cleanupRegistration(protocol: string): void {
  runPowerShell(
    "Remove-Item -LiteralPath $env:TEST_PROTOCOL_KEY -Recurse -Force -ErrorAction SilentlyContinue",
    { TEST_PROTOCOL_KEY: protocolKey(protocol) },
  );
}

test("package exposes add, remove, and focused test commands", () => {
  const packageJson = JSON.parse(
    readFileSync(resolve(repoRoot, "package.json"), "utf8"),
  ) as { scripts: Record<string, string> };

  expect(packageJson.scripts["dev:protocol:add"]).toBe(
    "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File scripts/windows-dev-protocol.ps1 -Action Add",
  );
  expect(packageJson.scripts["dev:protocol:remove"]).toBe(
    "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File scripts/windows-dev-protocol.ps1 -Action Remove",
  );
  expect(packageJson.scripts["test:dev-protocol"]).toBe(
    "cd scripts && bun test windows-dev-protocol.test.ts",
  );
});

testOnWindows("add writes the protocol values and is idempotent", () => {
  const protocol = nextProtocol();
  const executable = executablePath("idempotent app");

  try {
    expectSuccess(runScript("Add", protocol, executable));
    expectSuccess(runScript("Add", protocol, executable));

    expect(readRegistration(protocol)).toEqual({
      description: "URL:Antgrid Protocol",
      hasUrlProtocol: true,
      urlProtocol: "",
      command: `"${executable}" "%1"`,
    });
  } finally {
    cleanupRegistration(protocol);
  }
});

testOnWindows("add registers a missing executable path with a warning", () => {
  const protocol = nextProtocol();
  const executable = executablePath("missing app", false);

  try {
    const result = runScript("Add", protocol, executable);
    expectSuccess(result);
    expect(`${result.stdout}\n${result.stderr}`).toContain("does not exist yet");
    expect(readRegistration(protocol).command).toBe(`"${executable}" "%1"`);
  } finally {
    cleanupRegistration(protocol);
  }
});

testOnWindows("remove refuses a handler owned by another executable", () => {
  const protocol = nextProtocol();
  const expectedExecutable = executablePath("expected owner");
  const otherExecutable = executablePath("other owner");

  try {
    expectSuccess(runScript("Add", protocol, otherExecutable));

    const result = runScript("Remove", protocol, expectedExecutable);
    expect(result.status).not.toBe(0);
    expect(`${result.stdout}\n${result.stderr}`).toContain("Refusing to remove");
    expect(readRegistration(protocol).command).toBe(
      `"${otherExecutable}" "%1"`,
    );
  } finally {
    cleanupRegistration(protocol);
  }
});

testOnWindows("remove deletes a handler owned by the expected executable", () => {
  const protocol = nextProtocol();
  const executable = executablePath("owned handler");

  try {
    expectSuccess(runScript("Add", protocol, executable));
    expect(registrationExists(protocol)).toBe(true);
    expectSuccess(runScript("Remove", protocol, executable));
    expect(registrationExists(protocol)).toBe(false);
  } finally {
    cleanupRegistration(protocol);
  }
});

testOnWindows("remove treats an absent handler as success", () => {
  const protocol = nextProtocol();
  const executable = executablePath("absent handler");

  try {
    const result = runScript("Remove", protocol, executable);
    expectSuccess(result);
    expect(`${result.stdout}\n${result.stderr}`).toContain("is not registered");
  } finally {
    cleanupRegistration(protocol);
  }
});
