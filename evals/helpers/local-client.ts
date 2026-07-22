import { AbMessageSchema, type AbMessage } from "../../bridge/src/protocol";

/** Minimal loopback connect info: port + token are all the local WS needs. */
export interface LocalConnectInfo {
  port: number;
  token: string;
}

export class LocalTestClient {
  private ws: WebSocket | null = null;
  private listeners = new Set<(msg: AbMessage, channel: string) => void>();

  async connect(disc: LocalConnectInfo): Promise<void> {
    this.ws = new WebSocket(`ws://127.0.0.1:${disc.port}`);
    await new Promise<void>((resolve, reject) => {
      this.ws!.onopen = () => resolve();
      this.ws!.onerror = (e) => reject(e);
    });

    let ready = false;
    const readyPromise = new Promise<void>((resolve, reject) => {
      this.ws!.onmessage = (ev) => {
        const env = JSON.parse(String(ev.data));
        if (!ready) {
          if (env.type === "ready") { ready = true; resolve(); return; }
          reject(new Error("unexpected pre-ready: " + JSON.stringify(env)));
          return;
        }
        const channel = env.channel ?? "control";
        delete env.channel;
        const parsed = AbMessageSchema.safeParse(env);
        if (parsed.success) for (const l of this.listeners) l(parsed.data, channel);
      };
    });

    this.ws.send(JSON.stringify({ type: "hello", token: disc.token, appPid: process.pid, appVersion: "eval" }));
    await readyPromise;
  }

  on(fn: (msg: AbMessage, channel: string) => void): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  send(msg: AbMessage, channel: "control" | "preview" = "control"): void {
    this.ws?.send(JSON.stringify({ channel, ...msg }));
  }

  close(): void {
    this.ws?.close();
    this.ws = null;
  }
}
