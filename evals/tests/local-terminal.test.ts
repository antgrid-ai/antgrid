import { afterAll, beforeAll, expect, test } from "bun:test";
import { setupLocalTestEnv, type LocalTestEnv } from "../helpers/local-test-env";
import { createMessage } from "../../bridge/src/protocol";
import { TERMINAL_PROTOCOL_VERSION } from "../../bridge/src/terminal-frames/protocol";
import { writeFileSync } from "node:fs";
import { join } from "node:path";

let env: LocalTestEnv;
beforeAll(async () => { env = await setupLocalTestEnv(); });
afterAll(async () => { await env.cleanup(); });

test("local: terminal start + input + output", async () => {
  const outputs: string[] = [];
  let inputSent = false;
  writeFileSync(join(env.folder, "echo.cjs"), "process.stdin.once('data', data => { console.log('LOCAL_ECHO:' + data.toString().trim()); process.exit(0); }); console.log('LOCAL_READY');");
  env.client.on((m) => {
    if (m.type === "terminal:started" && m.terminalId === "s1") env.client.send(createMessage("terminal:subscribe", {
      terminalId: "s1", version: TERMINAL_PROTOCOL_VERSION, requestId: "local-terminal",
    }));
    if (m.type === "terminal:frame" && m.terminalId === "s1") {
      outputs.push(m.ansi);
      env.client.send(createMessage("terminal:ack", {
        terminalId: m.terminalId, runId: m.runId, attachmentId: m.attachmentId, sequence: m.sequence,
      }));
      if (!inputSent && m.ansi.includes("LOCAL_READY")) {
        inputSent = true;
        env.client.send(createMessage("terminal:input", { terminalId: "s1", data: "HELLO\r" }));
      }
    }
  });

  env.client.send(createMessage("terminal:start", {
    terminalId: "s1",
    name: "s1",
    command: "node",
    args: ["echo.cjs"],
    cwd: env.folder,
  }));
  const deadline = Date.now() + 8000;
  while (Date.now() < deadline && !outputs.join("").includes("LOCAL_ECHO:HELLO")) await Bun.sleep(50);

  try { expect(outputs.join("")).toContain("LOCAL_ECHO:HELLO"); }
  finally { env.client.send(createMessage("terminal:stop", { terminalId: "s1" })); }
}, 15000);
