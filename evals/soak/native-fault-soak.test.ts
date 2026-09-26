import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { createMessage } from "../../bridge/src/protocol";
import { allocatePort, setupTestEnv, startRelay } from "../helpers/harness";
import { TestApp } from "../helpers/test-app";
import { firstProjectStream } from "../support/stream";

const durationMs = Number(process.env.ANTGRID_NATIVE_SOAK_DURATION_MS ?? 30 * 60_000);
const seed = Number(process.env.ANTGRID_NATIVE_SOAK_SEED ?? 0x41c6ce57) >>> 0;

function randomSource(initial: number): () => number {
  let state = initial || 1;
  return () => {
    state ^= state << 13;
    state ^= state >>> 17;
    state ^= state << 5;
    return state >>> 0;
  };
}

async function waitForNoConnections(read: () => number): Promise<void> {
  for (let attempt = 0; attempt < 50; attempt++) {
    if (read() === 0) return;
    await Bun.sleep(100);
  }
  throw new Error(`stale relay sessions/admissions after cleanup: ${read()}`);
}

test("seeded loopback native fault soak releases ownership and never duplicates mutations", async () => {
  const relay = await startRelay({ port: allocatePort() });
  const random = randomSource(seed);
  const owned = new Set<number>();
  const startedAt = Date.now();
  Bun.gc(true); // force a full collection first — an uncollected sender-side buffer would otherwise inflate the baseline itself
  const initialRss = process.memoryUsage().rss;
  let cycle = 0;
  let rssDelta = 0;
  try {
    do {
      const current = cycle++;
      const env = await setupTestEnv({ fixtureName: "basic", relay });
      owned.add(current);
      try {
        const app = await TestApp.connect(env);
        const streamId = await firstProjectStream(env.app, env.projectId, 10_000);
        const marker = `${seed}:${current}`;
        const terminalId = `soak-${current}`;
        env.app.sendOnStream(streamId, createMessage("terminal:start", {
          terminalId,
          name: terminalId,
          command: "node",
          args: ["-e", `require("fs").appendFileSync("native-soak.log", "${marker}\\n")`],
        }));
        await env.app.waitForStreamAbType(streamId, "terminal:exited", 10_000);

        const fault = random() % 3;
        if (fault === 0) {
          env.app.dropSocket();
          await env.app.waitForClose(2_000);
          await app.waitForStateSnapshot();
        } else if (fault === 1) {
          env.app.dropNative();
          await env.app.reconnectNative();
          await env.app.performE2EHandshake(env.agentDeviceId, 10_000);
          await app.waitForStateSnapshot();
        } else {
          await env.restartAgent();
          await app.recoverStateSnapshot({ timeoutMs: 30_000 });
        }

        const lines = readFileSync(join(env.projectDir, "native-soak.log"), "utf8")
          .split(/\r?\n/)
          .filter(Boolean);
        expect(lines.filter((line) => line === marker)).toHaveLength(1);
      } finally {
        await env.teardown();
        owned.delete(current);
      }
      await waitForNoConnections(() => relay.connectionCount());
      expect(owned.size).toBe(0);
      Bun.gc(true); // same reason as the baseline: without it, GC timing noise dwarfs a real per-cycle leak
      rssDelta = process.memoryUsage().rss - initialRss;
      expect(rssDelta).toBeLessThan(128 * 1024 * 1024);
    } while (Date.now() - startedAt < durationMs);
    console.info(`native soak: ${cycle} cycles, final RSS delta ${rssDelta} bytes`);
  } finally {
    relay.stop();
  }
}, durationMs + 120_000);
