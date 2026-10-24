import { describe, expect, it } from "bun:test";
import {
  resolveTerminalInvocation, WindowsShellLimitError, windowsShellLimit,
  type TerminalInvocationHost,
} from "../src/terminal-invocation";

function host(platform: NodeJS.Platform, over: Partial<TerminalInvocationHost> = {}): TerminalInvocationHost {
  return {
    platform, shell: platform === "win32" ? "cmd.exe" : "/bin/sh",
    env: {},
    resolveWindowsExecutable: () => null,
    requiresWindowsShell: () => false,
    ...over,
  };
}

// `/v:off` overrides a registry DelayedExpansion=1, whose `!` pass would undo the caret escaping.
const VIA_ENV = ["/d", "/v:off", "/s", "/c", "set", "ANTGRID_CMDLINE=&", "%ANTGRID_CMDLINE%"];

describe("explicit terminal invocation", () => {
  it("executes a path with spaces and no arguments without treating it as shell text", () => {
    for (const platform of ["win32", "linux", "darwin"] as const) {
      const command = platform === "win32" ? "C:\\Program Files\\Agent\\agent.exe" : "/opt/My Agent/agent";
      expect(resolveTerminalInvocation({ command, args: [], invocationKind: "exec" }, host(platform)))
        .toEqual({ command, args: [] });
    }
  });

  it("keeps an executable direct and refuses a newline that a Windows shim cannot carry", () => {
    const args = ["--prompt", "first line\nsecond \"quoted\" line"];
    expect(resolveTerminalInvocation({ command: "C:\\Agent Tools\\agent.exe", args, invocationKind: "exec" }, host("win32")))
      .toEqual({ command: "C:\\Agent Tools\\agent.exe", args });
    const shim = { command: "C:\\Agent Tools\\agent.cmd", args, invocationKind: "exec" as const };
    expect(windowsShellLimit(shim, host("win32"))).toBe("newline");
    let error: unknown;
    try {
      resolveTerminalInvocation(shim, host("win32"));
    } catch (e) {
      error = e;
    }
    expect(error).toBeInstanceOf(WindowsShellLimitError);
    expect((error as WindowsShellLimitError).reason).toBe("newline");
    expect((error as Error).message).not.toContain("second");
  });

  it("refuses a multiline argument behind a Windows shell line", () => {
    const inv = { command: "agent --global value resume session", args: ["--", "first\nsecond"], invocationKind: "shell" as const };
    expect(() => resolveTerminalInvocation(inv, host("win32"))).toThrow(WindowsShellLimitError);
    expect(windowsShellLimit(inv, host("win32"))).toBe("newline");
  });

  it("honors shell intent without whitespace and retains legacy non-agent command inference", () => {
    expect(resolveTerminalInvocation({ command: "a|b", args: [], invocationKind: "shell" }, host("linux")))
      .toEqual({ command: "/bin/sh", args: ["-c", "a|b"] });
    expect(resolveTerminalInvocation({ command: "npm run serve", args: [] }, host("linux")))
      .toEqual({ command: "/bin/sh", args: ["-c", "npm run serve"] });
    expect(resolveTerminalInvocation({ command: "npm run serve", args: ["--", "a\nb"], invocationKind: "shell" }, host("darwin")))
      .toEqual({ command: "/bin/sh", args: ["-c", "npm run serve", "--", "a\nb"] });
    expect(windowsShellLimit({ command: "x", args: ["a\nb"], invocationKind: "exec" }, host("linux"))).toBeUndefined();
  });
});

describe("Windows cmd.exe launch line", () => {
  it("double-escapes tricky arguments for a batch shim and passes the line through the environment", () => {
    const args = ["a b", "it's 5\" & echo INJECTED & rem", "hi %USERNAME% 100%", "bang! x", "C:\\trail\\", "", "q\\\"x"];
    const r = resolveTerminalInvocation({ command: "C:\\sp ace\\agent.cmd", args, invocationKind: "exec" }, host("win32"));
    expect(r.command).toBe("cmd.exe");
    expect(r.args).toEqual(VIA_ENV);
    expect(r.env).toEqual({
      ANTGRID_CMDLINE:
        "\"C:\\sp ace\\agent.cmd\""
        + " ^^^\"a^^^ b^^^\""
        + " ^^^\"it's^^^ 5\\^^^\"^^^ ^^^&^^^ echo^^^ INJECTED^^^ ^^^&^^^ rem^^^\""
        + " ^^^\"hi^^^ ^^^%USERNAME^^^%^^^ 100^^^%^^^\""
        + " ^^^\"bang^^^!^^^ x^^^\""
        + " ^^^\"C:\\trail\\\\^^^\""
        + " ^^^\"^^^\""
        + " ^^^\"q\\\\\\^^^\"x^^^\"",
    });
  });

  it("escapes once for a real executable that requiresWindowsShell", () => {
    const r = resolveTerminalInvocation(
      { command: "agy", args: ["a b", "x&y"], invocationKind: "exec" },
      host("win32", {
        requiresWindowsShell: () => true,
        resolveWindowsExecutable: () => ({ path: "C:\\bin\\agy.exe", ext: ".exe" }),
      }),
    );
    expect(r.args).toEqual(VIA_ENV);
    expect(r.env).toEqual({ ANTGRID_CMDLINE: "agy ^\"a^ b^\" ^\"x^&y^\"" });
  });

  // Unquoted on purpose: a PATH-found batch file invoked under a quoted bare
  // name gets the working directory as its %~dp0, which breaks npm shims.
  it("routes a bare name that resolves to a shim through cmd, unquoted, and keeps a real exe direct", () => {
    const shim = host("win32", { resolveWindowsExecutable: () => ({ path: "C:\\n\\opencode.cmd", ext: ".cmd" }) });
    expect(resolveTerminalInvocation({ command: "opencode", args: ["x"], invocationKind: "exec" }, shim).env)
      .toEqual({ ANTGRID_CMDLINE: "opencode ^^^\"x^^^\"" });
    const exe = host("win32", { resolveWindowsExecutable: () => ({ path: "C:\\n\\tool.exe", ext: ".exe" }) });
    expect(resolveTerminalInvocation({ command: "tool", args: ["x"], invocationKind: "exec" }, exe))
      .toEqual({ command: "C:\\n\\tool.exe", args: ["x"] });
  });

  it("passes a shell line through verbatim and pre-expands defined %NAME% references only", () => {
    const r = resolveTerminalInvocation(
      { command: "probe --flag \"a b\" --x %Foo% %NOPE%", args: [], invocationKind: "shell" },
      host("win32", { env: { FOO: "bar", UNSET: undefined } }),
    );
    expect(r.args).toEqual(VIA_ENV);
    expect(r.env).toEqual({ ANTGRID_CMDLINE: "probe --flag \"a b\" --x bar %NOPE%" });
  });

  it("double-escapes trailing arguments after a shell line whose program is a batch file", () => {
    const r = resolveTerminalInvocation(
      { command: "\"C:\\sp ace\\my.cmd\" run", args: ["a b"], invocationKind: "shell" },
      host("win32"),
    );
    expect(r.env).toEqual({ ANTGRID_CMDLINE: "\"C:\\sp ace\\my.cmd\" run ^^^\"a^^^ b^^^\"" });
    const exe = resolveTerminalInvocation(
      { command: "C:\\bin\\my.exe run", args: ["a b"], invocationKind: "shell" },
      host("win32"),
    );
    expect(exe.env).toEqual({ ANTGRID_CMDLINE: "C:\\bin\\my.exe run ^\"a^ b^\"" });
  });

  it("refuses a line cmd.exe would reject as too long", () => {
    const inv = { command: "C:\\a\\agent.exe", args: ["x".repeat(9000)], invocationKind: "exec" as const };
    expect(resolveTerminalInvocation(inv, host("win32"))).toEqual({ command: inv.command, args: inv.args });
    const shim = { ...inv, command: "C:\\a\\agent.cmd" };
    expect(windowsShellLimit(shim, host("win32"))).toBe("length");
    expect(() => resolveTerminalInvocation(shim, host("win32"))).toThrow(WindowsShellLimitError);
    expect(windowsShellLimit({ ...shim, args: ["ok"] }, host("win32"))).toBeUndefined();
  });

  it("counts the carrier's own prefix and leaves room for a batch shim to re-expand %*", () => {
    const exeViaCmd = host("win32", {
      requiresWindowsShell: () => true,
      resolveWindowsExecutable: () => ({ path: "C:\\bin\\agy.exe", ext: ".exe" }),
    });
    // `agy ^"<n x's>^"` is n + 8 characters, and cmd also parses `set ANTGRID_CMDLINE=& ` (22) in front of it.
    const line = (length: number) => ({ command: "agy", args: ["x".repeat(length - 8)], invocationKind: "exec" as const });
    expect(windowsShellLimit(line(8191 - 22), exeViaCmd)).toBeUndefined();
    expect(windowsShellLimit(line(8191 - 21), exeViaCmd)).toBe("length");
    expect(windowsShellLimit(line(8191), exeViaCmd)).toBe("length");
    const shim = { command: "C:\\n\\kilo.cmd", args: ["--prompt", "x".repeat(7500)], invocationKind: "exec" as const };
    expect(windowsShellLimit(shim, host("win32"))).toBe("length");
    expect(() => resolveTerminalInvocation(shim, host("win32"))).toThrow(WindowsShellLimitError);
  });

  it("drops the newline a YAML block scalar leaves at the end of a shell line, and still refuses one inside it", () => {
    expect(resolveTerminalInvocation({ command: "npm run dev\n", args: [] }, host("win32")))
      .toEqual({ command: "cmd.exe", args: VIA_ENV, env: { ANTGRID_CMDLINE: "npm run dev" }, cmdLine: "npm run dev" });
    expect(windowsShellLimit({ command: "npm run dev\r\n\n", args: [] }, host("win32"))).toBeUndefined();
    const twoLines = { command: "npm install\nnpm run dev\n", args: [] };
    expect(windowsShellLimit(twoLines, host("win32"))).toBe("newline");
    expect(() => resolveTerminalInvocation(twoLines, host("win32"))).toThrow(WindowsShellLimitError);
  });

  it("refuses a NUL on every Windows route, since the carried line would end there and the rest become environment entries", () => {
    const prompt = "fix it\0NODE_OPTIONS=--require=C:/x/evil.js\0";
    const routes = [
      { command: "C:\\a\\agent.cmd", args: ["--prompt", prompt], invocationKind: "exec" as const },
      { command: "agent --global", args: ["--prompt", prompt], invocationKind: "shell" as const },
      { command: "C:\\a\\agent.exe", args: ["--prompt", prompt], invocationKind: "exec" as const },
    ];
    for (const inv of routes) {
      expect(windowsShellLimit(inv, host("win32"))).toBe("nul");
      expect(() => resolveTerminalInvocation(inv, host("win32"))).toThrow(WindowsShellLimitError);
    }
    try {
      resolveTerminalInvocation(routes[0]!, host("win32"));
    } catch (e) {
      expect((e as WindowsShellLimitError).reason).toBe("nul");
      expect((e as Error).message).not.toContain("NODE_OPTIONS");
    }
  });

  it("runs a configured command line that has arguments as a shell line, expanding %NAME% first", () => {
    const npm = host("win32", {
      resolveWindowsExecutable: (command) => command === "npm" ? { path: "C:\\n\\npm.cmd", ext: ".cmd" } : null,
    });
    expect(resolveTerminalInvocation({ command: "npm run dev", args: ["--", "--port", "3000"] }, npm).env)
      .toEqual({ ANTGRID_CMDLINE: "npm run dev ^^^\"--^^^\" ^^^\"--port^^^\" ^^^\"3000^^^\"" });
    expect(resolveTerminalInvocation({ command: "npx claude", args: ["--verbose"], invocationKind: "exec" }, npm).env)
      .toEqual({ ANTGRID_CMDLINE: "npx claude ^^^\"--verbose^^^\"" });
    const appData = host("win32", { env: { APPDATA: "C:\\Users\\A B\\AppData\\Roaming", TOOLS: "C:\\t" } });
    expect(resolveTerminalInvocation({ command: "%APPDATA%\\npm\\pnpm.cmd", args: ["dev"] }, appData).env)
      .toEqual({ ANTGRID_CMDLINE: "\"C:\\Users\\A B\\AppData\\Roaming\\npm\\pnpm.cmd\" ^^^\"dev^^^\"" });
    expect(resolveTerminalInvocation({ command: "%TOOLS%\\agent.exe", args: ["x"], invocationKind: "exec" }, appData))
      .toEqual({ command: "C:\\t\\agent.exe", args: ["x"] });
  });

  it("refuses a direct launch whose command line CreateProcess cannot hold", () => {
    const inv = { command: "C:\\a\\kilo.exe", args: ["--prompt", "x".repeat(32_800)], invocationKind: "exec" as const };
    expect(windowsShellLimit(inv, host("win32"))).toBe("length");
    expect(() => resolveTerminalInvocation(inv, host("win32"))).toThrow(WindowsShellLimitError);
    const fits = { ...inv, args: ["--prompt", "x".repeat(20_000)] };
    expect(windowsShellLimit(fits, host("win32"))).toBeUndefined();
    expect(resolveTerminalInvocation(fits, host("win32"))).toEqual({ command: fits.command, args: fits.args });
    expect(windowsShellLimit({ ...inv, invocationKind: "exec" }, host("linux"))).toBeUndefined();
  });
});
