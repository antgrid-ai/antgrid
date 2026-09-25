// Stage A concurrency gate: a dedicated terminal stream and a project stream
// share one native connection but not one send/receive loop, so a large
// transfer on the project stream must not stall the terminal stream sitting
// beside it (docs/iroh-reduction/stage-A-A5-contract.md §6, "A7"). Deviation
// D-6: a single `file:read` cannot itself reach 32MB (file-tree.ts's 10MB
// binary cap, ~13.3MB base64), so the load stimulus is three back-to-back
// reads of one file, not one oversize read.
import { test, expect } from "bun:test";
import { createHash, randomBytes } from "node:crypto";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { setupTestEnv } from "../helpers/harness";
import { createMessage } from "../../bridge/src/protocol";
import { TERMINAL_PROTOCOL_VERSION } from "../../bridge/src/terminal-frames/protocol";
import type { RelayClient, TerminalStreamClient } from "../helpers/relay-client";

const TICKER_INTERVAL_MS = 100;
const BASELINE_MS = 3_000;
const BIG_FILE_BODY_BYTES = 10_000_000;
const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const LOAD_WINDOW_MIN_STAMP_MS = 500;
const LOAD_MAX_LATENCY_MS = 2_000;
const LOAD_P95_SLACK_MS = 750;

async function startTerminal(
  app: RelayClient, streamId: string, terminalId: string, command: string, args: string[],
): Promise<void> {
  app.sendOnStream(streamId, createMessage("terminal:start", { terminalId, name: terminalId, command, args }));
  await app.waitFor(
    (m: any) => m.type === "terminal:started" && m._streamId === streamId && m.terminalId === terminalId,
    5_000,
  );
}

/** Cleanup only — a missing ENDED must never fail the row (mirrors the other
 *  terminal-stream gates' identical helper). */
async function stopTerminal(app: RelayClient, streamId: string, terminalId: string): Promise<void> {
  app.sendOnStream(streamId, createMessage("terminal:stop", { terminalId }));
  await app.waitFor(
    (m: any) => m.type === "terminal:display:status" && m._streamId === streamId &&
      m.terminalId === terminalId && m.code === "ENDED",
    10_000,
  ).catch(() => {});
}

function ackOnStream(client: TerminalStreamClient, frame: any): Promise<void> {
  return client.send(createMessage("terminal:ack", {
    terminalId: frame.terminalId, runId: frame.runId, attachmentId: frame.attachmentId, sequence: frame.sequence,
  }));
}

async function attachTerminalStream(
  app: RelayClient, projectId: string, terminalId: string,
): Promise<TerminalStreamClient> {
  const requestId = crypto.randomUUID();
  const client = await app.openTerminalStream({ projectId, requestId });
  await client.send(createMessage("terminal:subscribe", { terminalId, version: TERMINAL_PROTOCOL_VERSION, requestId }));
  await client.next((r) => r.type === "terminal:subscribed" && r.requestId === requestId);
  return client;
}

/** The screen is a cumulative VT render, so every frame carries every stamp
 *  still on-screen; the newest one is what dates that frame's arrival. */
function latestStamp(ansi: unknown): number | null {
  const text = String(ansi ?? "");
  let latest: number | null = null;
  for (const match of text.matchAll(/T(\d+)/g)) {
    const value = Number(match[1]);
    if (latest === null || value > latest) latest = value;
  }
  return latest;
}

function percentile(valuesMs: number[], p: number): number {
  const sorted = [...valuesMs].sort((a, b) => a - b);
  const idx = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
  return sorted[idx]!;
}

test("a terminal stream keeps delivering low-latency stamps while a large file transfers on the project stream", async () => {
  let bigFileSha = "";
  const env = await setupTestEnv({
    fixtureName: "basic",
    prepareProject: (dir) => {
      const body = randomBytes(BIG_FILE_BODY_BYTES);
      const bytes = Buffer.concat([PNG_SIGNATURE, body]);
      bigFileSha = createHash("sha256").update(bytes).digest("hex");
      writeFileSync(join(dir, "big.png"), bytes);
    },
  });
  const terminalId = "latency-under-transfer";
  try {
    await startTerminal(env.app, env.streamId, terminalId, "node", [
      "-e", `setInterval(() => process.stdout.write('T' + Date.now() + '\\n'), ${TICKER_INTERVAL_MS});`,
    ]);
    const client = await attachTerminalStream(env.app, env.projectId, terminalId);

    // Both ends drain independently for the whole test: this loop never
    // pauses to let the project-stream transfer below run undisturbed.
    const samples: Array<{ at: number; latencyMs: number }> = [];
    let draining = true;
    const drain = (async () => {
      while (draining) {
        const frame = await client.next((r) => r.type === "terminal:frame", 500).catch(() => null);
        if (!frame) continue;
        const receivedAt = Date.now();
        await ackOnStream(client, frame);
        const stamp = latestStamp(frame.ansi);
        if (stamp !== null) samples.push({ at: receivedAt, latencyMs: receivedAt - stamp });
      }
    })();

    await Bun.sleep(BASELINE_MS);
    const baselineEnd = Date.now();
    const baselineLatencies = samples.filter((s) => s.at <= baselineEnd).map((s) => s.latencyMs);
    expect(baselineLatencies.length).toBeGreaterThan(0);
    const baselineP95 = percentile(baselineLatencies, 95);

    const loadStart = Date.now();
    for (let i = 0; i < 3; i++) {
      env.app.sendOnStream(env.streamId, createMessage("file:read", { projectId: env.projectId, path: "big.png" }));
    }
    const replies = await Promise.all(
      Array.from({ length: 3 }, () =>
        env.app.waitFor(
          (m: any) => m._streamId === env.streamId && m.type === "file:content" && m.path === "big.png",
          30_000,
        )),
    );
    const loadEnd = Date.now();

    for (const reply of replies) {
      expect(reply.error).toBeUndefined();
      expect(reply.encoding).toBe("base64");
      const decoded = Buffer.from(reply.content ?? "", "base64");
      expect(createHash("sha256").update(decoded).digest("hex")).toBe(bigFileSha);
    }

    draining = false;
    await drain;

    const loadWindowMs = loadEnd - loadStart;
    const loadLatencies = samples.filter((s) => s.at >= loadStart && s.at <= loadEnd).map((s) => s.latencyMs);
    if (loadWindowMs > LOAD_WINDOW_MIN_STAMP_MS) {
      expect(loadLatencies.length).toBeGreaterThan(0);
      expect(Math.max(...loadLatencies)).toBeLessThanOrEqual(LOAD_MAX_LATENCY_MS);
      expect(percentile(loadLatencies, 95)).toBeLessThanOrEqual(baselineP95 + LOAD_P95_SLACK_MS);
    }
    client.reset();
  } finally {
    await stopTerminal(env.app, env.streamId, terminalId);
    await env.teardown();
  }
}, 90_000);
