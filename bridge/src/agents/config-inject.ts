import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { logger } from "../logger";

const log = logger.child({ component: "agent-config-inject" });

/**
 * Builds the launch-env entry pointing `envVar` at a bridge-owned config file.
 * Returns an empty env (no injection) when either the user already set
 * `envVar` themselves — their value flows through unchanged from `process.env`,
 * so we must not clobber it — or the config file can't be written, in which
 * case the agent still launches (just without the notification default).
 */
export function injectConfig(
  envVar: string,
  abDir: string,
  filename: string,
  content: unknown,
): Record<string, string> {
  if (process.env[envVar]) return {};
  const path = ensureJsonConfig(abDir, filename, content);
  return path ? { [envVar]: path } : {};
}

/**
 * Writes (idempotently) a bridge-owned agent config file and returns its path,
 * or null if the write fails (read-only dir, full disk) so the caller can spawn
 * without the env instead of aborting the launch.
 */
function ensureJsonConfig(abDir: string, filename: string, content: unknown): string | null {
  const dir = join(abDir, "agents");
  const path = join(dir, filename);
  try {
    mkdirSync(dir, { recursive: true });
    writeFileSync(path, JSON.stringify(content, null, 2));
    return path;
  } catch (err) {
    log.warn(`failed to write agent config ${path}: ${err}`);
    return null;
  }
}
