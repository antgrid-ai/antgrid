import { homedir } from "node:os";
import { isAbsolute, join } from "node:path";

/**
 * Mirrors opencode's db-read.ts resolution with Kilo's names: KILO_DB is used
 * as-is when absolute and resolves under the data dir when bare. `:memory:`
 * has no file to read, so it resolves to undefined. Channel-suffixed DBs are
 * out of scope, as for opencode.
 */
export function resolveKiloDbPath(env: NodeJS.ProcessEnv = process.env): string | undefined {
  const dataDir = join(env.XDG_DATA_HOME || join(homedir(), ".local", "share"), "kilo");
  const override = env.KILO_DB;
  if (override === ":memory:") return undefined;
  if (override) return isAbsolute(override) ? override : join(dataDir, override);
  return join(dataDir, "kilo.db");
}
