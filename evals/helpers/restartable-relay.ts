import { allocatePort } from "./harness";
import { TcpForwarder } from "./tcp-forwarder";

type RelayServer = ReturnType<typeof import("../../relay/src/server").startServer>;

/** The relay binds an OS-assigned port (config `port: 0`), so `.port` is always
 *  a real TCP port here — narrow away Bun's `number | undefined` (unix-socket case). */
function boundPort(server: RelayServer): number {
  const p = server.server.port;
  if (p == null) throw new Error("relay server has no bound TCP port");
  return p;
}

export interface RestartableRelay {
  /** Stable client-facing URL; unchanged across restarts so a same-URL client
   *  (the agent's unattended redial) always finds the relay. */
  readonly url: string;
  connectionCount(): number;
  /** Force-close live sockets + stop the CURRENT relay. The harness's graceful
   *  stop leaves existing WebSockets open (the agent then never redials), so we
   *  sever each live `ws` explicitly. Leaves the forwarder up. */
  forceStop(): void;
  /** Force-stop the current relay and bring a fresh one up on a NEW OS-assigned
   *  port, re-pointing the forwarder. Clients keep dialing `url` and reconnect
   *  unattended — no same-port rebind, so no Windows EADDRINUSE window. */
  restart(): void;
  /** Final teardown: stop the current relay and the forwarder. */
  stop(): void;
}

/**
 * A relay fronted by a stable-port {@link TcpForwarder}. Each (re)start binds
 * the relay to an OS-assigned ephemeral port and re-points the forwarder, so
 * the relay never rebinds a just-closed port — the source of the flaky
 * same-port EADDRINUSE on this dev box. `makeServer` is a thunk (config + gate
 * live in the caller) invoked once per start.
 */
export function startRestartableRelay(makeServer: () => RelayServer): RestartableRelay {
  const stablePort = allocatePort();
  let server = makeServer();
  const forwarder = new TcpForwarder(stablePort, boundPort(server));
  forwarder.start();

  const forceStopServer = (): void => {
    for (const c of server.connections.listConnections()) {
      const conn = server.connections.getByDeviceId(c.deviceId);
      try {
        conn?.ws.close();
      } catch {
        /* already closing */
      }
    }
    server.stop();
    server.server.stop(true);
  };

  return {
    url: `ws://localhost:${stablePort}/ws`,
    connectionCount: () => server.connections.getConnectionCount(),
    forceStop: forceStopServer,
    restart() {
      forceStopServer();
      server = makeServer();
      forwarder.retarget(boundPort(server));
    },
    stop() {
      forceStopServer();
      forwarder.stop();
    },
  };
}
