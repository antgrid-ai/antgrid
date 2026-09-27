import { expect, test } from "bun:test";
import { endpointKey, startIrohAuthorizationHarness } from "../support/iroh-authorization";

test("Iroh authorization: real HTTP device OAuth, signed enrollment, peer inventory, rotation and revocation", async () => {
  const harness = await startIrohAuthorizationHarness();
  try {
    const owner = await harness.user();
    const machine = await harness.provision(owner.cookie, "agent");
    const app = await harness.provision(owner.cookie, "app");
    const attacker = await harness.provision((await harness.user()).cookie, "app");
    const machineProof = await harness.challenge(machine);
    const appProof = await harness.challenge(app);
    const registrationPath = "/account/devices/me/endpoint-registration";
    expect((await harness.request(registrationPath, { token: attacker.token, body: machineProof.body })).status).toBe(409);
    expect((await harness.request(registrationPath, { token: app.token, body: machineProof.body })).status).toBe(409);
    expect((await harness.request(registrationPath, { token: machine.token, body: {
      ...machineProof.body, endpointSignature: Buffer.alloc(64).toString("base64"),
    } })).status).toBe(403);
    expect((await harness.request(registrationPath, { token: machine.token, body: machineProof.body })).status).toBe(200);
    expect((await harness.request(registrationPath, { token: machine.token, body: machineProof.body })).status).toBe(409);
    expect((await harness.request(registrationPath, { token: app.token, body: appProof.body })).status).toBe(200);
    expect((await harness.request("/account/devices/me/heartbeat", { token: machine.token,
      body: { deviceUuid: machine.deviceId, mobileAccessEnabled: true } })).status).toBe(200);
    const authorized = await harness.snapshot(app);
    expect(authorized.accountId).toBe(owner.userId);
    expect(authorized.enrollmentId).toBe(app.clientId);
    expect(authorized.allowed).toBe(true);
    expect(authorized.leaseMs).toBeGreaterThan(0);
    expect(authorized.leaseMs).toBeLessThanOrEqual(60_000);
    expect(authorized.relayUrls).toEqual(["https://iroh.staging.example/"]);
    expect(authorized.peers).toEqual([{ deviceId: machine.deviceId, ed25519Pub: machine.publicKey,
      endpoint: { endpointId: machineProof.endpoint.endpointId, generation: "1" } }]);
    expect((await harness.snapshot(attacker)).peers).toEqual([]);

    const rotated = await harness.challenge(machine, endpointKey(), "1");
    expect((await harness.request(registrationPath, { token: machine.token, body: rotated.body })).status).toBe(200);
    const newer = await harness.snapshot(app);
    expect(BigInt(newer.policyGeneration)).toBeGreaterThan(BigInt(authorized.policyGeneration));
    expect(newer.peers[0].endpoint).toEqual({ endpointId: rotated.endpoint.endpointId, generation: "2" });
    expect((await harness.db.peerEndpointRegistration.findUniqueOrThrow({
      where: { endpointId: machineProof.endpoint.endpointId },
    })).revokedAt).not.toBeNull();
    const reused = await harness.challenge(attacker, machineProof.endpoint);
    expect((await harness.request(registrationPath, { token: attacker.token, body: reused.body })).status).toBe(409);

    const devicesResponse = await harness.request("/account/devices", { cookie: owner.cookie });
    const inventory = await devicesResponse.json() as { devices: { id: string; device_id: string }[] };
    const deviceRow = inventory.devices.find((device) => device.device_id === machine.deviceId)!;
    expect((await harness.request(`/account/devices/${deviceRow.id}`, { cookie: owner.cookie, method: "DELETE" })).status).toBe(200);
    expect((await harness.request("/account/devices/me/authorization", { token: machine.token })).status).toBe(401);
    expect((await harness.snapshot(app)).peers).toEqual([]);
    expect((await harness.db.peerEndpointRegistration.findUniqueOrThrow({ where: { endpointId: rotated.endpoint.endpointId } })).revokedAt).not.toBeNull();
    expect(await harness.db.peerAuthorizationOutbox.count({ where: { userId: owner.userId, deliveredAt: null } })).toBeGreaterThan(0);
  } finally { await harness.stop(); }
}, 30_000);
