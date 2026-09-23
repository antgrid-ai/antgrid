import { expect, test } from "bun:test";
import type { Subprocess } from "bun";
import type { KeyObject } from "node:crypto";
import { randomBytes } from "node:crypto";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Endpoint, EndpointAddr, RelayMode } from "@number0/iroh/index.js";
import { PEER_ALPN } from "antgrid-wire";
import { allocatePort } from "../helpers/harness";
import { endpointKey, startIrohAuthorizationHarness } from "../support/iroh-authorization";

const ALPN = Array.from(Buffer.from(PEER_ALPN));

// Drives the stock `iroh-relay` binary against web's `access.http` route with
// real Postgres/OAuth behind it. It covers relay admission and denial only;
// retiring a live peer after revocation is `gate-iroh-host-authorization`'s job.
function resolveRelayBinary(): string {
  const configured = process.env.ANTGRID_IROH_RELAY_BIN;
  if (configured) {
    if (!existsSync(configured)) throw new Error(`ANTGRID_IROH_RELAY_BIN does not exist: ${configured}`);
    return configured;
  }
  const onPath = Bun.which("iroh-relay");
  if (onPath) return onPath;
  throw new Error("No stock iroh-relay binary found. Set ANTGRID_IROH_RELAY_BIN, or install with: " +
    "cargo install iroh-relay --version 1.2.0 --locked --features server --root .tmp/iroh-relay-bin");
}

// Dotted keys, never an `[access.http]` header: a root key written after a
// table header lands inside that table, and upstream ignores unknown fields,
// so the mistake parses clean. The bearer token stays in the child's env.
function relayConfigToml(httpPort: number, accessUrl: string): string {
  return [`http_bind_addr = "127.0.0.1:${httpPort}"`, "enable_metrics = false",
    `access.http.url = "${accessUrl}"`].join("\n");
}

async function waitForRelayReady(port: number, timeoutMs: number, stderrTail: () => Promise<string>): Promise<void> {
  const deadline = performance.now() + timeoutMs;
  for (;;) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/healthz`, { signal: AbortSignal.timeout(1_000) });
      if (res.ok) { await res.arrayBuffer().catch(() => {}); return; }
    } catch { /* not listening yet */ }
    if (performance.now() >= deadline) throw new Error(`stock iroh-relay did not become ready: ${(await stderrTail()).slice(-2_000)}`);
    await Bun.sleep(50);
  }
}

/** Fulfills `true`/`false` on the wrapped promise's own outcome, `false` on
 *  the deadline — and, either way, attaches its rejection handler up front so
 *  a denial that never settles `online()` (the common case) never surfaces as
 *  an unhandled rejection once the test moves on. */
async function resolvesWithin(promise: Promise<unknown>, timeoutMs: number): Promise<boolean> {
  const settlement = promise.then(() => "fulfilled" as const, () => "rejected" as const);
  const timedOut = Symbol("timeout");
  const outcome = await Promise.race([settlement, Bun.sleep(timeoutMs).then(() => timedOut)]);
  return outcome === "fulfilled";
}

async function bindEndpoint(privateKey: KeyObject, relayUrl: string) {
  const builder = Endpoint.builder();
  builder.applyMinimal();
  builder.secretKey(Array.from(privateKey.export({ type: "pkcs8", format: "der" }).subarray(-32)));
  builder.alpns([ALPN]);
  builder.relayMode(RelayMode.customFromUrls([relayUrl]));
  builder.bindAddr("127.0.0.1:0");
  return builder.bind();
}

test("stock iroh-relay admits registered endpoints over access.http and denies everyone else", async () => {
  const binary = resolveRelayBinary();
  const relayPort = allocatePort();
  const relayUrl = `http://127.0.0.1:${relayPort}/`;
  const token = randomBytes(32).toString("hex");

  let authorization: Awaited<ReturnType<typeof startIrohAuthorizationHarness>> | undefined;
  const workDir = mkdtempSync(join(tmpdir(), "antgrid-iroh-relay-gate-"));
  let child: Subprocess<"ignore", "ignore", "pipe"> | undefined;
  let accessTap: ReturnType<typeof Bun.serve> | undefined;
  const endpoints: Awaited<ReturnType<typeof bindEndpoint>>[] = [];
  try {
    authorization = await startIrohAuthorizationHarness({
      IROH_RELAY_URLS: [relayUrl], PEER_RELAY_ACCESS_TOKEN: token, ANTGRID_DEV_INSECURE_RELAY: true, PEER_POLICY_TARGETS: [],
    });
    // The relay's access callback goes through this tap so the test reads the
    // verdicts the relay itself received. A timed-out `online()` alone cannot
    // tell a route denial from a relay that never consulted the route at all.
    const verdicts: { endpointId: string; verdict: string }[] = [];
    const webOrigin = authorization.origin;
    accessTap = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: async (request) => {
      const incoming = new URL(request.url);
      const headers = new Headers();
      for (const name of ["authorization", "x-iroh-nodeid"]) {
        const value = request.headers.get(name);
        if (value !== null) headers.set(name, value);
      }
      const upstream = await fetch(`${webOrigin}${incoming.pathname}${incoming.search}`,
        { method: request.method, headers, redirect: "manual" });
      const verdict = await upstream.text();
      verdicts.push({ endpointId: (request.headers.get("x-iroh-nodeid") ?? "").toLowerCase(),
        verdict: `${upstream.status} ${verdict}` });
      return new Response(verdict, { status: upstream.status });
    } });
    const verdictsFor = (endpointId: string) =>
      verdicts.filter((entry) => entry.endpointId === endpointId.toLowerCase()).map((entry) => entry.verdict);
    const accessUrl = new URL("/internal/iroh-access", accessTap.url.origin);
    accessUrl.searchParams.set("relay", relayUrl);

    writeFileSync(join(workDir, "relay.toml"), relayConfigToml(relayPort, accessUrl.toString()));
    child = Bun.spawn([binary, "--config-path", join(workDir, "relay.toml")],
      { env: { ...process.env, IROH_RELAY_HTTP_BEARER_TOKEN: token }, stdin: "ignore", stdout: "ignore", stderr: "pipe" });
    const stderrText = new Response(child.stderr).text();
    await waitForRelayReady(relayPort, 10_000, () => stderrText);

    const owner = await authorization.user();
    const machine = await authorization.provision(owner.cookie, "agent");
    const app = await authorization.provision(owner.cookie, "app");
    const alphaKey = endpointKey();
    const betaKey = endpointKey();
    const alphaProof = await authorization.challenge(machine, alphaKey);
    const betaProof = await authorization.challenge(app, betaKey);
    expect((await authorization.request("/account/devices/me/endpoint-registration",
      { token: machine.token, body: alphaProof.body })).status).toBe(200);
    expect((await authorization.request("/account/devices/me/endpoint-registration",
      { token: app.token, body: betaProof.body })).status).toBe(200);

    // 1. A registered endpoint is admitted.
    const alpha = await bindEndpoint(alphaProof.endpoint.privateKey, relayUrl);
    endpoints.push(alpha);
    expect(await resolvesWithin(alpha.online(), 10_000)).toBe(true);
    expect(verdictsFor(alpha.id().toString())).toContain("200 true");

    // 2. The fail-open detector: a relay config that silently fell back to
    // Access::Everyone (`$UP/src/main.rs:537-549`) admits this endpoint. The
    // verdict check proves the denial came from the route, not from a relay
    // that failed for some unrelated reason.
    const stranger = endpointKey();
    const strangerEndpoint = await bindEndpoint(stranger.privateKey, relayUrl);
    endpoints.push(strangerEndpoint);
    expect(await resolvesWithin(strangerEndpoint.online(), 5_000)).toBe(false);
    const strangerVerdicts = verdictsFor(strangerEndpoint.id().toString());
    expect(strangerVerdicts.length).toBeGreaterThan(0);
    expect(strangerVerdicts.every((verdict) => verdict === "200 false")).toBe(true);

    // 3. A relay-only dial (no direct addresses in the EndpointAddr) between
    // two registered endpoints carries real packets. On loopback iroh may
    // later upgrade to a direct path, so the relay path is checked at connect,
    // before any hole-punch can complete.
    const beta = await bindEndpoint(betaProof.endpoint.privateKey, relayUrl);
    endpoints.push(beta);
    expect(await resolvesWithin(beta.online(), 10_000)).toBe(true);
    const payload = Array.from(randomBytes(16));
    const accepted = alpha.acceptNext().then((incoming) => {
      if (!incoming) throw new Error("alpha never saw the relay-only dial");
      return incoming.accept().then((accepting) => accepting.connect());
    });
    const dialer = await beta.connect(new EndpointAddr(alpha.id(), relayUrl, []), ALPN);
    const relayPaths = dialer.paths().filter((path) => path.isRelay);
    expect(relayPaths.length).toBeGreaterThan(0);
    expect(relayPaths.some((path) => path.stats.udpRxDatagrams > 0)).toBe(true);
    const outbound = await dialer.openBi();
    await outbound.send.writeAll(payload);
    await outbound.send.finish();
    const inbound = await accepted;
    const inboundBi = await inbound.acceptBi();
    expect(await inboundBi.recv.readExact(payload.length)).toEqual(payload);
    dialer.close(0n, []);
    inbound.close(0n, []);

    // 4. Revocation closes admission for a key that was previously registered:
    // a fresh bind (never a live connection to retire) must never come online.
    await beta.close();
    endpoints.splice(endpoints.indexOf(beta), 1);
    const inventory = await (await authorization.request("/account/devices",
      { cookie: owner.cookie })).json() as { devices: { id: string; device_id: string }[] };
    const appRow = inventory.devices.find((device) => device.device_id === app.deviceId)!;
    expect((await authorization.request(`/account/devices/${appRow.id}`,
      { cookie: owner.cookie, method: "DELETE" })).status).toBe(200);
    const admittedBeforeRevocation = verdictsFor(beta.id().toString()).length;
    const revoked = await bindEndpoint(betaProof.endpoint.privateKey, relayUrl);
    endpoints.push(revoked);
    expect(await resolvesWithin(revoked.online(), 5_000)).toBe(false);
    const revokedVerdicts = verdictsFor(revoked.id().toString()).slice(admittedBeforeRevocation);
    expect(revokedVerdicts.length).toBeGreaterThan(0);
    expect(revokedVerdicts.every((verdict) => verdict === "200 false")).toBe(true);
  } finally {
    await Promise.all(endpoints.map((endpoint) => endpoint.close().catch(() => {})));
    child?.kill();
    await child?.exited;
    accessTap?.stop(true);
    await authorization?.stop();
    rmSync(workDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
  }
}, 90_000);
