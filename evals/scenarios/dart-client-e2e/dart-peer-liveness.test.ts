import { test, expect } from "bun:test";
import { setupDartTestEnv, waitForHostFile } from "../../helpers/harness";
import { PEER_QUIC_MAX_IDLE_TIMEOUT_MS } from "antgrid-wire";

/**
 * The bridge never pings, so a Dart app that vanishes with no
 * CONNECTION_CLOSE (a hard kill, not a graceful exit) is retired only when
 * QUIC's own idle timeout fires. napi-to-napi timing cannot stand in for this:
 * it needs a REAL Dart VM on the other end of the connection.
 */
test("the bridge retires a hard-killed Dart app on QUIC idle", async () => {
  const env = await setupDartTestEnv({ fixtureName: "basic", clientName: "eval-dart-app" });
  try {
    await env.app.waitForAgentStatus(env.streamId, 10_000);

    const t0 = Date.now();
    await env.app.hardKill();

    const hostFile = await waitForHostFile(env.abDir);
    const deadline = Date.now() + 75_000;
    let elapsed: number | null = null;
    while (elapsed === null && Date.now() < deadline) {
      const res = await fetch(`http://127.0.0.1:${hostFile.controlPort}/netwatch?limit=500&follow=0`, {
        headers: { authorization: `Bearer ${hostFile.token}` },
      });
      const text = await res.text();
      for (const record of parseNetwatchRecords(text)) {
        if (
          record.msgType === "peer:native-retired" &&
          record.detail?.reason === "connection-lost" &&
          typeof record.at === "number" &&
          record.at > t0
        ) {
          elapsed = record.at - t0;
          break;
        }
      }
      if (elapsed === null) await Bun.sleep(500);
    }
    if (elapsed === null) throw new Error("no peer:native-retired record observed within 75s of the hard kill");

    // Report the measured number rather than loosen the bound: the >= 20s
    // side was only ever measured napi<->napi, so a Dart<->napi result below
    // it is evidence, not noise to hide.
    console.log(`dart-peer-liveness: retired ${elapsed}ms after hardKill()`);
    expect(elapsed).toBeGreaterThanOrEqual(20_000);
    expect(elapsed).toBeLessThanOrEqual(PEER_QUIC_MAX_IDLE_TIMEOUT_MS + 15_000);
  } finally {
    await env.teardown();
  }
}, 90_000);

/** Splits a `/netwatch` SSE body into its JSON records, dropping the
 *  `event: replayed`/`event: shed` metadata blocks (which carry no `msgType`
 *  and would otherwise be indistinguishable from a capture record once
 *  parsed). */
function parseNetwatchRecords(sseText: string): Array<Record<string, any>> {
  const records: Array<Record<string, any>> = [];
  for (const block of sseText.split("\n\n")) {
    if (!block.trim() || block.includes("event: ")) continue;
    const line = block.split("\n").find((l) => l.startsWith("data: "));
    if (!line) continue;
    try {
      records.push(JSON.parse(line.slice("data: ".length)));
    } catch {
      // Skip a malformed block rather than fail the whole poll.
    }
  }
  return records;
}
