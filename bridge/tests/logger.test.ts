import { describe, it, expect, beforeEach, afterEach, spyOn } from "bun:test";
import { logger, setLogLevel, setJsonMode } from "../src/logger";

describe("logger", () => {
  let logSpy: ReturnType<typeof spyOn>;
  let errorSpy: ReturnType<typeof spyOn>;
  let warnSpy: ReturnType<typeof spyOn>;

  beforeEach(() => {
    logSpy = spyOn(console, "log").mockImplementation(() => {});
    errorSpy = spyOn(console, "error").mockImplementation(() => {});
    warnSpy = spyOn(console, "warn").mockImplementation(() => {});
    setLogLevel("debug");
    setJsonMode(false);
  });

  afterEach(() => {
    logSpy.mockRestore();
    errorSpy.mockRestore();
    warnSpy.mockRestore();
    setLogLevel("info");
    setJsonMode(false);
  });

  it("logs at all levels when level is debug", () => {
    logger.debug("d");
    logger.info("i");
    logger.warn("w");
    logger.error("e");
    expect(logSpy).toHaveBeenCalledTimes(2); // debug + info
    expect(warnSpy).toHaveBeenCalledTimes(1);
    expect(errorSpy).toHaveBeenCalledTimes(1);
  });

  it("filters debug when level is info", () => {
    setLogLevel("info");
    logger.debug("hidden");
    logger.info("visible");
    expect(logSpy).toHaveBeenCalledTimes(1);
  });

  it("filters debug and info when level is warn", () => {
    setLogLevel("warn");
    logger.debug("hidden");
    logger.info("hidden");
    logger.warn("visible");
    expect(logSpy).toHaveBeenCalledTimes(0);
    expect(warnSpy).toHaveBeenCalledTimes(1);
  });

  it("only shows error when level is error", () => {
    setLogLevel("error");
    logger.debug("hidden");
    logger.info("hidden");
    logger.warn("hidden");
    logger.error("visible");
    expect(logSpy).toHaveBeenCalledTimes(0);
    expect(warnSpy).toHaveBeenCalledTimes(0);
    expect(errorSpy).toHaveBeenCalledTimes(1);
  });

  it("emits JSON when json mode is enabled", () => {
    setJsonMode(true);
    logger.info("hello %s", "world");
    expect(logSpy).toHaveBeenCalledTimes(1);
    const output = logSpy.mock.calls[0][0] as string;
    const parsed = JSON.parse(output);
    expect(parsed.level).toBe("info");
    expect(parsed.msg).toBe("hello world");
    expect(parsed.time).toBeDefined();
  });

  it("emits JSON errors to console.error", () => {
    setJsonMode(true);
    logger.error("fail");
    expect(errorSpy).toHaveBeenCalledTimes(1);
    const output = errorSpy.mock.calls[0][0] as string;
    const parsed = JSON.parse(output);
    expect(parsed.level).toBe("error");
    expect(parsed.msg).toBe("fail");
  });

  it("includes timestamp in human mode", () => {
    logger.info("test");
    const call = logSpy.mock.calls[0];
    const prefix = call[0] as string;
    // Format: HH:MM:SS.mmm [INFO ]
    expect(prefix).toMatch(/^\d{2}:\d{2}:\d{2}\.\d{3} \[INFO \]$/);
  });
});
