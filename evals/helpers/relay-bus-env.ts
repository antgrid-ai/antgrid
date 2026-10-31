import { randomUUID } from "node:crypto";
import { join } from "node:path";
import { computeProjectId } from "../../bridge/src/project-id";
import { createMessage } from "../../bridge/src/protocol";
import { createTestProject } from "./fixtures";
import {
  allocatePort,
  generateEvalAuth,
  setMobileAccess,
  spawnAgent,
  startFakeLicenseApi,
  startRelay,
  waitForHostFile,
  type AgentHandle,
  type EvalAuth,
  type FakeLicenseApi,
  type RelayHandle,
} from "./harness";
import { LocalTestClient, type LocalConnectInfo } from "./local-client";
import {
  SINK_SCRIPT_NAME,
  localVerb,
  postJson,
  prepareBusProject,
  untilAsync,
  type LocalBridge,
} from "../support/session-bus";

/**
 * Two real bridges on one relay and one account, with no app anywhere.
 *
 * A sibling of `setupTestEnv`, never a change to it: the harness is a frozen
 * shared surface and only the cross-machine bus rows need a second machine.
 * Both bridges share one fake licence API, which is what puts them in one
 * account directory; each keeps its own identity, project and PTY sink.
 */
export type MachineName = "a" | "b";

export interface RelayBusMachine {
  readonly name: MachineName;
  readonly auth: EvalAuth;
  readonly agent: AgentHandle;
  /** The bare device id, which is the bus address of this machine. */
  readonly machineId: string;
  readonly abDir: string;
  readonly projectDir: string;
  readonly projectId: string;
  readonly sinkPath: string;
  /** A loopback owner over this machine's project, reconnected on demand: a
   *  restart closes the previous socket. */
  local(): Promise<Pick<LocalBridge, "client">>;
  /** Kill the process; state on disk survives. */
  kill(): Promise<void>;
  /** Run `fn` when the env is torn down. */
  onStop(fn: () => void): void;
  /** Respawn over the same state, then re-open the remote-access switch. */
  restart(): Promise<void>;
}

export interface RelayBusEnv {
  relay: RelayHandle;
  license: FakeLicenseApi;
  a: RelayBusMachine;
  b: RelayBusMachine;
  /** Both machines have registered a bus key and read each other's from the
   *  account directory. Bounded by the directory refresh interval. */
  waitForBusKeys(timeoutMs?: number): Promise<void>;
  teardown(): Promise<void>;
}

export async function setupRelayBusEnv(opts: { tmp: string }): Promise<RelayBusEnv> {
  const relay = await startRelay({ port: allocatePort() });
  const license = startFakeLicenseApi({ relayInternalUrl: relay.httpUrl });
  const built: RelayBusMachine[] = [];
  const cleanups: Array<() => void | Promise<void>> = [];

  async function machine(name: MachineName): Promise<RelayBusMachine> {
    const auth = generateEvalAuth();
    const abDir = join(opts.tmp, `home-${name}`);
    const sinkPath = join(opts.tmp, `machine-${name}.log`);
    const project = createTestProject("basic", { __RELAY_URL__: relay.url.replace(/\/ws$/, "") });
    cleanups.push(() => project.cleanup());
    await prepareBusProject(project.dir);
    const projectId = computeProjectId(project.dir);
    const { mkdirSync } = await import("node:fs");
    mkdirSync(abDir, { recursive: true });

    const agent = await spawnAgent({
      relayUrl: relay.url,
      licenseApiUrl: license.url,
      abDir,
      projectDir: project.dir,
      auth,
      env: {
        ANTGRID_EVAL_TEST: "1",
        ANTGRID_EVAL_IROH_BIND_ADDR: `127.0.0.1:${allocatePort()}`,
        ANTGRID_EVAL_SINK: sinkPath,
      },
    });
    cleanups.push(() => agent.kill());
    await setMobileAccess(abDir, true);

    let client: LocalTestClient | null = null;
    const m: RelayBusMachine = {
      name,
      auth,
      agent,
      machineId: auth.deviceUuid,
      abDir,
      projectDir: project.dir,
      projectId,
      sinkPath,
      async local() {
        client?.close();
        const host = await waitForHostFile(abDir, 15_000);
        const started = await postJson(
          `http://127.0.0.1:${host.controlPort}/control`,
          { id: `relay-bus-start-${randomUUID()}`, type: "project:start", projectId },
          host.token,
        ) as { ok?: boolean; connect?: LocalConnectInfo };
        if (!started.ok || !started.connect) {
          throw new Error(`project:start on machine ${name} failed: ${JSON.stringify(started)}`);
        }
        client = new LocalTestClient();
        await client.connect(started.connect);
        return { client };
      },
      onStop(fn) { cleanups.push(fn); },
      async kill() {
        client?.close();
        client = null;
        await agent.kill();
      },
      async restart() {
        client?.close();
        client = null;
        await agent.restart();
        await setMobileAccess(abDir, true);
      },
    };
    cleanups.push(() => client?.close());
    built.push(m);
    return m;
  }

  try {
    const a = await machine("a");
    const b = await machine("b");
    return {
      relay,
      license,
      a,
      b,
      async waitForBusKeys(timeoutMs = 30_000) {
        await untilAsync(
          async () => (license.busKeyOf(a.machineId) && license.busKeyOf(b.machineId) ? true : undefined),
          timeoutMs,
          "both machines to register a bus key",
        );
        // Each bridge refreshes its directory after its own registration and
        // on a 20 s cadence, so the peer's key can lag the registration.
        // A throwaway probe address is not usable here (a send would create a
        // thread), so the wait is on the refresh window itself.
        await Bun.sleep(3_000);
      },
      async teardown() {
        for (const c of cleanups.reverse()) await Promise.resolve(c()).catch(() => {});
        license.stop();
        relay.stop();
      },
    };
  } catch (err) {
    for (const c of cleanups.reverse()) await Promise.resolve(c()).catch(() => {});
    license.stop();
    relay.stop();
    throw err;
  }
}

/** One session on a machine, started and ready to receive. `session:start` is
 *  required: work-status opens a turn only for a session it counts as running. */
export async function startSinkSession(m: RelayBusMachine, name: string): Promise<string> {
  const bridge = await m.local();
  const created = await localVerb(bridge, createMessage("session:create", {
    requestId: randomUUID(), name, command: `node ${SINK_SCRIPT_NAME}`, mode: "terminal",
  }));
  const sessionId = created.session.id as string;
  await localVerb(bridge, createMessage("session:start", { requestId: randomUUID(), sessionId }));
  return sessionId;
}
