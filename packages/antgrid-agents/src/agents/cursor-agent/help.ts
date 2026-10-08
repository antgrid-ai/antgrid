import { spawnSync } from "node:child_process";
import { logger } from "../../host";

const log = logger.child({ component: "agent-launch" });

// One `--help` read per process serves every flag check: cursor-agent builds
// predating a flag hard-exit on the unknown option (commander), which would
// kill every spawn on that machine. An inconclusive probe (binary not on PATH,
// empty/failed --help) counts as support: current builds have the flags, and a
// missing binary fails the spawn regardless of argv.
let helpText: string | null | undefined;
function readHelp(): string | null {
  if (helpText !== undefined) return helpText;
  helpText = null;
  try {
    const bin = Bun.which("cursor-agent");
    if (bin) {
      const res = spawnSync(bin, ["--help"], { timeout: 3000, encoding: "utf8" });
      const help = `${res.stdout ?? ""}\n${res.stderr ?? ""}`;
      if (help.trim().length > 0) helpText = help;
    }
  } catch (err) {
    log.warn("cursor-agent --help probe failed, assuming flag support: %s", err);
  }
  return helpText;
}

/** Test seam: a string stands in for `--help`, `null` for an inconclusive probe, `undefined` re-arms the real read. */
export function overrideCursorHelp(text: string | null | undefined): void {
  helpText = text;
}

export function cursorSupportsFlag(flag: string): boolean {
  const help = readHelp();
  return help === null ? true : help.includes(flag);
}
