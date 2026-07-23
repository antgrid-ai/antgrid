import pino, { type Logger, type Level, type DestinationStream, type LogFn } from "pino";

/**
 * Build a pino logger. Default destination is stdout (fd 1); tests inject a
 * capture stream. `base: { pid }` drops pino's default `hostname` binding so
 * lines never leak the machine name — the app tees this stdout into host.log.
 * pino's defaults already match our schema: numeric `level`, epoch-ms `time`.
 */
export function createLogger(opts?: {
  level?: Level;
  destination?: DestinationStream;
}): Logger {
  return pino({ level: opts?.level ?? "info", base: { pid: process.pid } }, opts?.destination);
}

/**
 * pino's `.child()` binds to its parent's destination stream at creation —
 * not a live reference to `root` — so a module that does
 * `const log = logger.child(...)` at import time (every component logger in
 * the bridge) would freeze onto whichever stream existed the moment that
 * module first loaded. Bun runs the whole test suite in one process sharing
 * the module cache, so `__setRootForTest` in one test file could never
 * redirect a child created via an earlier-imported module. Routing every
 * pino instance (root AND every child, forever) through this one mutable
 * indirection means `__setRootForTest` only has to flip `hub.target` and
 * every already-created child picks it up on its next write.
 */
class DestinationHub implements DestinationStream {
  target: DestinationStream = process.stdout;
  write(msg: string): void {
    this.target.write(msg);
  }
}
const hub = new DestinationHub();
const root: Logger = createLogger({ destination: hub });

// Children snapshot root.level at creation (pino does not propagate a later
// root.level change to existing children), so track them and update each in
// setLogLevel — otherwise --verbose/--log-level would never reach the
// component-tagged child loggers created at module-eval time.
const children = new Set<Logger>();

/** Raise/lower the runtime level (index.ts wires `--verbose` / `--log-level`). */
export function setLogLevel(level: Level): void {
  root.level = level;
  for (const c of children) c.level = level;
}

/**
 * Façade preserving the historical `logger.info(msg, ...args)` call shape used
 * across the bridge, plus pino's `.child({ component })`. Delegates to the live
 * `root` so `setLogLevel` (and the test reset below) affect already-imported
 * callers — updating both `root` itself and every child handed out via
 * `.child()` (the whole reason the `children` set exists).
 *
 * The methods MUST be typed as pino's real `LogFn` (all overloads: object-first
 * AND printf `logger.error("failed: %s", err)` with a non-string arg). Do NOT
 * type them `Parameters<Logger["info"]>` — pino's `LogFn` is overloaded, so
 * `Parameters<>` collapses the 2nd param to `msg?: string` and, under the
 * bridge's `strict` tsconfig (catch vars are `unknown`), breaks every existing
 * `logger.warn/error("…%s", err)` call across ~25+ sites. The arrow bodies call
 * `root.<m>(...)` so `this` stays bound to the live root — a `get info() {
 * return root.info; }` getter typechecks but THROWS at runtime (`this` becomes
 * `logger`, not `root`).
 *
 * This is why `pino` is pinned to an EXACT `9.7.0` in package.json (not `^9`):
 * pino >= 9.8 tightens `ParseLogFnArgs`, which reintroduces the printf-site
 * breakage above across ~25+ call sites. Do NOT bump the pin without converting
 * those `logger.<level>("…%s", err)` sites (or re-typing the façade) first.
 */
interface LoggerFacade {
  debug: LogFn;
  info: LogFn;
  warn: LogFn;
  error: LogFn;
  child(bindings: Record<string, unknown>): Logger;
}

export const logger: LoggerFacade = {
  debug: (...args: unknown[]) => (root.debug as (...a: unknown[]) => void)(...args),
  info: (...args: unknown[]) => (root.info as (...a: unknown[]) => void)(...args),
  warn: (...args: unknown[]) => (root.warn as (...a: unknown[]) => void)(...args),
  error: (...args: unknown[]) => (root.error as (...a: unknown[]) => void)(...args),
  child: (bindings: Record<string, unknown>): Logger => {
    const c = root.child(bindings);
    children.add(c);
    return c;
  },
};

/**
 * Test hook — redirect every pino instance (root and all children, past and
 * future) at the shared `hub` so specs can assert output regardless of which
 * module first created its component child logger.
 */
export function __setRootForTest(destination: DestinationStream, level: Level = "debug"): void {
  hub.target = destination;
  setLogLevel(level);
}
