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
  /** Wrap an already-connected native session for scenario-level operations. */
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

  get lifecycleGenerations(): Readonly<{ control: number; native: number; e2e: number }> {
    return this.client.lifecycleGenerations;
  }

  /** Prove the current native session is responsive without dialing,
   * reconnecting, or re-running the hello. */
  waitForStateSnapshot(opts: { timeoutMs?: number } = {}): Promise<{ ok: true }> {
    return this.snapshotRoundTrip(opts.timeoutMs ?? 10_000);
  }

  /**
   * Explicit recovery helper for tests whose subject is native redial or
   * bridge restart. Ordinary snapshot assertions must use
   * `waitForStateSnapshot`, which never changes transport generations.
   */
  async recoverStateSnapshot(opts: { timeoutMs?: number } = {}): Promise<{ ok: true }> {
    const timeoutMs = opts.timeoutMs ?? 10_000;
    const deadline = Date.now() + timeoutMs;
    let lastErr: unknown = new Error("recoverStateSnapshot: no attempt completed");
    while (Date.now() < deadline) {
      const remaining = Math.max(500, deadline - Date.now());
      try {
        return await this.snapshotRoundTrip(Math.min(2_000, remaining));
      } catch (err) {
        lastErr = err;
      }
      try {
        await this.client.reconnectNative();
        await this.client.performE2EHandshake(
          this.env.agentDeviceId,
          Math.min(2_000, Math.max(500, deadline - Date.now())),
        );
      } catch (err) {
        lastErr = err;
        await Bun.sleep(300);
      }
    }
    throw new Error(`recoverStateSnapshot timed out after ${timeoutMs}ms: ${String(lastErr)}`);
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
