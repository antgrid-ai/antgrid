export interface TerminalInvocation {
  command: string;
  args: string[];
  invocationKind?: "exec" | "shell";
}

export function resolveTerminalInvocation(
  invocation: TerminalInvocation,
  host: {
    platform: NodeJS.Platform;
    shell: string;
    resolveWindowsExecutable(command: string): { path: string; ext: string } | null;
    requiresWindowsShell(command: string): boolean;
  },
): { command: string; args: string[] } {
  const { command, args, invocationKind } = invocation;
  const shellLine = invocationKind === "shell"
    || (invocationKind === undefined && args.length === 0 && /\s/.test(command));
  let needsShell = shellLine;
  let directCommand = command;
  if (host.platform === "win32" && !shellLine) {
    if (/\.(cmd|bat)$/i.test(command) || host.requiresWindowsShell(command)) {
      needsShell = true;
    } else if (!/\.(exe|com)$/i.test(command) && !command.includes("\\") && !command.includes("/")) {
      const found = host.resolveWindowsExecutable(command);
      if (found && (found.ext === ".exe" || found.ext === ".com")) directCommand = found.path;
      else needsShell = true;
    }
  }
  if (!needsShell) return { command: directCommand, args };
  // bun-pty serializes its argv through shell_words before CreateProcess. A
  // prejoined Windows command would be quoted twice and corrupt embedded quotes.
  return {
    command: host.shell,
    args: host.platform === "win32" ? ["/d", "/s", "/c", command, ...args] : ["-c", command, ...args],
  };
}
