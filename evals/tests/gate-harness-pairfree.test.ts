import { test, expect } from "bun:test";
import { setupTestEnv } from "../helpers/harness";
import { TestApp } from "../helpers/test-app";
import { createMessage } from "../../bridge/src/protocol";

test("TestApp.connect drives a full session without ever sending a pair-request", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  const sent: string[] = [];
  try {
    const app = await TestApp.connect(env, { onOutbound: (raw) => sent.push(raw) });
    // Session is real: `waitForStateSnapshot` throws if the RPC never answers
    // ok:true, unlike `pullStateSnapshot`, which silently swallows a dead
    // session.
    await app.waitForStateSnapshot();
    const types = sent.map((s) => {
      try {
        return JSON.parse(s).type;
      } catch {
        return "";
      }
    });
    // Positive control: proves the `onOutbound` tap is actually live on the
    // send path (a hello always goes out), so the negative assertion below
    // isn't passing vacuously over an empty `sent`.
    expect(types).toContain("hello");
    // And nothing pairing-shaped left the socket. `pair-request`/`pair-approval`
    // are no longer even wire-parseable types (antgrid-wire deleted the
    // schemas) — TestApp/RelayClient could not construct one if they tried,
    // so this checks the same invariant the type system now also enforces:
    // no code path on this connect flow attempts to send a pairing frame.
    expect(types.some((t) => t.startsWith("pair-"))).toBe(false);
    await app.disconnect();
  } finally {
    await env.teardown();
  }
}, 30_000);

test("TestApp.connect(env) neither SUPERSEDED-closes env.app's socket nor ends its E2E session", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  try {
    // A second connection against the SAME env, using the default options —
    // the exact call shape `waitAgentReachable` (evals/support/reachable.ts)
    // and any other throwaway-probe caller uses. Before the relay-slot fix
    // this hello'd as the SAME bare deviceId env.app already holds a socket
    // under, with a strictly higher epoch (evals/helpers/relay-client.ts's
    // `nextEpoch`) — the second hello always won at relay/src/server.ts
    // (`connections.remove(existing)` + a SUPERSEDED close on env.app). The
    // default-slotted hello now addresses a DISTINCT relay connection, so
    // env.app's own WebSocket must survive.
    const second = await TestApp.connect(env);
    try {
      expect(env.app.isClosed).toBe(false);
      // Give any in-flight close a moment to land, then confirm it didn't:
      // `waitForClose` resolving `false` means the socket is still open.
      const closedWithinWindow = await env.app.waitForClose(500);
      expect(closedWithinWindow).toBe(false);

      // The socket surviving is NOT the same as the E2E session surviving,
      // and the two used to diverge here: the bridge held exactly one
      // established session and treated the second slot's signed hello as a
      // competing phone, so it sealed env.app a `session-takeover` and
      // zeroized its keys. A bridge now keeps one session PER APP DEVICE, so
      // both halves must hold — the probe is additive.
      //
      // Asserted with a direct RPC round trip rather than
      // `pullStateSnapshot`, which catches its own timeout and resolves
      // anyway: a dead session has to actually fail this.
      const requestId = "pairfree-probe-survivor";
      const responseP = env.app.waitFor(
        (m: any) => m.type === "response" && m.requestId === requestId,
        8_000,
      );
      env.app.sendEncrypted(
        createMessage("request", { requestId, method: "state.snapshot", params: { types: ["*"] } }),
      );
      expect(((await responseP) as { ok?: boolean }).ok).toBe(true);

      // And the displacement frame itself never left the bridge. Read off the
      // message queue, which holds everything decrypted since connect, so
      // this covers the whole window rather than one waiter's timeout.
      expect(env.app.drainQueued("session-takeover")).toBe(0);
    } finally {
      await second.disconnect();
    }
  } finally {
    await env.teardown();
  }
}, 30_000);
