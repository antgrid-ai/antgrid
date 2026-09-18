// `antgrid log-level` — raise the RUNNING host's verbosity for a bounded window,
// over the same loopback plane `antgrid watch` uses (host.json's port + bearer).
//
// Unlike a watcher, this CLI does NOT stay up to heartbeat the arm: nobody holds
// a terminal open for the length of a debugging session. The TTL is therefore
// the only thing that disarms on its own, which is why the host refuses an arm
// without one.

import { readHostFile, hostFilePath } from "../host-discovery";
import { postControl } from "./watch-transport";

/** Levels the host's own `log:level` schema admits. Kept as a literal list so a
 *  typo answers here, with the vocabulary printed, instead of as a BAD_REQUEST
 *  from a schema the caller cannot read. */
const LEVELS = ["trace", "debug", "info", "warn", "error", "fatal"] as const;

/** Default window. Long enough to reproduce a delivery by hand on two machines,
 *  short enough that an operator who walks away leaves nothing recording. */
const DEFAULT_LOG_LEVEL_TTL_MS = 600_000;

export interface LogLevelCliOptions {
  /** The level to run at. Absent is the disarm — there is nothing to raise, so
   *  the host goes back to the level it was configured with. */
  level?: string;
  /** Window in milliseconds. Zero restores the configured level immediately.
   *  Ignored when no level is named, which is already a disarm. */
  ttlMs?: number;
  /** ANTGRID_DIR override — a debug-build app runs under ~/.antgrid-dev. */
  dir?: string;
}

export async function runLogLevelCli(opts: LogLevelCliOptions): Promise<number> {
  // Naming no level is the disarm. The level still has to be spelled on the
  // wire because the verb's schema requires one; the host ignores it on a zero
  // window and answers with the level it restored.
  const disarm = opts.level === undefined;
  const level = opts.level ?? "info";
  if (!LEVELS.includes(level as (typeof LEVELS)[number])) {
    console.error(`antgrid log-level: unknown level "${level}"; use ${LEVELS.join(", ")}.`);
    return 1;
  }
  if (opts.dir) process.env.ANTGRID_DIR = opts.dir;

  const path = hostFilePath();
  const host = readHostFile(path);
  if (!host) {
    console.error(`antgrid log-level: no running host found (looked in ${path}).`);
    console.error("Start the app or the bridge first. A debug-build app runs under");
    console.error("~/.antgrid-dev — point at it with --dir or ANTGRID_DIR.");
    return 1;
  }

  const ttlMs = disarm ? 0 : (opts.ttlMs ?? DEFAULT_LOG_LEVEL_TTL_MS);
  const { error, reply } = await postControl(host, { type: "log:level", level, ttlMs }, "log-level");
  if (error) {
    console.error(`antgrid log-level: ${error}`);
    return 1;
  }
  // The host's answer, not the request: it clamps the window, and a disarm
  // reports the level it restored rather than the one that was named.
  const armed = typeof reply?.ttlMs === "number" ? reply.ttlMs : 0;
  const now = typeof reply?.level === "string" ? reply.level : level;
  console.log(
    armed > 0
      ? `host is logging at "${now}" for ${Math.round(armed / 1000)}s, then back to its configured level`
      : `host is back at its configured level ("${now}")`,
  );
  return 0;
}
