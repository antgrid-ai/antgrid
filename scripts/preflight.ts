/**
 * Preflight checks for `dev-setup.ts`, run before `prisma migrate deploy`.
 *
 * Today an absent Postgres surfaces as a generic "Migration failed" only
 * after the command has already committed to migrating — this lets
 * dev-setup print what's missing (and how to fix it) before that point.
 * Scope is deliberately narrow: detection only, no side effects. Offering
 * to start Postgres automatically is a separate, larger piece of #6.
 */
import { spawnSync } from "node:child_process";
import { createConnection } from "node:net";

export type PreflightResult = {
  postgresReachable: boolean;
  containerRuntime: "docker" | "podman" | null;
  flutterFound: boolean;
};

/** True if `cmd --version` runs at all, regardless of exit code or output. */
export function hasCommand(cmd: string): boolean {
  const result = spawnSync(cmd, ["--version"], { stdio: "ignore" });
  return result.error === undefined;
}

/**
 * TCP-level reachability only — this is "is anything listening", not "can
 * we authenticate". Real credential/db-name problems still surface from the
 * `prisma migrate deploy` call that follows, same as before.
 */
export function checkPortOpen(host: string, port: number, timeoutMs = 1500): Promise<boolean> {
  return new Promise((resolvePromise) => {
    const socket = createConnection({ host, port });
    const finish = (open: boolean) => {
      socket.removeAllListeners();
      socket.destroy();
      resolvePromise(open);
    };
    socket.setTimeout(timeoutMs);
    socket.once("connect", () => finish(true));
    socket.once("timeout", () => finish(false));
    socket.once("error", () => finish(false));
  });
}

function detectContainerRuntime(): "docker" | "podman" | null {
  if (hasCommand("docker")) return "docker";
  if (hasCommand("podman")) return "podman";
  return null;
}

export async function runPreflight(pgDatabaseUrl: string): Promise<PreflightResult> {
  let host = "localhost";
  let port = 5432;
  try {
    const parsed = new URL(pgDatabaseUrl);
    host = parsed.hostname || host;
    port = parsed.port ? Number(parsed.port) : port;
  } catch {
    // Malformed PG_DATABASE_URL: fall through with the postgres defaults so
    // the summary still prints something actionable, and let prisma's own
    // error be the authority on "why this URL is wrong".
  }

  const [postgresReachable, containerRuntime, flutterFound] = await Promise.all([
    checkPortOpen(host, port),
    Promise.resolve(detectContainerRuntime()),
    Promise.resolve(hasCommand("flutter")),
  ]);

  return { postgresReachable, containerRuntime, flutterFound };
}

/** Renders the result as the lines dev-setup prints before migrating. */
export function formatPreflightSummary(result: PreflightResult, pgDatabaseUrl: string): string[] {
  const lines: string[] = ["Preflight:"];
  lines.push(
    `  Postgres (${pgDatabaseUrl}): ${result.postgresReachable ? "reachable" : "NOT reachable"}`,
  );
  lines.push(
    `  Container runtime: ${result.containerRuntime ?? "not found (a system Postgres works too)"}`,
  );
  lines.push(
    `  Flutter: ${result.flutterFound ? "found" : "not found (only needed for app/, not for npm run setup)"}`,
  );
  return lines;
}
