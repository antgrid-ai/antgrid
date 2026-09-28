import { randomBytes } from "node:crypto";
import { buildHelloSigBody, normalizeRelayHost } from "antgrid-wire";

const TEST_LICENSE_TOKEN = "eval-license-token";
let epochCounter = 0;

function nextEpoch(): number {
  epochCounter = Math.max(epochCounter + 1, Math.floor(Date.now() / 1000));
  return epochCounter;
}

export interface CentralIdentity {
  publicKeyBase64: string;
  privateKey: CryptoKey;
  privateKeySeed: Buffer;
}

export interface CentralForgeOptions {
  corruptHelloSig?: boolean;
  reuseNonce?: string;
  skewTsMs?: number;
  epoch?: number;
  licenseToken?: string;
}

type ConnectOptions = {
  deviceType: "agent" | "app";
  name?: string;
  identity?: CentralIdentity;
  deviceId?: string;
  onOutbound?: (raw: string) => void;
} & CentralForgeOptions;

type Waiter = {
  match: (message: any) => boolean;
  resolve: (message: any) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
};

export class CentralTestClient {
  private ws: WebSocket | null = null;
  private generation = 0;
  private queue: any[] = [];
  private waiters: Waiter[] = [];
  private closed = false;
  private closeWaiters: Array<() => void> = [];
  lastCloseCode: number | null = null;
  lastHelloNonce = "";

  private constructor(
    readonly deviceId: string,
    private readonly deviceType: "agent" | "app",
    private readonly name: string,
    private readonly publicKeyBase64: string,
    private readonly privateKey: CryptoKey,
    private readonly privateKeySeed: Buffer,
    private readonly forge: CentralForgeOptions,
    private readonly onOutbound?: (raw: string) => void,
  ) {}

  static async connectAndAuth(
    relayUrl: string,
    options: ConnectOptions,
  ): Promise<CentralTestClient> {
    const deviceId = options.deviceId ?? crypto.randomUUID();
    let identity = options.identity;
    if (!identity) {
      const keys = await crypto.subtle.generateKey("Ed25519", true, ["sign", "verify"]);
      const publicKeyBase64 = Buffer.from(
        await crypto.subtle.exportKey("raw", keys.publicKey as CryptoKey),
      ).toString("base64");
      const pkcs8 = Buffer.from(
        await crypto.subtle.exportKey("pkcs8", keys.privateKey as CryptoKey),
      );
      identity = {
        publicKeyBase64,
        privateKey: keys.privateKey as CryptoKey,
        privateKeySeed: Buffer.from(pkcs8.subarray(pkcs8.length - 32)),
      };
    }
    const client = new CentralTestClient(
      deviceId,
      options.deviceType,
      options.name ?? `test-${options.deviceType}`,
      identity.publicKeyBase64,
      identity.privateKey,
      Buffer.from(identity.privateKeySeed),
      options,
      options.onOutbound,
    );
    await client.connect(relayUrl);
    return client;
  }

  exportIdentity(): CentralIdentity {
    return {
      publicKeyBase64: this.publicKeyBase64,
      privateKey: this.privateKey,
      privateKeySeed: Buffer.from(this.privateKeySeed),
    };
  }

  private connect(relayUrl: string): Promise<void> {
    const generation = ++this.generation;
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(relayUrl);
      let authenticated = false;
      let settled = false;
      const fail = (error: Error) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (this.ws === ws) this.ws = null;
        try { ws.close(); } catch {}
        reject(error);
      };
      const timer = setTimeout(() => fail(new Error("Auth timed out")), 10_000);
      ws.addEventListener("open", () => {
        this.ws = ws;
        this.closed = false;
        void this.sendHello(relayUrl).catch((error) =>
          fail(error instanceof Error ? error : new Error(String(error))));
      });
      ws.addEventListener("message", (event) => {
        if (typeof event.data !== "string") return;
        const message = JSON.parse(event.data);
        if (!authenticated) {
          if (message.type === "welcome") {
            authenticated = true;
            settled = true;
            clearTimeout(timer);
            resolve();
          } else if (message.type === "error") {
            fail(new Error(`Auth error: ${message.code} ${message.message}`));
          }
          return;
        }
        this.deliver(message);
      });
      ws.addEventListener("error", () => fail(new Error("WebSocket error")));
      ws.addEventListener("close", (event: any) => {
        if (generation !== this.generation) return;
        clearTimeout(timer);
        this.closed = true;
        this.lastCloseCode = typeof event?.code === "number" ? event.code : null;
        for (const close of this.closeWaiters.splice(0)) close();
        if (!authenticated) fail(new Error("Closed during auth"));
      });
    });
  }

  private async sendHello(relayUrl: string): Promise<void> {
    const licenseToken = this.forge.licenseToken ?? TEST_LICENSE_TOKEN;
    const epoch = this.forge.epoch ?? nextEpoch();
    const ts = new Date(Date.now() + (this.forge.skewTsMs ?? 0)).toISOString();
    const nonce = this.forge.reuseNonce ?? randomBytes(16).toString("base64");
    this.lastHelloNonce = nonce;
    const sigBody = buildHelloSigBody({
      relayHost: normalizeRelayHost(relayUrl),
      deviceType: this.deviceType,
      deviceId: this.deviceId,
      publicKey: this.publicKeyBase64,
      epoch,
      licenseToken,
      ts,
      nonce,
    });
    const signed = Buffer.from(
      await crypto.subtle.sign("Ed25519", this.privateKey, new Uint8Array(sigBody)),
    );
    if (this.forge.corruptHelloSig) signed[0] ^= 0xff;
    const raw = JSON.stringify({
      type: "hello",
      protocolVersion: 3,
      deviceType: this.deviceType,
      deviceId: this.deviceId,
      name: this.name,
      publicKey: this.publicKeyBase64,
      epoch,
      licenseToken,
      ts,
      nonce,
      sig: signed.toString("base64"),
    });
    this.onOutbound?.(raw);
    this.ws?.send(raw);
  }

  private deliver(message: any): void {
    for (let index = 0; index < this.waiters.length; index++) {
      if (!this.waiters[index].match(message)) continue;
      const waiter = this.waiters.splice(index, 1)[0];
      clearTimeout(waiter.timer);
      waiter.resolve(message);
      return;
    }
    this.queue.push(message);
  }

  sendRaw(data: unknown): void {
    if (!this.ws) throw new Error("Central control is not connected");
    const raw = JSON.stringify(data);
    this.onOutbound?.(raw);
    this.ws.send(raw);
  }

  waitFor(match: (message: any) => boolean, timeoutMs = 5_000): Promise<any> {
    const queued = this.queue.findIndex(match);
    if (queued !== -1) return Promise.resolve(this.queue.splice(queued, 1)[0]);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        const index = this.waiters.findIndex((waiter) => waiter.timer === timer);
        if (index !== -1) this.waiters.splice(index, 1);
        reject(new Error(`Timed out waiting for central message (${timeoutMs}ms)`));
      }, timeoutMs);
      this.waiters.push({ match, resolve, reject, timer });
    });
  }

  waitForClose(timeoutMs = 5_000): Promise<boolean> {
    if (this.closed) return Promise.resolve(true);
    return new Promise((resolve) => {
      const done = () => {
        clearTimeout(timer);
        resolve(true);
      };
      const timer = setTimeout(() => {
        const index = this.closeWaiters.indexOf(done);
        if (index !== -1) this.closeWaiters.splice(index, 1);
        resolve(false);
      }, timeoutMs);
      this.closeWaiters.push(done);
    });
  }

  async disconnect(): Promise<void> {
    this.generation++;
    for (const waiter of this.waiters.splice(0)) {
      clearTimeout(waiter.timer);
      waiter.reject(new Error("CentralTestClient disconnected"));
    }
    this.queue = [];
    this.ws?.close();
    this.ws = null;
    this.closed = true;
    this.privateKeySeed.fill(0);
  }
}
