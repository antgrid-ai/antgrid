import { connect, listen, type Socket, type TCPSocketListener } from "bun";

/** One forwarded connection: the accepted client socket and its upstream leg. */
interface Pair {
  client: Socket;
  upstream: Socket | null;
  /** Client bytes seen before the upstream leg finished connecting. */
  pending: Uint8Array[];
}

/**
 * A dumb bidirectional TCP byte forwarder on a STABLE client-facing port,
 * retargetable to a fresh upstream each relay restart. Lets a same-URL client
 * (e.g. the agent's unattended redial) survive a relay that comes back on a
 * NEW port, sidestepping the Windows same-port EADDRINUSE rebind window: a
 * just-closed listen socket lingers bound for tens of seconds on this dev box,
 * so restarting the relay on a fresh OS-assigned port and re-pointing this
 * forwarder is more reliable than waiting for the old port to free.
 *
 * Raw bytes only: the WS upgrade + Host header pass through untouched, so the
 * relay's `relayHost` signature check still sees the client's original Host.
 * Best-effort writes (no backpressure handling) — fine for eval-scale traffic.
 */
export class TcpForwarder {
  private listener: TCPSocketListener<undefined> | null = null;
  private readonly pairs = new Set<Pair>();
  private readonly bySocket = new WeakMap<Socket, Pair>();

  constructor(
    readonly port: number,
    private upstreamPort: number,
  ) {}

  start(): void {
    this.listener = listen({
      hostname: "127.0.0.1",
      port: this.port,
      socket: {
        open: (client) => this.onClientOpen(client),
        data: (client, data) => this.onClientData(client, data),
        close: (client) => this.closePair(this.bySocket.get(client)),
        error: (client) => this.closePair(this.bySocket.get(client)),
      },
    });
  }

  /** Point subsequently-accepted connections at a new upstream port. */
  retarget(upstreamPort: number): void {
    this.upstreamPort = upstreamPort;
  }

  /** Sever every live client so a same-URL peer redials into the current
   *  upstream target. */
  dropClients(): void {
    for (const pair of [...this.pairs]) this.closePair(pair);
  }

  stop(): void {
    this.dropClients();
    try {
      this.listener?.stop(true);
    } catch {
      /* already stopped */
    }
    this.listener = null;
  }

  private onClientOpen(client: Socket): void {
    const pair: Pair = { client, upstream: null, pending: [] };
    this.pairs.add(pair);
    this.bySocket.set(client, pair);
    void connect({
      hostname: "127.0.0.1",
      port: this.upstreamPort,
      socket: {
        open: (upstream) => {
          pair.upstream = upstream;
          this.bySocket.set(upstream, pair);
          for (const chunk of pair.pending) this.write(upstream, chunk);
          pair.pending = [];
        },
        data: (_upstream, data) => this.write(pair.client, data),
        close: () => this.closePair(pair),
        error: () => this.closePair(pair),
      },
    }).catch(() => this.closePair(pair));
  }

  private onClientData(client: Socket, data: Uint8Array): void {
    const pair = this.bySocket.get(client);
    if (!pair) return;
    if (pair.upstream) this.write(pair.upstream, data);
    else pair.pending.push(Uint8Array.from(data)); // copy: Bun may reuse the buffer
  }

  private write(sock: Socket, data: Uint8Array): void {
    try {
      sock.write(data);
    } catch {
      /* peer gone; the close cascade cleans up */
    }
  }

  private closePair(pair: Pair | undefined): void {
    if (!pair || !this.pairs.has(pair)) return;
    this.pairs.delete(pair);
    try {
      pair.client.end();
    } catch {
      /* already closed */
    }
    try {
      pair.upstream?.end();
    } catch {
      /* already closed */
    }
  }
}
