// Dependency-free on purpose: the memory-mcp subprocess imports this and must
// stay small to start.

type Env = Record<string, string | undefined>;

/** Strict decimal 1-65535, so a `${ANTGRID_API_PORT}` an agent never expanded reads as absent. */
export function parsePort(raw: string | undefined): number | null {
  if (!raw || !/^\d+$/.test(raw.trim())) return null;
  const value = Number(raw.trim());
  return Number.isInteger(value) && value >= 1 && value <= 65535 ? value : null;
}

/** A trimmed value, or undefined when unset or an unexpanded `${…}` reference that names nothing. */
export function readSessionValue(env: Env, name: string): string | undefined {
  const value = env[name]?.trim();
  return !value || value.startsWith("${") ? undefined : value;
}

export const readApiPort = (env: Env = process.env): number | null => parsePort(env.ANTGRID_API_PORT);
export const readTerminalId = (env: Env = process.env): string | undefined => readSessionValue(env, "ANTGRID_TERMINAL_ID");
export const readRunId = (env: Env = process.env): string | undefined => readSessionValue(env, "ANTGRID_RUN_ID");
