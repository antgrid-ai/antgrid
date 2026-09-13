import { describe, expect, it } from "bun:test";
import { resolveTerminalInvocation } from "../src/terminal-invocation";

function host(platform: NodeJS.Platform) {
  return {
    platform, shell: platform === "win32" ? "cmd.exe" : "/bin/sh",
    resolveWindowsExecutable: () => null,
    requiresWindowsShell: () => false,
  };
}

describe("explicit terminal invocation", () => {
  it("executes a path with spaces and no arguments without treating it as shell text", () => {
    for (const platform of ["win32", "linux", "darwin"] as const) {
      const command = platform === "win32" ? "C:\\Program Files\\Agent\\agent.exe" : "/opt/My Agent/agent";
      expect(resolveTerminalInvocation({ command, args: [], invocationKind: "exec" }, host(platform)))
        .toEqual({ command, args: [] });
    }
  });

  it("preserves discrete arguments including multiline prompts for executables and Windows shims", () => {
    const args = ["--prompt", "first line\nsecond \"quoted\" line"];
    expect(resolveTerminalInvocation({ command: "C:\\Agent Tools\\agent.exe", args, invocationKind: "exec" }, host("win32")))
      .toEqual({ command: "C:\\Agent Tools\\agent.exe", args });
    expect(resolveTerminalInvocation({ command: "C:\\Agent Tools\\agent.cmd", args, invocationKind: "exec" }, host("win32")))
      .toEqual({ command: "cmd.exe", args: ["/d", "/s", "/c", "C:\\Agent Tools\\agent.cmd", ...args] });
  });

  it("keeps a rendered Windows shell line separate from its multiline prompt arguments", () => {
    const command = "agent --global value resume session";
    const args = ["--", "first\nsecond"];
    expect(resolveTerminalInvocation({ command, args, invocationKind: "shell" }, host("win32")))
      .toEqual({ command: "cmd.exe", args: ["/d", "/s", "/c", command, ...args] });
  });

  it("honors shell intent without whitespace and retains legacy non-agent command inference", () => {
    expect(resolveTerminalInvocation({ command: "a|b", args: [], invocationKind: "shell" }, host("linux")))
      .toEqual({ command: "/bin/sh", args: ["-c", "a|b"] });
    expect(resolveTerminalInvocation({ command: "npm run serve", args: [] }, host("linux")))
      .toEqual({ command: "/bin/sh", args: ["-c", "npm run serve"] });
  });
});
