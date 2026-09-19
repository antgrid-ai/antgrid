// The switch that makes the delivery-path logging reachable in the field. A
// shipped app spawns the bridge with no `--log-level`, so without an arm every
// debug line below is a test-suite property and nothing else — and the arm only
// stays honest if it lapses on its own, because a bridge parked at debug writes
// a line per queued delivery and per turn close for as long as it runs.
import { afterAll, afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ControlRequestSchema, type ControlRequest, type ControlResponse } from "../src/control-protocol";
import { HostServer } from "../src/host-server";
import { __setRootForTest, armLogLevel, currentLogLevel, logger } from "../src/logger";

const lines: string[] = [];
const capture = {
  write(s: string): boolean {
    lines.push(s);
    return true;
  },
};

// Bun shares the module cache across the whole suite; leaving the hub pointed at
// a dead buffer would silently swallow another file's assertions.
afterAll(() => __setRootForTest(process.stdout));

describe("armLogLevel", () => {
  test("raises the level for the window and lapses back to the configured one", async () => {
    __setRootForTest(capture, "info");
    // A child, because every site the arm exists to reveal is one: pino snapshots
    // root.level into a child at creation, so an arm that reached only the root
    // would leave the delivery path silent and the feature inert.
    const child = logger.child({ component: "arm-spec" });
    lines.length = 0;

    child.debug("before");
    expect(lines).toHaveLength(0);

    armLogLevel("debug", 20);
    expect(currentLogLevel()).toBe("debug");
    child.debug("during");
    expect(lines).toHaveLength(1);

    await new Promise((r) => setTimeout(r, 60));
    expect(currentLogLevel()).toBe("info");
    child.debug("after");
    expect(lines).toHaveLength(1);
  });

  test("an arm with no expiry raises nothing", () => {
    __setRootForTest(capture, "info");
    lines.length = 0;

    armLogLevel("debug", 0);
    armLogLevel("debug", -1);
    armLogLevel("debug", Number.NaN);
    armLogLevel("debug", Number.POSITIVE_INFINITY);

    expect(currentLogLevel()).toBe("info");
    logger.debug("hidden");
    expect(lines).toHaveLength(0);
  });
});

describe("the log:level control verb", () => {
  test("admits a window and an explicit zero, and refuses a level and a window it cannot honour", () => {
    expect(ControlRequestSchema.safeParse({ id: "x", type: "log:level", level: "debug", ttlMs: 600_000 }).success).toBe(true);
    expect(ControlRequestSchema.safeParse({ id: "x", type: "log:level", level: "debug", ttlMs: 0 }).success).toBe(true);
    // A level with no logger method behind it, and a window the arming path
    // would read as a disarm while the caller meant to raise something.
    expect(ControlRequestSchema.safeParse({ id: "x", type: "log:level", level: "loud", ttlMs: 1 }).success).toBe(false);
    expect(ControlRequestSchema.safeParse({ id: "x", type: "log:level", level: "debug", ttlMs: -1 }).success).toBe(false);
  });
});

describe("the log:level verb at the loopback plane", () => {
  let host: HostServer | null = null;
  let abDir: string | undefined;
  let prevAbDir: string | undefined;

  beforeEach(() => {
    prevAbDir = process.env.ANTGRID_DIR;
    abDir = mkdtempSync(join(tmpdir(), "antgrid-loglevel-"));
    process.env.ANTGRID_DIR = abDir;
    __setRootForTest(capture, "info");
    lines.length = 0;
  });

  afterEach(async () => {
    armLogLevel("info", 0);
    __setRootForTest(process.stdout);
    await host?.shutdown();
    host = null;
    if (prevAbDir === undefined) delete process.env.ANTGRID_DIR;
    else process.env.ANTGRID_DIR = prevAbDir;
    if (abDir) rmSync(abDir, { recursive: true, force: true });
  });

  function control(req: ControlRequest): Promise<ControlResponse> {
    return (host as unknown as { handleControl(r: ControlRequest): Promise<ControlResponse> }).handleControl(req);
  }

  test("refuses an arm with no window, answers one with a window, and reports the state", async () => {
    host = new HostServer({});

    const noTtl = await control({ id: "a", type: "log:level", level: "debug" });
    expect(noTtl).toMatchObject({ ok: false, error: { code: "TTL_REQUIRED" } });
    expect(currentLogLevel()).toBe("info");

    const armed = await control({ id: "b", type: "log:level", level: "debug", ttlMs: 600_000 });
    expect(armed).toMatchObject({ ok: true, type: "log:level", level: "debug", ttlMs: 600_000 });
    expect(currentLogLevel()).toBe("debug");

    // The answer describes the state, so a disarm names what it restored rather
    // than echoing back the level the caller had to spell to reach this verb.
    const off = await control({ id: "c", type: "log:level", level: "debug", ttlMs: 0 });
    expect(off).toMatchObject({ ok: true, type: "log:level", level: "info", ttlMs: 0 });
    expect(currentLogLevel()).toBe("info");
  });

  test("clamps a window past the host's capture ceiling", async () => {
    host = new HostServer({});
    const armed = await control({ id: "a", type: "log:level", level: "trace", ttlMs: 999_999_999 });
    // The same ceiling every other arming verb on this plane takes: a window is
    // a diagnostic ask, never a configuration change with a different lifetime.
    expect(armed).toMatchObject({ ok: true, ttlMs: 3_600_000 });
  });
});
