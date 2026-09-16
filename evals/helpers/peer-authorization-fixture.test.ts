import { expect, test } from "bun:test";
import { generateKeyPairSync, randomBytes, randomUUID } from "node:crypto";
import { EndpointEnrollment } from "../../bridge/src/peer/enrollment";
import { PeerAuthorizationFixture } from "./peer-authorization-fixture";

test("eval authority binds enrollment to a device credential and denies revoked snapshots", async () => {
  const ed = generateKeyPairSync("ed25519");
  const raw = (key: typeof ed.publicKey, type: "spki" | "pkcs8") => key.export({ format: "der", type }).subarray(-32).toString("base64");
  const auth = { clientId: "fixture-client", clientSecret: "secret", deviceUuid: randomUUID(), userId: "fixture-account", ed25519Pub: raw(ed.publicKey, "spki") };
  const peer = { deviceId: randomUUID(), ed25519Pub: raw(generateKeyPairSync("ed25519").publicKey, "spki") };
  const authority = new PeerAuthorizationFixture(() => [peer]);
  authority.provision(auth);
  expect(authority.token(`Basic ${Buffer.from("fixture-client:wrong").toString("base64")}`)).toBeNull();
  const token = authority.token(`Basic ${Buffer.from("fixture-client:secret").toString("base64")}`)!;
  const claims = JSON.parse(Buffer.from(token.split(".")[1]!, "base64url").toString());
  expect(claims.tier).toBe("pro");
  expect(claims.exp).toBeGreaterThan(Date.now() / 1000);
  let registrationRequest: Request | undefined;
  const request = (async (input: string | URL | Request, init?: RequestInit) => {
    const req = new Request(input, init);
    if (req.url.endsWith("endpoint-registration")) registrationRequest = req.clone();
    return (await authority.handle(req))!;
  }) as typeof fetch;
  const enrollment = new EndpointEnrollment({ accountId: auth.userId, deviceId: auth.deviceUuid, enrollmentId: auth.clientId }, randomBytes(32).toString("base64"), raw(ed.privateKey, "pkcs8"), "https://fixture.invalid", () => token, request);
  try {
    expect((await request("https://fixture.invalid/account/devices/me/authorization", { headers: { authorization: "Bearer eval-license-token" } })).status).toBe(401);
    expect((await request("https://fixture.invalid/account/devices/me/authorization", { headers: { authorization: `Bearer ${token}.tampered` } })).status).toBe(401);
    await enrollment.register();
    expect((await authority.handle(registrationRequest!))!.status).toBe(403);
    const snapshot = await enrollment.authorization() as any;
    expect(snapshot.endpoint.endpointId).toBe(enrollment.endpointId);
    expect(snapshot.registrationGeneration).toBe("1");
    expect(snapshot.peers).toEqual([{ ...peer, endpoint: null }]);
    authority.revoke(peer.deviceId);
    expect((await enrollment.authorization() as any).peers).toEqual([]);
    authority.revoke(auth.deviceUuid);
    const denied = await enrollment.authorization() as any;
    expect(denied.allowed).toBe(false);
    expect(denied.endpoint).toBeNull();
    expect(denied.leaseMs).toBe(0);
  } finally { enrollment.close(); }
});
