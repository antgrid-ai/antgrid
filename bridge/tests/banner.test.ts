import { describe, it, expect, beforeEach, afterEach, spyOn } from "bun:test";
import { displayStartupBanner } from "../src/banner";

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
      terminalCount: 2,
      projectPath: "/home/user/project",
    });

    const output = logSpy.mock.calls.map((c: any[]) => c[0]).join("\n");
    expect(output).toContain("Antgrid Agent v0.1.0");
    expect(output).toContain("Radha AI");
    expect(output).toContain("ws://localhost:8374");
    // The ANTGRID-XXXX "Code:" line is gone: it fingerprinted the per-process
    // EPHEMERAL X25519 key, so it was neither a credential nor stable, and
    // nothing anywhere verified it.
    expect(output).not.toContain("ANTGRID-");
  });

  it("points at the app's machine list rather than a connect URI", async () => {
    await displayStartupBanner({
      version: "0.1.0",
      relayUrl: "ws://localhost:8374",
      identity: {
        deviceId: "test-id",
        deviceName: "test-device",
        createdAt: new Date().toISOString(),
      },
      terminalCount: 1,
      projectId: "proj-xyz",
    });

    const output = logSpy.mock.calls.map((c: any[]) => c[0]).join("\n");
    expect(output).toContain("Connect this machine from the app's machine list.");
    // Admission is account trust and /account/agents already carries every
    // machine's coordinates, so the banner must not reintroduce an address the
    // user is asked to carry by hand.
    expect(output).not.toContain("antgrid://");
  });

  it("shows the relay as unconfigured when there is none", async () => {
    await displayStartupBanner({
      version: "0.1.0",
      relayUrl: null,
      identity: {
        deviceId: "test-id",
        deviceName: "test-device",
        createdAt: new Date().toISOString(),
      },
      terminalCount: 1,
    });

    const output = logSpy.mock.calls.map((c: any[]) => c[0]).join("\n");
    expect(output).toContain("(not configured)");
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
      projectPath: "/very/long/path/that/exceeds/the/maximum/display/width/for/banner",
    });

    const output = logSpy.mock.calls.map((c: any[]) => c[0]).join("\n");
    expect(output).toContain("...");
  });
});
