import { test, expect } from "bun:test";
import { setupTestEnv, handshakeWithoutPairing } from "../helpers/harness";
import { RelayClient } from "../helpers/relay-client";
import { resolveOnFreshAdvert } from "../support/stream";
import { createMessage } from "../../bridge/src/protocol";

/**
 * Failure-matrix row for concurrent app sessions: ONE bridge now keeps an
 * established E2E session PER APP DEVICE, so a phone and a desktop app signed
 * into the same account drive the same machine at the same time. Before this,
 * the bridge held exactly one session and a second device's verified
 * client-hello displaced the first (sealed `session-takeover`, keys zeroized) —
 * the behaviour `gate-harness-pairfree.test.ts` used to pin.
 *
 * Unit coverage lives in `bridge/tests/handshake-pull.test.ts`, but only a real
 * relay plus a real bridge exercises the parts that unit tests stub: two
 * distinct account identities admitted from one inventory, per-session sealing
 * on one agent socket, and the relay's presence fan-out reaching a bridge that
 * now holds two live peers.
 *
 * The second device is added to the account inventory AFTER the agent's startup
 * fetch, so it connects via `handshakeWithoutPairing` (retries on the SAME
 * socket while the bridge's throttled inventory refresh lands) rather than
 * `TestApp.connect`, whose single-shot attempt would deterministically miss —
 * same dynamic as `gate-inventory-miss` / `gate-multi-machine-slots`.
 */

/** Round-trip the control-plane `state.snapshot` RPC and assert ok:true. Throws
 *  (via the `waitFor` timeout) if this device's session was torn down, or if
 *  the agent sealed the reply under some other device's keys. Deliberately not
 *  `pullStateSnapshot`, which resolves silently on a dead session. */
async function assertSnapshot(app: RelayClient, label: string): Promise<void> {
  const requestId = `gate-two-devices-${label}`;
  const responseP = app.waitFor((m: any) => m.type === "response" && m.requestId === requestId, 8_000);
  app.sendEncrypted(createMessage("request", { requestId, method: "state.snapshot", params: { types: ["*"] } }));
  const res = (await responseP) as { ok?: boolean };
  expect(res.ok).toBe(true);
}

/** Count `session-takeover` frames this client has decrypted. Reads the
 *  message QUEUE rather than arming a `waitFor` up front: a waiter covers only
 *  its own timeout window, whereas the queue holds anything that ever arrived
 *  for the whole life of the test. */
function takeoversSeen(app: RelayClient): number {
  return app.drainQueued("session-takeover");
}

test("two app devices hold concurrent sessions with one bridge, and neither displaces the other", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  let app2: RelayClient | undefined;
  try {
    // A SECOND account device: its own Ed25519 identity, its own bare deviceId,
    // so it addresses a relay connection distinct from env.app's (no slot
    // needed — the two are already different account devices).
    const second = await env.license.addAccountDevice();
    app2 = await RelayClient.connectAndAuth(env.relay.url, {
      deviceType: "app",
      name: "gate-two-devices-app2",
      identity: second,
      deviceId: second.deviceId,
    });
    await handshakeWithoutPairing(app2, env.agentDeviceId, env.agent.ed25519Pubkey);

    // Both apps plus the agent are live on the relay before anything is
    // asserted about fan-out.
    const deadline = Date.now() + 10_000;
    while (Date.now() < deadline && env.relay.connectionCount() < 3) await Bun.sleep(100);
    expect(env.relay.connectionCount()).toBeGreaterThanOrEqual(3);

    // (2) BOTH devices get answers on their OWN keys. app1's is the load-bearing
    // half: pre-wave-1 its session was zeroized the moment app2 was admitted,
    // so this RPC would never be answered.
    await assertSnapshot(env.app, "app1-after-app2-joins");
    await assertSnapshot(app2, "app2-first");

    // (3) One bus publish fans out to both sessions, sealed once per device.
    // Both resolve the SAME streamId — a stream is a project namespace, not a
    // device route — so `terminal:started`, published once on that project's
    // bus, must reach both.
    const streamId = await resolveOnFreshAdvert(env.app, env.projectId);
    const streamIdForApp2 = await resolveOnFreshAdvert(app2, env.projectId);
    expect(streamIdForApp2).toBe(streamId);

    const terminalId = `gate-two-devices-${Date.now()}`;
    const startedOnApp1 = env.app.waitForStreamAbType(streamId, "terminal:started", 15_000);
    const startedOnApp2 = app2.waitForStreamAbType(streamId, "terminal:started", 15_000);
    env.app.sendOnStream(
      streamId,
      createMessage("terminal:start", {
        terminalId,
        name: terminalId,
        command: "node",
        args: ["-e", "setTimeout(() => {}, 5000)"],
      }),
    );
    expect((await startedOnApp1).terminalId).toBe(terminalId);
    expect((await startedOnApp2).terminalId).toBe(terminalId);

    // (5) A same-device rekey is still make-before-break and still scoped to
    // the rekeying device: app2's session must not so much as flinch.
    await env.app.rekey(env.agentDeviceId, env.agent.ed25519Pubkey);
    await assertSnapshot(app2, "app2-after-app1-rekey");
    await assertSnapshot(env.app, "app1-after-own-rekey");

    // (1) Nothing was displaced, on either side, at any point above. Checked
    // for app2 here, while it is still connected.
    expect(takeoversSeen(app2)).toBe(0);
    expect(takeoversSeen(env.app)).toBe(0);
    expect(env.app.isClosed).toBe(false);
    expect(app2.isClosed).toBe(false);

    // (4) One device leaving is not the machine going offline: app2's
    // `peer-offline` must not suppress the surviving session's stream.
    await app2.disconnect();
    app2 = undefined;
    await Bun.sleep(500);
    await assertSnapshot(env.app, "app1-after-app2-left");
    expect(takeoversSeen(env.app)).toBe(0);
  } finally {
    await app2?.disconnect();
    await env.teardown();
  }
}, 120_000);
