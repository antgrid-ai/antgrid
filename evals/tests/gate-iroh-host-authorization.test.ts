import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Endpoint, EndpointAddr } from "@number0/iroh/index.js";
import { decodePeerFrame, encodePeerFrame } from "antgrid-wire";
import { HostServer } from "../../bridge/src/host-server";
import { PeerRecords } from "../../bridge/src/peer/records";
import { computeProjectId } from "../../bridge/src/project-id";
import { createMessage } from "../../bridge/src/protocol";
import { setLogLevel } from "../../bridge/src/logger";

import { test } from "bun:test";
import { startIrohAuthorizationHarness } from "../support/iroh-authorization";

// Central discovery is controlled; enrollment and payloads use real HTTP/QUIC.
test("real backend enrollment authorizes native host projects and revocation closes the pair", async () => {
  setLogLevel("fatal");
  const authorization = await startIrohAuthorizationHarness();
  try {
    const owner = await authorization.user();
    const machineDevice = await authorization.provision(owner.cookie, "agent");
    const appDevice = await authorization.provision(owner.cookie, "app");
    const asIdentity = (device: typeof machineDevice) => ({ id: device.deviceId, public: device.publicKey,
      secret: device.privateKey.export({ type: "pkcs8", format: "der" }).subarray(-32).toString("base64") });
    const machine = asIdentity(machineDevice);
    const phone = asIdentity(appDevice);
    const appProof = await authorization.challenge(appDevice);
    assert.equal((await authorization.request("/account/devices/me/endpoint-registration", {
      token: appDevice.token, body: appProof.body,
    })).status, 200);
    const endpointSecret = randomBytes(32);
    const appBuilder = Endpoint.builder();
    appBuilder.applyMinimal();
    appBuilder.secretKey(Array.from(appProof.endpoint.privateKey.export({ type: "pkcs8", format: "der" }).subarray(-32)));
    appBuilder.bindAddr("127.0.0.1:0");
    const app = await appBuilder.bind();
    assert.equal(app.id().toString(), appProof.endpoint.endpointId);
    const accountId = owner.userId;
    const enrollmentId = machineDevice.clientId;
    let centralOnline = true;
    let centralSocket: { close: () => void } | undefined;
    const backend = Bun.serve({ hostname: "127.0.0.1", port: 0,
      fetch(request, server) {
        if (request.headers.get("upgrade") === "websocket") {
          if (!centralOnline) return new Response(null, { status: 503 });
          return server.upgrade(request) ? undefined : new Response(null, { status: 400 });
        }
        return new Response(null, { status: 404 });
      },
      websocket: {
        open(ws) { centralSocket = ws; },
        message(ws, raw) {
          if (typeof raw !== "string") throw new Error("Payload unexpectedly used central WebSocket");
          const frame = JSON.parse(raw);
          if (frame.type === "hello") ws.send(JSON.stringify({ type: "welcome", deviceId: machine.id,
            epoch: frame.epoch, serverTime: new Date().toISOString() }));
          if (frame.type === "ping") ws.send(JSON.stringify({ type: "pong" }));
          // Stream admission is deliberately absent: native project readiness must
          // remain independent of a central WebSocket registration acknowledgement.
        },
      },
    });
    const root = mkdtempSync(join(tmpdir(), "antgrid-native-host-smoke-"));
    const previousDirectory = process.env.ANTGRID_DIR;
    process.env.ANTGRID_DIR = join(root, "state");
    const host = new HostServer({ remote: {
      relayUrl: `ws://127.0.0.1:${backend.port}`, licenseApiUrl: authorization.origin,
      identity: { deviceId: machine.id, deviceName: "native-host-smoke", createdAt: "",
        ed25519PublicKey: machine.public, ed25519PrivateKey: machine.secret },
      auth: { clientId: enrollmentId, clientSecret: machineDevice.clientSecret, deviceUuid: machine.id,
        userId: accountId, endpointSecret: endpointSecret.toString("base64") }, onAuthRevoked: () => {},
    }, remoteRuntimeFactory: async () => ({ maint: { getToken: () => machineDevice.token, stop: () => {} } }) });
    let records: PeerRecords | undefined;
    let connection: Awaited<ReturnType<Endpoint["connect"]>> | undefined;
    let timedOut = false;
    const timeout = setTimeout(() => { timedOut = true; void host.shutdown(); }, 55_000);
    try {
      await host.startControlPlane();
      await host.handleRemoteAccessVerb({ id: "enable", type: "mobile-access:set", enabled: true });
      const projects: { id: string; name: string }[] = [];
      for (const name of ["alpha", "beta"]) {
        const folder = join(root, name);
        mkdirSync(folder);
        writeFileSync(join(folder, "antgrid.yaml"), `name: ${name}\nagent:\n  tool: claude-code\n`);
        writeFileSync(join(folder, "proof.txt"), `${name}:native-host-proof`);
        const id = computeProjectId(folder);
        await host.open(id, folder, name === "alpha" ? "remote" : "local");
        projects.push({ id, name });
      }
      const endpoint = await until(() => (host as unknown as { controlPlaneRelay?: { peers?: { lifecycle?: { endpoint?: Endpoint } } } }).controlPlaneRelay?.peers?.lifecycle?.endpoint);
      assert.equal((await authorization.request("/account/devices/me/heartbeat", { token: machineDevice.token,
        body: { deviceUuid: machine.id, mobileAccessEnabled: true } })).status, 200);
      const appSnapshot = await authorization.snapshot(appDevice);
      const authorizedMachine = appSnapshot.peers.find((peer) => peer.deviceId === machine.id);
      assert.equal(authorizedMachine?.ed25519Pub, machine.public);
      assert.equal(authorizedMachine?.endpoint?.endpointId, endpoint.id().toString());
      assert.equal((await authorization.snapshot(machineDevice)).peers[0]?.endpoint?.endpointId, app.id().toString());
      const addresses = endpoint.boundSockets().filter((address) => address.startsWith("0.0.0.0:") || address.startsWith("127.0.0.1:"))
        .map((address) => address.replace("0.0.0.0:", "127.0.0.1:"));
      connection = await app.connect(new EndpointAddr(endpoint.id(), undefined, addresses), Array.from(Buffer.from("antgrid/peer/1")));
      const stream = await connection.openBi();
      records = new PeerRecords(stream, () => true, () => connection?.close(1n, []));
      const attemptId = randomUUID();
      const send = (value: object) =>
        records!.send(encodePeerFrame({ type: "message", channel: "control" }, Buffer.from(JSON.stringify(value), "utf8")));
      const read = async (predicate: (value: any) => boolean): Promise<any> => {
        for (;;) {
          const frame = decodePeerFrame(await records!.read());
          const value = JSON.parse(Buffer.from(frame.payload).toString("utf8"));
          const message = value.m ?? value;
          if (predicate(message)) return message;
        }
      };
      // QUIC/TLS between the endpoints the lease authorizes is the
      // confidentiality layer now — the hello is a plaintext frame the
      // bridge's lease re-check gates, not a signed transcript exchange.
      await send({ type: "session:hello", attemptId, capabilities: { checkoutRouting: true, pullsTree: true, terminalFramesV1: true } });
      await read((value) => value.type === "established" && value.attemptId === attemptId);
      const nativeConnectionId = connection.stableId();
      centralOnline = false;
      centralSocket?.close();
      for (const project of projects) {
        await send({ m: createMessage("project:start", { projectId: project.id }) });
        const ready = await read((value) => value.type === "stream-ready" && value.projectId === project.id);
        await send({ s: ready.streamId, m: createMessage("file:read", { projectId: project.id, path: "proof.txt" }) });
        const file = await read((value) => value.type === "file:content" && value.projectId === project.id);
        assert.equal(file.content, `${project.name}:native-host-proof`);
        assert.equal(connection.stableId(), nativeConnectionId);
      }
      const inventory = await (await authorization.request("/account/devices", { cookie: owner.cookie })).json() as {
        devices: { id: string; device_id: string }[] };
      const appRow = inventory.devices.find((device) => device.device_id === phone.id)!;
      const revokedAt = performance.now();
      assert.equal((await authorization.request(`/account/devices/${appRow.id}`, {
        cookie: owner.cookie, method: "DELETE",
      })).status, 200);
      assert.equal((await authorization.request("/account/devices/me/authorization", { token: appDevice.token })).status, 401);
      assert.equal((await authorization.snapshot(machineDevice)).peers.some((peer) => peer.deviceId === phone.id), false);
      await connection.closed();
      assert.equal(timedOut, false, "Revocation must close the pair without the test watchdog");
      const revocationLatencyMs = performance.now() - revokedAt;
      assert.ok(revocationLatencyMs < 60_000);
      const nativePeers = (host as unknown as { controlPlaneRelay: { peers: { nativePeers: Map<string, unknown> } } }).controlPlaneRelay.peers.nativePeers;
      assert.equal(nativePeers.size, 0);
      console.log(JSON.stringify({ result: "pass", authorization: "real-http-oauth-prisma", centralControl: "fixture",
        native: "real-direct-loopback", host: "real", e2e: "real", projects: projects.length,
        sharedConnection: true, centralOutage: true, revokedDeviceClosed: true, revocationLatencyMs }));
    } finally {
      clearTimeout(timeout);
      records?.close();
      await host.shutdown();
      await app.close();
      backend.stop(true);
      if (previousDirectory === undefined) delete process.env.ANTGRID_DIR; else process.env.ANTGRID_DIR = previousDirectory;
      rmSync(root, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
    }
  } finally { await authorization.stop(); }
}, 65_000);

async function until<T>(read: () => T | undefined | null): Promise<T> {
  for (let attempt = 0; attempt < 200; attempt++) {
    const result = read();
    if (result) return result;
    await Bun.sleep(25);
  }
  throw new Error("Native endpoint did not start");
}
