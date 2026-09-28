import { test, expect } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { setupDartTestEnv, waitForHostFile, type DartTestEnv } from "../helpers/harness";

/**
 * Native peer resume over the real Dart binding. A desktop reports every window
 * focus as a resume, so the host must refresh authorization without touching a
 * live `iroh_quic` peer: the same session and project stream keep serving.
 * Bridge-side resume is unit-tested against a mocked transport
 * (`native-host-connection.test.ts`); only a real Dart VM on the other end
 * catches a close the Dart binding would surface.
 */
async function hostPeerResume(env: DartTestEnv): Promise<void> {
  const hf = await waitForHostFile(env.abDir);
  const res = await fetch(`http://127.0.0.1:${hf.controlPort}/peer-resume`, {
    method: "POST",
    headers: { authorization: `Bearer ${hf.token}` },
  });
  expect(res.status).toBe(202);
}

test("a host resume keeps the Dart peer's session and project stream", async () => {
  const env = await setupDartTestEnv({ fixtureName: "basic", clientName: "eval-dart-resume" });
  try {
    for (let cycle = 0; cycle < 3; cycle++) {
      const proof = `resume:${cycle}`;
      writeFileSync(join(env.projectDir, "proof.txt"), proof);
      await hostPeerResume(env);
      const content = await env.app.requestFileContent(env.streamId, env.projectId, "proof.txt", 10_000);
      expect(content.data.content).toBe(proof);
    }
    await expect(env.app.waitForEvent(
      (e) => e.event === "stream-ended" && e.projectId === env.projectId, 2_000)).rejects.toThrow("Timed out");
  } finally {
    await env.teardown();
  }
}, 120_000);
