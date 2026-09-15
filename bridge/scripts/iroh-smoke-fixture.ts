import assert from "node:assert/strict";
import { generateKeyPairSync, randomBytes, randomUUID } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Endpoint } from "@number0/iroh/index.js";
import { HostServer } from "../src/host-server";
import { computeProjectId } from "../src/project-id";
import { setLogLevel } from "../src/logger";

// Shared host side of the native transport smokes. HTTP authorization and
// central authentication are fixtures; the native endpoint, HostServer, E2E and
// project services run their production implementations. The app role differs
// per gate — `@number0/iroh` in iroh-host-smoke, real Dart `IrohPeerLink` in
// iroh-interop-smoke — so it is deliberately NOT part of this module.

export interface SmokeDevice {
  id: string;
  public: string;
  secret: string;
}

export function device(): SmokeDevice {
  const pair = generateKeyPairSync("ed25519");
  return {
    id: randomUUID(),
    public: pair.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("base64"),
    secret: pair.privateKey.export({ type: "pkcs8", format: "der" }).subarray(-32).toString("base64"),
  };
}

/** Derive the endpoint id the host will present, without holding its endpoint open. */
export async function endpointIdFor(secret: Buffer): Promise<string> {
  const builder = Endpoint.builder();
  builder.applyMinimal();
  builder.secretKey(Array.from(secret));
  const temporary = await builder.bind();
  const id = temporary.id().toString();
  await temporary.close();
  return id;
}

export interface SmokeFixtureOptions {
  /** Native endpoint the app dials from; the host authorizes only this one. */
  appEndpointId: string;
  /** App's Ed25519 identity. Its secret stays with whoever drives the app role. */
  app: { id: string; public: string };
  label: string;
  projectNames?: string[];
}

export interface SmokeFixture {
  machine: SmokeDevice;
  projects: { id: string; name: string }[];
  root: string;
  host: HostServer;
  /** Resolves once the host's native endpoint is listening. */
  nativeAddress(): Promise<{ endpointId: string; addresses: string[] }>;
  /** Drops the central WebSocket; native payload paths must survive this. */
  takeCentralOffline(): void;
  dispose(): Promise<void>;
}

export async function startSmokeFixture(options: SmokeFixtureOptions): Promise<SmokeFixture> {
  // Host logs are noise in a passing run and the only diagnosis in a failing
  // one, since the native peer reports nothing about why the host dropped it.
  setLogLevel((process.env.IROH_SMOKE_LOG_LEVEL as Parameters<typeof setLogLevel>[0]) ?? "fatal");
  const machine = device();
  const endpointSecret = randomBytes(32);
  const machineEndpointId = await endpointIdFor(endpointSecret);
  const accountId = `${options.label}-account`;
  const enrollmentId = `${options.label}-credential`;
  const snapshot = {
    accountId, deviceId: machine.id, enrollmentId, policyGeneration: "1", registrationGeneration: "1",
    allowed: true, leaseMs: 60_000, endpoint: { endpointId: machineEndpointId, generation: "1" },
    peers: [{ deviceId: options.app.id, ed25519Pub: options.app.public,
      endpoint: { endpointId: options.appEndpointId, generation: "1" } }],
    relayUrls: ["https://relay.invalid/"],
  };
  let centralOnline = true;
  let centralSocket: { close: () => void } | undefined;
  const backend = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    fetch(request, server) {
      const url = new URL(request.url);
      if (url.pathname === "/account/devices/me/authorization") return Response.json(snapshot);
      if (request.headers.get("upgrade") === "websocket") {
        if (!centralOnline) return new Response(null, { status: 503 });
        return server.upgrade(request) ? undefined : new Response(null, { status: 400 });
      }
      return Response.json({ devices: [{ deviceId: options.app.id, ed25519Pub: options.app.public }] });
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
  const root = mkdtempSync(join(tmpdir(), `antgrid-${options.label}-`));
  const previousDirectory = process.env.ANTGRID_DIR;
  const previousMode = process.env.ANTGRID_PEER_TRANSPORT;
  process.env.ANTGRID_DIR = join(root, "state");
  process.env.ANTGRID_PEER_TRANSPORT = "iroh-preferred";
  const host = new HostServer({ remote: {
    relayUrl: `ws://127.0.0.1:${backend.port}`, licenseApiUrl: `http://127.0.0.1:${backend.port}`,
    identity: { deviceId: machine.id, deviceName: options.label, createdAt: "",
      ed25519PublicKey: machine.public, ed25519PrivateKey: machine.secret },
    auth: { clientId: enrollmentId, clientSecret: "test-only", deviceUuid: machine.id,
      userId: accountId, endpointSecret: endpointSecret.toString("base64") }, onAuthRevoked: () => {},
  }, remoteRuntimeFactory: async () => ({ maint: { getToken: () => "test-only", stop: () => {} } }) });
  await host.startControlPlane();
  await host.handleRemoteAccessVerb({ id: "enable", type: "mobile-access:set", enabled: true });
  const projects: { id: string; name: string }[] = [];
  for (const name of options.projectNames ?? ["alpha", "beta"]) {
    const folder = join(root, name);
    mkdirSync(folder);
    writeFileSync(join(folder, "antgrid.yaml"), `name: ${name}\nagent:\n  tool: claude-code\n`);
    writeFileSync(join(folder, "proof.txt"), `${name}:native-host-proof`);
    writeFileSync(join(folder, "native-echo.cjs"), "process.stdin.resume();process.stdin.on('data',data=>process.stdout.write('NATIVE_ECHO:'+data.toString().trim()+'\\n'));\n");
    for (const args of [["init"], ["config", "user.email", "native-smoke@example.invalid"],
      ["config", "user.name", "Native smoke"], ["add", "."], ["commit", "-m", "fixture"]]) {
      const child = Bun.spawn(["git", ...args], { cwd: folder, stdout: "ignore", stderr: "pipe" });
      assert.equal(await child.exited, 0, await new Response(child.stderr).text());
    }
    const id = computeProjectId(folder);
    await host.open(id, folder, name === "alpha" ? "remote" : "local");
    projects.push({ id, name });
  }
  return {
    machine, projects, root, host,
    async nativeAddress() {
      const endpoint = await until(() =>
        (host as unknown as { controlPlaneRelay?: { endpoint?: Endpoint } }).controlPlaneRelay?.endpoint);
      return {
        endpointId: endpoint.id().toString(),
        // The host binds a wildcard socket; the app dials loopback in-process.
        addresses: endpoint.boundSockets()
          .filter((address) => address.startsWith("0.0.0.0:") || address.startsWith("127.0.0.1:"))
          .map((address) => address.replace("0.0.0.0:", "127.0.0.1:")),
      };
    },
    takeCentralOffline() {
      centralOnline = false;
      centralSocket?.close();
    },
    async dispose() {
      await host.shutdown();
      backend.stop(true);
      if (previousDirectory === undefined) delete process.env.ANTGRID_DIR;
      else process.env.ANTGRID_DIR = previousDirectory;
      if (previousMode === undefined) delete process.env.ANTGRID_PEER_TRANSPORT;
      else process.env.ANTGRID_PEER_TRANSPORT = previousMode;
      rmSync(root, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
    },
  };
}

export async function until<T>(read: () => T | undefined | null): Promise<T> {
  for (let attempt = 0; attempt < 200; attempt++) {
    const result = read();
    if (result) return result;
    await Bun.sleep(25);
  }
  throw new Error("Native endpoint did not start");
}
