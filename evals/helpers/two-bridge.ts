import { randomUUID } from "node:crypto";
import { relaySlotId } from "antgrid-wire";
import type { HostFile } from "../../bridge/src/host-discovery";
import {
  createMessage,
  type AbMessage,
  type SessionBusAck,
  type SessionBusFetch,
  type SessionBusFetchResult,
  type SessionBusNotify,
  type SessionBusPost,
} from "../../bridge/src/protocol";
import { postJson } from "../support/session-bus";
import { firstProjectStream, resolveOnFreshAdvert } from "../support/stream";
import { generateAppIdentity, handshakeWithoutPairing, setupTestEnv, waitForHostFile, type TestEnv } from "./harness";
import { LocalTestClient, type LocalConnectInfo } from "./local-client";
import { RelayClient, type PhoneIdentity } from "./relay-client";

/**
 * Two real bridges, one relay, and the desktop app each of them has attached.
 *
 * A SIBLING of `setupTestEnv`, never a change to it: `helpers/harness.ts` is a
 * frozen shared surface, and the multi-machine rows are the only callers that
 * need a second machine. Composition also keeps the fidelity claim honest —
 * each half is exactly the env every single-machine row already runs against.
 *
 * The carrier here is a TEST OBJECT, never a third bridge: no bridge can dial
 * another (D7). It holds FOUR legs, because that is what the desktop apps hold
 * in production and because both directions have to work (§6.3 — a peer
 * initiates too):
 *
 * - a LOOPBACK owner socket on each machine. It is what `carrierPresent()`
 *   reads, so a machine without one refuses every off-machine send with
 *   `PEER_UNREACHABLE`, and it is the socket a bridge hands its own outbound
 *   frames to (lead-role dispatch, `sendToOwner`).
 * - a RELAY app session on each machine's project stream. It is how a frame
 *   OPENING an exchange enters the other bridge, and the only way in that
 *   leaves a route home: `noteRoute` is fed the app session that carried the
 *   frame, and a loopback delivery carries no such id.
 *
 * Routing follows that split exactly: a frame leaving a bridge over its
 * loopback goes to the target's RELAY leg, and one leaving over a relay leg
 * goes to the target's LOOPBACK leg. That is not a convention — it is the only
 * pairing that works. A frame off a loopback is its machine acting as LEAD, so
 * the far side is peer and needs the route only a relay arrival leaves; a frame
 * off a relay leg is the far side ANSWERING, addressed to the machine that
 * opened the context, which is lead there and needs no route at all. ONE
 * account identity drives both relay legs, which is what a real user has and
 * what re-exercises the per-machine relay slot (`relaySlotId`) end to end.
 */
export type MachineName = "a" | "b";

const MACHINE_NAMES: MachineName[] = ["a", "b"];

/** One machine, and everything a row addresses it through. */
export interface BridgeMachine {
  readonly name: MachineName;
  readonly env: TestEnv;
  /**
   * This bridge's bus address — its relay registration id, which is the bare
   * `deviceUuid` the harness also handshakes against.
   *
   * A row that wants this proven rather than assumed reads `machineId` off
   * `GET /session-bus/sessions` (or `session-bus:directory:result`) once a
   * session exists: a frame addressed to anything else is dropped unacked, so
   * a wrong id turns a routing bug into a silent timeout.
   */
  readonly machineId: string;
  /** The loopback control plane: the port and token every switch flip and
   *  directory push on this machine goes through. */
  readonly host: HostFile;
  /** The stream `env.app` drives this machine's project verbs on. Not one of
   *  the carrier's legs on purpose: the carrier CONSUMES the bus frames its
   *  legs receive, so a row waiting on one of those clients would race it. */
  readonly streamId: string;
}

/** What one machine's card turned out to be this cycle, in the vocabulary
 *  `session-bus:remote-directory` takes (`control-protocol.ts`). */
export type DirectoryOutcome = "rows" | "no-card" | "refused" | "reach-refused" | "unreachable";

/** One half of a directory pump: one machine's rows, offered to the other. */
export interface DirectoryPush {
  /** The machine whose mirror this filled. */
  into: MachineName;
  /** The machine whose card was read. */
  about: MachineName;
  outcome: DirectoryOutcome;
  rows: unknown[];
  truncated: number;
  /** The receiving bridge's own answer, verbatim: `accepted`/`dropped` when it
   *  took the push, `error.code` when it refused it. Never reduced to a
   *  boolean — a push that was accepted and mirrored NOTHING is a different
   *  failure from one the bridge would not take, and both end as
   *  `UNKNOWN_PEER` at the next send. */
  ack: any;
  /** Why this card read as `unreachable`, when it did. Three unlike failures
   *  share that outcome and only this separates them. */
  why?: string;
}

export interface Carrier {
  /** Every session-bus frame any leg observed, in arrival order. */
  readonly frames: AbMessage[];
  /** Frames the carrier could not hand to the machine they were addressed to —
   *  a stopped carrier, a machine whose app is detached, or an address on
   *  neither machine. Kept rather than swallowed: a row staging an outage
   *  asserts on this, and a routing bug surfaces here instead of as a silent
   *  timeout. */
  readonly undeliverable: AbMessage[];
  /** Resume forwarding. Already started by `setupTwoBridgeEnv`. */
  start(): void;
  /**
   * Stage a LOSSY link: both bridges stay live and both believe every frame
   * left, and nothing crosses.
   *
   * Not an unreachable machine. The sending bridge has already been told the
   * frame was carried, so nothing retries it and `start()` does not flush what
   * was staged — use `detachApp` for a machine that cannot send at all.
   */
  stop(): void;
  /** The desktop app on one machine quitting: its loopback socket closes, so
   *  that machine's own off-machine sends refuse `PEER_UNREACHABLE` and frames
   *  addressed INTO it have nowhere to land. */
  detachApp(machine: MachineName): void;
  /** The app coming back. The bridge's outbox retries on its own timer, so
   *  what it held while the app was gone goes out shortly after this. */
  attachApp(machine: MachineName): Promise<void>;
  /**
   * One cycle of the app's remote-directory pump, in both directions.
   *
   * Without it each machine's mirror is empty and EVERY cross-machine send
   * answers `UNKNOWN_PEER`: a bridge cannot ask another bridge what sessions
   * it holds, so the only thing that ever fills the mirror is this push. The
   * push is also the carrier heartbeat the mirror ages out on, so a long row
   * pumps again rather than once (`REMOTE_CARRIER_SILENCE_MS`).
   *
   * Both halves are read over the relay and pushed over loopback, exactly as
   * the app does it — and both are gated on the ANSWERING machine's remote
   * access and agent reach, and on the RECEIVING machine's remote access. A
   * row that flips a switch pumps before it flips.
   */
  pumpDirectory(): Promise<DirectoryPush[]>;
}

export interface TwoBridgeEnv {
  a: BridgeMachine;
  b: BridgeMachine;
  carrier: Carrier;
  /** The one account device id every relay leg connects under. */
  account: string;
  identity: PhoneIdentity;
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
 * Drill into a project's stream on a freshly handshaked client.
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
  return resolveOnFreshAdvert(app, projectId, {
    attempts: 15,
    gapMs: 100,
    resolve: async (client) => {
      await firstProjectStream(client, projectId, 700);
      return client.openProjectStream(projectId, 10_000);
    },
  });
}

/** The desktop app's own view of a peer machine's sessions, over the relay
 *  control plane — the ONLY read that carries them, and the input the pump
 *  pushes home. Classified into the five outcomes the wire verb names, because
 *  a caller that cannot tell "that machine refused" from "nobody answered"
 *  renders both as "nobody else is there".
 *
 *  `unreachable` is the outcome three unlike failures share — a timeout, a dead
 *  leg, and an answer of a shape nothing here recognises — so it carries `why`
 *  as well. Without it a row that fails on this read reports that a machine
 *  said nothing, which is the one explanation that is never actionable. */
async function readSessionCard(
  app: RelayClient,
  timeoutMs = 10_000,
): Promise<{ outcome: DirectoryOutcome; rows: unknown[]; truncated: number; why?: string }> {
  const requestId = randomUUID();
  let failure: string | undefined;
  // Armed before the send: the answer can arrive inside the same tick.
  const answered = app
    .waitFor((m: any) => m.type === "response" && m.requestId === requestId, timeoutMs)
    .catch((err: unknown) => {
      failure = err instanceof Error ? err.message : String(err);
      return null;
    });
  app.sendEncrypted(
    createMessage("request", {
      requestId,
      method: "machine.capability-card",
      params: { includeSessions: true },
    }),
  );
  const res = (await answered) as
    | { ok?: boolean; result?: { sessions?: unknown[]; sessionsTruncated?: number }; error?: { code?: string } }
    | null;
  if (res === null) return { outcome: "unreachable", rows: [], truncated: 0, why: failure ?? "no answer" };
  if (!res.ok) {
    const code = res.error?.code;
    if (code === "NOT_ALLOWED_AGENT_REACH") return { outcome: "reach-refused", rows: [], truncated: 0 };
    if (code === "NOT_ALLOWED") return { outcome: "refused", rows: [], truncated: 0 };
    return { outcome: "unreachable", rows: [], truncated: 0, why: `refused ${code ?? "with no code"}` };
  }
  const sessions = res.result?.sessions;
  // An absent key is a bridge that does not know `includeSessions`, which is a
  // different fact from a bridge that answered none.
  if (!Array.isArray(sessions)) return { outcome: "no-card", rows: [], truncated: 0 };
  return { outcome: "rows", rows: sessions, truncated: res.result?.sessionsTruncated ?? 0 };
}

/** `project:start` on a machine's loopback control plane, whose answer carries
 *  the port and token the owner socket connects with. */
async function startProject(machine: BridgeMachine): Promise<LocalConnectInfo> {
  const started = await postJson(
    `http://127.0.0.1:${machine.host.controlPort}/control`,
    { id: `two-bridge-start-${randomUUID()}`, type: "project:start", projectId: machine.env.projectId },
    machine.host.token,
  ) as { ok?: boolean; connect?: LocalConnectInfo };
  if (!started.ok || !started.connect) {
    throw new Error(`project:start on machine ${machine.name} failed: ${JSON.stringify(started)}`);
  }
  return started.connect;
}

type BusFrame = SessionBusPost | SessionBusNotify | SessionBusFetch | SessionBusFetchResult | SessionBusAck;

// The five frames a bridge actually carries between machines — the same set
// `SessionBusCoordinator.handleInbound` (bridge/src/session-bus/coordinator.ts)
// enumerates. NOT a `session-bus:` prefix match: that prefix also covers the
// app's own reads of its bridge (inbox, directory, arrived, …), which carry no
// `to.machineId` and so would land in `undeliverable` on every run — silent
// today only because nothing asserts on that array yet.
//
// Filled through the frame types and read back as plain strings: the element
// type makes a name the protocol renamed a compile error here, and the wider
// read is what lets an arrival of any shape be tested.
const BUS_FRAME_TYPES: ReadonlySet<string> = new Set<BusFrame["type"]>([
  "session-bus:post",
  "session-bus:notify",
  "session-bus:fetch",
  "session-bus:fetch:result",
  "session-bus:ack",
]);

/** A predicate rather than a boolean so the routing below reads `to` off the
 *  frame itself: every one of the five declares it, and a cast there would
 *  survive the field being renamed and route nothing. */
function isBusFrame(m: unknown): m is BusFrame {
  if (typeof m !== "object" || m === null || !("type" in m)) return false;
  return typeof m.type === "string" && BUS_FRAME_TYPES.has(m.type);
}

type LegKind = "loopback" | "relay";

class TwoBridgeCarrier implements Carrier {
  readonly frames: AbMessage[] = [];
  readonly undeliverable: AbMessage[] = [];
  private running = false;
  private disposed = false;
  private readonly pumps: Promise<void>[] = [];
  private readonly loopbacks: Record<MachineName, LocalTestClient | null> = { a: null, b: null };
  private readonly unsubscribe: Record<MachineName, (() => void) | null> = { a: null, b: null };

  constructor(
    private readonly machines: Record<MachineName, BridgeMachine>,
    private readonly relays: Record<MachineName, RelayClient>,
    private readonly relayStreams: Record<MachineName, string>,
  ) {}

  /** Begin forwarding. The relay legs are pumped from here; each machine's app
   *  is attached separately, and a row may take one away again. */
  open(): void {
    this.running = true;
    for (const name of MACHINE_NAMES) this.pumps.push(this.pumpRelayLeg(name));
  }

  start(): void {
    this.running = true;
  }

  stop(): void {
    this.running = false;
  }

  detachApp(machine: MachineName): void {
    this.unsubscribe[machine]?.();
    this.unsubscribe[machine] = null;
    this.loopbacks[machine]?.close();
    this.loopbacks[machine] = null;
  }

  async attachApp(machine: MachineName): Promise<void> {
    this.detachApp(machine);
    const connect = await startProject(this.machines[machine]);
    const client = new LocalTestClient();
    // Subscribed BEFORE the hello resolves: a frame the bridge replays on
    // connect must not land in the gap between `connect()` and the first
    // listener.
    this.unsubscribe[machine] = client.on((m) => this.observe(m, machine, "loopback"));
    this.loopbacks[machine] = client;
    await client.connect(connect, { capabilities: { sessionBusCarrier: true } });
  }

  async pumpDirectory(): Promise<DirectoryPush[]> {
    // Each machine's rows into the OTHER machine's mirror: a mirror holds only
    // peers, and a bridge reads its own sessions live.
    return [await this.pushDirectory("b", "a"), await this.pushDirectory("a", "b")];
  }

  dispose(): void {
    this.disposed = true;
    this.running = false;
    for (const name of MACHINE_NAMES) this.detachApp(name);
  }

  async settle(): Promise<void> {
    await Promise.all(this.pumps.map((p) => p.catch(() => {})));
  }

  private async pushDirectory(about: MachineName, into: MachineName): Promise<DirectoryPush> {
    const answer = await readSessionCard(this.relays[about]);
    const host = this.machines[into].host;
    const ack = await postJson(
      `http://127.0.0.1:${host.controlPort}/control`,
      {
        id: `two-bridge-directory-${randomUUID()}`,
        type: "session-bus:remote-directory",
        machines: [
          {
            machineId: this.machines[about].machineId,
            observedAt: Date.now(),
            outcome: answer.outcome,
            rows: answer.rows,
            truncated: answer.truncated,
          },
        ],
        notConnected: 0,
      },
      host.token,
    );
    return { into, about, ...answer, ack };
  }

  // The carrier moves BYTES, not meaning: a frame is forwarded exactly as it
  // arrived. Never re-`createMessage` it, never re-stamp `from`/`to`/
  // `contextId`/`threadId`, never fill in a field the sender left out. Each of
  // those is a fact only a bridge may author — a carrier that repairs a frame
  // turns a protocol bug on one machine into agreed state on both, and the
  // ack/retry ladder stops meaning anything.
  private observe(frame: AbMessage, from: MachineName, leg: LegKind): void {
    if (!isBusFrame(frame)) return;
    this.frames.push(frame);
    if (!this.running) { this.undeliverable.push(frame); return; }
    // Routed by ADDRESS, never by the leg it arrived on: `to` is the only thing
    // that says which machine owes this frame, and a member on neither machine
    // has to be visibly undeliverable rather than quietly handed to whichever
    // leg happened to be open. The leg it arrived on decides only HOW it is
    // handed over — see this class's own doc.
    const to = frame.to?.machineId;
    const target = MACHINE_NAMES.find((name) => this.machines[name].machineId === to);
    // A frame addressed to the machine that just sent it is one no carrier
    // should ever see: a same-machine send is handed straight to the target's
    // delivery queue and never leaves the bridge.
    if (target !== undefined && target !== from) {
      try {
        if (leg === "loopback") {
          this.relays[target].sendOnStream(this.relayStreams[target], frame);
          return;
        }
        const loopback = this.loopbacks[target];
        if (loopback) { loopback.send(frame, "control"); return; }
      } catch {
        // A closed leg is the same fact as an unreachable machine.
      }
    }
    this.undeliverable.push(frame);
  }

  /** A relay leg is a `RelayClient`, which has no listener hook — so it is
   *  polled with a re-arming short `waitFor`. `waitForCancelable` scans what has
   *  already arrived before it arms, so the gap between arms loses nothing, and
   *  it splices what it matches, so nothing is forwarded twice. */
  private async pumpRelayLeg(machine: MachineName): Promise<void> {
    const leg = this.relays[machine];
    while (!this.disposed) {
      let frame: any;
      try {
        frame = await leg.waitFor(isBusFrame, 200);
      } catch {
        continue;
      }
      if (this.disposed) return;
      // `_streamId` is the harness's own arrival stamp (`RelayClient`), not part
      // of the frame — dropping it un-stamps the transport, it does not edit
      // what the bridge sent.
      const { _streamId, ...rest } = frame;
      this.observe(rest as AbMessage, machine, "relay");
    }
  }
}

export async function setupTwoBridgeEnv(opts: {
  fixtureName?: string;
  prepareProject?: (dir: string) => void | Promise<void>;
  /** Agent env for BOTH bridges. */
  env?: Record<string, string>;
  /** Agent env for one machine only — the PTY sink path has to differ per
   *  machine, and the sink script reads one fixed variable name. */
  envA?: Record<string, string>;
  envB?: Record<string, string>;
} = {}): Promise<TwoBridgeEnv> {
  const fixtureName = opts.fixtureName ?? "basic";

  // ONE relay, two bridges — machine A's env owns it, so B must be torn down
  // first (see `teardown`).
  const envA = await setupTestEnv({
    fixtureName,
    prepareProject: opts.prepareProject,
    env: { ...opts.env, ...opts.envA },
  });
  // Every handle below reaches the caller ONLY through the `TwoBridgeEnv` this
  // resolves with, so a throw partway leaves two bridges, their PTY trees, both
  // fake licence servers and the shared relay running with nothing left holding
  // them — and the rows that follow then fight those ports for the rest of the
  // process. The catch unwinds in `teardown`'s own order.
  let builtEnvB: TestEnv | undefined;
  const builtRelayLegs: RelayClient[] = [];
  let builtCarrier: TwoBridgeCarrier | undefined;
  try {
    const envB = await setupTestEnv({
      fixtureName,
      relay: envA.relay,
      prepareProject: opts.prepareProject,
      env: { ...opts.env, ...opts.envB },
    });
    builtEnvB = envB;

    const { account, identity } = await seedSharedAccountDevice(envA, envB);

    const machines = {} as Record<MachineName, BridgeMachine>;
    const relays = {} as Record<MachineName, RelayClient>;
    const relayStreams = {} as Record<MachineName, string>;
    for (const [name, env] of [["a", envA], ["b", envB]] as Array<[MachineName, TestEnv]>) {
      machines[name] = {
        name,
        env,
        machineId: env.agentDeviceId,
        host: await waitForHostFile(env.abDir, 15_000),
        // The row's own client joins the project stream so it can drive that
        // machine's session verbs. The leak invariants do NOT rest on that
        // join: a bridge broadcast reaches every established app session
        // whether or not it joined a stream (see `resolveStream`), which is
        // what makes "no carried frame ever arrived here" a fact about the
        // bridge rather than about this client's subscriptions.
        streamId: await resolveStream(env.app, env.projectId),
      };
      const leg = await connectSlotted(env, identity, account, env.agentDeviceId);
      builtRelayLegs.push(leg);
      relays[name] = leg;
      relayStreams[name] = await resolveStream(leg, env.projectId);
    }

    const carrier = new TwoBridgeCarrier(machines, relays, relayStreams);
    builtCarrier = carrier;
    carrier.open();
    for (const name of MACHINE_NAMES) await carrier.attachApp(name);

    return {
      a: machines.a,
      b: machines.b,
      carrier,
      account,
      identity,
      async teardown() {
        carrier.stop();
        carrier.dispose();
        await carrier.settle();
        for (const leg of builtRelayLegs) await leg.disconnect().catch(() => {});
        // B first: A owns the shared relay and stops it on teardown.
        await envB.teardown();
        await envA.teardown();
      },
    };
  } catch (err) {
    // Each step guarded on its own: a cleanup that throws must not replace the
    // failure the caller needs to read.
    try {
      builtCarrier?.stop();
      builtCarrier?.dispose();
      await builtCarrier?.settle();
    } catch { /* nothing left to salvage */ }
    for (const leg of builtRelayLegs) await leg.disconnect().catch(() => {});
    await builtEnvB?.teardown().catch(() => {});
    await envA.teardown().catch(() => {});
    throw err;
  }
}
