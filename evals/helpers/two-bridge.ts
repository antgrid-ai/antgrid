import { relaySlotId } from "antgrid-wire";
import type { HostFile } from "../../bridge/src/host-discovery";
import type { AbMessage } from "../../bridge/src/protocol";
import { firstProjectStream } from "../support/stream";
import { generateAppIdentity, handshakeWithoutPairing, setupTestEnv, waitForHostFile, type TestEnv } from "./harness";
import { LocalTestClient, type LocalConnectInfo } from "./local-client";
import { RelayClient, type PhoneIdentity } from "./relay-client";

/**
 * Two real bridges, one relay, one desktop app between them.
 *
 * A SIBLING of `setupTestEnv`, never a change to it: `helpers/harness.ts` is a
 * frozen shared surface, and the multi-machine rows are the only callers that
 * need a second machine. Composition also keeps the fidelity claim honest —
 * each half is exactly the env every single-machine row already runs against.
 *
 * The carrier here is a TEST OBJECT with two legs, and never a third bridge: no
 * bridge can reach another (D7). Its lead leg is the loopback owner socket the
 * desktop app holds over an open project; its peer leg is an ordinary relay app
 * session on the peer's project stream. ONE account identity drives both, which
 * is what a real user has and what re-exercises the per-machine relay slot
 * (`relaySlotId`) end to end.
 */
export interface Carrier {
  /** Every session-bus frame either leg observed, in arrival order. */
  readonly frames: AbMessage[];
  /** Frames the carrier could not hand to the machine they were addressed to —
   *  an unreachable member, or a leg that is closed or stopped. Kept rather
   *  than swallowed: a scenario staging an unreachable machine asserts on this,
   *  and a routing bug surfaces here instead of as a silent timeout. */
  readonly droppedToPeer: AbMessage[];
  /** Resume forwarding. Already started by `setupTwoBridgeEnv`. */
  start(): void;
  /** Stage an unreachable peer WITHOUT killing a bridge: both legs stay open
   *  and both bridges stay live, but nothing crosses. */
  stop(): void;
}

export interface TwoBridgeEnv {
  lead: TestEnv;
  peer: TestEnv;
  carrier: Carrier;
  /** The one account device id both legs connect under. */
  account: string;
  identity: PhoneIdentity;
  leadMachineId: string;
  peerMachineId: string;
  /** The peer project's stream on the carrier's peer leg. */
  peerStreamId: string;
  /** The lead project's stream on `lead.app` — where the app drives A's own
   *  session verbs, and the channel the leak invariants watch. */
  leadStreamId: string;
  /** The carrier's peer leg. Raw `RelayClient`, not `TestApp`: the forwarding
   *  loop needs `waitFor`/`sendOnStream`, which the wrapper does not expose. */
  peerApp: RelayClient;
  /** The carrier's lead leg — the loopback owner socket. */
  leadCarrier: LocalTestClient;
  leadHost: HostFile;
  peerHost: HostFile;
  /**
   * Re-establish the peer leg after `peer.restartAgent()`: the bridge came back
   * with fresh session keys and a freshly registered project stream, so the
   * handshake and the streamId both have to be resolved again.
   */
  rebindPeerLeg(): Promise<void>;
  teardown(): Promise<void>;
}

/**
 * One account device, seeded into BOTH fake inventories.
 *
 * Each bridge only ever consults its OWN `/account/devices/me/peers`, so an
 * account id seeded on one machine is unadmittable on the other. Seeded after
 * both agents started (and cached their startup inventory), which is why every
 * connect below goes through `handshakeWithoutPairing` — it retries on the SAME
 * socket until the bridge's inventory refresh lands.
 */
async function seedSharedAccountDevice(
  envA: TestEnv,
  envB: TestEnv,
): Promise<{ account: string; identity: PhoneIdentity }> {
  const generated = await generateAppIdentity();
  const account = generated.deviceId;
  const identity: PhoneIdentity = generated;
  await envA.license.addAccountDevice({ deviceId: account, identity });
  await envB.license.addAccountDevice({ deviceId: account, identity });
  return { account, identity };
}

/** Connect `identity` to `env` under the per-machine slot
 *  `<account>#<machineDeviceId>` — one account holding a live E2E session with
 *  two bridges at once, which is only possible because the relay keys the
 *  connection on the slot while the transcript stays bound to the bare account
 *  id. */
async function connectSlotted(
  env: TestEnv,
  identity: PhoneIdentity,
  account: string,
  machineDeviceId: string,
): Promise<RelayClient> {
  const client = await RelayClient.connectAndAuth(env.relay.url, {
    deviceType: "app",
    name: "two-bridge-carrier",
    identity,
    deviceId: relaySlotId(account, machineDeviceId),
    transcriptDeviceId: account,
  });
  await handshakeWithoutPairing(client, env.agentDeviceId, env.agent.ed25519Pubkey);
  return client;
}

/**
 * Drill into the peer's project stream on a freshly handshaked client.
 *
 * Two steps, both load-bearing. The advert says the project is dialable at all —
 * it is seeded only by a snapshot pull, and a project registers a beat after the
 * handshake establishes, the same race `setupTestEnv` polls out. `project:start`
 * is what JOINS the stream, which is what makes the project's verbs ADDRESSABLE
 * from this client. It is NOT what makes a broadcast reachable: `resolveRecipients`
 * (`bridge/src/relay-client.ts`) seals a broadcast for every established app
 * session and filters only on the mux's `where` predicate (`mayDeliverTo` in
 * `project-core.ts` — the checkout-routing capability), and the relay cannot
 * filter by stream at all, since the streamId travels inside the sealed payload.
 */
async function resolveStream(app: RelayClient, projectId: string): Promise<string> {
  let lastErr: unknown;
  for (let i = 0; i < 15; i++) {
    app.drainQueued("agent:projects");
    await app.pullStateSnapshot();
    try {
      await firstProjectStream(app, projectId, 700);
      return await app.openProjectStream(projectId, 10_000);
    } catch (err) {
      lastErr = err;
      await Bun.sleep(100);
    }
  }
  throw new Error(`no streamId advertised for project ${projectId}: ${String(lastErr)}`);
}

// The five frames a bridge actually carries between machines — the same set
// `SessionBusCoordinator.handleInbound` (bridge/src/session-bus/coordinator.ts)
// enumerates. NOT a `session-bus:` prefix match: that prefix also covers the
// app's own reads of its bridge (inbox, directory, unread, …), which carry no
// `to.machineId` and so would land in `droppedToPeer` on every run — silent
// today only because nothing asserts on that array yet.
const BUS_FRAME_TYPES = new Set([
  "session-bus:post",
  "session-bus:notify",
  "session-bus:fetch",
  "session-bus:fetch:result",
  "session-bus:ack",
]);

function isBusFrame(m: any): boolean {
  return typeof m?.type === "string" && BUS_FRAME_TYPES.has(m.type);
}

class TwoBridgeCarrier implements Carrier {
  readonly frames: AbMessage[] = [];
  readonly droppedToPeer: AbMessage[] = [];
  private running = false;
  private disposed = false;
  private pump: Promise<void> | null = null;
  private unsubscribeLead: (() => void) | null = null;

  constructor(
    private readonly leadLeg: LocalTestClient,
    private readonly peerLeg: RelayClient,
    private peerStreamId: string,
    private readonly leadMachineId: string,
    private readonly peerMachineId: string,
  ) {}

  attach(): void {
    this.unsubscribeLead = this.leadLeg.on((m) => this.observe(m));
    this.running = true;
    this.pump = this.pumpPeerLeg();
  }

  start(): void {
    this.running = true;
  }

  stop(): void {
    this.running = false;
  }

  /** After a peer bridge restart: the stream its project is reachable on is
   *  reallocated, and forwarding to the old one would go nowhere. */
  repointPeerStream(streamId: string): void {
    this.peerStreamId = streamId;
  }

  dispose(): void {
    this.disposed = true;
    this.running = false;
    this.unsubscribeLead?.();
    this.unsubscribeLead = null;
  }

  async settle(): Promise<void> {
    await this.pump?.catch(() => {});
  }

  // The carrier moves BYTES, not meaning: a frame is forwarded exactly as it
  // arrived. Never re-`createMessage` it, never re-stamp `from`/`to`/`seq`/
  // `taskId`, never fill in a field the sender left out. Each of those is a fact
  // only a bridge may author — a carrier that repairs a frame turns a protocol
  // bug on one machine into agreed state on both, and the ack/retry ladder stops
  // meaning anything.
  private observe(frame: AbMessage): void {
    if (!isBusFrame(frame)) return;
    this.frames.push(frame);
    if (!this.running) { this.droppedToPeer.push(frame); return; }
    // Routed by ADDRESS, never by the leg it arrived on: `to` is the only thing
    // that says which machine owes this frame, and a member on neither machine
    // has to be visibly undeliverable rather than quietly handed to whichever
    // leg happened to be open.
    const to = (frame as any).to?.machineId;
    try {
      if (to === this.peerMachineId) { this.peerLeg.sendOnStream(this.peerStreamId, frame); return; }
      // Inbound to A goes back down the SAME loopback leg rather than over the
      // phone's project stream: that socket is the only inbound bus route the
      // desktop carrier has, and a frame arriving any other way would exercise a
      // path production never takes.
      if (to === this.leadMachineId) { this.leadLeg.send(frame, "control"); return; }
    } catch {
      // A closed leg is the same fact as an unreachable machine.
    }
    this.droppedToPeer.push(frame);
  }

  /** The peer leg is a `RelayClient`, which has no listener hook — so it is
   *  polled with a re-arming short `waitFor`. `waitForCancelable` scans what has
   *  already arrived before it arms, so the gap between arms loses nothing. */
  private async pumpPeerLeg(): Promise<void> {
    while (!this.disposed) {
      let frame: any;
      try {
        frame = await this.peerLeg.waitFor(isBusFrame, 200);
      } catch {
        continue;
      }
      if (this.disposed) return;
      // `_streamId` is the harness's own arrival stamp (`RelayClient`), not part
      // of the frame — dropping it un-stamps the transport, it does not edit
      // what the bridge sent.
      const { _streamId, ...rest } = frame;
      this.observe(rest as AbMessage);
    }
  }
}

export async function setupTwoBridgeEnv(opts: {
  fixtureName?: string;
  prepareProject?: (dir: string) => void | Promise<void>;
  /** Agent env for BOTH bridges. */
  env?: Record<string, string>;
  /** Agent env for one side only — the PTY sink path has to differ per machine,
   *  and the sink script reads one fixed variable name. */
  leadEnv?: Record<string, string>;
  peerEnv?: Record<string, string>;
} = {}): Promise<TwoBridgeEnv> {
  const fixtureName = opts.fixtureName ?? "basic";

  // ONE relay, two bridges — the lead env owns it, so the peer must be torn
  // down first (see `teardown`).
  const lead = await setupTestEnv({
    fixtureName,
    prepareProject: opts.prepareProject,
    env: { ...opts.env, ...opts.leadEnv },
  });
  // Every handle below reaches the caller ONLY through the `TwoBridgeEnv` this
  // resolves with, so a throw partway leaves two bridges, their PTY trees, both
  // fake licence servers and the shared relay running with nothing left holding
  // them — and the rows that follow then fight those ports for the rest of the
  // process. The catch unwinds in `teardown`'s own order.
  let builtPeer: TestEnv | undefined;
  let builtPeerApp: RelayClient | undefined;
  let builtLeadCarrier: LocalTestClient | undefined;
  let builtCarrier: TwoBridgeCarrier | undefined;
  try {
    const peer = await setupTestEnv({
      fixtureName,
      relay: lead.relay,
      prepareProject: opts.prepareProject,
      env: { ...opts.env, ...opts.peerEnv },
    });
    builtPeer = peer;

    const { account, identity } = await seedSharedAccountDevice(lead, peer);

    // The phone joins A's project stream so the scenarios can address A's own
    // session verbs on it. The leak invariants do NOT rest on that join: a bridge
    // broadcast reaches every established app session whether or not it joined a
    // stream (see `resolveStream`), which is exactly what makes "no bus frame ever
    // arrived here" a fact about the bridge on either client.
    const leadStreamId = await resolveStream(lead.app, lead.projectId);

    // --- lead leg: the desktop app's loopback owner socket ---
    // D7 again: the lead bridge addresses every outbound frame to this socket and
    // nowhere else, and only once the owner declares itself the carrier.
    const leadHost = await waitForHostFile(lead.abDir, 15_000);
    const started = await fetch(`http://127.0.0.1:${leadHost.controlPort}/control`, {
      method: "POST",
      headers: { "Content-Type": "application/json", authorization: `Bearer ${leadHost.token}` },
      body: JSON.stringify({ id: "two-bridge-carrier", type: "project:start", projectId: lead.projectId }),
    }).then((r) => r.json() as Promise<{ ok?: boolean; connect?: LocalConnectInfo }>);
    if (!started.ok || !started.connect) {
      throw new Error(`project:start on the lead failed: ${JSON.stringify(started)}`);
    }
    const leadCarrier = new LocalTestClient();
    builtLeadCarrier = leadCarrier;

    // --- peer leg: an ordinary relay app session on the peer's project stream ---
    const peerApp = await connectSlotted(peer, identity, account, peer.agentDeviceId);
    builtPeerApp = peerApp;
    const peerStreamId = await resolveStream(peerApp, peer.projectId);
    const peerHost = await waitForHostFile(peer.abDir, 15_000);

    const carrier = new TwoBridgeCarrier(
      leadCarrier,
      peerApp,
      peerStreamId,
      lead.agentDeviceId,
      peer.agentDeviceId,
    );
    builtCarrier = carrier;
    // Subscribed BEFORE the hello resolves: a frame the bridge replays on connect
    // must not land in the gap between `connect()` and the first listener.
    carrier.attach();
    await leadCarrier.connect(started.connect, { capabilities: { sessionBusCarrier: true } });

    const env: TwoBridgeEnv = {
      lead,
      peer,
      carrier,
      account,
      identity,
      // The bridge's own half of every bus address. Taken from the harness here
      // and PROVEN against `GET /session-bus/role` in each scenario — a frame
      // addressed to anything else is dropped unacked, so an assumed id would
      // turn a routing bug into a silent timeout.
      leadMachineId: lead.agentDeviceId,
      peerMachineId: peer.agentDeviceId,
      peerStreamId,
      leadStreamId,
      peerApp,
      leadCarrier,
      leadHost,
      peerHost,
      async rebindPeerLeg() {
        // The relay closes an agent's streams when it disconnects, and
        // `RelayClient` never invalidates its own project->stream cache on a
        // peer-offline — so the stale entry has to go before the re-drill, or the
        // carrier keeps forwarding onto a stream id the relay no longer routes.
        (peerApp as unknown as { streamByProject: Map<string, string> }).streamByProject.delete(peer.projectId);
        // Generous: the fresh process has to spawn, register with the relay and
        // become routable before a client-hello can be answered at all.
        await handshakeWithoutPairing(peerApp, peer.agentDeviceId, peer.agent.ed25519Pubkey, {
          attempts: 30,
          perAttemptTimeoutMs: 2_000,
          gapMs: 300,
        });
        const next = await resolveStream(peerApp, peer.projectId);
        env.peerStreamId = next;
        carrier.repointPeerStream(next);
      },
      async teardown() {
        carrier.stop();
        carrier.dispose();
        await carrier.settle();
        leadCarrier.close();
        await peerApp.disconnect().catch(() => {});
        // Peer first: `lead` owns the shared relay and stops it on teardown.
        await peer.teardown();
        await lead.teardown();
      },
    };
    return env;
  } catch (err) {
    // Each step guarded on its own: a cleanup that throws must not replace the
    // failure the caller needs to read.
    try {
      builtCarrier?.stop();
      builtCarrier?.dispose();
      await builtCarrier?.settle();
    } catch { /* nothing left to salvage */ }
    try { builtLeadCarrier?.close(); } catch { /* already closed */ }
    await builtPeerApp?.disconnect().catch(() => {});
    await builtPeer?.teardown().catch(() => {});
    await lead.teardown().catch(() => {});
    throw err;
  }
}
