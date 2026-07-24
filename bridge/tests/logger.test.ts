import { describe, it, expect, beforeEach, afterAll } from "bun:test";
import { logger, setLogLevel, __setRootForTest } from "../src/logger";

// Collect each pino line (pino writes one JSON string per call, newline-terminated).
const lines: string[] = [];
const capture = {
  write(s: string): boolean {
    lines.push(s);
    return true;
  },
};

function last(): Record<string, unknown> {
  return JSON.parse(lines[lines.length - 1]!);
}

describe("logger", () => {
  beforeEach(() => {
    lines.length = 0;
    __setRootForTest(capture, "debug");
  });

  // Bun shares the module cache across the whole suite; without this the hub
  // stays pointed at our dead in-memory buffer and a later stdout-asserting
  // test in another file would silently capture nothing. Restore the real sink.
  afterAll(() => __setRootForTest(process.stdout));

  it("emits one pino-shaped JSON line per call", () => {
    logger.info("hello %s", "world");
    expect(lines.length).toBe(1);
    const o = last();
    expect(typeof o.level).toBe("number");
    expect(o.level).toBe(30);
    expect(typeof o.time).toBe("number");
    expect(o.pid).toBe(process.pid);
    expect(o.msg).toBe("hello world");
    expect("hostname" in o).toBe(false); // dropped via base:{pid}
  });

  it("maps each method to its numeric level", () => {
    logger.debug("d");
    logger.info("i");
    logger.warn("w");
    logger.error("e");
    const levels = lines.map((l) => (JSON.parse(l) as { level: number }).level);
    expect(levels).toEqual([20, 30, 40, 50]);
  });

  it("filters below the active level", () => {
    __setRootForTest(capture, "warn");
    logger.debug("hidden");
    logger.info("hidden");
    logger.warn("shown");
    expect(lines.length).toBe(1);
    expect(last().level).toBe(40);
  });

  it("respects setLogLevel at runtime", () => {
    __setRootForTest(capture, "info");
    logger.debug("hidden");
    expect(lines.length).toBe(0);
    setLogLevel("debug");
    logger.debug("now shown");
    expect(lines.length).toBe(1);
  });

  it("adds a component binding via child()", () => {
    const log = logger.child({ component: "relay-client" });
    log.warn("connected");
    const o = last();
    expect(o.component).toBe("relay-client");
    expect(o.level).toBe(40);
    expect(o.msg).toBe("connected");
  });

  it("merges a fields object passed as the first arg", () => {
    logger.info({ projectId: "abc" }, "opened");
    const o = last();
    expect(o.projectId).toBe("abc");
    expect(o.msg).toBe("opened");
  });

  it("propagates setLogLevel to an already-created child", () => {
    __setRootForTest(capture, "info");
    const child = logger.child({ component: "late" });
    child.debug("hidden");
    expect(lines.length).toBe(0);
    setLogLevel("debug");
    child.debug("now shown");
    expect(lines.length).toBe(1);
    expect(last().component).toBe("late");
  });
});
