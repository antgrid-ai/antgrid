import { test, expect } from "bun:test";
import { generateKeyPairSync } from "node:crypto";
import { setupPairFlowTestEnv } from "../helpers/test-env";
import { TestApp } from "../helpers/test-app";

test("phone rejects pair-approval signed by wrong key", async () => {
  const env = await setupPairFlowTestEnv();
  try {
    const app = await TestApp.connect(env);
    const evilKp = generateKeyPairSync("ed25519");
    await expect(
      app.injectForgedApproval(env.agent.deviceId, evilKp),
    ).rejects.toThrow(/signature/i);
    await app.disconnect();
  } finally {
    await env.teardown();
  }
}, 30_000);
