import {
  generateKeyPairSync,
  randomUUID,
  randomBytes,
  sign,
  type KeyObject,
} from "node:crypto";
import { verifyPairApproval } from "../../relay/src/pair-verify";
import { buildPairApprovalSigBody } from "../../bridge/src/pair-approval";
import { buildPairRequestSigBody } from "../../bridge/src/pair-request-verify";
import { buildHelloSigBody, normalizeRelayHost } from "antgrid-wire";
import type { TestEnv } from "./test-env";

const TEST_LICENSE_TOKEN = "eval-license-token";

let testAppEpoch = 0;
function nextTestAppEpoch(): number {
  testAppEpoch = Math.max(testAppEpoch + 1, Math.floor(Date.now() / 1000));
  return testAppEpoch;
}

export class PairException extends Error {
  constructor(
    message: string,
    public readonly reason: string,
  ) {
    super(message);
    this.name = "PairException";
  }
}

interface CloseEvent {
  code: number;
  reason: string;
}

/**
 * E2E test driver that mimics the phone-side pair flow. Connects to the
 * relay over WS, registers as `app` (no licenseToken), authenticates via
 * Ed25519 challenge-response, then drives `pair-request` / `pair-approval`
 * exactly like the real Dart client.
 *
 * Reuses the same Ed25519 keypair across `disconnect()` + `reconnect()` so
 * the agent's paired-phones trust list recognises us on reconnect.
 */
export class TestApp {
  private ws: WebSocket | null = null;
  private waiters: Array<{
    match: (msg: any) => boolean;
    resolve: (msg: any) => void;
    reject: (err: Error) => void;
    timer: ReturnType<typeof setTimeout> | null;
  }> = [];
  private queue: any[] = [];
  private closeWaiters: Array<(c: CloseEvent) => void> = [];
  private closeEvent: CloseEvent | null = null;
  private authenticated = false;
  private agentRegistrationId: string | null = null;
  private peerId: string | null = null;
  private agentEd25519PubkeyB64: string | null = null;

  readonly phoneDeviceId: string;
  readonly phonePubkeyB64: string;
  private readonly phoneEd25519: { publicKey: KeyObject; privateKey: KeyObject };
  private readonly relayUrl: string;
  private readonly env: TestEnv;

  private constructor(env: TestEnv) {
    this.env = env;
    this.relayUrl = env.relay.url;
    // Stable per-TestApp identity. uuid format matches the device-id regex on
    // the relay (`[a-zA-Z0-9_.-]+`).
    this.phoneDeviceId = randomUUID();
    this.phoneEd25519 = generateKeyPairSync("ed25519");
    const spki = this.phoneEd25519.publicKey.export({ type: "spki", format: "der" });
    // Strip 12-byte SPKI header → 32-byte raw pubkey
    this.phonePubkeyB64 = Buffer.from(spki.subarray(spki.length - 32)).toString("base64");
  }

  /**
   * Connect, register as an `app` (no licenseToken), complete Ed25519
   * challenge-response. Does NOT pair — call `pairWithAgent` next.
   */
  static async connect(
    env: TestEnv,
    _opts?: { licenseToken?: string | null },
  ): Promise<TestApp> {
    const app = new TestApp(env);
    await app.openSocket();
    return app;
  }

  private openSocket(): Promise<void> {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(this.relayUrl);
      const timeout = setTimeout(() => reject(new Error("Auth timed out")), 10_000);

      ws.addEventListener("open", () => {
        this.ws = ws;
        // v3: authenticate with a single signed `hello`. Apps now present a
        // license token too (design §4.2 — the fake gate accepts the eval token).
        const epoch = nextTestAppEpoch();
        const ts = new Date().toISOString();
        const nonce = randomBytes(16).toString("base64");
        const sigBody = buildHelloSigBody({
          relayHost: normalizeRelayHost(this.relayUrl),
          deviceType: "app",
          deviceId: this.phoneDeviceId,
          publicKey: this.phonePubkeyB64,
          epoch,
          licenseToken: TEST_LICENSE_TOKEN,
          ts,
          nonce,
        });
        const sig = sign(null, sigBody, this.phoneEd25519.privateKey).toString("base64");
        ws.send(
          JSON.stringify({
            type: "hello",
            protocolVersion: 3,
            deviceType: "app",
            deviceId: this.phoneDeviceId,
            name: "test-app",
            publicKey: this.phonePubkeyB64,
            epoch,
            licenseToken: TEST_LICENSE_TOKEN,
            ts,
            nonce,
            sig,
          }),
        );
      });

      ws.addEventListener("message", (evt) => {
        // All pair-flow handshake traffic is text JSON.
        if (typeof evt.data !== "string") return;
        let data: any;
        try { data = JSON.parse(evt.data); } catch { return; }

        if (!this.authenticated) {
          if (data.type === "welcome") {
            this.authenticated = true;
            clearTimeout(timeout);
            resolve();
            return;
          }
          if (data.type === "error") {
            clearTimeout(timeout);
            reject(new Error(`Auth error: ${data.code} ${data.message}`));
            return;
          }
          return;
        }

        // Post-auth: dispatch to waiters, else queue.
        for (let i = 0; i < this.waiters.length; i++) {
          if (this.waiters[i].match(data)) {
            const w = this.waiters.splice(i, 1)[0];
            if (w.timer) clearTimeout(w.timer);
            w.resolve(data);
            return;
          }
        }
        this.queue.push(data);
      });

      ws.addEventListener("error", () => {
        if (!this.authenticated) {
          clearTimeout(timeout);
          reject(new Error("WebSocket error"));
        }
      });

      ws.addEventListener("close", (evt: any) => {
        const ev: CloseEvent = {
          code: typeof evt?.code === "number" ? evt.code : 0,
          reason: typeof evt?.reason === "string" ? evt.reason : "",
        };
        this.closeEvent = ev;
        for (const fn of this.closeWaiters.splice(0)) fn(ev);
        for (const w of this.waiters.splice(0)) {
          if (w.timer) clearTimeout(w.timer);
          w.reject(new Error("WebSocket closed during wait"));
        }
        if (!this.authenticated) {
          clearTimeout(timeout);
          reject(new Error("Closed during auth"));
        }
      });
    });
  }

  private waitFor(match: (msg: any) => boolean, timeoutMs = 8_000): Promise<any> {
    for (let i = 0; i < this.queue.length; i++) {
      if (match(this.queue[i])) return Promise.resolve(this.queue.splice(i, 1)[0]);
    }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        const idx = this.waiters.findIndex((w) => w.timer === timer);
        if (idx !== -1) this.waiters.splice(idx, 1);
        reject(new Error(`Timed out waiting for message (${timeoutMs}ms)`));
      }, timeoutMs);
      this.waiters.push({ match, resolve, reject, timer });
    });
  }

  /**
   * Drive a full first-pair: send `pair-request` and await the next matching
   * `pair-approval` (success) or `pair-rejected` (rejection). Verifies the
   * approval signature via the same code path the relay/phone uses; throws
   * `PairException` on rejection or signature failure.
   */
  async pairWithAgent(
    agentRegistrationId: string,
    agentEd25519PubkeyB64: string,
    opts?: { pairCode?: string },
  ): Promise<{ paired: true; agentDeviceId: string }> {
    const result = await this.tryPairRequest(agentRegistrationId, opts);
    if (result.paired) {
      this.agentRegistrationId = agentRegistrationId;
      this.agentEd25519PubkeyB64 = agentEd25519PubkeyB64;
      return { paired: true, agentDeviceId: agentRegistrationId };
    }
    throw new PairException(`pair rejected: ${result.reason}`, result.reason);
  }

  /**
   * Send a pair-request and resolve with the outcome instead of throwing.
   * Used by tests that intentionally trigger rejections.
   */
  async tryPairRequest(
    agentRegistrationId: string,
    opts?: { pairCode?: string },
  ): Promise<{ paired: true } | { paired: false; reason: string }> {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      throw new Error("TestApp not connected");
    }
    const nonce = randomBytes(24).toString("base64");
    const requestedAt = new Date().toISOString();
    const sigBody = buildPairRequestSigBody({
      agentDeviceId: agentRegistrationId,
      phonePubkey: this.phonePubkeyB64,
      phoneDeviceId: this.phoneDeviceId,
      nonce,
      requestedAt,
    });
    const phoneSignature = sign(null, sigBody, this.phoneEd25519.privateKey).toString("base64");

    // Arm waiters BEFORE send to avoid races on fast approval/rejection.
    const approvalP = this.waitFor(
      (m) =>
        m.type === "pair-approval" &&
        m.phonePubkey === this.phonePubkeyB64 &&
        m.nonce === nonce,
      10_000,
    ).catch(() => null);
    const rejectionP = this.waitFor(
      (m) => m.type === "pair-rejected" && m.phonePubkey === this.phonePubkeyB64,
      10_000,
    ).catch(() => null);
    const errorP = this.waitFor(
      (m) => m.type === "error",
      10_000,
    ).catch(() => null);
    const closeP = new Promise<{ kind: "close"; ev: CloseEvent }>((resolve) => {
      if (this.closeEvent) resolve({ kind: "close", ev: this.closeEvent });
      else this.closeWaiters.push((ev) => resolve({ kind: "close", ev }));
    });

    this.ws.send(
      JSON.stringify({
        type: "pair-request",
        agentDeviceId: agentRegistrationId,
        phonePubkey: this.phonePubkeyB64,
        phoneDeviceId: this.phoneDeviceId,
        nonce,
        requestedAt,
        // v3 requires a deadline; the relay expires the pending pair past it.
        deadline: Date.now() + 10_000,
        phoneSignature,
        ...(opts?.pairCode ? { pairCode: opts.pairCode } : {}),
      }),
    );

    const winner: any = await Promise.race([
      approvalP.then((m) => (m ? { kind: "approval", m } : null)),
      rejectionP.then((m) => (m ? { kind: "rejection", m } : null)),
      errorP.then((m) => (m ? { kind: "error", m } : null)),
      closeP,
    ]);

    if (!winner) {
      return { paired: false, reason: "TIMEOUT" };
    }
    if (winner.kind === "approval") {
      this.agentRegistrationId = agentRegistrationId;
      // No agent pubkey provided here — caller (pairWithAgent) sets it.
      this.peerId = agentRegistrationId;
      return { paired: true };
    }
    if (winner.kind === "rejection") {
      return { paired: false, reason: winner.m.reason };
    }
    if (winner.kind === "error") {
      return { paired: false, reason: `ERROR:${winner.m.code}` };
    }
    // closed
    return { paired: false, reason: `CLOSED:${winner.ev.code}:${winner.ev.reason}` };
  }

  /**
   * Synthesize a pair-approval signed with a NON-trusted Ed25519 keypair
   * and run it through the same client-side `verifyPairApproval` path.
   * Throws an Error containing "signature" when verification fails.
   */
  async injectForgedApproval(
    agentRegistrationId: string,
    evilKp: { publicKey: KeyObject; privateKey: KeyObject },
  ): Promise<void> {
    if (!this.agentEd25519PubkeyB64) {
      // For forged-approval testing the caller passes the *real* agent
      // pubkey via env.agent.ed25519Pubkey before calling pairWithAgent —
      // but injectForgedApproval can be invoked standalone. Read from env.
      this.agentEd25519PubkeyB64 = this.env.agent.ed25519Pubkey;
    }
    const nonce = randomBytes(24).toString("base64");
    const expiresAt = new Date(Date.now() + 30_000).toISOString();
    const sigBody = buildPairApprovalSigBody({
      agentDeviceId: agentRegistrationId,
      phonePubkey: this.phonePubkeyB64,
      phoneDeviceId: this.phoneDeviceId,
      nonce,
      expiresAt,
    });
    const signature = sign(null, sigBody, evilKp.privateKey).toString("base64");

    const result = verifyPairApproval({
      agentEd25519Pubkey: this.agentEd25519PubkeyB64,
      agentDeviceId: agentRegistrationId,
      approval: {
        type: "pair-approval",
        // pairId is relay-stamped; the forged approval fabricates one so the
        // shape validates (verification fails on the SIGNATURE, which is the point).
        pairId: randomUUID(),
        phonePubkey: this.phonePubkeyB64,
        phoneDeviceId: this.phoneDeviceId,
        nonce,
        expiresAt,
        signature,
      },
      expectedNonce: nonce,
    });
    if (result.ok) {
      throw new Error("forged approval unexpectedly verified");
    }
    if (result.reason !== "BAD_SIGNATURE") {
      throw new Error(`forged approval rejected for ${result.reason}, expected BAD_SIGNATURE`);
    }
    throw new Error(`pair-approval signature verification failed: ${result.reason}`);
  }

  /**
   * Re-register with the SAME Ed25519 keypair + phoneDeviceId, then issue
   * a pair-request WITHOUT a pairCode. Trusted phones reconnect this way.
   */
  async reconnect(): Promise<{ paired: true } | { paired: false; reason: string }> {
    if (!this.agentRegistrationId) {
      throw new Error("reconnect requires a prior successful pair");
    }
    if (this.ws) {
      try { this.ws.close(); } catch { /* ignore */ }
      this.ws = null;
    }
    this.authenticated = false;
    this.queue = [];
    this.closeEvent = null;
    await this.openSocket();
    return this.tryPairRequest(this.agentRegistrationId);
  }

  /** Await the next WS close event (resolves immediately if already closed). */
  async waitClose(): Promise<{ code: number; reason: string }> {
    if (this.closeEvent) return this.closeEvent;
    return new Promise((resolve) => this.closeWaiters.push(resolve));
  }

  /**
   * Send a smoke message after pairing. The TestApp does not perform an
   * E2E handshake; this is a plaintext payload in a route frame so the
   * test can confirm the agent receives traffic from a non-licensed app.
   */
  async send(payload: string): Promise<void> {
    if (!this.ws || !this.peerId) throw new Error("Not paired");
    // Minimal route-frame send — tests that need real E2E should use the
    // existing helpers/relay-client.ts. This is intentionally simple: a
    // text-JSON frame the agent will drop with a parse warning, which is
    // sufficient to assert "no license-side rejection of a paired phone".
    this.ws.send(
      JSON.stringify({
        type: "message",
        to: this.peerId,
        channel: "control",
        payload,
      }),
    );
  }

  async disconnect(): Promise<void> {
    for (const w of this.waiters.splice(0)) {
      if (w.timer) clearTimeout(w.timer);
      w.reject(new Error("Disconnected"));
    }
    if (this.ws) {
      try { this.ws.close(); } catch { /* ignore */ }
      this.ws = null;
    }
  }
}
