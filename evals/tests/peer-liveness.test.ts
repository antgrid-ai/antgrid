import { test, expect } from "bun:test";
import { setupTestEnv } from "../helpers/harness";

/**
 * QUIC keep-alive/idle is what detects a dead peer, so the bridge sends a
 * live-but-idle app nothing at all on the session stream. No unit test can
 * see this: it needs a real wall-clock idle window on a real session stream,
 * long enough (45s) that a bridge ping on a 20s silence threshold swept every
 * 20s would have fired.
 */
test("the bridge never pings an idle app, and still pongs", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  try {
    await Bun.sleep(45_000);
    expect(env.app.sessionFrameTypes()).not.toContain("session:ping");

    const rtMs = await env.app.ping();
    expect(rtMs).toBeGreaterThanOrEqual(0);
  } finally {
    await env.teardown();
  }
}, 70_000);
