import { test, expect } from "bun:test";
import { startRelay, allocatePort } from "../helpers/harness";
import { RelayClient } from "../helpers/relay-client";

/**
 * v3 makes the license token MANDATORY for apps: the tokenless
 * legacy-QR registration path is deleted, and the hello schema requires
 * `licenseToken` (min length 1). A phone that presents an empty/absent token is
 * therefore not even a well-formed v3 hello — the relay rejects it terminally
 * with `PROTOCOL_VIOLATION` and closes the socket. This replaces the retired v2
 * "app pairs without a license token" scenario.
 */
test("app hello with an empty license token is terminally rejected (PROTOCOL_VIOLATION)", async () => {
  const relay = await startRelay({ port: allocatePort() });
  try {
    // An empty token fails the hello schema's `licenseToken: min(1)`, so the
    // relay closes the socket during auth → connectAndAuth rejects.
    await expect(
      RelayClient.connectAndAuth(relay.url, { deviceType: "app", licenseToken: "" }),
    ).rejects.toThrow(/PROTOCOL_VIOLATION|Closed during auth/);
  } finally {
    relay.stop();
  }
}, 15_000);
