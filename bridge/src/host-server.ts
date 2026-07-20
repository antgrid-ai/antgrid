import { randomBytes, randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { hostname } from "node:os";
import { basename, join } from "node:path";
import { ProjectCore, type ProjectCoreDeps, type ProjectCoreRemoteDeps, type PromotionHandle, type RegisterOutcome } from "./project-core";
import { OAuthClient, startTokenMaintenance } from "./auth/oauth-client";
import { cachedAccountPeerKeys } from "./account-peers";
import { sendHeartbeat } from "./heartbeat";
import { ControlListener } from "./control-listener";
import type { ControlRequest, ControlResponse } from "./control-protocol";
import { hostFilePath, writeHostFile, removeHostFile } from "./host-discovery";
import { loadPairedPhones, type PairedPhonesStore } from "./paired-phones";
import { loadMobileAccessPolicy, type MobileAccessPolicyStore } from "./mobile-access-policy";
import { resolveAbDir } from "./antgrid-dir";
import { VERSION } from "./version";
import type { DeviceIdentity } from "./device";
import type { ProjectSummary, ConnectInfo, PairedPhoneSummary, KnownProject } from "./control-protocol";
import { logger } from "./logger";
import { RelayClient, type RelayClientOptions } from "./relay-client";
import type { MachineRelaySession } from "./relay-promotion";
import type { AgentEnableRelay } from "./protocol";
import { MessageBus, type Channel } from "./message-bus";
import { dispatchRpc } from "./rpc/methods";
import { createPairingWindow, type PairingWindow } from "./pairing-window";
import { generateEphemeralKeypair } from "./key-exchange";
import { joinRelayWsPath } from "./relay-url";
import { createMessage } from "./protocol";
import { detectInstalledTools, type DetectOptions } from "./tool-detector";
import { isChatCapableTool } from "./structured/chat-capable";
import type { AbMessage, ProjectAdvertEntry, RpcRequest } from "./protocol";
import { z } from "zod";
import { SessionManager } from "./session-manager";
import { isSafeProjectId } from "./project-id";

const SessionsListParams = z.object({
  projectId: z.string(),
  includeArchived: z.boolean().optional(),
});

const SessionsDeleteParams = z.object({
  projectId: z.string(),
  sessionId: z.string().min(1),
});

/** Desktop warm-core cap (mirrors the app's kWarmCapLocal). The host runs on a
 *  dev machine, so there is no mobile cap. */
export const kHostWarmCap = 10;

export interface HostServerOptions {
  /** Machine-level remote config (device auth + relay/license endpoints).
   *  Present whenever a device record exists; cores opened with mode "remote"
   *  use it. Absent → only local cores can be opened. */
  remote?: HostRemoteConfig;
  /** Override the warm-core cap (tests). Defaults to kHostWarmCap. */
  warmCap?: number;
  /** Test seam: builds the lazy machine OAuth runtime on the first remote open.
   *  Defaults to {@link buildRemoteRuntime} (real OAuth + token maintenance). */
  remoteRuntimeFactory?: (r: HostRemoteConfig) => Promise<RemoteRuntime>;
  /** Test seam: builds the single machine {@link RelayClient}. Defaults to a
   *  real `new RelayClient(opts)` — overridden in tests to observe stream
   *  admission (onAdmitted/onRejected) without a live relay socket. */
  relayClientFactory?: (opts: RelayClientOptions) => RelayClient;
  /** Invoked when a `host:shutdown` control verb arrives (the app is closing).
   *  The entrypoint wires this to its process-level graceful shutdown (which
   *  calls {@link HostServer.shutdown} then exits). Absent → the verb is a
   *  no-op beyond its OK response. */
  onShutdownRequested?: () => void;
}

export interface HostRemoteConfig {
  relayUrl: string;
  licenseApiUrl: string;
  identity: DeviceIdentity;
  auth: { clientId: string; clientSecret: string; deviceUuid: string };
  /** Called when OAuth detects the credential was revoked (host exits). */
  onAuthRevoked: () => void;
}

export interface RemoteRuntime {
  maint: { getToken: () => string; stop: () => void };
  getAccountPeerKeys: () => Promise<Set<string>>;
}

/** The real machine OAuth runtime: mint an initial token, keep it fresh, and
 *  expose the account-peer-keys cache. Swappable via
 *  {@link HostServerOptions.remoteRuntimeFactory} for tests. The returned
 *  `oauth` client is captured inside `maint`; the host never needs it directly. */
async function buildRemoteRuntime(r: HostRemoteConfig): Promise<RemoteRuntime> {
  const oauth = new OAuthClient({
    licenseApiUrl: r.licenseApiUrl,
    clientId: r.auth.clientId,
    clientSecret: r.auth.clientSecret,
    onAuthRevoked: r.onAuthRevoked,
  });
  const initial = await oauth.mint();
  const maint = startTokenMaintenance(oauth, initial);
  const getAccountPeerKeys = cachedAccountPeerKeys({
    licenseApiUrl: r.licenseApiUrl,
    getToken: () => maint.getToken(),
  });
  return { maint, getAccountPeerKeys };
}

interface CatalogEntry {
  core: ProjectCore;
  path: string;
  mode: "local" | "remote";
  lastFocusedMs: number;
  // Set when an already-open LOCAL core has been promoted onto the relay (an
  // additive relay slot on its existing bus). Absence means not-yet-promoted;
  // presence makes a re-issued project:start idempotent. Distinct from the
  // legacy per-project promotion in project-core.ts (relay-promotion.ts).
  promotion?: PromotionHandle;
}

export interface OpenResult {
  running: boolean;
  connect: ConnectInfo | null;
}

export class HostServer {
  private readonly cores = new Map<string, CatalogEntry>();
  // In-flight open() promises keyed by projectId, so concurrent opens of the
  // same not-yet-open project share one core instead of each starting their own.
  private readonly opening = new Map<string, Promise<OpenResult>>();
  private nowCounter = 0; // monotonic stand-in for focus ordering
  private remoteRuntime: RemoteRuntime | null = null;
  // In-flight build of the machine OAuth runtime. Concurrent first-remote-opens
  // of distinct projects must share one mint, or each would start its own
  // token-maintenance timer and orphan all but the last (a leaked re-mint loop).
  private remoteRuntimePromise: Promise<RemoteRuntime> | null = null;
  private control: ControlListener | null = null;
  // The single machine-level trust store, shared by every project core so the
  // per-project allowlist gate reads one in-memory view. Constructed once here;
  // each core receives this exact instance via startCore().
  private readonly pairedPhonesStore: PairedPhonesStore = loadPairedPhones(resolveAbDir());
  private readonly mobileAccessPolicy: MobileAccessPolicyStore = loadMobileAccessPolicy(resolveAbDir());
  private stopPhonesWatch: (() => void) | null = null;
  // NON-AUTHORITATIVE hint catalog: projectId → {path, label}. Carries ZERO
  // trust state — authorization ALWAYS flows through pairedPhonesStore.isAllowed.
  // It only answers "where does projectId X live + what's its label" so a
  // known-but-STOPPED project can still be advertised. If projects.json is lost,
  // worst case a stopped project isn't advertised until reopened — no security
  // consequence. Persisted to <abDir>/projects.json.
  private readonly seenProjects: Map<string, SeenProject> = loadSeenProjects(seenProjectsPath());
  // The always-on, coreless control-plane relay registered under the BARE
  // deviceUuid (no projectId), used to advertise the project catalog and accept
  // allowlist-gated project verbs from a paired phone. Opened only when remote
  // config is present; one phone at a time on this registration (concurrent
  // multi-phone control is out of scope). null until startRemoteControlPlane().
  private controlPlaneRelay: RelayClient | null = null;
  // retained to prevent GC of the bus before shutdown
  private controlPlaneBus: MessageBus | null = null;
  // Machine remote config synthesized from the desktop wizard's `agent:enableRelay`
  // credentials when the host was launched WITHOUT remote config (local-only). Lets
  // `requireRemoteConfig()` bring the one machine socket up on demand.
  private wizardRemote: HostRemoteConfig | null = null;
  // projectId → the streamId its relay data-plane stream was allocated. Read by
  // buildProjectsAdvertisement (per-project streamId) and stream-ready. Populated
  // when a core attaches (remoteDepsFor's wrapper), cleared on detach.
  private readonly streamIds = new Map<string, string>();
  // Single-use pairing window for the control-plane registration. A phone pairs
  // to the bare deviceUuid here, distinct from per-project core pairings. Used
  // only when remote config is present (the control plane never opens otherwise).
  private readonly pairingWindow: PairingWindow = createPairingWindow();

  constructor(private readonly opts: HostServerOptions) {
    // Watch the backing file so external edits (e.g. `antgrid phones allow/deny`)
    // reload the shared store before the callback runs — every core's gate reads
    // the refreshed in-memory `phones` array live. On top of the reload we
    // re-advertise to the currently-connected control-plane phone so its project
    // picker reflects an allowlist change WITHOUT requiring a reconnect (the
    // advertisement is otherwise only sent on handshake / after project:start).
    // The fs.watch handle MUST be closed in shutdown() (see stopPhonesWatch).
    this.stopPhonesWatch = this.pairedPhonesStore.watch(() => {
      this.readvertiseToControlPlane();
    });
    this.pruneMissingSeenProjects();
  }

  /** Self-heal the hint catalog at startup: drop any entry whose folder no
   *  longer exists on disk (deleted temp dirs, moved/renamed projects). Without
   *  this the append-only catalog accumulates dead entries forever — they
   *  resurface in `projects.json` on every flush and clutter a phone's picker.
   *  Conservative: only `existsSync(path) === false` is pruned, so a project on
   *  a temporarily-unmounted drive is re-added on its next open, not lost
   *  silently. Best-effort persist; a flush failure leaves the in-memory prune
   *  intact (the read path already tolerates a stale file). */
  private pruneMissingSeenProjects(): void {
    let removedAny = false;
    for (const [id, seen] of this.seenProjects) {
      if (!existsSync(seen.path)) {
        this.seenProjects.delete(id);
        removedAny = true;
      }
    }
    if (removedAny) this.flushSeen();
  }

  /** Push a fresh `agent:projects` to the connected control-plane phone, if any.
   *  No-op when the control plane isn't open or no phone is connected. Reads the
   *  (already-reloaded) allowlist live, so an `allow`/`deny` immediately updates
   *  the phone's picker. */
  private readvertiseToControlPlane(): void {
    const client = this.controlPlaneRelay;
    const bus = this.controlPlaneBus;
    if (!client || !bus) return;
    const pk = client.currentPeerPubkey();
    if (!pk) return;
    this.sendProjectsAdvertisement(pk, bus);
    this.sendToolsAdvertisement(bus);
  }

  /** TEST SEAM: install a control-plane bus + a fake connected peer, then run
   *  the exact re-advertise the file-watch callback runs. Lets the
   *  allowlist-change → re-advertise path be verified without standing up a
   *  live relay (the fake relay URL never connects, so no real peer exists). */
  readvertiseForTest(bus: MessageBus, peerPubkey: string): void {
    this.controlPlaneBus = bus;
    this.controlPlaneRelay = {
      currentPeerPubkey: () => peerPubkey,
      close: () => {},
    } as unknown as RelayClient;
    this.readvertiseToControlPlane();
  }

  /** The single machine-level paired-phones store shared across all cores. */
  get pairedPhones(): PairedPhonesStore {
    return this.pairedPhonesStore;
  }

  /** Bind the loopback control plane and publish host.json. Returns the bound
   *  port + token (also written to host.json). */
  async startControlPlane(): Promise<{ port: number; token: string }> {
    const token = randomBytes(32).toString("base64url");
    const listener = new ControlListener({ token, handler: (req) => this.handleControl(req) });
    await listener.start();
    this.control = listener;
    writeHostFile(hostFilePath(), {
      version: 1,
      pid: process.pid,
      controlPort: listener.port,
      token,
      startedAt: new Date().toISOString(),
      agentVersion: VERSION,
    });
    logger.info(`host control plane ready on 127.0.0.1:${listener.port}; host.json written`);
    // Open the always-on remote control plane only when the machine has remote
    // config (device auth + relay endpoints). Local-only hosts have no relay.
    // Best-effort: a control-plane open failure (e.g. the OAuth mint throwing in
    // ensureRemoteRuntime) must NOT crash an otherwise-healthy host — the
    // loopback plane is already up and local cores still work. The swallow is
    // intentional; a genuine auth failure is surfaced by the first-project
    // host.open (index.ts's try/catch → clean exit 1). ensureRemoteRuntime
    // clears remoteRuntimePromise on failure, so that later open() can still
    // retry the mint — we don't double-consume the failure here.
    if (this.opts.remote) {
      await this.startRemoteControlPlane().catch((err) =>
        logger.warn("host: remote control plane failed to start (will not retry): %s", err?.message ?? err),
      );
    }
    return { port: listener.port, token };
  }

  /** Open the always-on, coreless control-plane RelayClient registered under the
   *  bare deviceUuid (no projectId → registrationId === deviceUuid). It carries
   *  no preview tunnel and owns no terminal; it advertises the project catalog
   *  (Task 4.3) and dispatches allowlist-gated project verbs (Task 4.4). */
  private async startRemoteControlPlane(): Promise<void> {
    const r = this.requireRemoteConfig();
    await this.ensureRemoteRuntime();
    const rt = this.remoteRuntime!;
    const bus = new MessageBus();

    const buildClient = this.opts.relayClientFactory ?? ((o: RelayClientOptions) => new RelayClient(o));
    const client = buildClient({
      url: joinRelayWsPath(r.relayUrl),
      // Bare deviceUuid: this is the ONLY registration shape in v3 — one socket
      // per machine, project cores attach as multiplexed streams (design §7).
      identity: { ...r.identity, deviceId: r.auth.deviceUuid },
      abDir: resolveAbDir(),
      // Kept exception (B2): a terminal relay LICENSE verdict tells the user to
      // re-enroll (index.ts writes auth_revoked + exits). SUPERSEDED never does.
      onAuthRevoked: () => this.requireRemoteConfig().onAuthRevoked(),
      getAccountPeerKeys: rt.getAccountPeerKeys,
      sameAccountDefaultProjects: () => this.mobileAccessPolicy.listSameAccountDefaultProjects(),
      getLicenseToken: () => Promise.resolve(rt.maint.getToken()),
      pairedPhones: this.pairedPhonesStore,
      pairingWindow: this.pairingWindow,
      generateKeypair: () => generateEphemeralKeypair(),
      onTunnelMessage: () => {}, // no preview tunnel on the control plane
      // The always-on control plane is the registration a phone's autoOpen dials,
      // so it MUST keep the account inventory's relay_url/machine_name fresh —
      // otherwise the only writers are incidental promotion/remote-core heartbeats,
      // and a machine whose LAN IP changed advertises a dead relay_url (the phone
      // then dials the wrong address → AGENT_OFFLINE → never pairs). RelayClient
      // fires onAuthenticated on every (re)connect, so this re-publishes the
      // current relayUrl each time the control plane comes up.
      onAuthenticated: () => this.pushHeartbeat(),
      onHandshakeComplete: () => {
        const pk = client.currentPeerPubkey();
        if (pk) this.sendProjectsAdvertisement(pk, bus); // Task 4.3 — STUB for now
        this.sendToolsAdvertisement(bus); // machine-level; no phone-pubkey needed
      },
      onPaired: (_id, name) => {
        logger.info("Phone '%s' paired to control plane", name);
        this.readvertiseToControlPlane();
      },
      // A bridge-side reconnect to the RELAY (heartbeat lapse, network blip on
      // this machine — NOT the phone dropping) clears `_peerId` for the gap and
      // restores it here on `peer-online`, with NO fresh E2E handshake in
      // between (the phone never saw a disconnect, so it never re-sends
      // client-hello — see relay-client.ts's post-establishment lockout). Any
      // `readvertiseToControlPlane()` call that raced that gap (e.g. a desktop
      // mobile-access toggle) silently no-opped on the then-null peer id with no
      // retry. Re-advertising here — right after `_peerId` is restored, before
      // this callback runs — closes that window instead of leaving the phone
      // stuck on a stale catalog until an unrelated project:start forces a
      // full recompute.
      onPeerOnline: () => this.readvertiseToControlPlane(),
      // A transient disconnect is NOT a revocation. Multiple phones share this
      // one control-plane registration, so onUnpaired fires per-peer; demoting
      // here would tear down promoted slots that OTHER still-connected phones
      // are actively using, and force a re-promote round-trip when this phone
      // reconnects. Promotions are torn down only by allowlist changes
      // (phones:deny / phones:unpair → demoteIfOrphaned) and core lifecycle
      // (stop / evict / shutdown). The promoted slot is a bounded idle outbound
      // socket meanwhile; it reconnects with the core.
      onUnpaired: (id) => logger.info("Control-plane phone %s disconnected — promotions left intact", id),
    });

    bus.setInboundHandler((msg, channel) => {
      const pk = client.currentPeerPubkey();
      if (!pk) return; // no authenticated peer → ignore
      this.dispatchControlPlaneInbound(msg, channel, pk, bus);
    });
    client.setBus(bus);

    this.controlPlaneRelay = client;
    this.controlPlaneBus = bus;
    client.connect();
    logger.info("host: remote control plane relay opened (device=%s)", client.deviceId);
  }

  /** Bring the machine relay socket up (from the desktop wizard's credentials if
   *  the host was launched local-only) and return its pairing + stream-attach
   *  surface. Idempotent: reuses the live control-plane socket when present. */
  async ensureMachineRelay(msg: AgentEnableRelay): Promise<MachineRelaySession> {
    const auth = msg.auth;
    if (!auth?.deviceUuid || !auth.ed25519Pub || !auth.ed25519Priv) {
      throw new Error("enableRelay requires signed-in account device credentials");
    }
    const relayBase = msg.relayUrl ?? this.opts.remote?.relayUrl ?? process.env.RELAY_URL ?? null;
    if (!relayBase) throw new Error("no relay URL configured");
    // Synthesize a machine remote config from the wizard creds when the host has
    // none (local-only launch). requireRemoteConfig() then returns it.
    if (!this.opts.remote && !this.wizardRemote) {
      this.wizardRemote = {
        relayUrl: relayBase,
        licenseApiUrl: msg.licenseApiUrl ?? "",
        identity: {
          deviceId: auth.deviceUuid,
          deviceName: process.env.ANTGRID_HOST_NAME ?? hostname(),
          createdAt: new Date().toISOString(),
          ed25519PublicKey: auth.ed25519Pub,
          ed25519PrivateKey: auth.ed25519Priv,
        },
        auth: { clientId: auth.clientId ?? "", clientSecret: auth.clientSecret ?? "", deviceUuid: auth.deviceUuid },
        onAuthRevoked: () => {},
      };
    }
    await this.ensureRemoteRuntime();
    if (!this.controlPlaneRelay) await this.startRemoteControlPlane();
    const client = this.controlPlaneRelay!;
    return {
      attachStream: (bus, opts) => client.attachStream(bus, opts),
      currentPeerPubkey: () => client.currentPeerPubkey(),
      sendPushDeliver: (m) => client.sendPushDeliver(m),
      pairingWindow: this.pairingWindow,
      agentDeviceId: auth.deviceUuid,
      ed25519Pub: auth.ed25519Pub,
      relayBase,
    };
  }

  /** Build the project advertisement for a paired phone: the phones's
   *  `allowedProjects` ∩ (seen catalog ∪ warm cores), each tagged with whether
   *  it's DIALABLE. Security invariant: the result starts from
   *  `phone.allowedProjects`, so a project NOT in the phone's allowlist NEVER
   *  appears, even if warm/seen. Unknown phone → empty.
   *
   *  `running` here means "has an admitted relay data-plane slot" (the core's
   *  {@link ProjectCore.isRelayRegistered}), NOT merely "warm/open on the host".
   *  A desktop-open project that was never promoted is warm but has NO relay
   *  slot — advertising it `running:true` made the phone dial a slot the relay
   *  never admitted, looping AGENT_OFFLINE. So a warm-but-unpromoted core reads
   *  `running:false` until project:start promotes it and the slot registers; the
   *  phone's awaitProjectRunning then keys correctly off the post-register advert
   *  (and off the SESSION_LIMIT_EXCEEDED control:result on rejection). The
   *  visibility filter still includes warm cores, so the project is listed — it's
   *  just flagged not-yet-dialable. (The desktop hub advertises plain warmth via
   *  `knownProjectsForHub`, which is a different question; keep them distinct.) */
  buildProjectsAdvertisement(phonePubkey: string): ProjectAdvertEntry[] {
    const phone = this.pairedPhonesStore.get(phonePubkey);
    if (!phone) return [];
    const warm = new Set(this.cores.keys());
    return phone.allowedProjects
      .filter((id) => this.seenProjects.has(id) || warm.has(id))
      .map((id) => {
        const seen = this.seenProjects.get(id);
        const entry = this.cores.get(id);
        const dialable = entry?.core.isRelayRegistered() ?? false;
        // A reconnecting phone binds its ProjectSession to this streamId without a
        // fresh project:start (design §7.4). Only surfaced for a dialable stream.
        const streamId = dialable ? this.streamIds.get(id) : undefined;
        // Live work status for warm cores only. Cold projects omit it (their
        // agent PTY isn't alive → nothing "working"); the app falls back to
        // `running` for those, reading them as done/offline.
        return { projectId: id, label: seen?.label, path: seen?.path, running: dialable, status: entry?.core.workStatus, lastActiveAt: seen?.lastActiveAt, streamId };
      });
  }

  /** All paired phones for the desktop allowlist hub. Reads the shared store
   *  live, so a CLI `allow`/`deny` between calls is reflected. */
  listPairedPhones(): PairedPhoneSummary[] {
    return this.pairedPhonesStore.list().map((p) => ({
      phonePubkey: p.phonePubkey,
      phoneDeviceId: p.phoneDeviceId,
      label: p.label,
      pairedAt: p.pairedAt,
      lastSeenAt: p.lastSeenAt,
      admission: p.admission,
      allowedProjects: p.allowedProjects,
    }));
  }

  /** The machine's known projects (warm cores ∪ seen-catalog hints) for the
   *  hub's column set. The hub additionally renders any allowlisted id absent
   *  here, so a CLI-granted-but-unopened project is never hidden. */
  knownProjectsForHub(): KnownProject[] {
    const warm = new Set(this.cores.keys());
    const ids = new Set<string>([...this.seenProjects.keys(), ...warm]);
    return [...ids].map((id) => {
      const seen = this.seenProjects.get(id);
      return { projectId: id, label: seen?.label, path: seen?.path, running: warm.has(id) };
    });
  }

  private sendProjectsAdvertisement(phonePubkey: string, bus: MessageBus): void {
    bus.publish(
      createMessage("agent:projects", { projects: this.buildProjectsAdvertisement(phonePubkey) }),
      "control",
    );
  }

  /** Machine-level installed-tool catalog for the control plane. Not gated by
   *  the allowlist — tools are a property of the machine, not of any project.
   *  `chatCapable` is stamped here so the wire is authoritative over which
   *  tools support Chat mode; the app's static list is a fallback only. */
  buildToolsAdvertisement(opts: DetectOptions = {}): Array<{ tool: string; path: string; chatCapable: boolean }> {
    return detectInstalledTools(opts).map((t) => ({ ...t, chatCapable: isChatCapableTool(t.tool) }));
  }

  private sendToolsAdvertisement(bus: MessageBus): void {
    bus.publish(createMessage("agent:tools", { tools: this.buildToolsAdvertisement() }), "control");
  }

  /** Route one inbound control-plane frame from the paired phone: either the
   *  welcome-replay `state.snapshot` RPC or a project verb. Extracted from the
   *  bus inbound handler so the request/verb split is unit-testable without a
   *  live relay. `channel` is the bus channel the frame arrived on (always
   *  "control" for the control plane), echoed back on the RPC response. */
  dispatchControlPlaneInbound(
    msg: AbMessage,
    channel: Channel,
    phonePubkey: string,
    bus: MessageBus,
  ): void {
    // The app's RelayTransport.connect() fires a `state.snapshot` request to
    // seed its replay cache with the durable frames (agent:projects /
    // agent:tools) the control plane published at handshake. The control-plane
    // bus must answer it exactly like the data-plane bus (see agent-core.ts) or
    // the request times out (10s) and the phone's FIRST picker render shows no
    // tools/projects until an unrelated re-advertise. It exposes no authority
    // the handshake adverts didn't already grant this paired phone.
    if (msg.type === "request") {
      // RECOMPUTE the adverts fresh before answering — the snapshot is the
      // phone's pull, and it fires only once the phone is fully connected and
      // upserted, which is STRICTLY later than the handshake push. If that
      // push ran before this phone's allowlist/catalog was ready it cached an
      // empty `agent:projects`, and replay alone would faithfully echo the
      // empty frame forever (the bus's payload-dedup also suppresses an
      // identical re-push). Re-publishing here updates the replay cache that
      // dispatchRpc then reads; an unchanged payload is still a cheap no-op.
      if (msg.method === "state.snapshot") {
        this.sendProjectsAdvertisement(phonePubkey, bus);
        this.sendToolsAdvertisement(bus);
      }
      if (msg.method === "sessions.list") {
        // Gated, core-free session peek — handled HERE (not in the generic
        // dispatchRpc) because authz needs phonePubkey + the host's allowlist
        // store, which dispatchRpc's (bus, params) signature can't see. Async:
        // the handler reads sessions.json off the event loop (see
        // SessionManager.readPersisted), so publish on resolve.
        void this.handleSessionsListRpc(msg, phonePubkey)
          .then((res) => bus.publish(res, channel))
          .catch((err) => logger.warn("sessions.list handler threw: %s", err));
        return;
      }
      if (msg.method === "sessions.delete") {
        void this.handleSessionsDeleteRpc(msg, phonePubkey)
          .then((res) => bus.publish(res, channel))
          .catch((err) => logger.warn("sessions.delete handler threw: %s", err));
        return;
      }
      void dispatchRpc(bus, msg).then((res) => bus.publish(res, channel));
      return;
    }
    // Dispatch the verb (Task 4.4) and feed its FAILURE back to the phone as a
    // control:result so a rejected start (NOT_ALLOWED/UNKNOWN_PROJECT/OPEN_FAILED)
    // isn't silently dropped. Success re-advertises agent:projects inside the
    // handler, so we only publish on !ok. `.catch` guards an unexpected throw.
    void this.handleControlPlaneVerb(msg, phonePubkey, bus)
      .then((res) => {
        if (!res.ok) {
          bus.publish(
            createMessage("control:result", { ok: false, verb: msg.type, error: res.error }),
            "control",
          );
        }
      })
      .catch((err) => logger.warn("control-plane verb handler threw: %s", err));
  }

  /** Handle a desktop allowlist-hub verb over the loopback control plane. The
   *  bridge is the single writer of paired-phones.json — the app NEVER writes it
   *  directly. Each mutation re-advertises to any connected control-plane phone
   *  so its project picker updates without a reconnect.
   *
   *  `phones:deny` and `phones:unpair` update the allowlist, re-advertise, and
   *  — if no remaining paired phone still allows an affected project — tear down
   *  its promoted relay slot (hygiene; the allowlist gate already blocks inbound
   *  at the per-message level the instant the mutation returns). */
  async handlePhonesVerb(req: ControlRequest): Promise<ControlResponse> {
    switch (req.type) {
      case "phones:list":
        return { id: req.id, ok: true, type: "phones:list", phones: this.listPairedPhones(), knownProjects: this.knownProjectsForHub() };
      case "phones:allow":
        this.pairedPhonesStore.allowProject(req.phonePubkey, req.projectId);
        this.readvertiseToControlPlane();
        return { id: req.id, ok: true, type: "phones:allow" };
      case "phones:deny": {
        // denyProject returns false when the grant didn't exist — a no-op. Only
        // run the side effects (demote check, re-advertise) when something
        // actually changed; the verb is still idempotently ok either way.
        const changed = this.pairedPhonesStore.denyProject(req.phonePubkey, req.projectId);
        if (changed) {
          this.demoteIfOrphaned(req.projectId);
          this.readvertiseToControlPlane();
        }
        return { id: req.id, ok: true, type: "phones:deny" };
      }
      case "phones:unpair": {
        // Snapshot the unpaired phone's grants BEFORE removal, then demote any
        // slot left orphaned — symmetric to phones:deny. demoteIfOrphaned reads
        // the store AFTER the mutation, so it only tears down a project no
        // remaining paired phone still allows.
        const removed = this.pairedPhonesStore.get(req.phonePubkey);
        this.pairedPhonesStore.remove(req.phonePubkey);
        for (const projectId of removed?.allowedProjects ?? []) {
          this.demoteIfOrphaned(projectId);
        }
        this.readvertiseToControlPlane();
        return { id: req.id, ok: true, type: "phones:unpair" };
      }
      default:
        return { id: req.id, ok: false, error: { code: "UNKNOWN_VERB", message: `not a phones verb: ${(req as ControlRequest).type}` } };
    }
  }

  /** Handle a mobile-access defaults verb over the loopback control plane. The
   *  bridge is the single writer of mobile-access-policy.json. enable-project
   *  both stores the default and bulk-grants every same-account-admitted phone so
   *  they gain access immediately without a reconnect. disable-project clears the
   *  default and revokes the project from every phone (regardless of admission) so
   *  a re-paired phone doesn't re-inherit a stale grant. */
  async handleMobileAccessVerb(req: ControlRequest): Promise<ControlResponse> {
    switch (req.type) {
      case "mobile-access:get":
        return {
          id: req.id,
          ok: true,
          type: "mobile-access:get",
          projectIds: this.mobileAccessPolicy.listSameAccountDefaultProjects(),
        };
      case "mobile-access:enable-project":
        this.mobileAccessPolicy.enableProject(req.projectId);
        // Grant existing same-account phones in one flush (not one per phone).
        this.pairedPhonesStore.allowProjectForSameAccount(req.projectId);
        this.readvertiseToControlPlane();
        this.pushHeartbeat();
        return {
          id: req.id,
          ok: true,
          type: "mobile-access:enable-project",
          projectIds: this.mobileAccessPolicy.listSameAccountDefaultProjects(),
        };
      case "mobile-access:disable-project":
        this.mobileAccessPolicy.disableProject(req.projectId);
        // Revoke from same-account phones only — the toggle governs the
        // same-account default, so a pair-code phone granted this project
        // explicitly via `phones allow` keeps it. (forget() revokes ALL phones;
        // that's project deletion, a different operation.)
        this.pairedPhonesStore.denyProjectForSameAccount(req.projectId);
        this.demoteIfOrphaned(req.projectId);
        this.readvertiseToControlPlane();
        this.pushHeartbeat();
        return {
          id: req.id,
          ok: true,
          type: "mobile-access:disable-project",
          projectIds: this.mobileAccessPolicy.listSameAccountDefaultProjects(),
        };
      default:
        return { id: req.id, ok: false, error: { code: "UNKNOWN_VERB", message: `not a mobile-access verb: ${(req as ControlRequest).type}` } };
    }
  }

  /** Answer the drawer's `sessions.list` control-plane RPC: an allowlist-gated,
   *  core-free session-list peek. Reads the persisted sessions.json directly —
   *  no project:start, no data-plane socket, no side effect of running a stopped
   *  project's startup terminals. Returns a `response` envelope mirroring
   *  dispatchRpc's shape so the app correlates by requestId unchanged. */
  async handleSessionsListRpc(req: RpcRequest, phonePubkey: string): Promise<AbMessage> {
    const parsed = SessionsListParams.safeParse(req.params ?? {});
    if (!parsed.success) {
      return createMessage("response", {
        requestId: req.requestId, ok: false,
        error: { code: "E_BAD_PARAMS", message: parsed.error.issues.map((i) => i.message).join("; ") },
      });
    }
    const { projectId, includeArchived } = parsed.data;
    // SECURITY: reject path separators / dot dirs / hidden names so projectId
    // can never escape or target a dotfile under agents/ (defense-in-depth; the
    // allowlist already confines it to host-catalog ids, which never contain
    // separators).
    if (!isSafeProjectId(projectId)) {
      return createMessage("response", {
        requestId: req.requestId, ok: false,
        error: { code: "E_BAD_PARAMS", message: "invalid projectId" },
      });
    }
    // SECURITY: same gate as project:start — a trusted-but-not-allowed phone
    // sees nothing of this project.
    if (!this.pairedPhonesStore.isAllowed(phonePubkey, projectId)) {
      return createMessage("response", {
        requestId: req.requestId, ok: false,
        error: { code: "NOT_ALLOWED", message: "project not in phone allowlist" },
      });
    }
    // A WARM core (open/promoted) owns the live PTY/chat state — delegate so the
    // peek reports true per-session `running`; a stopped project has no warm core
    // and its disk file is authoritative (every session genuinely not-running).
    // listSessions returns null when the core hasn't finished initializing yet
    // (pre-handshake), in which case fall back to disk exactly as for a cold core.
    // Mirrors handleSessionsDeleteRpc's warm-core-vs-disk routing.
    const entry = this.cores.get(projectId);
    const liveSessions = entry?.core.listSessions(includeArchived ?? false);
    const sessions = liveSessions ?? await SessionManager.readPersisted(resolveAbDir(), projectId, includeArchived);
    return createMessage("response", { requestId: req.requestId, ok: true, result: { sessions } });
  }

  /** Answer the Recent tab's `sessions.delete` control-plane RPC: allowlist-gated
   *  session delete. A WARM core (promoted/open) is delegated to its live
   *  SessionManager so in-memory state and sessions.json stay consistent; a
   *  STOPPED project is mutated on disk via SessionManager.deletePersisted. Never
   *  warms a stopped core just to delete. */
  async handleSessionsDeleteRpc(req: RpcRequest, phonePubkey: string): Promise<AbMessage> {
    const parsed = SessionsDeleteParams.safeParse(req.params ?? {});
    if (!parsed.success) {
      return createMessage("response", {
        requestId: req.requestId, ok: false,
        error: { code: "E_BAD_PARAMS", message: parsed.error.issues.map((i) => i.message).join("; ") },
      });
    }
    const { projectId, sessionId } = parsed.data;
    if (!isSafeProjectId(projectId)) {
      return createMessage("response", {
        requestId: req.requestId, ok: false,
        error: { code: "E_BAD_PARAMS", message: "invalid projectId" },
      });
    }
    if (!this.pairedPhonesStore.isAllowed(phonePubkey, projectId)) {
      return createMessage("response", {
        requestId: req.requestId, ok: false,
        error: { code: "NOT_ALLOWED", message: "project not in phone allowlist" },
      });
    }
    const entry = this.cores.get(projectId);
    let deleted: boolean;
    if (entry) {
      // Warm core owns sessions.json — delegate so the live state + disk + any
      // connected peers stay in sync (kills the PTY, emits session:updated).
      deleted = entry.core.deleteSession(sessionId);
    } else {
      deleted = await SessionManager.deletePersisted(resolveAbDir(), projectId, sessionId);
    }
    return createMessage("response", { requestId: req.requestId, ok: true, result: { deleted } });
  }

  /** Dispatch an E2E control-plane verb from the paired phone identified by
   *  phonePubkey. Returns a structured result; callers on the bus path discard
   *  it (void). */
  async handleControlPlaneVerb(
    verb: AbMessage,
    phonePubkey: string,
    bus: MessageBus,
  ): Promise<{ ok: true } | { ok: false; error: { code: string; message: string } }> {
    if (verb.type === "project:start") {
      // SECURITY: the allowlist is the ONLY gate, checked BEFORE open() — open()
      // runs the project's `terminals:` startup commands, so a non-allowed
      // project must be rejected with NO core created.
      if (!this.pairedPhonesStore.isAllowed(phonePubkey, verb.projectId)) {
        return { ok: false, error: { code: "NOT_ALLOWED", message: "project not in phone allowlist" } };
      }
      // SECURITY: the path comes from the host's OWN catalog, never from the
      // phone's message (the message has no path field). An allowed projectId
      // with no path on record is rejected — never opened with a guessed path.
      const seen = this.seenProjects.get(verb.projectId);
      if (!seen) return { ok: false, error: { code: "UNKNOWN_PROJECT", message: "no path on record; open from desktop first" } };
      const entry = this.cores.get(verb.projectId);
      // An already-open LOCAL core (desktop attached over loopback) gets PROMOTED:
      // an additive relay slot is wired onto its EXISTING bus — no close+reopen,
      // the live local session is undisturbed. ensureRemoteRuntime FIRST because a
      // local-opened core never built the machine runtime, and remoteDepsFor()
      // throws when remoteRuntime is null. Wrapped like the open() path so a mint
      // failure becomes a structured error, never an unhandled rejection.
      const projectId = verb.projectId;
      if (entry && entry.mode === "local" && !entry.promotion) {
        let handle: PromotionHandle;
        try {
          await this.ensureRemoteRuntime();
          if (!this.controlPlaneRelay) await this.startRemoteControlPlane();
          handle = entry.core.promote(this.remoteDepsFor(projectId));
        } catch (err) {
          return { ok: false, error: { code: "OPEN_FAILED", message: (err as Error)?.message ?? String(err) } };
        }
        entry.promotion = handle;
        // Gate the phone-facing running advert on a REAL relay register and
        // surface a terminal rejection (e.g. SESSION_LIMIT_EXCEEDED). project:start
        // itself returns ok immediately — the outcome is pushed asynchronously.
        this.reportFirstRegister(handle.firstRegister, projectId, phonePubkey, bus, () => {
          // Tear the rejected slot down so a retry (after the user upgrades / frees
          // a slot) can re-promote, and so the core reads not-promoted again.
          try { handle.stop(); } catch {}
          const e = this.cores.get(projectId);
          if (e?.promotion === handle) e.promotion = undefined;
        });
        return { ok: true };
      } else if (!entry) {
        // Not open at all → fresh remote open. open() can throw (runtime mint
        // failure, requireRemoteConfig, core.start spawn/config error); return a
        // structured error instead of letting it reject into the void caller.
        try {
          await this.open(projectId, seen.path, "remote"); // reuses Phase A open()
        } catch (err) {
          return { ok: false, error: { code: "OPEN_FAILED", message: (err as Error)?.message ?? String(err) } };
        }
        const coreRef = this.cores.get(projectId)?.core;
        const firstRegister = coreRef?.whenRelayRegistered();
        if (firstRegister) {
          this.reportFirstRegister(firstRegister, projectId, phonePubkey, bus, () => {
            // A fresh remote core's relay slot IS its primary session — a rejected
            // register leaves it unreachable, so close it for a clean retry. Guard
            // on identity (like the promote path's `e?.promotion === handle`): a
            // concurrent evict/stop/reopen may have replaced this core's slot
            // between project:start and the async rejection — don't tear down a
            // newer, unrelated core that now holds the same projectId.
            if (this.cores.get(projectId)?.core === coreRef) {
              void this.stop(projectId).catch(() => {});
            }
          });
          return { ok: true };
        }
      }
      // else: already remote OR already promoted → idempotent. Re-advertise so the
      // phone re-reads the current dialable state (running:true only if the slot
      // is actually relay-admitted — buildProjectsAdvertisement gates on that, so
      // a promoted-but-not-yet-registered core still reads not-running here).
      this.sendProjectsAdvertisement(phonePubkey, bus);
      return { ok: true };
    }
    return { ok: false, error: { code: "UNKNOWN_VERB", message: `unsupported control-plane verb: ${verb.type}` } };
  }

  /** Report a relay slot's FIRST register outcome to the requesting phone over
   *  the control plane. On success, advertise `running:true` ONLY now — so the
   *  phone never dials a data-plane slot the gate hasn't admitted (the empty-slot
   *  AGENT_OFFLINE loop). On a terminal rejection, run `onFatal` (tear the dead
   *  slot down) and push a structured `control:result` so the phone surfaces the
   *  real reason (e.g. a session-limit upgrade prompt) instead of retrying.
   *  Non-blocking + never throws into the caller. */
  private reportFirstRegister(
    firstRegister: Promise<RegisterOutcome>,
    projectId: string,
    phonePubkey: string,
    bus: MessageBus,
    onFatal: () => void,
  ): void {
    void firstRegister
      .then((outcome) => {
        if (outcome.ok) {
          // Advertise the streamId binding so the phone can attach its
          // ProjectSession services without a fresh project:start (design §7.4).
          const streamId = this.streamIds.get(projectId);
          if (streamId) {
            bus.publish(createMessage("stream-ready", { projectId, streamId }), "control");
          }
          this.sendProjectsAdvertisement(phonePubkey, bus);
          return;
        }
        onFatal();
        bus.publish(
          createMessage("control:result", {
            ok: false,
            verb: "project:start",
            error: { code: outcome.code, message: outcome.message },
          }),
          "control",
        );
      })
      .catch((e) => logger.warn("reportFirstRegister threw for %s: %s", projectId, e));
  }

  /** True once an already-open core has been promoted onto the relay (additive
   *  relay slot). Diagnostic/test seam for the promote path. */
  isPromoted(id: string): boolean {
    return !!this.cores.get(id)?.promotion;
  }

  /** Stop the promoted relay slot for `projectId` if no paired phone still has
   *  it in their allowlist. The loopback session and AgentCore are untouched.
   *  Called after denyProject so the now-orphaned outbound slot is torn down
   *  as hygiene (the allowlist gate already blocks inbound per-message). */
  private demoteIfOrphaned(projectId: string): void {
    const entry = this.cores.get(projectId);
    if (!entry?.promotion) return;
    const stillAllowed = this.listPairedPhones().some((p) => p.allowedProjects.includes(projectId));
    if (stillAllowed) return;
    try {
      entry.promotion.stop();
    } catch (e) {
      logger.warn("Failed to demote orphaned core %s: %s", projectId, e instanceof Error ? e.message : String(e));
    }
    entry.promotion = undefined;
  }

  /** Tear down every active relay slot (PromotionHandle) and return each core
   *  to loopback-only. An explicit "drop all relay slots" primitive (e.g. a
   *  future go-offline command) — NOT wired to phone disconnect, which must not
   *  demote (a transient drop is not a revocation; see the control plane's
   *  onUnpaired). Idempotent: safe to call when no core is promoted. The core
   *  itself — and its live loopback session — is left ENTIRELY untouched; only
   *  the additive relay slot is stopped. Public so tests can invoke it directly
   *  without standing up a real relay connection. */
  demoteAllPromoted(): void {
    for (const [projectId, entry] of this.cores) {
      if (!entry.promotion) continue;
      try {
        entry.promotion.stop();
      } catch (e) {
        // PromotionHandle.stop() isolates each teardown sub-step internally; an
        // unexpected throw escaping those inner catches must be reported, never
        // dropped silently. The slot is still cleared below.
        logger.warn("Failed to demote promoted core %s: %s", projectId, e instanceof Error ? e.message : String(e));
      }
      entry.promotion = undefined;
    }
  }

  /** Test/diagnostic seam: the control-plane relay device id (bare deviceUuid),
   *  or null if the control plane was not started. */
  get controlPlaneRegistrationId(): string | null {
    return this.controlPlaneRelay?.deviceId ?? null;
  }

  private async handleControl(req: ControlRequest): Promise<ControlResponse> {
    switch (req.type) {
      case "project:list":
        return { id: req.id, ok: true, type: "project:list", projects: this.list() };
      case "tools:list":
        return {
          id: req.id,
          ok: true,
          type: "tools:list",
          tools: detectInstalledTools().map((t) => ({ ...t, chatCapable: isChatCapableTool(t.tool) })),
        };
      case "project:open": {
        const r = await this.open(req.projectId, req.projectPath, req.mode);
        return { id: req.id, ok: true, type: "project:open", running: r.running, connect: r.connect };
      }
      case "project:start": {
        // Re-advertises an already-open core. `connect` is the loopback
        // port+token for all modes — every core binds a listener regardless of
        // whether it also holds a relay slot. Starting a known-but-stopped
        // project by id (no path) needs a persisted catalog and is deferred to
        // the app-launcher unit.
        const existing = this.get(req.projectId);
        if (!existing) {
          return { id: req.id, ok: false, error: { code: "NOT_OPEN", message: `project ${req.projectId} is not open; use project:open with a path` } };
        }
        return { id: req.id, ok: true, type: "project:start", running: existing.running, connect: existing.connect };
      }
      case "project:stop":
        await this.stop(req.projectId);
        return { id: req.id, ok: true, type: "project:stop" };
      case "project:forget":
        await this.forget(req.projectId);
        return { id: req.id, ok: true, type: "project:forget" };
      case "host:shutdown":
        // Defer the actual teardown so THIS request's OK response flushes before
        // shutdown() tears the control listener down underneath it. The handler
        // (wired by the entrypoint) calls shutdown() + exits the process.
        setTimeout(() => this.opts.onShutdownRequested?.(), 0);
        return { id: req.id, ok: true, type: "host:shutdown" };
      case "phones:list":
      case "phones:allow":
      case "phones:deny":
      case "phones:unpair":
        return this.handlePhonesVerb(req);
      case "mobile-access:get":
      case "mobile-access:enable-project":
      case "mobile-access:disable-project":
        return this.handleMobileAccessVerb(req);
    }
  }

  /** Idempotent: returns the existing running core if already open, and
   *  coalesces concurrent opens of the same not-yet-open project. */
  async open(projectId: string, projectPath: string, mode: "local" | "remote"): Promise<OpenResult> {
    const existing = this.cores.get(projectId);
    if (existing) {
      existing.lastFocusedMs = this.tick();
      this.touchSeenProject(projectId);
      return this.resultFor(existing);
    }
    // A core isn't in `cores` until startCore() finishes, so two concurrent
    // opens would both miss the check above and each start a core — the second
    // cores.set would overwrite (and orphan) the first. Share the in-flight
    // promise instead so the second caller gets the same core.
    const inflight = this.opening.get(projectId);
    if (inflight) return inflight;
    const promise = this.startCore(projectId, projectPath, mode);
    this.opening.set(projectId, promise);
    try {
      return await promise;
    } finally {
      this.opening.delete(projectId);
    }
  }

  private async startCore(projectId: string, projectPath: string, mode: "local" | "remote"): Promise<OpenResult> {
    let remote: ProjectCoreRemoteDeps | undefined;
    if (mode === "remote") {
      await this.ensureRemoteRuntime();
      // A remote core attaches to the ONE machine socket (design §7); ensure it
      // is up (startControlPlane already opened it when launched with remote
      // config — this guards the wizard-bootstrapped path).
      if (!this.controlPlaneRelay) await this.startRemoteControlPlane();
      remote = this.remoteDepsFor(projectId);
    }
    const core = new ProjectCore({
      folder: projectPath,
      mode,
      identity: this.identityFor(mode),
      pairedPhones: this.pairedPhonesStore,
      sameAccountDefaultProjects: () => this.mobileAccessPolicy.listSameAccountDefaultProjects(),
      ensureMachineRelay: (msg) => this.ensureMachineRelay(msg),
      ...(mode === "remote" ? { remote } : {}),
    });
    await core.start();
    const entry: CatalogEntry = { core, path: projectPath, mode, lastFocusedMs: this.tick() };
    this.cores.set(projectId, entry);
    // Re-advertise on a real work-status transition so the phone's Recent/sidebar
    // track activity (working/attention/error/done) without warming this core
    // themselves. Deduped inside the core, so this fires on transitions only.
    core.onWorkStatusChange(() => this.readvertiseToControlPlane());
    // Record in the non-authoritative hint catalog so a later stop()/evict still
    // lets us advertise this project as known-but-stopped. NOT removed on stop.
    // The in-memory .set() is what matters for runtime; the flush is a non-secret
    // best-effort persist whose failure must NEVER break opening a project (the
    // read path already "never throws into the caller" — extend that to writes).
    this.seenProjects.set(projectId, { path: projectPath, label: basename(projectPath), lastActiveAt: new Date().toISOString() });
    this.flushSeen();
    logger.info(`host: opened project ${projectId} (mode=${mode}, ${this.cores.size} core(s) warm)`);
    await this.evictIfNeeded(projectId);
    return this.resultFor(entry);
  }

  /** Build the machine OAuth runtime once, on the first remote open. Coalesces
   *  concurrent first-opens onto a single in-flight mint (the `await oauth.mint()`
   *  yields before `remoteRuntime` is set, so a plain re-check would race). */
  private ensureRemoteRuntime(): Promise<RemoteRuntime> {
    if (this.remoteRuntime) return Promise.resolve(this.remoteRuntime);
    if (this.remoteRuntimePromise) return this.remoteRuntimePromise;
    const r = this.requireRemoteConfig();
    const build = this.opts.remoteRuntimeFactory ?? buildRemoteRuntime;
    const promise = (async () => {
      this.remoteRuntime = await build(r);
      return this.remoteRuntime;
    })();
    // Hold the in-flight promise so concurrent callers share it; clear it on
    // failure so a later open() can retry the mint.
    this.remoteRuntimePromise = promise;
    promise.catch(() => { this.remoteRuntimePromise = null; });
    return promise;
  }

  /** The machine remote config, or throw — a remote open is illegal without it.
   *  Single chokepoint so the "requires machine remote config" invariant and
   *  message live in one place. */
  private requireRemoteConfig(): HostRemoteConfig {
    const r = this.opts.remote ?? this.wizardRemote;
    if (!r) throw new Error("HostServer: remote mode requires machine remote config");
    return r;
  }

  /** Push the machine's current mobile-access state (relayUrl, machineName,
   *  and whether ANY same-account project is enabled) to the account
   *  inventory. Called both on relay (re)authentication and immediately after
   *  a `mobile-access:*` toggle mutation, so `Device.mobileAccessEnabled` in
   *  the web DB reflects the actual policy rather than lagging until the next
   *  reconnect. No-op without remote config or before the machine OAuth
   *  runtime exists — every real caller has already gone through
   *  startRemoteControlPlane/ensureRemoteRuntime by the time this can fire. */
  private pushHeartbeat(): void {
    if (!this.opts.remote || !this.remoteRuntime) return;
    const r = this.opts.remote;
    const rt = this.remoteRuntime;
    void sendHeartbeat({
      licenseApiUrl: r.licenseApiUrl,
      getToken: rt.maint.getToken,
      deviceUuid: r.auth.deviceUuid,
      mobileAccessEnabled: this.mobileAccessPolicy.listSameAccountDefaultProjects().length > 0,
      relayUrl: r.relayUrl,
      machineName: process.env.ANTGRID_HOST_NAME ?? hostname(),
    }).then((ok) => {
      if (!ok) logger.warn("heartbeat POST failed (non-2xx or network error)", { deviceUuid: r.auth.deviceUuid });
    });
  }

  get(projectId: string): OpenResult | null {
    const entry = this.cores.get(projectId);
    return entry ? this.resultFor(entry) : null;
  }

  list(): ProjectSummary[] {
    return [...this.cores.entries()].map(([projectId, e]) => ({
      projectId, path: e.path, running: true, mode: e.mode,
      workStatus: e.core.workStatus,
    }));
  }

  async stop(projectId: string): Promise<void> {
    const entry = this.cores.get(projectId);
    if (!entry) return;
    this.cores.delete(projectId);
    // A promoted local core holds a relay slot separate from its loopback session
    // (core.shutdown only closes the core's own `this.relay`, which a local core
    // never set). Stop the slot explicitly so it doesn't leak past teardown.
    try { entry.promotion?.stop(); } catch (e) { logger.warn("Failed to stop promotion for %s: %s", projectId, e instanceof Error ? e.message : String(e)); }
    await entry.core.shutdown();
  }

  /** Erase every machine-side trace of a project so reopening the same folder
   *  starts clean. The app calls this on project delete: `sessions.json` is the
   *  AUTHORITATIVE session list (the app merely caches it), so without this a
   *  removed project's sessions reload on the next open. Each step is
   *  best-effort — a failure in one must never strand the others:
   *    1. stop a warm core (kills its PTYs + any relay slot),
   *    2. delete the on-disk store dir (`agents/<id>/`, holding sessions.json),
   *    3. drop the seen-catalog hint (also clears the stale projects.json entry),
   *    4. revoke the project from every paired phone's allowlist.
   *  Idempotent: forgetting an unknown/already-forgotten id is a no-op. */
  async forget(projectId: string): Promise<void> {
    await this.stop(projectId);
    this.deleteProjectStores(projectId);
    if (this.seenProjects.delete(projectId)) this.flushSeen();
    // Clear the same-account default so a later same-account pairing doesn't
    // re-inherit a grant for a deleted project.
    const defaultChanged = this.mobileAccessPolicy.disableProject(projectId);
    let revokedAny = false;
    for (const phone of this.pairedPhonesStore.list()) {
      if (this.pairedPhonesStore.denyProject(phone.phonePubkey, projectId)) revokedAny = true;
    }
    // A forgotten project must vanish from a live phone's picker without a
    // reconnect (the advertisement is otherwise only re-sent on handshake).
    if (revokedAny || defaultChanged) this.readvertiseToControlPlane();
  }

  /** Delete a project's on-disk per-project dirs (best-effort). Two locations,
   *  both keyed by projectId under the `~/.antgrid` root:
   *    - `agents/<id>/`   — SessionManager's `sessions.json` (the authoritative
   *      session list); MUST mirror `join(storeDir, "agents", projectId)`.
   *    - `projects/<id>/` — legacy ephemeral-pubkey dir. No longer written (the
   *      pubkey is in-memory only), but older bridges left these behind; clean
   *      them so a forgotten project leaves nothing on disk. */
  private deleteProjectStores(projectId: string): void {
    const abDir = resolveAbDir();
    for (const dir of [join(abDir, "agents", projectId), join(abDir, "projects", projectId)]) {
      try {
        rmSync(dir, { recursive: true, force: true });
      } catch (e) {
        logger.warn("host: failed to delete %s: %s", dir, e instanceof Error ? e.message : String(e));
      }
    }
  }

  async shutdown(reason?: string): Promise<void> {
    // Persist the hint catalog up front so memory↔disk agree on a clean exit
    // (and so it survives even if a force-kill backstop fires before the slower
    // core teardown below finishes).
    this.flushSeen();
    this.controlPlaneRelay?.close();
    this.controlPlaneRelay = null;
    this.controlPlaneBus = null;
    this.remoteRuntime?.maint.stop();
    // Always close the paired-phones fs.watch handle, even if the control plane
    // was never started, so tests don't leak handles (Windows EBUSY).
    this.stopPhonesWatch?.();
    this.stopPhonesWatch = null;
    await this.control?.stop();
    if (this.control) removeHostFile(hostFilePath());
    this.control = null;
    const entries = [...this.cores.values()];
    this.cores.clear();
    for (const e of entries) { try { e.promotion?.stop(); } catch (err) { logger.warn("Failed to stop promotion for %s during shutdown: %s", e.core.projectId, err instanceof Error ? err.message : String(err)); } }
    await Promise.all(entries.map((e) => e.core.shutdown(reason).catch(() => {})));
  }

  // --- internals ---

  private resultFor(entry: CatalogEntry): OpenResult {
    return { running: true, connect: entry.core.localConnectInfo };
  }

  private identityFor(mode: "local" | "remote"): DeviceIdentity {
    if (mode === "remote") return this.requireRemoteConfig().identity;
    // Local identity is ephemeral and unused for trust (loopback + token is the
    // boundary). One fresh identity per local core preserves today's behavior.
    return { deviceId: randomUUID(), deviceName: "local", createdAt: new Date().toISOString() };
  }

  /** Stream-attach surface for a project core: it attaches its bus to the ONE
   *  machine socket (design §7) rather than owning a RelayClient. The wrapper
   *  records the allocated streamId under `projectId` (for the advertisement +
   *  stream-ready) and clears it on detach. */
  private remoteDepsFor(projectId: string): ProjectCoreRemoteDeps {
    const client = this.controlPlaneRelay;
    if (!client) throw new Error("HostServer: machine relay socket not started (call startRemoteControlPlane first)");
    return {
      attachStream: (bus, opts) => {
        const handle = client.attachStream(bus, opts);
        this.streamIds.set(projectId, handle.streamId);
        return {
          streamId: handle.streamId,
          sendTunnel: (data) => handle.sendTunnel(data),
          detach: () => {
            if (this.streamIds.get(projectId) === handle.streamId) this.streamIds.delete(projectId);
            handle.detach();
          },
        };
      },
      currentPeerPubkey: () => client.currentPeerPubkey(),
      sendPushDeliver: (m) => client.sendPushDeliver(m),
    };
  }

  private async evictIfNeeded(justOpened: string): Promise<void> {
    const cap = this.opts.warmCap ?? kHostWarmCap;
    let evictedAny = false;
    while (this.cores.size > cap) {
      const victim = this.selectEvictionVictim(justOpened);
      if (!victim) break;
      const entry = this.cores.get(victim);
      this.cores.delete(victim);
      try { entry?.promotion?.stop(); } catch (e) { logger.warn("Failed to stop promotion for evicted core %s: %s", victim, e instanceof Error ? e.message : String(e)); }
      logger.info(`host: evicting LRU core ${victim} (cap ${cap})`);
      // Await teardown so eviction is observable (discovery file removed) before
      // open() returns. open() already awaits core.start(), so this is consistent.
      await entry?.core.shutdown("evicted").catch(() => {});
      evictedAny = true;
    }
    // A phone's picker shows running:true for warm cores; an evicted core must
    // flip back to running:false there. The data socket drops on its own (the
    // core's RelayClient closes), but the control-plane advertisement is the
    // picker-facing signal. The app-side warm cap (kWarmCapRelay) can exceed this
    // host cap, so without this re-advertise the app may still believe an evicted
    // project is warm.
    if (evictedAny) this.readvertiseToControlPlane();
  }

  /** Least-recently-focused core, never the just-opened one. */
  private selectEvictionVictim(protect: string): string | null {
    let victim: string | null = null;
    let oldest = Infinity;
    for (const [id, e] of this.cores) {
      if (id === protect) continue;
      if (e.lastFocusedMs < oldest) { oldest = e.lastFocusedMs; victim = id; }
    }
    return victim;
  }

  private tick(): number { return ++this.nowCounter; }

  /** Stamp `lastActiveAt` for an already-seen project and persist. Called by
   *  BOTH the warm-reopen branch of open() and (via the set+flush in) startCore,
   *  so projects.json never goes stale after a restart — the warm path used to
   *  mutate memory only, losing the most-recent-use stamp on the next launch. */
  private touchSeenProject(projectId: string): void {
    const seen = this.seenProjects.get(projectId);
    if (!seen) return;
    seen.lastActiveAt = new Date().toISOString();
    this.flushSeen();
  }

  /** Best-effort persist of the non-authoritative seen-projects hint catalog. A
   *  write failure must NEVER break opening/focusing a project — it's a non-secret
   *  cache the read path already tolerates losing. */
  private flushSeen(): void {
    try { flushSeenProjects(seenProjectsPath(), this.seenProjects); }
    catch (e) { logger.warn("host: failed to persist projects.json (hint only): %s", e); }
  }
}

// --- seen-projects hint catalog (NON-AUTHORITATIVE) ---
// A tiny {version,projects} read/write mirroring paired-phones.ts's helpers.
// projects.json is non-secret (no chmod 0600); corrupt/missing → empty Map,
// never throws.

/** One entry in the non-authoritative known-projects hint catalog. */
export interface SeenProject {
  path: string;
  label?: string;
  lastActiveAt?: string;
}

interface SeenProjectsFileShape {
  version: 1;
  projects: Record<string, SeenProject>;
}

function seenProjectsPath(): string {
  return join(resolveAbDir(), "agents", "projects.json");
}

export function loadSeenProjects(path: string): Map<string, SeenProject> {
  if (!existsSync(path)) return new Map();
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as SeenProjectsFileShape;
    if (parsed.version !== 1 || typeof parsed.projects !== "object" || parsed.projects === null) {
      return new Map();
    }
    return new Map(Object.entries(parsed.projects));
  } catch {
    return new Map();
  }
}

export function flushSeenProjects(path: string, map: Map<string, SeenProject>): void {
  const dir = join(path, "..");
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  const data: SeenProjectsFileShape = { version: 1, projects: Object.fromEntries(map) };
  writeFileSync(path, JSON.stringify(data, null, 2));
}
