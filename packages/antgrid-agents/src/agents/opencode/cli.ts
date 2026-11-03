import { resolveToolLaunchPath } from "../launch-path";
import { cmdProgramToken, escapeCmdArg, WINDOWS_CMD_CARRIER_ARGS, WINDOWS_CMDLINE_ENV } from "../windows-argv";

export function opencodeSpawnArgs(command: string, args: string[], env: Record<string, string | undefined>) {
  const program = resolveToolLaunchPath(command, env.PATH ?? env.Path);
  if (process.platform !== "win32" || !/\.(cmd|bat)$/i.test(program)) return { cmd: [program, ...args], env };
  return {
    cmd: [env.ComSpec ?? "cmd.exe", ...WINDOWS_CMD_CARRIER_ARGS],
    env: { ...env, [WINDOWS_CMDLINE_ENV]: [cmdProgramToken(program), ...args.map((arg) => escapeCmdArg(arg, true))].join(" ") },
  };
}
