import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { allocatePort, startRelay, type RelayHandle } from "../helpers/harness";
import { CentralTestClient } from "../helpers/central-test-client";

/** Epoch arbitration stays on the central control plane. Bridge restart and
 * native recovery are covered independently by gate-bridge-restart.test.ts. */
describe("gate: epoch supersession — relay arbitration", () => {
  let relay: RelayHandle;

  beforeAll(async () => {
    relay = await startRelay({ port: allocatePort() });
  });

  afterAll(() => {
    relay.stop();
  });

  test("higher epoch supersedes: old connection gets SUPERSEDED, new one is admitted", async () => {
    const deviceId = crypto.randomUUID();
    const identityClient = await CentralTestClient.connectAndAuth(relay.url, {
      deviceType: "agent",
      name: "epoch-a",
      deviceId,
      epoch: 100,
    });
    const identity = identityClient.exportIdentity();

    const closeP = identityClient.waitForClose(5_000);
    const errorP = identityClient.waitFor((m: any) => m.type === "error", 5_000);

    const newer = await CentralTestClient.connectAndAuth(relay.url, {
      deviceType: "agent",
      name: "epoch-b",
      deviceId,
      identity,
      epoch: 200,
    });

    const errFrame = await errorP;
    expect(errFrame.code).toBe("SUPERSEDED");
    expect(errFrame.retryable).toBe(false);
    expect(await closeP).toBe(true);

    // The new (higher-epoch) connection stays live and usable.
    expect(await newer.waitForClose(1_000)).toBe(false);
    await newer.disconnect();
  }, 15_000);

  test("equal epoch under the same identity admits: a redial evicts its own zombie", async () => {
    const deviceId = crypto.randomUUID();
    // The half-open scenario: the client's watchdog closed this socket and
    // redialed with the SAME per-process epoch, but the relay hasn't reaped
    // the old connection yet (equal-epoch rule).
    const zombie = await CentralTestClient.connectAndAuth(relay.url, {
      deviceType: "agent",
      name: "epoch-zombie",
      deviceId,
      epoch: 300,
    });
    const identity = zombie.exportIdentity();
    const zombieCloseP = zombie.waitForClose(5_000);
    const zombieErrP = zombie.waitFor((m: any) => m.type === "error", 5_000);

    const redial = await CentralTestClient.connectAndAuth(relay.url, {
      deviceType: "agent",
      name: "epoch-redial",
      deviceId,
      identity,
      epoch: 300,
    });

    const errFrame = await zombieErrP;
    expect(errFrame.code).toBe("SUPERSEDED");
    expect(await zombieCloseP).toBe(true);

    // The redial is the live holder and stays usable.
    expect(await redial.waitForClose(1_000)).toBe(false);
    await redial.disconnect();
  }, 15_000);

  test("lower epoch is rejected: a stale process cannot displace a newer one", async () => {
    const deviceId = crypto.randomUUID();
    const current = await CentralTestClient.connectAndAuth(relay.url, {
      deviceType: "agent",
      name: "epoch-current",
      deviceId,
      epoch: 500,
    });
    const identity = current.exportIdentity();

    // A stale hello with a LOWER epoch must itself be rejected+closed, and the
    // CURRENT (higher-epoch) connection must be undisturbed.
    let staleRejected = false;
    try {
      await CentralTestClient.connectAndAuth(relay.url, {
        deviceType: "agent",
        name: "epoch-stale",
        deviceId,
        identity,
        epoch: 499,
      });
    } catch {
      staleRejected = true;
    }
    expect(staleRejected).toBe(true);
    expect(await current.waitForClose(1_500)).toBe(false);
    await current.disconnect();
  }, 15_000);
});
