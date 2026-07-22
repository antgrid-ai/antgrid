import { describe, expect, test } from "bun:test";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  hookArgv,
  hookShellCommand,
  resolveHookCommand,
} from "../src/hook-command";

describe("resolveHookCommand", () => {
  test("packaged bridge invokes its own hook subcommand", () => {
    expect(
      resolveHookCommand({
        compiled: true,
        binary: "/Applications/Antgrid App/antgrid-bridge",
        entrypoint: "/repo/bridge/src/index.ts",
      }),
    ).toEqual({
      binary: "/Applications/Antgrid App/antgrid-bridge",
      preargs: ["hook"],
    });
  });

  test("development bridge re-enters the source entrypoint through Bun", () => {
    expect(
      resolveHookCommand({
        compiled: false,
        binary: "C:\\Users\\O'Brien\\.bun\\bin\\bun.exe",
        entrypoint: "C:\\repo path\\bridge\\src\\index.ts",
      }),
    ).toEqual({
      binary: "C:\\Users\\O'Brien\\.bun\\bin\\bun.exe",
      preargs: ["C:\\repo path\\bridge\\src\\index.ts", "hook"],
    });
  });
});

test("hookArgv appends the agent and event", () => {
  const command = { binary: "/opt/antgrid bridge", preargs: ["hook"] };
  expect(hookArgv(command, "claude", "stop")).toEqual([
    "/opt/antgrid bridge",
    "hook",
    "claude",
    "stop",
  ]);
});

describe("hookShellCommand", () => {
  test("quotes POSIX apostrophes and spaces", () => {
    const command = {
      binary: "/Users/O'Brien/Antgrid App/antgrid-bridge",
      preargs: ["hook"],
    };
    expect(hookShellCommand(command, "codex", "stop", { platform: "linux" })).toBe(
      "'/Users/O'\"'\"'Brien/Antgrid App/antgrid-bridge' 'hook' 'codex' 'stop'",
    );
  });

  test("forward-slashes and quotes Windows command arguments", () => {
    const command = {
      binary: "C:\\Program Files\\Antgrid\\antgrid-bridge.exe",
      preargs: ["hook"],
    };
    const rendered = hookShellCommand(command, "codex", "stop", { platform: "win32" });
    expect(rendered).toBe(
      '& "C:/Program Files/Antgrid/antgrid-bridge.exe" "hook" "codex" "stop"',
    );
    expect(rendered).not.toContain("\\");
  });

  test("omits the call operator for a consumer that supplies its own", () => {
    const command = {
      binary: "C:\\Program Files\\Antgrid\\antgrid-bridge.exe",
      preargs: ["hook"],
    };
    expect(
      hookShellCommand(command, "cursor", "stop", {
        platform: "win32",
        callOperator: false,
      }),
    ).toBe('"C:/Program Files/Antgrid/antgrid-bridge.exe" "hook" "cursor" "stop"');
  });

  test("never emits the call operator on POSIX, where it is a syntax error", () => {
    const command = { binary: "/opt/antgrid bridge", preargs: ["hook"] };
    for (const platform of ["linux", "darwin"] as const) {
      expect(
        hookShellCommand(command, "codex", "stop", { platform }),
      ).not.toContain("&");
    }
  });
});

// A string-shape assertion cannot catch the defect this guards: the rendered
// command was well-formed and still never executed. Only running it through the
// shell the agent actually uses proves the program is reached, so this spawns
// PowerShell for real against a binary path containing a space.
describe.if(process.platform === "win32")("hookShellCommand round-trip", () => {
  test("the Windows form actually invokes the program under PowerShell", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-hookcmd-"));
    try {
      // Mirror the default install location: a path with a space in it.
      const progDir = join(dir, "Program Files", "Antgrid");
      mkdirSync(progDir, { recursive: true });
      const marker = join(dir, "ran.txt");
      const script = join(progDir, "marker.ts");
      writeFileSync(
        script,
        `await Bun.write(${JSON.stringify(marker)}, process.argv.slice(2).join("|"));\n`,
      );

      const rendered = hookShellCommand(
        { binary: process.execPath, preargs: [script] },
        "codex",
        "stop",
        { platform: "win32" },
      );

      // How codex runs a hook on Windows: it resolves the hook shell from the
      // detected user shell, which is hard-coded to PowerShell on Windows.
      const proc = Bun.spawn(
        ["powershell.exe", "-NoProfile", "-Command", rendered],
        { stdout: "pipe", stderr: "pipe" },
      );
      const code = await proc.exited;
      const stderr = await new Response(proc.stderr).text();

      expect(stderr).toBe("");
      expect(code).toBe(0);
      expect(readFileSync(marker, "utf8")).toBe("codex|stop");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
