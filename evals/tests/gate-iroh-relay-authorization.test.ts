import { expect, test } from "bun:test";
import { createPrivateKey, createPublicKey, randomBytes } from "node:crypto";
import { resolve } from "node:path";
import { existsSync } from "node:fs";
import { startIrohAuthorizationHarness } from "../support/iroh-authorization";

function fixedEndpoint(byte: number) {
  const privateKey = createPrivateKey({ format: "der", type: "pkcs8",
    key: Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), Buffer.alloc(32, byte)]) });
  return { privateKey, endpointId: createPublicKey(privateKey).export({ format: "der", type: "spki" }).subarray(-32).toString("hex") };
}

// Requires the locked Rust example build and the same Postgres prerequisites as
// the backend authorization gate. Uses real service code and trusted TLS relay
// packets; it does not qualify native QUIC/E2E traffic through the relay.
test("real backend admission and revocation bound trusted TLS relay traffic", async () => {
  const binary = process.env.ANTGRID_IROH_RELAY_GATE ?? resolve(import.meta.dir,
    "../../iroh-relay/target/debug/examples", process.platform === "win32" ? "real_backend_gate.exe" : "real_backend_gate");
  if (!existsSync(binary)) throw new Error("Build iroh-relay example real_backend_gate or set ANTGRID_IROH_RELAY_GATE");
  const child = Bun.spawn([binary], { stdin: "pipe", stdout: "pipe", stderr: "pipe" });
  const stderr = new Response(child.stderr).text();
  const reader = child.stdout.getReader();
  const decoder = new TextDecoder();
  let buffered = "";
  let authorization: Awaited<ReturnType<typeof startIrohAuthorizationHarness>> | undefined;
  async function stage(expected: string, timeoutMs: number): Promise<Record<string, unknown>> {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const reading = (async () => {
      for (;;) {
        const newline = buffered.indexOf("\n");
        if (newline >= 0) {
          const line = buffered.slice(0, newline); buffered = buffered.slice(newline + 1);
          const value = JSON.parse(line) as Record<string, unknown>;
          if (value.stage === expected) return value;
          continue;
        }
        const chunk = await reader.read();
        if (chunk.done) throw new Error(`Rust relay gate ended before ${expected}: ${(await stderr).slice(-2000)}`);
        buffered += decoder.decode(chunk.value, { stream: true });
        if (buffered.length > 64 * 1024) throw new Error("Rust relay gate output exceeded bound");
      }
    })();
    try {
      return await Promise.race([reading, new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error(`Rust relay gate timed out at ${expected}`)), timeoutMs);
      })]);
    } finally { if (timer) clearTimeout(timer); }
  }
  try {
    const listening = await stage("listening", 5000);
    expect(typeof listening.relayUrl).toBe("string");
    const admissionSecret = randomBytes(32).toString("hex");
    authorization = await startIrohAuthorizationHarness({
      RELAY_INTERNAL_SECRET: admissionSecret, IROH_RELAY_URLS: [String(listening.relayUrl)], PEER_POLICY_TARGETS: [],
    });
    const owner = await authorization.user();
    const machine = await authorization.provision(owner.cookie, "agent");
    const app = await authorization.provision(owner.cookie, "app");
    for (const [device, seed] of [[machine, 5], [app, 6]] as const) {
      const proof = await authorization.challenge(device, fixedEndpoint(seed));
      expect((await authorization.request("/account/devices/me/endpoint-registration", {
        token: device.token, body: proof.body,
      })).status).toBe(200);
    }
    expect((await authorization.request("/account/devices/me/heartbeat", { token: machine.token,
      body: { deviceUuid: machine.deviceId, mobileAccessEnabled: true } })).status).toBe(200);
    child.stdin.write(`${JSON.stringify({ backendUrl: authorization.origin, admissionSecret })}\n`);
    await child.stdin.flush();
    const ready = await stage("ready", 15_000);
    expect(ready).toMatchObject({ trustedTls: true, bidirectionalPackets: true, unregisteredDenied: true });

    const inventory = await (await authorization.request("/account/devices", { cookie: owner.cookie })).json() as
      { devices: { id: string; device_id: string }[] };
    const row = inventory.devices.find((device) => device.device_id === machine.deviceId)!;
    const revokedAt = performance.now();
    expect((await authorization.request(`/account/devices/${row.id}`, { cookie: owner.cookie, method: "DELETE" })).status).toBe(200);
    child.stdin.write("revoked\n");
    await child.stdin.flush();
    const revoked = await stage("revoked", 60_000);
    expect(revoked).toMatchObject({ bothConnectionsClosed: true, reconnectDenied: true });
    expect(revoked.elapsedMs).toBeLessThanOrEqual(60_000);
    expect(performance.now() - revokedAt).toBeLessThanOrEqual(60_000);
    expect((await authorization.request("/account/devices/me/authorization", { token: machine.token })).status).toBe(401);
    expect(await child.exited).toBe(0);
  } finally {
    child.kill();
    await child.exited;
    await reader.cancel().catch(() => {});
    await stderr;
    await authorization?.stop();
  }
}, 100_000);
