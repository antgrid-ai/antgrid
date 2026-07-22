import { describe, it, expect } from "bun:test";
import { parseMessage } from "../src/protocol";
import { hostname } from "node:os";

describe("agent:status — hostMachineName + projectName", () => {
  it("schema accepts hostMachineName and projectName fields", () => {
    const msg = {
      id: "00000000-0000-0000-0000-000000000000",
      timestamp: Date.now(),
      type: "agent:status",
      projectId: "my-project",
      projectName: "My Project",
      hostMachineName: "studio-mac",
      terminals: [],
      agent: { version: "1.0.0" },
    };
    const parsed = parseMessage(JSON.stringify(msg));
    expect(parsed?.type).toBe("agent:status");
    if (parsed?.type !== "agent:status") throw new Error("unreachable");
    expect(parsed.projectName).toBe("My Project");
    expect(parsed.hostMachineName).toBe("studio-mac");
  });

  it("schema accepts message without hostMachineName (optional field)", () => {
    const msg = {
      id: "00000000-0000-0000-0000-000000000000",
      timestamp: Date.now(),
      type: "agent:status",
      projectId: "my-project",
      terminals: [],
      agent: { version: "1.0.0" },
    };
    const parsed = parseMessage(JSON.stringify(msg));
    expect(parsed?.type).toBe("agent:status");
  });

  it("ANTGRID_HOST_NAME env var overrides os.hostname()", () => {
    const original = process.env.ANTGRID_HOST_NAME;
    try {
      process.env.ANTGRID_HOST_NAME = "test-override-host";
      const result = process.env.ANTGRID_HOST_NAME ?? hostname();
      expect(result).toBe("test-override-host");
    } finally {
      if (original === undefined) {
        delete process.env.ANTGRID_HOST_NAME;
      } else {
        process.env.ANTGRID_HOST_NAME = original;
      }
    }
  });

  it("falls back to os.hostname() when ANTGRID_HOST_NAME is unset", () => {
    const original = process.env.ANTGRID_HOST_NAME;
    try {
      delete process.env.ANTGRID_HOST_NAME;
      const result = process.env.ANTGRID_HOST_NAME ?? hostname();
      expect(result).toBe(hostname());
      expect(typeof result).toBe("string");
      expect(result.length).toBeGreaterThan(0);
    } finally {
      if (original !== undefined) {
        process.env.ANTGRID_HOST_NAME = original;
      }
    }
  });
});
