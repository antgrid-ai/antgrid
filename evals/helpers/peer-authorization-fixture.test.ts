import { expect, test } from "bun:test";
import { generateKeyPairSync, randomBytes, randomUUID } from "node:crypto";
import { EndpointEnrollment } from "../../bridge/src/peer/enrollment";
import { PeerAuthorizationFixture } from "./peer-authorization-fixture";

test("eval authority binds enrollment to a device credential and denies revoked snapshots", async () => {
  const ed = generateKeyPairSync("ed25519");
  const raw = (key: typeof ed.publicKey, type: "spki" | "pkcs8") => key.export({ format: "der", type }).subarray(-32).toString("base64");
  const auth = { clientId: "fixture-client", clientSecret: "secret", deviceUuid: randomUUID(), userId: "fixture-account", ed25519Pub: raw(ed.publicKey, "spki"), kind: "agent" as const };
  const peerEd = generateKeyPairSync("ed25519");
  const peer = { deviceId: randomUUID(), ed25519Pub: raw(peerEd.publicKey, "spki") };
  const peerAuth = { clientId: "fixture-peer", clientSecret: "peer-secret", deviceUuid: peer.deviceId,
    userId: auth.userId, ed25519Pub: peer.ed25519Pub, kind: "app" as const };
  const authority = new PeerAuthorizationFixture(() => [peer]);
  authority.provision(auth);
  authority.provision(peerAuth);
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
    const peerToken = authority.token(`Basic ${Buffer.from("fixture-peer:peer-secret").toString("base64")}`)!;
    const peerEnrollment = new EndpointEnrollment({ accountId: auth.userId, deviceId: peer.deviceId,
      enrollmentId: peerAuth.clientId }, randomBytes(32).toString("base64"), raw(peerEd.privateKey, "pkcs8"),
      "https://fixture.invalid", () => peerToken, request);
    await peerEnrollment.register();
    const withEndpoint = await enrollment.authorization() as any;
    expect(withEndpoint.peers[0]?.endpoint?.endpointId).toBe(peerEnrollment.endpointId);
    peerEnrollment.close();
    authority.revoke(peer.deviceId);
    expect((await enrollment.authorization() as any).peers).toEqual([]);
    authority.revoke(auth.deviceUuid);
    const denied = await enrollment.authorization() as any;
    expect(denied.allowed).toBe(false);
    expect(denied.endpoint).toBeNull();
    expect(denied.leaseMs).toBe(0);
  } finally { enrollment.close(); }
});

test("eval authority serves the machine directory and captures bus keys, agents only", async () => {
  const pub = () => randomBytes(32).toString("base64");
  const mk = (id: string, kind: "agent" | "app" = "agent") => ({ clientId: `c-${id}`, clientSecret: "s", deviceUuid: randomUUID(),
    userId: "acct", ed25519Pub: pub(), kind });
  const self = mk("self"), other = mk("other"), gone = mk("gone"), app = mk("app", "app");
  const authority = new PeerAuthorizationFixture(() => []);
  for (const c of [self, other, gone, app]) authority.provision(c);
  const tokens = new Map<string, string>();
  const bearer = (c: typeof self) => {
    if (!tokens.has(c.clientId)) tokens.set(c.clientId, authority.token(`Basic ${Buffer.from(`${c.clientId}:s`).toString("base64")}`)!);
    return { authorization: `Bearer ${tokens.get(c.clientId)}` };
  };
  // Tokens are minted before the revoke: a revoked credential cannot mint one.
  for (const c of [self, other, gone, app]) bearer(c);
  const get = async (c: typeof self) => (await authority.handle(new Request("https://f.invalid/account/devices/me/machines", { headers: bearer(c) })))!;
  const key = pub();
  const post = async (c: typeof self, body: unknown) => (await authority.handle(new Request("https://f.invalid/account/devices/me/bus-key",
    { method: "POST", headers: bearer(c), body: JSON.stringify(body) })))!;
  expect((await post(other, { busPublicKey: key })).status).toBe(200);
  expect((await post(other, { busPublicKey: "short" })).status).toBe(400);
  expect(authority.busKeyOf(other.deviceUuid)).toBe(key);
  authority.setOrchestrator(self.deviceUuid, true);
  authority.setBusControl(other.deviceUuid, true);
  authority.revoke(gone.deviceUuid);
  const dir = await (await get(self)).json() as any;
  expect(dir.self).toEqual({ busPublicKey: null, orchestrator: true, busControl: false });
  expect(dir.machines).toHaveLength(1);
  expect(dir.machines[0]).toMatchObject({ deviceId: other.deviceUuid, busPublicKey: key, orchestrator: false, busControl: true, machineName: null });
  expect((await get(app)).status).toBe(403);
  expect((await post(app, { busPublicKey: key })).status).toBe(403);
  expect((await get(gone)).status).toBe(401);
});

test("eval authority serves session-bus grants lower-only and refuses a raise", async () => {
  const mk = (id: string, kind: "agent" | "app") => ({ clientId: `c-${id}`, clientSecret: "s", deviceUuid: randomUUID(),
    userId: "acct", ed25519Pub: randomBytes(32).toString("base64"), kind });
  const agent = mk("agent", "agent"), app = mk("app", "app");
  const authority = new PeerAuthorizationFixture(() => []);
  authority.provision(agent);
  authority.provision(app);
  const bearer = (c: typeof agent) => ({ authorization: `Bearer ${authority.token(`Basic ${Buffer.from(`${c.clientId}:s`).toString("base64")}`)!}` });
  const call = async (c: typeof agent, method: string, body?: unknown) => (await authority.handle(new Request(
    "https://f.invalid/account/devices/me/session-bus",
    { method, headers: bearer(c), body: body === undefined ? undefined : JSON.stringify(body) })))!;
  authority.setOrchestrator(agent.deviceUuid, true);
  authority.setBusControl(agent.deviceUuid, true);
  expect(await (await call(agent, "GET")).json()).toEqual({ orchestrator: true, busControl: true });
  const raise = await call(agent, "POST", { orchestrator: true });
  expect(raise.status).toBe(403);
  expect(await raise.json()).toEqual({ error: "OWNER_SESSION_REQUIRED" });
  for (const bad of [{}, { orchestrator: "no" }, { other: false }]) {
    const refused = await call(agent, "POST", bad);
    expect(refused.status).toBe(400);
    expect(await refused.json()).toEqual({ error: "BAD_REQUEST" });
  }
  expect(await (await call(agent, "POST", { orchestrator: false })).json()).toEqual({ orchestrator: false, busControl: true });
  expect(await (await call(agent, "GET")).json()).toEqual({ orchestrator: false, busControl: true });
  expect((await call(app, "GET")).status).toBe(403);
  expect((await call(app, "POST", { busControl: false })).status).toBe(403);
});
