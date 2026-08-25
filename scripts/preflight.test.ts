import { afterEach, expect, test } from "bun:test";
import { createServer, type Server } from "node:net";
import { checkPortOpen, formatPreflightSummary, hasCommand } from "./preflight";

let server: Server | undefined;

afterEach(() => {
  server?.close();
  server = undefined;
});

function listenOnEphemeralPort(): Promise<number> {
  return new Promise((resolvePromise, reject) => {
    server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server!.address();
      if (address === null || typeof address === "string") {
        reject(new Error("expected an AddressInfo"));
        return;
      }
      resolvePromise(address.port);
    });
  });
}

test("checkPortOpen resolves true when something is listening", async () => {
  const port = await listenOnEphemeralPort();
  expect(await checkPortOpen("127.0.0.1", port)).toBe(true);
});

test("checkPortOpen resolves false when nothing is listening", async () => {
  // Port 1 is privileged/unassigned in every CI sandbox this runs in.
  expect(await checkPortOpen("127.0.0.1", 1, 300)).toBe(false);
});

test("hasCommand finds a command that exists on PATH", () => {
  const probe = process.platform === "win32" ? "cmd" : "sh";
  expect(hasCommand(probe)).toBe(true);
});

test("hasCommand returns false for a command that doesn't exist", () => {
  expect(hasCommand("definitely-not-a-real-command-xyz")).toBe(false);
});

test("formatPreflightSummary reports an unreachable database and a missing runtime", () => {
  const lines = formatPreflightSummary(
    { postgresReachable: false, containerRuntime: null, flutterFound: false },
    "postgres://postgres:postgres@localhost:5432/antgrid",
  );
  expect(lines.some((l) => l.includes("NOT reachable"))).toBe(true);
  expect(lines.some((l) => l.includes("not found (a system Postgres works too)"))).toBe(true);
});

test("formatPreflightSummary reports a reachable database and a found runtime", () => {
  const lines = formatPreflightSummary(
    { postgresReachable: true, containerRuntime: "docker", flutterFound: true },
    "postgres://postgres:postgres@localhost:5432/antgrid",
  );
  expect(lines.some((l) => l.includes("reachable") && !l.includes("NOT"))).toBe(true);
  expect(lines.some((l) => l.includes("docker"))).toBe(true);
});
