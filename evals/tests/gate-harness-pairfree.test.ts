import { test, expect } from "bun:test";
import { setupTestEnv } from "../helpers/harness";
import { TestApp } from "../helpers/test-app";

test("TestApp.connect drives a full session without ever sending a pair-request", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  const sent: string[] = [];
  try {
    const app = await TestApp.connect(env, { onOutbound: (raw) => sent.push(raw) });
    // Session is real: `waitForStateSnapshot` throws if the RPC never answers
    // ok:true, unlike `pullStateSnapshot` (used in the next test in this file)
    // which silently swallows a dead session.
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

test("TestApp.connect(env) does not trigger the relay's SUPERSEDED-close on env.app's socket, but DOES end env.app's E2E session via the bridge's single-active-phone takeover", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  try {
    // Arm the waiter BEFORE the second connect: `session-takeover` is sent by
    // the bridge the moment it admits the second slot's client-hello, which
    // can land before `TestApp.connect` below even resolves.
    const takeoverP = env.app.waitFor((m: any) => m.type === "session-takeover", 5_000);

    // A second connection against the SAME env, using the default options —
    // the exact call shape `waitAgentReachable` (evals/support/reachable.ts)
    // and any other throwaway-probe caller uses. Before the fix this hello'd
    // as the SAME bare deviceId env.app already holds a socket under, with a
    // strictly higher epoch (evals/helpers/relay-client.ts's `nextEpoch`) —
    // the second hello always wins at relay/src/server.ts:307-312
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

      // The positive half: the relay socket surviving is NOT the same as the
      // E2E session surviving. The bridge holds exactly one established
      // session (bridge/src/relay-client.ts:1128) and treats the second
      // slot's signed hello as a competing phone regardless of relay
      // routing, so it sends env.app a sealed `session-takeover` and
      // zeroizes env.app's keys (:1146-1151) — chosen over asserting a dead
      // `pullStateSnapshot` round trip because that helper swallows a timeout
      // silently (`RelayClient.pullStateSnapshot` catches and returns on no
      // response), so a timeout-based assertion would prove nothing without
      // first patching around that swallow. Observing the frame itself is
      // the direct, un-papered-over signal of the mechanism firing.
      const takeover = await takeoverP;
      expect(takeover.type).toBe("session-takeover");
    } finally {
      await second.disconnect();
    }
  } finally {
    await env.teardown();
  }
}, 30_000);
