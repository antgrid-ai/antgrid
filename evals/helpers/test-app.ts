import { relaySlotId } from "antgrid-wire";
import { RelayClient } from "./relay-client";
import { createMessage } from "../../bridge/src/protocol";
import type { TestEnv } from "./harness";

/**
 * Thin wrapper around `RelayClient` that drives a full account-trusted
 * session (hello with an account token → E2E handshake admitted from the
 * account inventory) with no pairing ceremony — the production path.
 * `TestApp.connect` is single-shot; a caller that needs to absorb the
 * agent-just-spawned startup race uses `waitAgentReachable`
 * (`evals/support/reachable.ts`), which retries it.
 */
export class TestApp {
  private constructor(
    private readonly client: RelayClient,
    private readonly env: TestEnv,
  ) {}

  /**
   * Connect, authenticate, and complete the E2E handshake against
   * `env.agentDeviceId`. Reuses `env.appIdentity` (the SAME Ed25519 identity
   * `setupTestEnv` registered with the fake account inventory) so admission
   * resolves without a pair-request — a fresh, never-registered identity
   * cannot be admitted (the bridge's `TrustedPeersProvider` is deviceId-keyed).
   *
   * `machineDeviceId` addresses this connection on a per-machine relay SLOT
   * (`relaySlotId`) while the E2E transcript still binds the bare
   * `accountDeviceId` — see `RelayClient`'s `deviceId`/`transcriptDeviceId`
   * split. With the DEFAULT `accountDeviceId` (`env.appIdentity.deviceId`),
   * `env.app` already holds a live socket under that exact bare deviceId, so
   * an unslotted second hello would supersede it (the relay closes the older
   * of two same-deviceId connections — strictly monotonic epochs). An omitted
   * `machineDeviceId` defaults to a fresh random one whenever the RESOLVED
   * `accountDeviceId` equals `env.appIdentity.deviceId` (the default) — this
   * is a value comparison, not an `opts.accountDeviceId` presence check, so
   * passing `accountDeviceId: env.appIdentity.deviceId` explicitly is NOT a
   * no-op: it's treated identically to omitting the option. Only an
   * `accountDeviceId` that actually DIFFERS from the default opts back in to
   * the old bare-id (displacing) behaviour, leaving `machineDeviceId` unset
   * unless the caller also supplies one.
   *
   * An ADDITIVE probe on both layers: the relay routes the slotted hello to a
   * distinct connection, so it sends no SUPERSEDED close to `env.app`'s
   * socket, and the bridge keeps one established E2E session per app device
   * (`bridge/src/relay-client.ts`), so it admits this one alongside `env.app`'s
   * rather than displacing it. `env.app` stays usable afterwards with no
   * re-handshake. The one residue is bookkeeping: a probe that disconnects
   * without rekeying leaves an unreachable session on the bridge until its TTL
   * reap, and a suite opening many probes can reach the bridge's session cap,
   * at which point the OLDEST session is evicted with a `session-takeover`.
   */
  static async connect(
    env: TestEnv,
    opts: {
      onOutbound?: (raw: string) => void;
      accountDeviceId?: string;
      machineDeviceId?: string;
    } = {},
  ): Promise<TestApp> {
    // Always env.appIdentity: a caller needing a different signing key for a
    // different accountDeviceId (a late-added or cross-env device) drives
    // RelayClient directly, e.g. `handshakeWithoutPairing` in
    // gate-inventory-miss / gate-multi-machine-slots — connect+claim staying
    // coupled here rules out signing with one key while claiming another.
    const identity = env.appIdentity;
    const accountDeviceId = opts.accountDeviceId ?? env.appIdentity.deviceId;
    // Value comparison, not `opts.accountDeviceId` presence: a caller passing
    // `accountDeviceId: env.appIdentity.deviceId` explicitly is visually a
    // no-op and must slot exactly like an omitted option, not silently fall
    // back to the displacing unslotted path.
    const machineDeviceId =
      opts.machineDeviceId ?? (accountDeviceId === env.appIdentity.deviceId ? crypto.randomUUID() : undefined);
    const helloDeviceId = machineDeviceId
      ? relaySlotId(accountDeviceId, machineDeviceId)
      : accountDeviceId;
    const client = await RelayClient.connectAndAuth(env.relay.url, {
      deviceType: "app",
      name: "test-app",
      identity,
      deviceId: helloDeviceId,
      transcriptDeviceId: accountDeviceId,
      onOutbound: opts.onOutbound,
    });
    client.setPeerId(env.agentDeviceId);
    await client.performE2EHandshake(env.agentDeviceId, 10_000, {
      agentEd25519Pub: env.agent.ed25519Pubkey,
    });
    return new TestApp(client, env);
  }

  /** Wrap an ALREADY connected + already E2E-handshaked `RelayClient` as a
   *  `TestApp` — for callers that need `handshakeWithoutPairing`'s retry
   *  (SAME socket, resent client-hello) instead of `connect`'s single-shot
   *  attempt, e.g. a slotted identity added to the account inventory AFTER
   *  the agent's own startup fetch (gate-multi-machine-slots). */
  static wrap(client: RelayClient, env: TestEnv): TestApp {
    return new TestApp(client, env);
  }

  /** Pull-then-replay welcome state (see `RelayClient.pullStateSnapshot`). Note:
   *  it silently swallows a dead/unresponsive session (resolves anyway) — a
   *  suite asserting recovery should use `waitForStateSnapshot` instead, which
   *  actually throws on failure. */
  pullStateSnapshot(): Promise<void> {
    return this.client.pullStateSnapshot();
  }

  /** Hard-close the underlying socket without touching E2E bookkeeping —
   *  simulates an unintentional network drop (see `RelayClient.dropSocket`). */
  dropSocket(): void {
    this.client.dropSocket();
  }

  /** Resolve once the underlying socket closes, with the WS close code (e.g.
   *  4002 for `/internal/revoke` — see relay's `internal-routes.ts`). `code`
   *  is `null` if the timeout elapsed with no close observed. */
  async waitClose(timeoutMs = 5_000): Promise<{ closed: boolean; code: number | null }> {
    const closed = await this.client.waitForClose(timeoutMs);
    return { closed, code: closed ? this.client.lastCloseCode : null };
  }

  /**
   * Re-establish a fresh authenticated socket + E2E handshake under the SAME
   * identity. Trusted phones reconnect this way — no re-pair. Mints a fresh
   * app token before each redial (`env.license.mintAppToken()`), mirroring
   * the real app re-presenting its account token on every connect — this is
   * what lets `env.license.expireNextToken()` actually reach the wire.
   */
  async reconnect(): Promise<{ connected: true } | { connected: false; reason: string }> {
    try {
      this.client.setLicenseToken(this.env.license.mintAppToken());
      await this.client.reconnectAndAuth(this.env.relay.url);
      this.client.setPeerId(this.env.agentDeviceId);
      await this.client.performE2EHandshake(this.env.agentDeviceId, 10_000, {
        agentEd25519Pub: this.env.agent.ed25519Pubkey,
      });
      return { connected: true };
    } catch (err) {
      return { connected: false, reason: err instanceof Error ? err.message : String(err) };
    }
  }

  /**
   * Strong session-liveness proof for the failure-matrix suites: sends a
   * direct `state.snapshot` RPC and THROWS if it never answers ok:true —
   * unlike `pullStateSnapshot` (which silently returns on a dead session, see
   * its doc comment), a caller asserting "the session recovered" actually
   * fails when it hasn't. Tries the RPC on the CURRENT E2E context first; on
   * failure, re-runs the E2E handshake on the SAME live socket (no reconnect,
   * no re-pair — mirrors a bridge restart handing the phone fresh keys) and
   * retries, until `timeoutMs` elapses.
   */
  async waitForStateSnapshot(opts: { timeoutMs?: number } = {}): Promise<{ ok: true }> {
    const timeoutMs = opts.timeoutMs ?? 10_000;
    const deadline = Date.now() + timeoutMs;
    let lastErr: unknown = new Error("waitForStateSnapshot: no attempt completed");
    while (Date.now() < deadline) {
      const remaining = Math.max(500, deadline - Date.now());
      try {
        return await this.snapshotRoundTrip(Math.min(2_000, remaining));
      } catch (err) {
        lastErr = err;
      }
      try {
        this.client.setPeerId(this.env.agentDeviceId);
        await this.client.performE2EHandshake(this.env.agentDeviceId, Math.min(2_000, Math.max(500, deadline - Date.now())), {
          agentEd25519Pub: this.env.agent.ed25519Pubkey,
        });
      } catch (err) {
        lastErr = err;
        await Bun.sleep(300);
      }
    }
    throw new Error(`waitForStateSnapshot timed out after ${timeoutMs}ms: ${String(lastErr)}`);
  }

  private async snapshotRoundTrip(timeoutMs: number): Promise<{ ok: true }> {
    const requestId = `snap-${Math.random().toString(36).slice(2)}`;
    const responseP = this.client.waitFor((m: any) => m.type === "response" && m.requestId === requestId, timeoutMs);
    this.client.sendEncrypted(createMessage("request", { requestId, method: "state.snapshot", params: { types: ["*"] } }));
    const res = (await responseP) as { ok?: boolean };
    if (!res?.ok) throw new Error(`state.snapshot returned ok:false (${JSON.stringify(res)})`);
    return { ok: true };
  }

  disconnect(): Promise<void> {
    return this.client.disconnect();
  }
}
