// E2E control-plane tool discovery (Task I2):
//   Prove that an account-trusted app RECEIVES `agent:tools` over a real relay
//   handshake, on the control plane, WITHOUT opening any per-project data-plane
//   session.
//
// Why this eval exists: the bridge unit tests use FakeAgentTransport (keys always
// present) and so never exercise the real E2E key-establishment timing over a
// relay transport. `agent:tools` is in REPLAY_TYPES (welcome-replay) and is
// re-emitted on re-advertise; this is the ONLY test that closes the
// delivery-timing risk by asserting a paired app actually receives the frame.
//
// `agent:tools` is MACHINE-LEVEL — it is not a project verb, so the Phase B
// allowlist gate does NOT apply. The phone receives it on handshake-complete
// without any `allowProject`. We therefore assert ONLY on `agent:tools` to keep
// the test focused and avoid the allowlist trap. The agent-under-test may or may
// not have a real KNOWN_AGENTS bin on PATH, so we assert the frame ARRIVES with
// an array payload rather than a specific tool being present.
//
// Known Windows test noise (NOT failures): fs.watch EPERM/EBUSY on teardown,
// temp-dir cleanup races. Judge by pass/fail counts.
import { test, expect } from "bun:test";
import { setupTestEnv } from "../helpers/harness";

test("control plane delivers agent:tools to an account-trusted app over a real relay handshake", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  try {
    // setupTestEnv already paired ONCE against the control plane (bare
    // deviceUuid) with NO pairing ceremony and completed the E2E handshake. No
    // per-project data plane is ever opened — discovery must happen on the
    // control plane.

    // Pull the control-plane snapshot (re-emits agent:tools) rather than racing
    // the de-duped live handshake push (v3 MessageBus payload-equality dedup).
    await env.app.pullStateSnapshot();
    const toolsAdvert = await env.app.waitForAbType("agent:tools", 10_000);

    expect(toolsAdvert.type).toBe("agent:tools");
    expect(Array.isArray((toolsAdvert as any).tools)).toBe(true);
    // Each entry, when present, is { tool, path } — sanity-check the shape
    // without requiring any specific tool to be installed on the test machine.
    for (const t of (toolsAdvert as any).tools) {
      expect(typeof t.tool).toBe("string");
      expect(typeof t.path).toBe("string");
    }
  } finally {
    await env.teardown();
  }
}, 120_000);
