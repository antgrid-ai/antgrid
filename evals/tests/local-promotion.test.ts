import { afterAll, beforeAll, expect, test } from "bun:test";
import { startRelay, startFakeLicenseApi, TEST_LICENSE_TOKEN, type RelayHandle, type FakeLicenseApi } from "../helpers/harness";
import { setupLocalTestEnv, type LocalTestEnv } from "../helpers/local-test-env";
import { createMessage, type AbMessage } from "../../bridge/src/protocol";

let relay: RelayHandle;
let local: LocalTestEnv;
let licenseApi: FakeLicenseApi;

beforeAll(async () => {
  // Pick a random port to dodge collisions with long-running dev processes
  // (e.g. an attached flutter dart.exe holding the global allocator's range).
  const port = 19_000 + Math.floor(Math.random() * 1_000);
  relay = await startRelay({ port });
  // v3 promotion resolves the machine remote runtime (token maintenance +
  // account-peer fetch) over a web base — supply a fake one via enableRelay's
  // licenseApiUrl so those fetches succeed.
  licenseApi = startFakeLicenseApi();
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

test("agent:enableRelay promotes: pairingReady emitted, local channel intact", async () => {
  const seen: AbMessage[] = [];
  local.client.on((m) => seen.push(m));

  local.client.send(
    createMessage("agent:enableRelay", {
      relayUrl: relay.url.replace(/\/ws$/, ""),
      licenseApiUrl: licenseApi.url,
      auth: {
        deviceUuid: local.promo.deviceUuid,
        ed25519Pub: local.promo.ed25519Pub,
        ed25519Priv: local.promo.ed25519Priv,
        licenseToken: TEST_LICENSE_TOKEN,
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

  // pairingReady lands almost immediately, well before a freshly-spawned PTY
  // has echoed anything — wait for both signals under one deadline so the
  // "OK" assertion below isn't racing the shell.
  const deadline = Date.now() + 8_000;
  const sawOutput = () => seen.some((m) => m.type === "terminal:output" && m.data.includes("OK"));
  while (
    Date.now() < deadline &&
    (!seen.some((m) => m.type === "agent:pairingReady") || !sawOutput())
  ) {
    await Bun.sleep(100);
  }

  expect(seen.filter((m) => m.type === "agent:relayError")).toEqual([]);
  const ready = seen.find((m) => m.type === "agent:pairingReady");
  expect(ready).toBeDefined();

  const outputs = seen
    .filter((m): m is Extract<AbMessage, { type: "terminal:output" }> => m.type === "terminal:output")
    .map((m) => m.data)
    .join("");
  expect(outputs).toContain("OK");

  local.client.send(createMessage("agent:disableRelay", {}));
  await Bun.sleep(300);
}, 20_000);
