import { rm } from "node:fs/promises";

/** Backoff for [removeWithRetries]. Each entry is the wait BEFORE that attempt,
 * so the first is free and the budget is ~2.3s over five tries. Sized for the
 * holder it exists to outlast — a just-killed process (a PTY's grandchildren,
 * or a `TerminateProcess`d git clone) whose OS handle to the directory does not
 * close synchronously with the kill — and no longer: a handle nothing is
 * closing needs the caller's error, not more patience. */
const RECLAIM_BACKOFF_MS = [0, 100, 300, 700, 1200];

/** Recursive delete that actually retries a transient Windows sharing
 * violation. `fs.rm`'s own `maxRetries`/`retryDelay` cannot be used: Bun
 * accepts both options and honours NEITHER — measured on the pinned runtime
 * (1.3.14), `rm` against a directory held as a live child's cwd returns in 0ms
 * with EBUSY where Node retries for the full budget. The bridge runs on Bun in
 * both `bun run` and `bun build --compile` form, so the options were a no-op
 * everywhere it ships. Swallows the final failure — callers re-test the path
 * and report it themselves, since whatever still holds it open is worth
 * surfacing rather than retrying blindly. */
export async function removeWithRetries(path: string): Promise<void> {
  for (const wait of RECLAIM_BACKOFF_MS) {
    if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
    try {
      await rm(path, { recursive: true, force: true });
      return;
    } catch {
      // Caller re-tests the directory and reports the failure — whatever holds
      // it open is worth surfacing rather than retrying blindly.
    }
  }
}
