import { expect, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { setupDartTestEnv, waitForHostFile } from "../helpers/harness";
import { createTestProject } from "../helpers/fixtures";
import { computeProjectId } from "../../bridge/src/project-id";

test("host resume restores Dart E2E and both project streams without a client redial", async () => {
  const env = await setupDartTestEnv({ fixtureName: "basic" });
  const second = createTestProject("basic", { "__RELAY_URL__": env.relay.url });
  try {
    const host = await waitForHostFile(env.abDir);
    const headers = { authorization: `Bearer ${host.token}`, "content-type": "application/json" };
    const origin = `http://127.0.0.1:${host.controlPort}`;
    const secondId = computeProjectId(second.dir);
    const opened = await fetch(`${origin}/control`, { method: "POST", headers,
      body: JSON.stringify({ id: "open-second", type: "project:open", projectId: secondId,
        projectPath: second.dir, mode: "remote" }) });
    expect((await opened.json() as { ok: boolean }).ok).toBe(true);
    const secondStream = await env.app.openProjectStream(secondId);
    const projects = [
      { id: env.projectId, dir: env.projectDir, stream: env.streamId },
      { id: secondId, dir: second.dir, stream: secondStream },
    ];
    for (const project of projects) {
      await env.app.requestFileContent(project.stream, project.id, "README.md", 5_000);
    }
    const latencies: number[] = [];
    for (let cycle = 0; cycle < 3; cycle++) {
      const started = performance.now();
      expect((await fetch(`${origin}/peer-resume`, { method: "POST", headers })).status).toBe(202);
      // Allow the normal central reconnect jitter, but stay far below the E2E
      // liveness timeout that used to be the only signal of the erased keys.
      await Bun.sleep(1_500);
      for (const project of projects) {
        const proof = `${project.id}:resume:${cycle}`;
        writeFileSync(join(project.dir, "resume-proof.txt"), proof);
        const content = await env.app.requestFileContent(project.stream, project.id, "resume-proof.txt", 5_000);
        expect(content.data.content).toBe(proof);
      }
      latencies.push(performance.now() - started);
      expect(env.relay.connectionCount()).toBe(2);
    }
    console.log(JSON.stringify({ resumeRecoveryMs: latencies, projects: projects.length,
      client: "real-Dart", host: "real", transport: "websocket", authorization: "fixture" }));
  } finally {
    await env.teardown();
    second.cleanup();
  }
}, 90_000);
