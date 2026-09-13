import { homedir } from "node:os";
import { join } from "node:path";

/** Returns the Antgrid home directory (respects ANTGRID_DIR env override). */
export function resolveAbDir(): string {
  return process.env.ANTGRID_DIR ?? join(homedir(), ".antgrid");
}

/** Path to the one machine-wide terminal-history database (D3, see
 *  `terminal-frames/history.ts`) — bridge-managed, opened only from
 *  `terminal-manager.ts`, and never accepted from a client. Directory and
 *  file permissions are set at the open site, since this file only resolves
 *  the path. */
export function resolveTerminalHistoryPath(): string {
  return join(resolveAbDir(), "terminal-history.sqlite");
}
