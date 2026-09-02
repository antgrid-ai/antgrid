import { afterEach, describe, expect, test } from "bun:test";
import * as Sentry from "@sentry/bun";
import type { ErrorEvent } from "@sentry/bun";
import {
  __resetCrashReportingForTest,
  captureBridgeError,
  flushCrashReports,
  initCrashReporting,
  scrubCrashEvent,
} from "../src/crash-reporting";

/** Minimal well-typed event; each test fills only the field it is about. */
function evt(fields: Partial<ErrorEvent>): ErrorEvent {
  return { type: undefined, ...fields } as ErrorEvent;
}

describe("scrubCrashEvent", () => {
  test("redacts paths in the message and keeps the surrounding prose", () => {
    const e = scrubCrashEvent(evt({ message: "Failed reading C:/Users/me/project/secret.ts" }));
    expect(e.message).not.toContain("secret.ts");
    expect(e.message).not.toContain("C:/Users");
    expect(e.message).toContain("Failed reading");
    expect(e.message).toContain("<redacted-path>");
  });

  // The primary leak vector: an ENOENT/git error carries the full path in its
  // own message, and that is the field a reader would actually look at.
  test("redacts paths in exception values", () => {
    const e = scrubCrashEvent(
      evt({
        exception: {
          values: [
            {
              type: "Error",
              value: "ENOENT: no such file, open '/home/me/proj/secret.ts'",
            },
          ],
        },
      }),
    );
    const value = e.exception!.values![0]!.value!;
    expect(value).not.toContain("/home/me/proj");
    expect(value).not.toContain("secret.ts");
    expect(value).toContain("ENOENT: no such file");
  });

  test("redacts frame paths and DROPS source lines and locals", () => {
    const e = scrubCrashEvent(
      evt({
        exception: {
          values: [
            {
              type: "Error",
              stacktrace: {
                frames: [
                  {
                    filename: "C:\\Users\\me\\proj\\worktree.ts",
                    abs_path: "C:\\Users\\me\\proj\\worktree.ts",
                    function: "removeCheckout",
                    lineno: 42,
                    context_line: "const secret = readFileSync(userPath);",
                    pre_context: ["// user source above"],
                    post_context: ["// user source below"],
                    vars: { userPath: "/home/me/proj/.env" },
                  },
                ],
              },
            },
          ],
        },
      }),
    );
    const frame = e.exception!.values![0]!.stacktrace!.frames![0]!;
    expect(frame.filename).toBe("<redacted-path>");
    expect(frame.abs_path).toBe("<redacted-path>");
    expect(frame.context_line).toBeUndefined();
    expect(frame.pre_context).toBeUndefined();
    expect(frame.post_context).toBeUndefined();
    expect(frame.vars).toBeUndefined();
    // Non-content frame fields are what makes the report readable at all.
    expect(frame.function).toBe("removeCheckout");
    expect(frame.lineno).toBe(42);
  });

  test("scrubs thread stacks, which are attached independently of exceptions", () => {
    const e = scrubCrashEvent(
      evt({
        threads: {
          values: [
            { stacktrace: { frames: [{ filename: "/home/me/proj/a.ts", context_line: "secret" }] } },
          ],
        },
      }),
    );
    const frame = e.threads!.values![0]!.stacktrace!.frames![0]!;
    expect(frame.filename).toBe("<redacted-path>");
    expect(frame.context_line).toBeUndefined();
  });

  test("redacts breadcrumb data recursively, including keys, preserving non-strings", () => {
    const e = scrubCrashEvent(
      evt({
        breadcrumbs: [
          {
            message: "opened /home/me/repo/notes.md",
            data: {
              "/home/me/repo/notes.md": "opened",
              nested: { path: "/home/me/repo/x.ts", list: ["/home/me/y.ts"] },
              count: 3,
              ok: true,
            },
          },
        ],
      }),
    );
    const crumb = e.breadcrumbs![0]!;
    expect(crumb.message).not.toContain("notes.md");
    const data = crumb.data as Record<string, unknown>;
    expect(Object.keys(data)).toContain("<redacted-path>");
    expect(JSON.stringify(data)).not.toContain("/home/me");
    expect(data.count).toBe(3);
    expect(data.ok).toBe(true);
  });

  // `logger.ts` drops pino's hostname binding for this exact reason; an event
  // that carried the machine name would undo it.
  test("replaces server_name and clears user/request", () => {
    const e = scrubCrashEvent(
      evt({
        server_name: "DESKTOP-0LT318M",
        user: { id: "u1", email: "me@example.com" },
        request: { url: "http://127.0.0.1:9/hook", data: "prompt text" },
      }),
    );
    expect(e.server_name).toBe("<redacted-host>");
    expect(e.user).toBeUndefined();
    expect(e.request).toBeUndefined();
  });

  test("leaves an event with nothing to scrub untouched", () => {
    const e = scrubCrashEvent(evt({ message: "relay handshake timed out" }));
    expect(e.message).toBe("relay handshake timed out");
  });
});

// The filter in crash-reporting.ts matches the SDK's own integration `name`s.
// An upstream rename would not fail to compile and would not fail any test that
// only exercises the scrubber — it would just quietly re-enable the integration
// that reads hook request bodies. So assert the names still exist.
test("every excluded integration name still exists in the SDK defaults", () => {
  const expected = [
    "Console",
    "ContextLines",
    "RequestData",
    "Http",
    "NodeFetch",
    "BunServer",
    "ProcessSession",
  ];
  const actual = new Set(Sentry.getDefaultIntegrations({}).map((i) => i.name));
  for (const name of expected) expect([name, actual.has(name)]).toEqual([name, true]);
});

// The gate is the part with a wrong answer that matters: reporting on a user
// who was never asked. Both halves must fail CLOSED independently.
describe("initCrashReporting gate", () => {
  const DSN = "https://abc123@example.invalid/1";

  afterEach(async () => {
    __resetCrashReportingForTest();
    await Sentry.close(0);
  });

  test("stays off without consent, even with a DSN", () => {
    expect(initCrashReporting({ enabled: false, dsn: DSN })).toBe(false);
  });

  test("stays off without a DSN, even with consent", () => {
    expect(initCrashReporting({ enabled: true, dsn: "" })).toBe(false);
  });

  test("captures and flushes are inert while off", async () => {
    initCrashReporting({ enabled: false, dsn: DSN });
    captureBridgeError(new Error("boom"), "test");
    // Shutdown awaits this on every exit, reporting or not, so an un-consented
    // host must get through it without the SDK ever being brought up.
    await expect(flushCrashReports(1)).resolves.toBeUndefined();
    expect(Sentry.getClient()).toBeUndefined();
  });

  test("comes up with consent and a DSN", () => {
    expect(initCrashReporting({ enabled: true, dsn: DSN, release: "1.2.3 (abc)" })).toBe(true);
    expect(Sentry.getClient()).toBeDefined();
  });

  // Measured, not hypothetical: the JS SDKs reject a DSN whose project id is
  // not numeric, and errex issues SLUGS. `Sentry.init` swallows that — no
  // throw, no status — and every later capture and flush then succeeds while
  // sending nothing, so without this guard the feature ships inert and looks
  // healthy. The app is unaffected: sentry-dart takes the last path segment as
  // an opaque String.
  test("refuses a slug project id instead of reporting success", () => {
    expect(
      initCrashReporting({ enabled: true, dsn: "https://abc123@example.invalid/antgrid-app" }),
    ).toBe(false);
    // The SDK still built a client; it is the DSN-less, transport-less kind,
    // which is exactly why the client alone cannot be the health check.
    expect(Sentry.getClient()?.getDsn()).toBeUndefined();
  });

  test("a refused DSN leaves capture and flush inert", async () => {
    initCrashReporting({ enabled: true, dsn: "https://abc123@example.invalid/antgrid-app" });
    captureBridgeError(new Error("boom"), "test");
    await expect(flushCrashReports(1)).resolves.toBeUndefined();
  });

  // The reason these two are kept rather than excluded: they are what stamps a
  // fatal `handled: false`. Installed EXACTLY once each (our configured copy
  // replaces the same-named default rather than doubling the listener), and
  // pinned not to exit — an SDK that exits on its own skips the teardown that
  // sweeps every PTY, which POSIX has no backstop for.
  test("installs exactly one pinned top-level handler of each kind", () => {
    const beforeUncaught = process.listeners("uncaughtException").length;
    const beforeRejection = process.listeners("unhandledRejection").length;

    initCrashReporting({ enabled: true, dsn: DSN });
    const client = Sentry.getClient()!;

    expect(client.getIntegrationByName("OnUncaughtException")).toBeDefined();
    expect(client.getIntegrationByName("OnUnhandledRejection")).toBeDefined();
    expect(process.listeners("uncaughtException").length).toBe(beforeUncaught + 1);
    expect(process.listeners("unhandledRejection").length).toBe(beforeRejection + 1);
  });

  // The payoff of keeping the SDK handler, and the condition it depends on.
  //
  // Sentry decides whether to exit AT CRASH TIME, by counting the other
  // `uncaughtException` listeners — so the contract is not "we configured it
  // right" but "index.ts's handler is registered before any crash". Standing
  // in a listener for index.ts's is therefore the whole point of this test, not
  // a convenience: without one the SDK is the sole listener, takes the fatal
  // path, and exits (which is what it does in a bare script, verified).
  test("with our handler present, a fatal is captured unhandled and we keep the exit", async () => {
    const mechanisms: Array<{ type?: string; handled?: boolean }> = [];
    const before = process.listeners("uncaughtException");

    const ours = () => {}; // stands in for index.ts's shutdown handler
    process.on("uncaughtException", ours);
    try {
      initCrashReporting({ enabled: true, dsn: DSN });
      const sdkOnly = process
        .listeners("uncaughtException")
        .filter((l) => l !== ours && !before.includes(l));
      expect(sdkOnly).toHaveLength(1);

      Sentry.addEventProcessor((event) => {
        const m = event.exception?.values?.[0]?.mechanism;
        if (m) mechanisms.push({ type: m.type, handled: m.handled });
        return null; // nothing leaves the process
      });

      (sdkOnly[0] as (e: Error) => void)(new Error("fatal"));
      await flushCrashReports(500);
    } finally {
      process.removeListener("uncaughtException", ours);
    }

    // `handled: false` is the entire reason this integration is kept: a
    // hand-rolled captureException reports the same fatal as handled/generic.
    expect(mechanisms).toEqual([{ type: "auto.node.onuncaughtexception", handled: false }]);
    // Reaching this line at all is the other half — the SDK did not exit.
  });
});
