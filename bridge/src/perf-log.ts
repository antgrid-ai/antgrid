// Lightweight perf instrumentation for the agent process. Enabled via
// `--debug-perf` on the CLI. Samples `process.memoryUsage()` at 1Hz and
// appends a single line per sample to `<abDir>/perf.log` (ANTGRID_DIR-aware).
//
// Target: an idle warm agent (no active session) should stay well under
// the 80MB RSS budget called out in the spec.

import { join } from "node:path";
import { mkdirSync, appendFileSync, existsSync } from "node:fs";
import { resolveAbDir } from "./antgrid-dir";

export interface PerfLogHandle {
  /** Stop the sampler and flush a final marker line. Idempotent. */
  stop(): void;
  /** Path of the log file (for tests / debugging). */
  readonly path: string;
}

export function startPerfLog(projectId: string): PerfLogHandle {
  const dir = resolveAbDir();
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  const path = join(dir, "perf.log");

  safeAppend(
    path,
    `=== agent ${projectId} started at ${new Date().toISOString()} pid=${process.pid} ===\n`,
  );

  const timer = setInterval(() => {
    const m = process.memoryUsage();
    safeAppend(
      path,
      `agent ${projectId} rss=${m.rss} heap=${m.heapUsed} ext=${m.external} ts=${new Date().toISOString()}\n`,
    );
  }, 1000);
  // Don't keep the event loop alive just for sampling.
  if (typeof timer.unref === "function") timer.unref();

  let stopped = false;
  return {
    path,
    stop(): void {
      if (stopped) return;
      stopped = true;
      clearInterval(timer);
      safeAppend(
        path,
        `=== agent ${projectId} stopped at ${new Date().toISOString()} ===\n`,
      );
    },
  };
}

function safeAppend(path: string, line: string): void {
  try {
    appendFileSync(path, line);
  } catch {
    // Instrumentation must never crash the agent.
  }
}
