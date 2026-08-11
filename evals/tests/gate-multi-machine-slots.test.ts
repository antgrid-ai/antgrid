import { test, expect } from "bun:test";
import { relaySlotId } from "antgrid-wire";
import { setupTestEnv, generateAppIdentity, handshakeWithoutPairing } from "../helpers/harness";
import { RelayClient, type PhoneIdentity } from "../helpers/relay-client";
import { TestApp } from "../helpers/test-app";
import type { TestEnv } from "../helpers/harness";

/**
 * Failure-matrix row created by the relay-slot fix: an app's `hello.deviceId`
 * is now a per-machine SLOT
 * (`<accountDeviceUuid>#<machineDeviceUuid>`), so ONE account device (one
 * phone) can hold a live E2E session with TWO different bridges (two
 * machines) at once without either superseding the other. Unit coverage
 * exists on all four sides (antgrid-wire, relay/tests/connections.test.ts,
 * bridge/tests/handshake-pull.test.ts, the Dart relay client) but nothing
 * end-to-end — this needs a REAL relay with TWO real bridges live at once,
 * which only `evals/` can drive.
 *
 * Both envs share ONE relay (`setupTestEnv({ relay: envA.relay })`) — the
 * pre-fix bug was specifically the RELAY conflating two same-account
 * connections under one bare deviceId, so two separate relays would not
 * exercise it. Both envs' fake license APIs seed the SAME account device id
 * (`account`) under the SAME Ed25519 identity (`shared`) — each bridge only
 * ever consults its OWN `/account/devices/me/peers`, so this must be seeded
 * into BOTH `envA.license` and `envB.license` explicitly (a freshly-chosen
 * account id is otherwise unadmittable on either bridge — see the task
 * brief's hint on this).
 *
 * `addAccountDevice` here runs AFTER each env's agent already started (and
 * cached its startup inventory) — same miss-then-refresh dynamic as
 * `gate-inventory-miss.test.ts` — so connecting uses `handshakeWithoutPairing`
 * (retries on the SAME socket) rather than `TestApp.connect` (documented
 * single-shot; a bare attempt here would deterministically time out on the
 * first, pre-refresh, hello).
 */
async function seedSharedAccountDevice(
  envA: TestEnv,
  envB: TestEnv,
): Promise<{ account: string; identity: PhoneIdentity }> {
  const generated = await generateAppIdentity();
  const account = generated.deviceId;
  const identity: PhoneIdentity = generated;
  await envA.license.addAccountDevice({ deviceId: account, identity });
  await envB.license.addAccountDevice({ deviceId: account, identity });
  return { account, identity };
}

/** Connect `identity` to `env` under the per-machine slot
 *  `<account>#<machineDeviceId>`, retrying the E2E handshake on the SAME
 *  socket until the bridge's account-inventory refresh lands (see file
 *  header) — then wrap it as a `TestApp` for the shared assertion helpers. */
async function connectSlotted(
  env: TestEnv,
  identity: PhoneIdentity,
  account: string,
  machineDeviceId: string,
): Promise<TestApp> {
  const client = await RelayClient.connectAndAuth(env.relay.url, {
    deviceType: "app",
    name: "gate-multi-machine-slots-app",
    identity,
    deviceId: relaySlotId(account, machineDeviceId),
    transcriptDeviceId: account,
  });
  await handshakeWithoutPairing(client, env.agentDeviceId, env.agent.ed25519Pubkey);
  return TestApp.wrap(client, env);
}

test("one account device holds two machines at once — neither supersedes the other", async () => {
  const envA = await setupTestEnv({ fixtureName: "basic" });
  const envB = await setupTestEnv({ fixtureName: "basic", relay: envA.relay });
  let a: TestApp | undefined;
  let b: TestApp | undefined;
  try {
    const { account, identity } = await seedSharedAccountDevice(envA, envB);

    a = await connectSlotted(envA, identity, account, envA.agentDeviceId);
    b = await connectSlotted(envB, identity, account, envB.agentDeviceId);

    // Both sessions are independently live — the pre-slot bug would have had
    // B's hello (same bare deviceId as A, no slot) supersede A on the relay.
    expect((await a.waitForStateSnapshot()).ok).toBe(true);
    expect((await b.waitForStateSnapshot()).ok).toBe(true);

    // Each bridge registered the ACCOUNT device, not the slot it was reached
    // on (bridge/CLAUDE.md's relay-slot.ts note: everything account-keyed
    // base-strips the slot).
    expect(envA.agent.pairedPhones().map((p) => p.phoneDeviceId)).toContain(account);
    expect(envB.agent.pairedPhones().map((p) => p.phoneDeviceId)).toContain(account);

    // And a sibling slot naming the OTHER machine must not have repointed
    // this bridge's reply address or torn its session down — the same-account
    // presence fan-out reaches both agents with both slots (isForeignSlot).
    expect((await a.waitForStateSnapshot()).ok).toBe(true);

    await a.disconnect();
    await b.disconnect();
  } finally {
    await envB.teardown();
    await envA.teardown();
  }
}, 90_000);

/**
 * The guard on Task 4 (grants deletion): if the relay's account-wide revoke
 * loop (`connections.getByAccountDevice`) were ever collapsed back to a
 * single-device `getByDeviceId` lookup, revoking the account device would
 * close only ONE of the two machine slots and this test would fail on
 * whichever socket stayed open — a real, catchable failure, not a vacuous
 * pass on a lucky ordering.
 */
test("revoking the account device closes every machine's socket, not just one", async () => {
  const envA = await setupTestEnv({ fixtureName: "basic" });
  const envB = await setupTestEnv({ fixtureName: "basic", relay: envA.relay });
  let a: TestApp | undefined;
  let b: TestApp | undefined;
  try {
    const { account, identity } = await seedSharedAccountDevice(envA, envB);

    a = await connectSlotted(envA, identity, account, envA.agentDeviceId);
    b = await connectSlotted(envB, identity, account, envB.agentDeviceId);
    await a.waitForStateSnapshot();
    await b.waitForStateSnapshot();

    await envA.license.revokeDevice(account);

    const aClose = await a.waitClose(10_000);
    const bClose = await b.waitClose(10_000);
    expect(aClose.code).toBe(4002);
    expect(bClose.code).toBe(4002);
  } finally {
    await a?.disconnect();
    await b?.disconnect();
    await envB.teardown();
    await envA.teardown();
  }
}, 90_000);
