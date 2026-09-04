import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { getApiUrl, getTerminalId } from "../src/mcp/server";

const saved = {
  port: process.env.ANTGRID_API_PORT,
  dir: process.env.ANTGRID_DIR,
  terminal: process.env.ANTGRID_TERMINAL_ID,
};

function restore(
  key: "ANTGRID_API_PORT" | "ANTGRID_DIR" | "ANTGRID_TERMINAL_ID",
  value: string | undefined,
) {
  if (value === undefined) delete process.env[key];
  else process.env[key] = value;
}

afterEach(() => {
  restore("ANTGRID_API_PORT", saved.port);
  restore("ANTGRID_DIR", saved.dir);
  restore("ANTGRID_TERMINAL_ID", saved.terminal);
});

describe("getApiUrl", () => {
  test("names the loopback core from the port the spawn stamped", () => {
    process.env.ANTGRID_API_PORT = "51423";
    expect(getApiUrl()).toBe("http://127.0.0.1:51423");
  });

  test("reports no core when the port is unset", () => {
    delete process.env.ANTGRID_API_PORT;
    expect(getApiUrl()).toBeNull();
  });

  // An injected entry declares the port as `${ANTGRID_API_PORT}`; an agent that
  // never expands it delivers that literal, which must read as absent rather
  // than as a host.
  test("reports no core for an unexpanded variable reference", () => {
    process.env.ANTGRID_API_PORT = "${ANTGRID_API_PORT}";
    expect(getApiUrl()).toBeNull();
  });

  // The regression this file exists for: the loopback API is unauthenticated
  // and antgrid_run_command executes antgrid.yaml commands, so a port-file
  // fallback would hand command execution against the most-recently-started
  // core to any local process able to spawn this subcommand.
  test("never falls back to the api.port file", () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-mcp-port-"));
    try {
      writeFileSync(join(dir, "api.port"), "51423\n", "utf8");
      process.env.ANTGRID_DIR = dir;
      delete process.env.ANTGRID_API_PORT;
      expect(getApiUrl()).toBeNull();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

// The caller's session, and therefore its CHECKOUT: an isolated session shares
// its core's loopback API with main, so a tool call that names no terminal is
// answered out of main's tree.
describe("getTerminalId", () => {
  test("names the slot the spawn stamped", () => {
    process.env.ANTGRID_TERMINAL_ID = "term-7";
    expect(getTerminalId()).toBe("term-7");
  });

  test("names nothing when the slot is unset", () => {
    delete process.env.ANTGRID_TERMINAL_ID;
    expect(getTerminalId()).toBeUndefined();
  });

  test("names nothing for an unexpanded variable reference", () => {
    process.env.ANTGRID_TERMINAL_ID = "${ANTGRID_TERMINAL_ID}";
    expect(getTerminalId()).toBeUndefined();
  });
});
