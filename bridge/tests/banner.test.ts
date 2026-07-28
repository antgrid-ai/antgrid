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
      mode: "agent",
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

  it("displays pair banner without error, with connect (not pair) copy", async () => {
    await displayStartupBanner({
      version: "0.1.0",
      relayUrl: "ws://localhost:8374",
      identity: {
        deviceId: "test-id",
        deviceName: "test-device",
        createdAt: new Date().toISOString(),
      },
      mode: "pair",
    });

    const output = logSpy.mock.calls.map((c: any[]) => c[0]).join("\n");
    expect(output).toContain("Antgrid Agent v0.1.0");
    expect(output).toContain("Connect URI:");
    expect(output).toContain("Open the URI above in the Antgrid app to connect this machine.");
    expect(output).not.toContain("Pair URI:");
  });

  it("emits a Connect URI carrying the BARE deviceUuid (not the compound id)", async () => {
    await displayStartupBanner({
      version: "0.1.0",
      relayUrl: "ws://localhost:8374",
      identity: {
        deviceId: "test-id",
        deviceName: "test-device",
        createdAt: new Date().toISOString(),
      },
      mode: "agent",
      terminalCount: 1,
      projectId: "proj-xyz",
    });

    const output = logSpy.mock.calls.map((c: any[]) => c[0]).join("\n");
    const line = output.split("\n").find((l: string) => l.startsWith("Connect URI:"));
    expect(line).toBeDefined();
    const url = line!.slice("Connect URI:".length).trim();
    const d = new URL(url).searchParams.get("d");
    expect(d).toBe("test-id");
    expect(url).not.toContain("test-id.proj-xyz");
  });

  it("emits a Connect URI whose r= decodes to a parseable URL", async () => {
    await displayStartupBanner({
      version: "0.1.0",
      relayUrl: "ws://localhost:8374",
      identity: {
        deviceId: "test-id",
        deviceName: "test-device",
        createdAt: new Date().toISOString(),
      },
      mode: "agent",
      terminalCount: 1,
    });

    const output = logSpy.mock.calls.map((c: any[]) => c[0]).join("\n");
    const uriLines = output
      .split("\n")
      .filter((l: string) => l.startsWith("Connect URI"));
    expect(uriLines.length).toBeGreaterThan(0);
    for (const line of uriLines) {
      const url = line.slice(line.indexOf(":") + 1).trim();
      const r = new URL(url).searchParams.get("r");
      expect(r).toBeTruthy();
      const decoded = Buffer.from(r!, "base64url").toString("utf8");
      // The app takes r= verbatim whenever present (QrPayload.parse), so a
      // non-URL here is adopted as the relay URL instead of falling back.
      expect(() => new URL(decoded)).not.toThrow();
    }
  });

  it("emits no Connect URI when there is no relay URL", async () => {
    await displayStartupBanner({
      version: "0.1.0",
      relayUrl: null,
      identity: {
        deviceId: "test-id",
        deviceName: "test-device",
        createdAt: new Date().toISOString(),
      },
      mode: "agent",
      terminalCount: 1,
    });

    const output = logSpy.mock.calls.map((c: any[]) => c[0]).join("\n");
    expect(output).not.toContain("Connect URI");
    expect(output).not.toContain("Open the URI above");
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
      mode: "agent",
      projectPath: "/very/long/path/that/exceeds/the/maximum/display/width/for/banner",
    });

    const output = logSpy.mock.calls.map((c: any[]) => c[0]).join("\n");
    expect(output).toContain("...");
  });
});
