import { afterAll, beforeAll, expect, test } from "bun:test";
import { setupLocalTestEnv, type LocalTestEnv } from "../helpers/local-test-env";
import { createMessage } from "../../bridge/src/protocol";

let env: LocalTestEnv;
beforeAll(async () => { env = await setupLocalTestEnv(); });
afterAll(async () => { await env.cleanup(); });

test("local: terminal start + input + output", async () => {
  const outputs: string[] = [];
  env.client.on((m) => {
    if (m.type === "terminal:output") outputs.push((m as any).data);
  });

  // confirm is the E2E handshake tag — meaningless on the trusted local socket,
  // but the v3 schema requires it; agent-core only uses app:ready as a resync nudge.
  env.client.send(createMessage("app:ready", { confirm: "" }));
  await new Promise((r) => setTimeout(r, 500));

  env.client.send(createMessage("terminal:start", {
    terminalId: "s1",
    name: "s1",
    command: "node",
    args: ["-e", "console.log('HELLO')"],
    cwd: env.folder,
  }));
  await new Promise((r) => setTimeout(r, 3000));

  expect(outputs.join("")).toContain("HELLO");
});
