import { test, expect } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { setupDartTestEnv, waitForHostFile, type DartTestEnv } from "../helpers/harness";

/**
 * Native peer resume over the real Dart binding: the bridge closes a live
 * `iroh_quic` peer on a host resume, and the Dart side must observe that close
 * and come back on the same endpoint identity. Bridge-side resume is
 * unit-tested against a mocked transport (`native-host-connection.test.ts`);
 * only a real Dart VM on the other end catches a close the Dart binding never
 * surfaces.
 */
async function hostPeerResume(env: DartTestEnv): Promise<void> {
  const hf = await waitForHostFile(env.abDir);
  const res = await fetch(`http://127.0.0.1:${hf.controlPort}/peer-resume`, {
    method: "POST",
    headers: { authorization: `Bearer ${hf.token}` },
  });
  expect(res.status).toBe(202);
}

test("a host resume closes the Dart peer, which re-establishes and reads fresh project state", async () => {
  const env = await setupDartTestEnv({ fixtureName: "basic", clientName: "eval-dart-resume" });
  try {
    for (let cycle = 0; cycle < 3; cycle++) {
      const proof = `resume:${cycle}`;
      writeFileSync(join(env.projectDir, "proof.txt"), proof);
      const ended = env.app.waitForEvent(
        (e) => e.event === "stream-ended" && e.projectId === env.projectId, 20_000);
      await hostPeerResume(env);
      await ended;
      const streamId = await env.reestablishPeer();
      const content = await env.app.requestFileContent(streamId, env.projectId, "proof.txt", 10_000);
      expect(content.data.content).toBe(proof);
    }
  } finally {
    await env.teardown();
  }
}, 120_000);
