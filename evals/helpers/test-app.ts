import { RelayClient } from "./relay-client";
import { createMessage } from "../../bridge/src/protocol";
import type { TestEnv } from "./harness";

/** Scenario-facing helpers over the one enrolled native app endpoint owned by TestEnv. */export class TestApp {
  private constructor(
    private readonly client: RelayClient,
    private readonly env: TestEnv,
    private readonly ownsClient = true,
  ) {}

  /** Borrow the environment's established native client without taking ownership. */
  static async connect(env: TestEnv): Promise<TestApp> {
    return new TestApp(env.app, env, false);
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
   * Re-establish the central control socket under the SAME
   * identity. Trusted phones reconnect this way — no re-pair. Mints a fresh
   * app token before each redial (`env.license.mintAppToken()`), mirroring
   * the real app re-presenting its account token on every connect — this is
   * what lets `env.license.expireNextToken()` actually reach the wire.
   */
  async reconnect(): Promise<{ connected: true } | { connected: false; reason: string }> {
    try {
      this.client.setLicenseToken(this.env.license.mintAppToken());
      await this.client.reconnectAndAuth(this.env.relay.url);
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
        await this.client.reconnectNative();
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
    return this.ownsClient ? this.client.disconnect() : Promise.resolve();
  }
}
