import { describe, it, expect, beforeEach, afterEach, spyOn } from "bun:test";
import { displayStartupBanner } from "../src/banner";
import { randomBytes } from "node:crypto";

describe("banner", () => {
  let logSpy: ReturnType<typeof spyOn>;

  beforeEach(() => {
    logSpy = spyOn(console, "log").mockImplementation(() => {});
  });

  afterEach(() => {
    logSpy.mockRestore();
  });

  it("displays agent banner without error", async () => {
    await displayStartupBanner({
      version: "0.1.0",
      relayUrl: "ws://localhost:8374",
      identity: {
        deviceId: "test-id",
        deviceName: "test-device",
        createdAt: new Date().toISOString(),
      },
      pubkey: randomBytes(32),
      mode: "agent",
      terminalCount: 2,
      projectPath: "/home/user/project",
    });

    const output = logSpy.mock.calls.map((c: any[]) => c[0]).join("\n");
    expect(output).toContain("Antgrid Agent v0.1.0");
    expect(output).toContain("Radha AI");
    expect(output).toContain("ws://localhost:8374");
    expect(output).toContain("ANTGRID-");
  });

  it("displays pair banner without error", async () => {
    await displayStartupBanner({
      version: "0.1.0",
      relayUrl: "ws://localhost:8374",
      identity: {
        deviceId: "test-id",
        deviceName: "test-device",
        createdAt: new Date().toISOString(),
      },
      pubkey: randomBytes(32),
      mode: "pair",
    });

    const output = logSpy.mock.calls.map((c: any[]) => c[0]).join("\n");
    expect(output).toContain("Antgrid Agent v0.1.0");
    expect(output).toContain("pair");
  });

  it("emits a Pair URI carrying the BARE deviceUuid (not the compound id)", async () => {
    await displayStartupBanner({
      version: "0.1.0",
      relayUrl: "ws://localhost:8374",
      identity: {
        deviceId: "test-id",
        deviceName: "test-device",
        createdAt: new Date().toISOString(),
      },
      pubkey: randomBytes(32),
      mode: "agent",
      terminalCount: 1,
      projectId: "proj-xyz",
    });

    const output = logSpy.mock.calls.map((c: any[]) => c[0]).join("\n");
    const line = output.split("\n").find((l: string) => l.startsWith("Pair URI:"));
    expect(line).toBeDefined();
    const url = line!.slice("Pair URI:".length).trim();
    const d = new URL(url).searchParams.get("d");
    expect(d).toBe("test-id");
    expect(url).not.toContain("test-id.proj-xyz");
  });

  it("truncates long project paths", async () => {
    await displayStartupBanner({
      version: "0.1.0",
      relayUrl: "ws://localhost:8374",
      identity: {
        deviceId: "test-id",
        deviceName: "test-device",
        createdAt: new Date().toISOString(),
      },
      pubkey: randomBytes(32),
      mode: "agent",
      projectPath: "/very/long/path/that/exceeds/the/maximum/display/width/for/banner",
    });

    const output = logSpy.mock.calls.map((c: any[]) => c[0]).join("\n");
    expect(output).toContain("...");
  });
});
