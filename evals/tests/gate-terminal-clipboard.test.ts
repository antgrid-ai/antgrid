import { expect, test } from "bun:test";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setupTestEnv, establishNativeSession } from "../helpers/harness";
import type { RelayClient } from "../helpers/relay-client";
import { firstProjectStream, streamSnapshot } from "../support/stream";
import { createMessage } from "../../bridge/src/protocol";
import { TERMINAL_PROTOCOL_VERSION } from "../../bridge/src/terminal-frames/protocol";

test("live PTY clipboard targets one authenticated viewer, conflicts fail closed, and payloads never replay", async () => {
  const scratch = await mkdtemp(join(tmpdir(), "antgrid-clipboard-eval-"));
  const rawLog = join(scratch, "pty.bin");
  const env = await setupTestEnv({ fixtureName: "basic", env: { ANTGRID_DEBUG_PTY_LOG: rawLog } });
  let second: RelayClient | undefined;
  const terminalId = "clipboard-eval";
  const text = "clipboard-only-秘密-🙂";
  const encoded = Buffer.from(text).toString("base64");
  try {
    const stream = await firstProjectStream(env.app, env.projectId, 15000);
    const identity = await env.license.addAccountDevice();
    second = await env.connectNativeApp({ identity, accountDeviceId: identity.deviceId, name: "clipboard-second" });
    await establishNativeSession(second, env.agentDeviceId, env.agent.ed25519Pubkey);
    await second.pullStateSnapshot();
    const otherStream = await firstProjectStream(second, env.projectId, 15000);
    env.app.sendOnStream(stream, createMessage("terminal:start", {
      terminalId, command: "node", args: ["-e",
        `process.stdin.setRawMode(true);process.stdout.write('CLIPBOARD-READY');process.stdin.on('data',()=>{process.stdout.write('\\x1b]52;c;${encoded}\\x07');process.stdout.write('INPUT-HANDLED');});`],
    }));
    await env.app.waitFor((m) => m.type === "terminal:started" && m.terminalId === terminalId);
    async function subscribe(app: RelayClient, id: string) {
      const requestId = crypto.randomUUID();
      app.sendOnStream(id, createMessage("terminal:subscribe", { terminalId, checkoutId: "main", version: TERMINAL_PROTOCOL_VERSION, clipboardVersion: 1, requestId }));
      const granted = await app.waitFor((m) => m.type === "terminal:subscribed" && m.requestId === requestId);
      expect(granted.clipboardVersion).toBe(1);
      const frame = await app.waitFor((m) => m.type === "terminal:frame" && m.terminalId === terminalId && m.attachmentId === granted.attachmentId && m.ansi.includes("CLIPBOARD-READY"));
      app.sendOnStream(id, createMessage("terminal:ack", { terminalId, checkoutId: "main", runId: frame.runId, attachmentId: frame.attachmentId, sequence: frame.sequence }));
      return { terminalId, checkoutId: "main", runId: granted.runId, attachmentId: granted.attachmentId };
    }
    const active = await subscribe(env.app, stream);
    const passive = await subscribe(second, otherStream);
    const requestId = crypto.randomUUID();
    // No wait between these sends: the claim must be resolved before PTY input.
    env.app.sendOnStream(stream, createMessage("terminal:clipboard:claim", { ...active, requestId }));
    env.app.sendOnStream(stream, createMessage("terminal:input", { terminalId, checkoutId: "main", data: "x" }));
    const granted = await env.app.waitFor((m) => m.type === "terminal:clipboard:claimed" && m.requestId === requestId);
    expect(granted.grant).toBeDefined();
    const write = await env.app.waitFor((m) => m.type === "terminal:clipboard:write" && m.terminalId === terminalId);
    const recordingSink = [Buffer.from(write.text, "base64").toString("utf8")];
    expect(recordingSink).toEqual([text]);
    expect(write.claimId).toBe(granted.grant.claimId);
    env.app.sendOnStream(stream, createMessage("terminal:clipboard:result", {
      ...active, claimId: write.claimId, epoch: write.epoch, eventId: write.eventId, outcome: "copied",
    }));
    expect(second.queuedCount((m) => m.type === "terminal:clipboard:write")).toBe(0);

    const conflictRequest = crypto.randomUUID();
    second.sendOnStream(otherStream, createMessage("terminal:clipboard:claim", { ...passive, requestId: conflictRequest }));
    second.sendOnStream(otherStream, createMessage("terminal:input", { terminalId, checkoutId: "main", data: "y" }));
    const conflict = await second.waitFor((m) => m.type === "terminal:clipboard:claimed" && m.requestId === conflictRequest);
    expect(conflict.reason).toBe("conflict");
    const revoked = await env.app.waitFor((m) => m.type === "terminal:clipboard:revoked" && m.claimId === write.claimId);
    expect(revoked.reason).toBe("conflict");
    await second.waitFor((m) => m.type === "terminal:frame" && m.terminalId === terminalId && m.ansi.includes("INPUT-HANDLEDINPUT-HANDLED"));
    expect(env.app.queuedCount((m) => m.type === "terminal:clipboard:write")).toBe(0);
    expect(second.queuedCount((m) => m.type === "terminal:clipboard:write")).toBe(0);
    env.app.sendOnStream(stream, createMessage("terminal:unsubscribe", active));
    await subscribe(env.app, stream);
    expect(env.app.queuedCount((m) => m.type === "terminal:clipboard:write")).toBe(0);
    const snapshot = await streamSnapshot(env.app, stream);
    expect(snapshot.some((m) => m.type.startsWith("terminal:clipboard:"))).toBe(false);
    const logged = await readFile(rawLog, "utf8");
    expect(logged).not.toContain(encoded);
    expect(logged).not.toContain(text);
    env.app.sendOnStream(stream, createMessage("terminal:stop", { terminalId }));
  } finally {
    await second?.disconnect();
    await env.teardown();
    await rm(scratch, { recursive: true, force: true });
  }
}, 60000);
