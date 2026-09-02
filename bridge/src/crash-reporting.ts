import * as Sentry from "@sentry/bun";
import type { Breadcrumb, ErrorEvent, StackFrame } from "@sentry/bun";
import { logger } from "./logger";

const log = logger.child({ component: "crash-reporting" });

/** Integrations dropped from the SDK defaults. Every one either reads user
 *  content off disk / off the wire, or bills a shutdown budgeted in ms:
 *
 *  - `Console` turns each `console.*` line into a breadcrumb holding the line
 *    verbatim — for the bridge that is checkout paths, branch names, session ids.
 *  - `ContextLines` reads the source lines AROUND the crash off disk into
 *    `context_line`/`pre_context`/`post_context`. In a dev (uncompiled) host
 *    that is our own source; the field is a content leak either way.
 *  - `RequestData`, `Http`, `NodeFetch` and `BunServer` instrument the loopback
 *    api-server and every outbound fetch. Hook payloads (prompts, tool input)
 *    arrive as request BODIES on that server, so this is the worst exposure in
 *    the list; the URLs alone carry project ids.
 *  - `ProcessSession` posts a release-health session on exit, adding a network
 *    round-trip to a shutdown path that races a Store destage on Windows.
 *
 *  The two top-level handler integrations are NOT here. They are re-added below
 *  with their options pinned — see `TOP_LEVEL_HANDLER_INTEGRATIONS`.
 *
 *  Names are matched against the SDK's own integration `name`s, so a rename
 *  upstream silently stops filtering. `crash-scrubber.test.ts` pins this list
 *  against the live defaults for exactly that reason. */
const EXCLUDED_INTEGRATIONS = new Set([
  "Console",
  "ContextLines",
  "RequestData",
  "Http",
  "NodeFetch",
  "BunServer",
  "ProcessSession",
]);

/**
 * `OnUncaughtException` and `OnUnhandledRejection`, re-added with their options
 * stated rather than inherited. They replace the identically-named defaults
 * (the SDK keys integrations by name, so exactly ONE listener of each is
 * installed — not a duplicate pair).
 *
 * They own the CAPTURE on both top-level paths, and `index.ts` deliberately
 * does not `captureBridgeError` there. That is the whole reason to keep them:
 * they stamp `mechanism { type: "auto.node.onuncaughtexception", handled: false }`,
 * which is what makes an event a CRASH rather than a handled error in the UI
 * and in release health. A hand-rolled `captureException` reports the same
 * fatal as `generic`/`handled: true` — measurably wrong, and wrong in exactly
 * the dimension this instrumentation exists to answer.
 *
 * `exitEvenIfOtherHandlersAreRegistered: false` is the load-bearing option and
 * is pinned here rather than inherited from the SDK's default. True would make
 * the SDK `process.exit(1)` on its own, skipping `index.ts`'s teardown — the
 * teardown that sweeps every PTY. Windows survives that (the kernel closes our
 * job handles), but POSIX has no such backstop and every agent tree would be
 * orphaned. Do not drop the option because the default currently agrees with it.
 *
 * The option is only half the contract, and the other half lives in `index.ts`:
 * measured on 10.70, the SDK re-counts the OTHER `uncaughtException` listeners
 * at CRASH TIME. With one of ours present it defers and we keep the exit; as
 * the SOLE listener it takes the fatal path and exits regardless of this option.
 * So the guarantee is "index.ts registers its handlers before a crash can
 * matter", not "we configured the integration correctly".
 */
const TOP_LEVEL_HANDLER_INTEGRATIONS = [
  Sentry.onUncaughtExceptionIntegration({ exitEvenIfOtherHandlersAreRegistered: false }),
  // `strict` re-raises the rejection as an uncaught exception; `warn` leaves the
  // process to us, which is the only mode compatible with owning our own exit.
  Sentry.onUnhandledRejectionIntegration({ mode: "warn" }),
];

/** Kept in lockstep with `_pathLike` in `app/lib/analytics/crash_reporting.dart`
 *  — the app and the bridge report into the same errex project, and a path that
 *  survives one scrubber but not the other is one leak wearing two faces. */
const PATH_LIKE = /([a-zA-Z]:)?[\\/][^\s"]+/g;
const REDACTED_PATH = "<redacted-path>";

/** How long a shutdown may wait on the transport. Bounded hard: the drain that
 *  follows is what kills every PTY, and on Windows it races a Store destage. */
const FLUSH_TIMEOUT_MS = 2_000;

function redact(input: string): string {
  return input.replace(PATH_LIKE, REDACTED_PATH);
}

function redactNullable<T extends string | undefined>(input: T): T {
  return (input === undefined ? undefined : redact(input)) as T;
}

/** Recursively redact strings inside arbitrary breadcrumb/extra data — nested
 *  objects and arrays, not just the top level. KEYS are redacted too: a map can
 *  be keyed by a path (`{"/home/me/x.ts": "opened"}`), which would otherwise
 *  travel verbatim. Non-string scalars pass through untouched. */
function redactDeep(value: unknown): unknown {
  if (typeof value === "string") return redact(value);
  if (Array.isArray(value)) return value.map(redactDeep);
  if (value !== null && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      out[redact(k)] = redactDeep(v);
    }
    return out;
  }
  return value;
}

/** Redacts the on-disk path and DELETES every source/local field. `context_line`
 *  and its neighbours are literal lines of whatever file the crash landed in and
 *  `vars` carries local values — both raw content, never needed for an anonymous
 *  report, so they are dropped rather than redacted. The `ContextLines`
 *  integration that populates them is already excluded above; this is the
 *  belt-and-braces half, and it also covers frames an SDK synthesized itself. */
function scrubFrame(frame: StackFrame): void {
  frame.filename = redactNullable(frame.filename);
  frame.abs_path = redactNullable(frame.abs_path);
  frame.module = redactNullable(frame.module);
  delete frame.context_line;
  delete frame.pre_context;
  delete frame.post_context;
  delete frame.vars;
}

function scrubBreadcrumb(crumb: Breadcrumb): void {
  crumb.message = redactNullable(crumb.message);
  if (crumb.data) crumb.data = redactDeep(crumb.data) as Record<string, unknown>;
}

/**
 * Strips user content (paths, project/file names, source snippets, the machine
 * name) from an event before transmit. Defense-in-depth even though errex is
 * self-hosted: the zero-knowledge promise is that we never hold readable user
 * content, and the bridge is the process that actually touches the working tree.
 *
 * Mutates and returns [event] — the idiomatic `beforeSend` shape.
 *
 * Coverage is every field the SDK was MEASURED to populate for this process
 * (`crash-scrubber.test.ts` records that probe): message/logentry, exception
 * values and their frames, thread stacks, breadcrumbs, extra, transaction, and
 * `server_name`, which arrives as the bare hostname — `logger.ts` drops pino's
 * `hostname` binding for the same reason. `user` and `request` are not populated
 * at all with `sendDefaultPii: false` and the server integrations excluded, and
 * are cleared anyway so re-enabling one cannot quietly start shipping them.
 * `contexts` is deliberately NOT scrubbed: it is os/runtime/device-HARDWARE
 * metadata with no name or path in it, and it is most of why a cross-platform
 * bridge reports at all. Re-run the probe and revisit this list on an SDK major.
 */
export function scrubCrashEvent(event: ErrorEvent): ErrorEvent {
  event.message = redactNullable(event.message);
  if (event.logentry?.message) {
    event.logentry.message = redact(event.logentry.message);
  }

  for (const crumb of event.breadcrumbs ?? []) scrubBreadcrumb(crumb);

  for (const exception of event.exception?.values ?? []) {
    exception.value = redactNullable(exception.value);
    for (const frame of exception.stacktrace?.frames ?? []) scrubFrame(frame);
  }

  // Threads carry the same frames as exceptions and are attached independently.
  for (const thread of event.threads?.values ?? []) {
    for (const frame of thread.stacktrace?.frames ?? []) scrubFrame(frame);
  }

  event.transaction = redactNullable(event.transaction);
  if (event.extra) event.extra = redactDeep(event.extra) as Record<string, unknown>;
  if (event.server_name !== undefined) event.server_name = "<redacted-host>";
  delete event.user;
  delete event.request;

  return event;
}

/** Set once by `initCrashReporting`. Everything below is a no-op while false, so
 *  a host with no consent (or no DSN) never touches the SDK after init. */
let active = false;

export interface CrashReportingOptions {
  /** The user's telemetry consent, as the spawning app read it. Absent from a
   *  bootstrap payload sent by the CLI or a test, which is why the caller
   *  resolves that absence to `false` rather than this defaulting it. */
  enabled: boolean;
  /** A build-time constant in a shipped bridge (`--define`), ambient env
   *  otherwise — which is what keeps a dev host silent unless deliberately
   *  configured. Same shape as `LICENSE_API_URL`. */
  dsn: string;
  /** The spawning app's `ownerBuild`, used verbatim — never parsed, per the
   *  contract in `credentials.ts`. It is the only per-build identifier the host
   *  has: `VERSION` is a static literal nobody bumps, so it is identical across
   *  every release, and CI builds this binary and the app from one commit. */
  release?: string;
}

/** Returns whether reporting actually came up — callers log it, nothing branches. */
export function initCrashReporting(opts: CrashReportingOptions): boolean {
  if (active) return true;
  if (!opts.enabled || !opts.dsn) return false;

  Sentry.init({
    dsn: opts.dsn,
    ...(opts.release ? { release: opts.release } : {}),
    sendDefaultPii: false,
    integrations: (defaults) => [
      ...defaults.filter((i) => !EXCLUDED_INTEGRATIONS.has(i.name)),
      ...TOP_LEVEL_HANDLER_INTEGRATIONS,
    ],
    beforeSend: (event) => scrubCrashEvent(event),
  });

  // `Sentry.init` NEVER throws and NEVER returns a status: a DSN it refuses
  // leaves a client with no transport, and every later `captureException` and
  // `flush` then succeeds silently — `flush` resolves TRUE with nothing sent.
  // The refusal that matters here is measured, not hypothetical: the JS SDKs
  // require a NUMERIC project id, while errex issues slugs (`antgrid-app`), so
  // the DSN CI bakes in is rejected outright and the whole feature ships inert.
  // A missing DSN here is therefore never "reporting is off" — it is reporting
  // that believes it is on. Fail loudly and stay off.
  if (!Sentry.getClient()?.getDsn()) {
    log.error(
      "crash reporting DISABLED: the SDK refused the DSN (JS SDKs require a numeric project id)",
    );
    return false;
  }

  Sentry.setTag("component", "bridge");
  active = true;
  return true;
}

/** Record an error the bridge CAUGHT and decided to log — a failed shutdown,
 *  say. The two top-level handler paths do NOT come through here: the SDK's own
 *  integrations capture those, so they keep `handled: false` (see
 *  `TOP_LEVEL_HANDLER_INTEGRATIONS`), and `handled: true` here is the honest
 *  answer for an error we caught. [context] is the call site, not a message — it
 *  becomes a tag, so it must stay a fixed vocabulary and never carry user
 *  content. */
export function captureBridgeError(err: unknown, context: string): void {
  if (!active) return;
  Sentry.captureException(err, { tags: { bridge_context: context } });
}

/** Drain the transport before exit, bounded so a dead network cannot hold up the
 *  teardown that sweeps the PTYs.
 *
 *  Unconditional while reporting is on, deliberately: most captures now happen
 *  inside the SDK's own top-level handlers, so nothing on this side can know
 *  whether the queue is empty — and it need not, since a flush with nothing to
 *  send measures ~15ms, well under the 5s graceful ask that follows it. */
export async function flushCrashReports(timeoutMs: number = FLUSH_TIMEOUT_MS): Promise<void> {
  if (!active) return;
  try {
    await Sentry.flush(timeoutMs);
  } catch {
    // A report we could not send must never change how the host exits.
  }
}

/** Test seam: `initCrashReporting` latches a module-level flag exactly once. */
export function __resetCrashReportingForTest(): void {
  active = false;
}
