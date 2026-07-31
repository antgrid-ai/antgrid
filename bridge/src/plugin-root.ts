import { existsSync } from "node:fs";
import { join } from "node:path";

/**
 * The plugin assets bundled alongside the bridge sources (`bridge/plugin/`).
 *
 * Resolved here, from this module's own location, and nowhere else. An
 * `import.meta.dir`-relative join computed inside a per-agent file resolves one
 * directory deeper the moment that file moves, and nothing reports it: the
 * generated config still writes, the agent still launches, it just loads no
 * plugin because none is at the path the config names.
 */
export const PLUGIN_ROOT = join(import.meta.dir, "..", "plugin");

/**
 * Path to a bundled plugin asset, verified present.
 *
 * Throws instead of returning the path, deliberately: a missing bundled asset is
 * a packaging bug on our side, not a user-environment condition. Callers here
 * are all fail-soft (an injection must never abort a spawn), so without this
 * check the only symptom would be an agent that quietly stops naming sessions.
 */
export function bundledPluginPath(...segments: string[]): string {
  const path = join(PLUGIN_ROOT, ...segments);
  if (!existsSync(path)) {
    throw new Error(`bundled plugin asset missing: ${path}`);
  }
  return path;
}
