import { test, expect } from "bun:test";
import { setupPairFlowTestEnv } from "../helpers/test-env";
import { TestApp } from "../helpers/test-app";

test("UNKNOWN_PHONE: stranger phone with no pairCode is rejected", async () => {
  const env = await setupPairFlowTestEnv();
  try {
    // Open the pairing window only to confirm the agent's local API is up;
    // then poll the relay-side pair-request until the agent is AUTHENTICATED
    // so we get the agent's UNKNOWN_PHONE reject instead of an early
    // AGENT_OFFLINE close from the relay.
    await env.agent.openPairingWindow();
    let lastReason = "";
    for (let i = 0; i < 50; i++) {
      const probe = await TestApp.connect(env);
      const r = await probe.tryPairRequest(env.agent.deviceId);
      await probe.disconnect();
      if (!r.paired) {
        lastReason = r.reason;
        if (/UNKNOWN_PHONE/.test(r.reason)) {
          expect(r.reason).toMatch(/UNKNOWN_PHONE/);
          return;
        }
      }
      await Bun.sleep(100);
    }
    throw new Error(`never observed UNKNOWN_PHONE — last reason: ${lastReason}`);
  } finally {
    await env.teardown();
  }
}, 30_000);

test("PAIRING_WINDOW_CLOSED: pair-request with a wrong pairCode (window not consumed)", async () => {
  const env = await setupPairFlowTestEnv();
  try {
    // Any pairCode presented on the bare-deviceUuid control plane that doesn't
    // consume a window is rejected PAIRING_WINDOW_CLOSED. (v3: the control-plane
    // pairing window has no eval open-hook — the /test/open-pairing-window route
    // opens the per-project AgentCore window, which the machine control plane
    // never consults — so no eval-presented code ever matches. The reject reason
    // for "a code that consumes no window" is still PAIRING_WINDOW_CLOSED.)
    // Poll past the startup race: until the agent authenticates to the relay,
    // the relay itself answers AGENT_OFFLINE before the agent can reject.
    let lastReason = "";
    for (let i = 0; i < 50; i++) {
      const app = await TestApp.connect(env);
      const result = await app.tryPairRequest(env.agent.deviceId, { pairCode: "wrong-code" });
      await app.disconnect();
      expect(result.paired).toBe(false);
      if (!result.paired) {
        lastReason = result.reason;
        if (!/AGENT_OFFLINE/.test(result.reason)) {
          expect(result.reason).toMatch(/PAIRING_WINDOW_CLOSED/);
          return;
        }
      }
      await Bun.sleep(100);
    }
    throw new Error(`never observed PAIRING_WINDOW_CLOSED — last reason: ${lastReason}`);
  } finally {
    await env.teardown();
  }
}, 30_000);

test("AGENT_OFFLINE: pair-request to an unknown agent registration id", async () => {
  const env = await setupPairFlowTestEnv();
  try {
    const app = await TestApp.connect(env);
    const result = await app.tryPairRequest("missing-agent");
    expect(result.paired).toBe(false);
    if (!result.paired) {
      expect(result.reason).toMatch(/AGENT_OFFLINE/);
    }
    await app.disconnect();
  } finally {
    await env.teardown();
  }
}, 30_000);
