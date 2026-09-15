import { afterAll, beforeAll, expect, test } from "bun:test";
import { startRelay, startFakeLicenseApi, generateEvalAuth, TEST_LICENSE_TOKEN, type RelayHandle, type FakeLicenseApi } from "../helpers/harness";
import { setupLocalTestEnv, type LocalTestEnv } from "../helpers/local-test-env";
import { createMessage, type AbMessage } from "../../bridge/src/protocol";
import { TERMINAL_PROTOCOL_VERSION } from "../../bridge/src/terminal-frames/protocol";

let relay: RelayHandle;
let local: LocalTestEnv;
let licenseApi: FakeLicenseApi;
const auth = generateEvalAuth();

beforeAll(async () => {
  // Pick a random port to dodge collisions with long-running dev processes
  // (e.g. an attached flutter dart.exe holding the global allocator's range).
  const port = 19_000 + Math.floor(Math.random() * 1_000);
  relay = await startRelay({ port });
  // v3 promotion resolves the machine remote runtime (token maintenance +
  // account-peer fetch) over a web base — supply a fake one via enableRelay's
  // licenseApiUrl so those fetches succeed.
  licenseApi = startFakeLicenseApi();
  licenseApi.provision(auth);
  local = await setupLocalTestEnv({
    licenseToken: TEST_LICENSE_TOKEN,
    relayUrl: relay.url.replace(/\/ws$/, ""),
  });
});

afterAll(async () => {
  await local.cleanup();
  relay.stop();
  licenseApi.stop();
});

test("agent:enableRelay promotes: relayReady emitted, local channel intact", async () => {
  const seen: AbMessage[] = [];
  local.client.on((m) => {
    seen.push(m);
    if (m.type === "terminal:started") local.client.send(createMessage("terminal:subscribe", {
      terminalId: m.terminalId, version: TERMINAL_PROTOCOL_VERSION, requestId: "promotion-terminal",
    }));
    if (m.type === "terminal:frame") local.client.send(createMessage("terminal:ack", {
      terminalId: m.terminalId, runId: m.runId, attachmentId: m.attachmentId, sequence: m.sequence,
    }));
  });

  local.client.send(
    createMessage("agent:enableRelay", {
      relayUrl: relay.url.replace(/\/ws$/, ""),
      licenseApiUrl: licenseApi.url,
      auth: {
        deviceUuid: auth.deviceUuid,
        ed25519Pub: auth.ed25519Pub,
        ed25519Priv: auth.ed25519Priv,
        userId: auth.userId,
        endpointSecret: auth.endpointSecret,
        clientId: auth.clientId,
        clientSecret: auth.clientSecret,
      },
    }),
  );

  // Concurrent: drive the local channel to prove promotion doesn't disrupt it.
  local.client.send(
    createMessage("terminal:start", {
      terminalId: "t1",
      command: process.platform === "win32" ? "cmd.exe" : "bash",
      args: process.platform === "win32" ? ["/c", "echo OK"] : ["-c", "echo OK"],
      cwd: local.folder,
    }),
  );

  // relayReady lands almost immediately, well before a freshly-spawned PTY
  // has echoed anything — wait for both signals under one deadline so the
  // "OK" assertion below isn't racing the shell.
  const deadline = Date.now() + 8_000;
  const sawOutput = () => seen.some((m) => m.type === "terminal:frame" && m.ansi.includes("OK"));
  while (
    Date.now() < deadline &&
    (!seen.some((m) => m.type === "agent:relayReady") || !sawOutput())
  ) {
    await Bun.sleep(100);
  }

  expect(seen.filter((m) => m.type === "agent:relayError")).toEqual([]);
  const ready = seen.find((m) => m.type === "agent:relayReady");
  expect(ready).toBeDefined();

  const outputs = seen
    .filter((m): m is Extract<AbMessage, { type: "terminal:frame" }> => m.type === "terminal:frame")
    .map((m) => m.ansi)
    .join("");
  expect(outputs).toContain("OK");

  local.client.send(createMessage("agent:disableRelay", {}));
  await Bun.sleep(300);
}, 20_000);
