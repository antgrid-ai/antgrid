import { test, expect } from "bun:test";
import { setupTestEnv } from "../helpers/harness";
import { createMessage } from "../../bridge/src/protocol";

async function snapshotRoundTrip(env: Awaited<ReturnType<typeof setupTestEnv>>, label: string): Promise<void> {
  const requestId = `native-snapshot-${label}`;
  const response = env.app.waitFor(
    (message: any) => message.type === "response" && message.requestId === requestId,
    8_000,
  );
  env.app.sendEncrypted(createMessage("request", {
    requestId,
    method: "state.snapshot",
    params: { types: ["*"] },
  }));
  expect(((await response) as { ok?: boolean }).ok).toBe(true);
}

test("ordinary eval harness establishes an account-authorized native session", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  try {
    await snapshotRoundTrip(env, "initial");
    expect(env.relay.connectionCount()).toBe(2);
  } finally {
    await env.teardown();
  }
}, 30_000);

test("central socket loss does not interrupt a healthy native payload session", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  try {
    env.app.dropSocket();
    expect(await env.app.waitForClose(2_000)).toBe(true);
    await snapshotRoundTrip(env, "central-offline");
  } finally {
    await env.teardown();
  }
}, 30_000);