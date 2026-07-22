import { homedir } from "node:os";
import { join } from "node:path";

/** Returns the Antgrid home directory (respects ANTGRID_DIR env override). */
export function resolveAbDir(): string {
  return process.env.ANTGRID_DIR ?? join(homedir(), ".antgrid");
}
