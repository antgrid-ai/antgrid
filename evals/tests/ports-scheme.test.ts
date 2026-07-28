import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { setupTestEnv, type TestEnv } from "../helpers/harness";
import { createMessage } from "../../bridge/src/protocol";
import { firstProjectStream } from "../support/stream";

/**
 * E2E guard for scheme propagation in ports:update (agent → relay → app).
 * A dev server that only speaks HTTPS used to be advertised scheme-less, so
 * the app opened it over plain HTTP. The PortDetector now attaches the scheme
 * observed in terminal output URL sightings and re-emits the port list when a
 * sighting reveals it.
 */
describe("ports:update scheme propagation", () => {
  let env: TestEnv;
  let streamId: string;

  beforeAll(async () => {
    env = await setupTestEnv({ fixtureName: "basic" });
    streamId = await firstProjectStream(env.app, env.projectId, 10_000);
  }, 60_000);

  afterAll(async () => {
    await env?.teardown();
  });

  test("https URL in terminal output yields ports:update entry with scheme", async () => {
    env.app.sendOnStream(streamId, createMessage("terminal:start", {
      terminalId: "https-emitter",
      name: "https-emitter",
      command: "node",
      args: ["-e", "console.log('Local: https://localhost:8443/'); setTimeout(() => {}, 60000)"],
    }));
    await env.app.waitForStreamAbType(streamId, "terminal:started", 5_000);

    // ports:update may arrive more than once (line-feed detection first,
    // scheme-bearing re-emit after the URL sighting) — accept the first one
    // that carries the port WITH its scheme.
    const deadline = Date.now() + 15_000;
    let entry: { port: number; scheme?: string } | undefined;
    while (Date.now() < deadline) {
      let msg: any;
      try {
        msg = await env.app.waitForStreamAbType(streamId, "ports:update", 5_000);
      } catch {
        break;
      }
      const found = (msg.ports as { port: number; scheme?: string }[])
        .find((p) => p.port === 8443);
      if (found?.scheme) {
        entry = found;
        break;
      }
    }

    expect(entry).toBeDefined();
    expect(entry!.scheme).toBe("https");
  });
});
