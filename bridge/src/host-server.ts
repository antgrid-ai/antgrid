import { randomBytes, randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { hostname } from "node:os";
import { basename, join, resolve } from "node:path";
import { ProjectCore, type ProjectCoreDeps, type ProjectCoreRemoteDeps, type PromotionHandle, type RegisterOutcome } from "./project-core";
import { OAuthClient, startTokenMaintenance } from "./auth/oauth-client";
import { sendHeartbeat } from "./heartbeat";
import { ControlListener } from "./control-listener";
import type { ControlRequest, ControlResponse } from "./control-protocol";
import { hostFilePath, writeHostFile, removeHostFile } from "./host-discovery";
import { loadPairedPhones, type PairedPhonesStore } from "./paired-phones";
import { TrustedPeersProvider } from "./trusted-peers";
import { loadRemoteAccessPolicy, type RemoteAccessPolicyStore } from "./remote-access-policy";
import { resolveAbDir } from "./antgrid-dir";
import { VERSION } from "./version";
import type { DeviceIdentity } from "./device";
import type { ProjectSummary, ConnectInfo, PairedPhoneSummary, KnownProject } from "./control-protocol";
import { logger } from "./logger";
const log = logger.child({ component: "host-server" });
import { RelayClient, type RelayClientOptions } from "./relay-client";
import type { MachineRelaySession } from "./relay-promotion";
import type { AgentEnableRelay } from "./protocol";
import { MessageBus, type Channel } from "./message-bus";
import { dispatchRpc } from "./rpc/methods";
import { generateEphemeralKeypair } from "./key-exchange";
import { joinRelayWsPath } from "./relay-url";
import { createMessage } from "./protocol";
import { detectInstalledTools, type DetectOptions } from "./tool-detector";
import { isChatCapableTool } from "./structured/chat-capable";
import type { AbMessage, ProjectAdvertEntry, RpcRequest } from "./protocol";
import { z } from "zod";
import { SessionManager } from "./session-manager";
import { isSafeProjectId } from "./project-id";
import { listLocalBranches, checkoutLocalBranch } from "./git-branches";
import { resolveProject } from "./worktrees/project-resolver";
import { WorktreeError, WorktreeManager } from "./worktrees/worktree-manager";
export { WORKTREE_SESSIONS_SUPPORTED } from "./worktree-capability";
import { WORKTREE_SESSIONS_SUPPORTED } from "./worktree-capability";

const SessionsListParams = z.object({
  projectId: z.string(),
  includeArchived: z.boolean().optional(),
});

const SessionsDeleteParams = z.object({
  projectId: z.string(),
  sessionId: z.string().min(1),
  force: z.boolean().optional(),
  removeCheckout: z.boolean().optional(),
  deleteBranch: z.boolean().optional(),
});

const GitBranchesParams = z.object({
  projectId: z.string(),
});

const GitCheckoutParams = z.object({
  projectId: z.string(),
  branch: z.string().min(1),
  allowActiveSessions: z.boolean().optional(),
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
  remoteRuntimeFactory?: (r: HostRemoteConfig, onMinted?: () => void) => Promise<RemoteRuntime>;
  /** Test seam: builds the single machine {@link RelayClient}. Defaults to a
   *  real `new RelayClient(opts)` — overridden in tests to observe stream
   *  admission (onAdmitted/onRejected) without a live relay socket. */
  relayClientFactory?: (opts: RelayClientOptions) => RelayClient;
  /** Test seam: override the pushHeartbeat() cadence. Defaults to
   *  {@link HEARTBEAT_REFRESH_INTERVAL_MS} (60s). */
  heartbeatIntervalMs?: number;
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
}

/** The real machine OAuth runtime: mint an initial token and keep it fresh.
 *  Swappable via {@link HostServerOptions.remoteRuntimeFactory} for tests. The
 *  returned `oauth` client is captured inside `maint`; the host never needs it
 *  directly. */
async function buildRemoteRuntime(r: HostRemoteConfig, onMinted?: () => void): Promise<RemoteRuntime> {
  const oauth = new OAuthClient({
    licenseApiUrl: r.licenseApiUrl,
    clientId: r.auth.clientId,
    clientSecret: r.auth.clientSecret,
    onAuthRevoked: r.onAuthRevoked,
  });
  const initial = await oauth.mint();
  // onMinted redials the machine socket after a LICENSE_EXPIRED stop (recoverable
  // by time); the initial mint deliberately doesn't fire it.
  const maint = startTokenMaintenance(oauth, initial, { onMinted });
  return { maint };
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

// pushHeartbeat() rides one cadence for both the device heartbeat POST and the
// trustedPeers inventory refresh (see pushHeartbeat()'s doc comment). 60s
// mirrors the interval this device-heartbeat design already settled on for a
// no-reconnect-hook periodic POST (the original design predates account-trust
// admission replacing pair-request auto-approve; the interval choice stands).
const HEARTBEAT_REFRESH_INTERVAL_MS = 60_000;

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
  // The single machine-level phone registry (identity, label, push routing),
  // shared by every project core so they read one in-memory view. Carries no
  // authorization. Constructed once here; each core receives this exact instance
  // via startCore().
  private readonly pairedPhonesStore: PairedPhonesStore = loadPairedPhones(resolveAbDir());
  // The one authorization gate for remote phones: is this machine reachable
  // from mobile at all. Every project verb from a phone is checked against it.
  private readonly remoteAccessPolicy: RemoteAccessPolicyStore = loadRemoteAccessPolicy(resolveAbDir());
  private stopPhonesWatch: (() => void) | null = null;
  // projectId → {path, label} for every project this machine has opened. Since
  // the per-phone allowlist went away this is the ONLY per-project bound on what
  // a phone may name: `remoteAccessPolicy` says whether ANY project is
  // reachable, and membership here says WHICH ids exist — so every phone-facing
  // verb that takes a projectId must look it up (project:start, sessions.list,
  // sessions.delete) and the advert is derived from it. It still holds no trust
  // state of its own. Persisted to <abDir>/projects.json; if that file is lost,
  // worst case a stopped project isn't advertised until reopened.
  private readonly seenProjects: Map<string, SeenProject> = loadSeenProjects(seenProjectsPath());
  // The always-on, coreless control-plane relay registered under the BARE
  // deviceUuid (no projectId), used to advertise the project catalog and accept
  // mobile-access-gated project verbs from a paired phone. Opened only when remote
  // config is present; one phone at a time on this registration (concurrent
  // multi-phone control is out of scope). null until startRemoteControlPlane().
  private controlPlaneRelay: RelayClient | null = null;
  // retained to prevent GC of the bus before shutdown
  private controlPlaneBus: MessageBus | null = null;
  // Account device inventory, the primary E2E-admission trust source (spec
  // 2026-07-24 §3.3). Built once on the first startRemoteControlPlane() call
  // and reused across reconnects so its in-memory cache stays warm; refreshed
  // on the existing heartbeat cadence (see pushHeartbeat()).
  private trustedPeers: TrustedPeersProvider | null = null;
  // Owns the periodic pushHeartbeat() cadence (started once, in
  // startRemoteControlPlane; cleared in shutdown()). unref'd so it never keeps
  // the process alive on its own — mirrors owner-watchdog.ts's idiom.
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  // Machine remote config synthesized from the desktop wizard's `agent:enableRelay`
  // credentials when the host was launched WITHOUT remote config (local-only). Lets
  // `requireRemoteConfig()` bring the one machine socket up on demand.
  private wizardRemote: HostRemoteConfig | null = null;
  // Whether an `invalid_client` verdict may kill the process. Disarmed for the
  // duration of the boot-time control-plane start only — see start().
  private fatalRevokeArmed = true;
  // projectId → the streamId its relay data-plane stream was allocated. Read by
  // buildProjectsAdvertisement (per-project streamId) and stream-ready. Populated
  // when a core attaches (remoteDepsFor's wrapper), cleared on detach.
  private readonly streamIds = new Map<string, string>();

  constructor(private readonly opts: HostServerOptions) {
    // Watch the backing file so an external edit (e.g. `antgrid phones remove`)
    // reloads the shared store before the callback runs — push targeting and
    // `phones:list` read the refreshed in-memory `phones` array live. On top of
    // the reload we re-advertise to the currently-connected control-plane phone,
    // since the removed row may be the peer we were advertising to.
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
   *  No-op when the control plane isn't open or no phone is connected. Recomputes
   *  from the live catalog + machine switch, so a `mobile-access:set` or a
   *  catalog change immediately updates the phone's picker. */
  private readvertiseToControlPlane(): void {
    const client = this.controlPlaneRelay;
    const bus = this.controlPlaneBus;
    if (!client || !bus) return;
    // No authenticated peer → nothing to tell; the next handshake advertises.
    if (!client.currentPeerPubkey()) return;
    this.sendProjectsAdvertisement(bus);
    this.sendToolsAdvertisement(bus);
  }

  /** TEST SEAM: install a control-plane bus + a fake connected peer, then run
   *  the exact re-advertise the file-watch callback runs. Lets the
   *  policy/catalog-change → re-advertise path be verified without standing up a
   *  live relay (the fake relay URL never connects, so no real peer exists). */
  readvertiseForTest(bus: MessageBus, peerPubkey: string): void {
    this.controlPlaneBus = bus;
    this.controlPlaneRelay = {
      currentPeerPubkey: () => peerPubkey,
      close: () => {},
    } as unknown as RelayClient;
    this.readvertiseToControlPlane();
  }

  /** The single machine-level phone registry shared across all cores. */
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
    log.info(`host control plane ready on 127.0.0.1:${listener.port}; host.json written`);
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
      // Disarmed across this call because the swallow below CANNOT catch an
      // `invalid_client` verdict: index.ts's onAuthRevoked calls process.exit,
      // so the host would die here — after host.json and the ready marker have
      // already gone out — and the app's supervisor would respawn it straight
      // back into the same dead credential pair. A rotated-away OAuth client is
      // the common way to reach this, so the loop would be permanent. The
      // credentials are re-supplied by a respawn (local_host_warmup.dart), not
      // by anything this process can do, so exiting buys nothing here; a revoke
      // detected LATER, by token maintenance, stays fatal.
      this.fatalRevokeArmed = false;
      await this.startRemoteControlPlane().catch((err) =>
        log.warn("host: remote control plane failed to start (will not retry): %s", err?.message ?? err),
      );
      this.fatalRevokeArmed = true;
    }
    return { port: listener.port, token };
  }

  /** Open the always-on, coreless control-plane RelayClient registered under the
   *  bare deviceUuid (no projectId → registrationId === deviceUuid). It carries
   *  no preview tunnel and owns no terminal; it advertises the project catalog
   *  and dispatches mobile-access-gated project verbs. */
  private async startRemoteControlPlane(): Promise<void> {
    const r = this.requireRemoteConfig();
    await this.ensureRemoteRuntime();
    const rt = this.remoteRuntime!;
    const bus = new MessageBus();
    const abDir = resolveAbDir();

    // Built once and reused across reconnects (same licenseApiUrl/getToken the
    // heartbeat push already uses — see pushHeartbeat()) so the on-disk cache
    // and in-memory map survive socket churn.
    if (!this.trustedPeers) {
      this.trustedPeers = new TrustedPeersProvider({
        licenseApiUrl: r.licenseApiUrl,
        getToken: rt.maint.getToken,
        filePath: join(abDir, "trusted-peers.json"),
      });
    }

    const buildClient = this.opts.relayClientFactory ?? ((o: RelayClientOptions) => new RelayClient(o));
    const client = buildClient({
      url: joinRelayWsPath(r.relayUrl),
      // Bare deviceUuid: this is the ONLY registration shape in v3 — one socket
      // per machine, project cores attach as multiplexed streams (design §7).
      identity: { ...r.identity, deviceId: r.auth.deviceUuid },
      abDir,
      // Kept exception (B2): a terminal relay LICENSE verdict tells the user to
      // re-enroll (index.ts writes auth_revoked + exits). SUPERSEDED never does.
      onAuthRevoked: () => this.requireRemoteConfig().onAuthRevoked(),
      getLicenseToken: () => Promise.resolve(rt.maint.getToken()),
      pairedPhones: this.pairedPhonesStore,
      trustedPeers: this.trustedPeers,
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
        this.sendProjectsAdvertisement(bus);
        this.sendToolsAdvertisement(bus);
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
      // No peer-disconnect hook is wired on purpose. A transient disconnect is
      // NOT a revocation, and multiple phones share this one control-plane
      // registration, so demoting here would tear down promoted slots that OTHER
      // still-connected phones are actively using. Promotions are torn down only
      // by turning mobile access off (mobile-access:set → demoteAllPromoted) and
      // core lifecycle (stop / evict / shutdown). The promoted slot is a bounded
      // idle outbound socket meanwhile; it reconnects with the core.
    });

    bus.setInboundHandler((msg, channel) => {
      // Admission is "an account-trusted phone completed the E2E handshake";
      // WHICH phone no longer changes any answer, so the pubkey is only checked
      // for presence here. Authorization is the machine switch, applied per verb.
      if (!client.currentPeerPubkey()) return;
      this.dispatchControlPlaneInbound(msg, channel, bus);
    });
    client.setBus(bus);

    this.controlPlaneRelay = client;
    this.controlPlaneBus = bus;
    client.connect();
    log.info("host: remote control plane relay opened (device=%s)", client.deviceId);

    // pushHeartbeat() was previously event-triggered only (onAuthenticated +
    // mobile-access mutations), so a long-lived, stably-connected bridge never
    // re-fetched trustedPeers — a removed/re-keyed phone's stale identity stuck
    // around indefinitely. Give it the actual cadence the design describes.
    if (!this.heartbeatTimer) {
      const intervalMs = this.opts.heartbeatIntervalMs ?? HEARTBEAT_REFRESH_INTERVAL_MS;
      this.heartbeatTimer = setInterval(() => this.pushHeartbeat(), intervalMs);
      this.heartbeatTimer.unref?.();
    }
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
    // The host's boot credentials arrive once, on stdin, and are never re-read.
    // If that pair was already dead when the host started, its mint failed and
    // nothing came up — no token maintenance, no machine socket. Adopt the
    // caller's freshly-authenticated pair instead of retrying a client the web
    // has deleted. Deliberately gated on "nothing is live and nothing is being
    // built": swapping under a live runtime would orphan its token maintenance,
    // and swapping under an IN-FLIGHT mint would leave that build racing this
    // one, with only the last-assigned runtime ever stopped at shutdown.
    const existing = this.remoteConfig();
    if (
      existing &&
      auth.clientId &&
      auth.clientSecret &&
      auth.clientId !== existing.auth.clientId &&
      !this.controlPlaneRelay &&
      !this.remoteRuntime &&
      !this.remoteRuntimePromise
    ) {
      existing.auth = {
        clientId: auth.clientId,
        clientSecret: auth.clientSecret,
        deviceUuid: auth.deviceUuid,
      };
      // The identity travels WITH the auth block. A sign-out rotates the whole
      // account device, so keeping the old Ed25519 pair here would sign the
      // relay's v3 hello with a key that is not the one registered for the new
      // deviceUuid — AUTH_FAILED, and the socket never comes up at all.
      existing.identity = {
        ...existing.identity,
        deviceId: auth.deviceUuid,
        ed25519PublicKey: auth.ed25519Pub,
        ed25519PrivateKey: auth.ed25519Priv,
      };
    }
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
      agentDeviceId: auth.deviceUuid,
      ed25519Pub: auth.ed25519Pub,
      relayBase,
    };
  }

  /** Build the project advertisement for the connected phone: the machine's
   *  whole catalog (seen hints ∪ warm cores), each tagged with whether it's
   *  DIALABLE — or NOTHING at all while mobile access is off. Every
   *  account-trusted phone sees the same list; the machine switch is the only
   *  thing that varies, which is why this takes no phone identity.
   *
   *  `running` here means "has an admitted relay data-plane slot" (the core's
   *  {@link ProjectCore.isRelayRegistered}), NOT merely "warm/open on the host".
   *  A desktop-open project that was never promoted is warm but has NO relay
   *  slot — advertising it `running:true` made the phone dial a slot the relay
   *  never admitted, looping AGENT_OFFLINE. So a warm-but-unpromoted core reads
   *  `running:false` until project:start promotes it and the slot registers; the
   *  phone's awaitProjectRunning then keys correctly off the post-register advert
   *  (and off the rejection control:result, which current relays never send —
   *  the retired SESSION_LIMIT_EXCEEDED came from older ones). The
   *  visibility filter still includes warm cores, so the project is listed — it's
   *  just flagged not-yet-dialable. (The desktop hub advertises plain warmth via
   *  `knownProjectsForHub`, which is a different question; keep them distinct.) */
  buildProjectsAdvertisement(): ProjectAdvertEntry[] {
    if (!this.remoteAccessPolicy.isEnabled()) return [];
    const warm = new Set(this.cores.keys());
    return [...new Set([...this.seenProjects.keys(), ...warm])]
      .map((id) => {
        const seen = this.seenProjects.get(id);
        const entry = this.cores.get(id);
        const needsCheckoutRouting = entry?.core.hasManagedSessions() ?? false;
        const peerCanRoute = this.controlPlaneRelay?.peerSupportsCheckoutRouting === true;
        const dialable = (entry?.core.isRelayRegistered() ?? false)
          && (!needsCheckoutRouting || peerCanRoute);
        // A reconnecting phone binds its ProjectSession to this streamId without a
        // fresh project:start (design §7.4). Only surfaced for a dialable stream.
        const streamId = dialable ? this.streamIds.get(id) : undefined;
        // Live work status + running-session count for warm cores only. Cold
        // projects omit both (their agent PTY isn't alive → nothing "working");
        // the app falls back to `running` for those, reading them as done/offline.
        return { projectId: id, label: seen?.label, path: seen?.path, running: dialable, status: entry?.core.workStatus, runningSessions: entry?.core.workRunningCount, sessionStatuses: entry?.core.sessionWorkStatuses, lastActiveAt: seen?.lastActiveAt, streamId };
      });
  }

  /** All registered phones for the desktop mobile-devices hub. Reads the shared
   *  store live, so a CLI `phones remove` between calls is reflected. */
  listPairedPhones(): PairedPhoneSummary[] {
    return this.pairedPhonesStore.list().map((p) => ({
      phonePubkey: p.phonePubkey,
      phoneDeviceId: p.phoneDeviceId,
      label: p.label,
      pairedAt: p.pairedAt,
      lastSeenAt: p.lastSeenAt,
    }));
  }

  /** The machine's known projects (warm cores ∪ seen-catalog hints) — the same
   *  catalog a phone is shown while mobile access is on. */
  knownProjectsForHub(): KnownProject[] {
    const warm = new Set(this.cores.keys());
    const ids = new Set<string>([...this.seenProjects.keys(), ...warm]);
    return [...ids].map((id) => {
      const seen = this.seenProjects.get(id);
      return { projectId: id, label: seen?.label, path: seen?.path, running: warm.has(id) };
    });
  }

  private sendProjectsAdvertisement(bus: MessageBus): void {
    bus.publish(
      createMessage("agent:projects", { projects: this.buildProjectsAdvertisement() }),
      "control",
    );
  }

  /** Machine-level installed-tool catalog for the control plane. Not per-project
   *  — tools are a property of the machine, not of any project.
   *  `chatCapable` is stamped here so the wire is authoritative over which
   *  tools support Chat mode; the app's static list is a fallback only. */
  buildToolsAdvertisement(opts: DetectOptions = {}): Array<{ tool: string; path: string; chatCapable: boolean; label: string }> {
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
      // phone's pull, and it fires only once the phone is fully connected,
      // which is STRICTLY later than the handshake push. If that push ran
      // before the catalog was ready it cached an empty `agent:projects`, and
      // replay alone would faithfully echo the empty frame forever (the bus's
      // payload-dedup also suppresses an identical re-push). Re-publishing here
      // updates the replay cache that dispatchRpc then reads; an unchanged
      // payload is still a cheap no-op.
      if (msg.method === "state.snapshot") {
        this.sendProjectsAdvertisement(bus);
        this.sendToolsAdvertisement(bus);
      }
      if (msg.method === "sessions.list") {
        // Gated, core-free session peek — handled HERE (not in the generic
        // dispatchRpc) because authz needs the host's mobile-access policy and
        // seen-catalog, which dispatchRpc's (bus, params) signature can't see.
        // Async: the handler reads sessions.json off the event loop (see
        // SessionManager.readPersisted), so publish on resolve.
        void this.handleSessionsListRpc(msg)
          .then((res) => bus.publish(res, channel))
          .catch((err) => log.warn("sessions.list handler threw: %s", err));
        return;
      }
      if (msg.method === "sessions.delete") {
        void this.handleSessionsDeleteRpc(msg)
          .then((res) => bus.publish(res, channel))
          .catch((err) => log.warn("sessions.delete handler threw: %s", err));
        return;
      }
      if (msg.method === "git.branches") {
        void this.handleGitBranchesRpc(msg)
          .then((res) => bus.publish(res, channel))
          .catch((err) => log.warn("git.branches handler threw: %s", err));
        return;
      }
      if (msg.method === "git.checkout") {
        void this.handleGitCheckoutRpc(msg)
          .then((res) => bus.publish(res, channel))
          .catch((err) => log.warn("git.checkout handler threw: %s", err));
        return;
      }
      void dispatchRpc(bus, msg).then((res) => bus.publish(res, channel));
      return;
    }
    // Dispatch the verb (Task 4.4) and feed its FAILURE back to the phone as a
    // control:result so a rejected start (NOT_ALLOWED/UNKNOWN_PROJECT/OPEN_FAILED)
    // isn't silently dropped. Success re-advertises agent:projects inside the
    // handler, so we only publish on !ok. `.catch` guards an unexpected throw.
    void this.handleControlPlaneVerb(msg, bus)
      .then((res) => {
        if (!res.ok) {
          // projectId lets the phone fail the exact pending bind (MachineSession
          // keys its stream-ready waiters by projectId) instead of guessing.
          const projectId = "projectId" in msg && typeof msg.projectId === "string" ? msg.projectId : undefined;
          bus.publish(
            createMessage("control:result", { ok: false, verb: msg.type, projectId, error: res.error }),
            "control",
          );
        }
      })
      .catch((err) => log.warn("control-plane verb handler threw: %s", err));
  }

  /** Handle a desktop mobile-devices-hub verb over the loopback control plane.
   *  The bridge is the single writer of paired-phones.json — the app NEVER
   *  writes it directly.
   *
   *  `phones:unpair` drops the phone's identity/push row and re-advertises. It
   *  is NOT a revocation: admission is the account inventory, so the next
   *  client-hello from that device recreates the row. Revoking a device means
   *  signing it out of the account, or turning this machine's mobile access
   *  off for every phone. */
  async handlePhonesVerb(req: ControlRequest): Promise<ControlResponse> {
    switch (req.type) {
      case "phones:list":
        return { id: req.id, ok: true, type: "phones:list", phones: this.listPairedPhones(), knownProjects: this.knownProjectsForHub() };
      case "phones:unpair": {
        this.pairedPhonesStore.remove(req.phonePubkey);
        this.readvertiseToControlPlane();
        return { id: req.id, ok: true, type: "phones:unpair" };
      }
      default:
        return { id: req.id, ok: false, error: { code: "UNKNOWN_VERB", message: `not a phones verb: ${(req as ControlRequest).type}` } };
    }
  }

  /** Handle the machine mobile-access switch over the loopback control plane.
   *  The bridge is the single writer of mobile-access-policy.json, and this
   *  verb is its only mutation path (the store has no fs watcher).
   *
   *  Turning it OFF is machine-wide and immediate: every promoted relay slot is
   *  torn down, so no project is left dialable. The socket itself stays
   *  registered — this switch is authorization, not presence — but the catalog
   *  goes empty and every project verb is rejected. */
  async handleRemoteAccessVerb(req: ControlRequest): Promise<ControlResponse> {
    switch (req.type) {
      case "mobile-access:get":
        return { id: req.id, ok: true, type: "mobile-access:get", enabled: this.remoteAccessPolicy.isEnabled() };
      case "mobile-access:set": {
        const changed = this.remoteAccessPolicy.setEnabled(req.enabled);
        if (changed && !req.enabled) this.demoteAllPromoted();
        if (changed) {
          // The advert derives from the switch, and `Device.mobileAccessEnabled`
          // in the account inventory must not lag until the next reconnect.
          this.readvertiseToControlPlane();
          this.pushHeartbeat();
        }
        return { id: req.id, ok: true, type: "mobile-access:set", enabled: this.remoteAccessPolicy.isEnabled() };
      }
      default:
        return { id: req.id, ok: false, error: { code: "UNKNOWN_VERB", message: `not a mobile-access verb: ${(req as ControlRequest).type}` } };
    }
  }

  /** Answer the drawer's `sessions.list` control-plane RPC: a gated, core-free
   *  session-list peek. Reads the persisted sessions.json directly — no
   *  project:start, no data-plane socket, no side effect of running a stopped
   *  project's startup terminals. Returns a `response` envelope mirroring
   *  dispatchRpc's shape so the app correlates by requestId unchanged. */
  async handleSessionsListRpc(req: RpcRequest): Promise<AbMessage> {
    const parsed = SessionsListParams.safeParse(req.params ?? {});
    if (!parsed.success) {
      return createMessage("response", {
        requestId: req.requestId, ok: false,
        error: { code: "E_BAD_PARAMS", message: parsed.error.issues.map((i) => i.message).join("; ") },
      });
    }
    const { projectId, includeArchived } = parsed.data;
    // SECURITY: reject path separators / dot dirs / hidden names so projectId
    // can never escape or target a dotfile under agents/. Shape only — the
    // catalog lookup below is what confines it to a real project.
    if (!isSafeProjectId(projectId)) {
      return createMessage("response", {
        requestId: req.requestId, ok: false,
        error: { code: "E_BAD_PARAMS", message: "invalid projectId" },
      });
    }
    // SECURITY: same gate as project:start — with mobile access off a phone
    // sees nothing of this machine.
    if (!this.remoteAccessPolicy.isEnabled()) {
      return createMessage("response", {
        requestId: req.requestId, ok: false,
        error: { code: "NOT_ALLOWED", message: "mobile access is disabled on this machine" },
      });
    }
    // SECURITY: the machine switch is machine-wide, so the seen catalog is the
    // ONLY thing bounding WHICH project this reads. Without it any
    // separator-free id would be accepted and `agents/<anything>/sessions.json`
    // read off disk.
    if (!this.seenProjects.has(projectId)) {
      return createMessage("response", {
        requestId: req.requestId, ok: false,
        error: { code: "UNKNOWN_PROJECT", message: "no such project on this machine" },
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

  /** Answer the Recent tab's `sessions.delete` control-plane RPC: gated session
   *  delete. A WARM core (promoted/open) is delegated to its live
   *  SessionManager so in-memory state and sessions.json stay consistent; a
   *  STOPPED project is mutated on disk via SessionManager.deletePersisted. Never
   *  warms a stopped core just to delete. */
  async handleSessionsDeleteRpc(req: RpcRequest): Promise<AbMessage> {
    const parsed = SessionsDeleteParams.safeParse(req.params ?? {});
    if (!parsed.success) {
      return createMessage("response", {
        requestId: req.requestId, ok: false,
        error: { code: "E_BAD_PARAMS", message: parsed.error.issues.map((i) => i.message).join("; ") },
      });
    }
    const { projectId, sessionId, force, removeCheckout, deleteBranch } = parsed.data;
    // SECURITY: shape check only (no separators / dot dirs / hidden names) —
    // the catalog lookup below is what confines it to a real project.
    if (!isSafeProjectId(projectId)) {
      return createMessage("response", {
        requestId: req.requestId, ok: false,
        error: { code: "E_BAD_PARAMS", message: "invalid projectId" },
      });
    }
    if (!this.remoteAccessPolicy.isEnabled()) {
      return createMessage("response", {
        requestId: req.requestId, ok: false,
        error: { code: "NOT_ALLOWED", message: "mobile access is disabled on this machine" },
      });
    }
    // SECURITY: load-bearing, and more so here than on the read path — this verb
    // DELETES. The machine switch says whether any project is reachable; only
    // the seen catalog says which ids exist, so without this an unknown
    // separator-free id would mutate `agents/<anything>/sessions.json`.
    if (!this.seenProjects.has(projectId)) {
      return createMessage("response", {
        requestId: req.requestId, ok: false,
        error: { code: "UNKNOWN_PROJECT", message: "no such project on this machine" },
      });
    }
    const entry = this.cores.get(projectId);
    let deleted: boolean;
    if (entry) {
      // Warm core owns sessions.json — delegate so the live state + disk + any
      // connected peers stay in sync (kills the PTY, emits session:updated).
      deleted = await entry.core.deleteSession(sessionId, { force, removeCheckout, deleteBranch });
    } else {
      try {
        deleted = await this.deleteColdSession(projectId, sessionId, { force, removeCheckout, deleteBranch });
      } catch (error) {
        const code = error instanceof WorktreeError ? error.code : "DELETE_FAILED";
        const message = error instanceof WorktreeError ? error.message : "Could not delete this session.";
        return createMessage("response", { requestId: req.requestId, ok: false, error: { code, message } });
      }
    }
    return createMessage("response", { requestId: req.requestId, ok: true, result: { deleted } });
  }

  async handleGitBranchesRpc(req: RpcRequest): Promise<AbMessage> {
    const parsed = GitBranchesParams.safeParse(req.params ?? {});
    if (!parsed.success) {
      return createMessage("response", {
        requestId: req.requestId,
        ok: false,
        error: { code: "E_BAD_PARAMS", message: parsed.error.issues.map((i) => i.message).join("; ") },
      });
    }
    const { projectId } = parsed.data;
    if (!isSafeProjectId(projectId)) {
      return createMessage("response", {
        requestId: req.requestId,
        ok: false,
        error: { code: "E_BAD_PARAMS", message: "invalid projectId" },
      });
    }
    if (!this.remoteAccessPolicy.isEnabled()) {
      return createMessage("response", {
        requestId: req.requestId,
        ok: false,
        error: { code: "NOT_ALLOWED", message: "mobile access is disabled on this machine" },
      });
    }
    const seen = this.seenProjects.get(projectId);
    if (!seen || !seen.path) {
      return createMessage("response", {
        requestId: req.requestId,
        ok: false,
        error: { code: "UNKNOWN_PROJECT", message: "no such project on this machine" },
      });
    }
    try {
      const catalog = await listLocalBranches(seen.path);
      return createMessage("response", {
        requestId: req.requestId,
        ok: true,
        result: {
          isRepository: catalog.isRepository,
          current: catalog.current,
          branches: catalog.branches,
          worktreeSessionsSupported: catalog.isRepository && WORKTREE_SESSIONS_SUPPORTED,
        },
      });
    } catch (err: any) {
      return createMessage("response", {
        requestId: req.requestId,
        ok: false,
        error: { code: err.code || "UNKNOWN_ERROR", message: err.message || String(err) },
      });
    }
  }

  async handleGitCheckoutRpc(req: RpcRequest): Promise<AbMessage> {
    const parsed = GitCheckoutParams.safeParse(req.params ?? {});
    if (!parsed.success) {
      return createMessage("response", {
        requestId: req.requestId,
        ok: false,
        error: { code: "E_BAD_PARAMS", message: parsed.error.issues.map((i) => i.message).join("; ") },
      });
    }
    const { projectId, branch, allowActiveSessions } = parsed.data;
    if (!isSafeProjectId(projectId)) {
      return createMessage("response", {
        requestId: req.requestId,
        ok: false,
        error: { code: "E_BAD_PARAMS", message: "invalid projectId" },
      });
    }
    if (!this.remoteAccessPolicy.isEnabled()) {
      return createMessage("response", {
        requestId: req.requestId,
        ok: false,
        error: { code: "NOT_ALLOWED", message: "mobile access is disabled on this machine" },
      });
    }
    const seen = this.seenProjects.get(projectId);
    if (!seen || !seen.path) {
      return createMessage("response", {
        requestId: req.requestId,
        ok: false,
        error: { code: "UNKNOWN_PROJECT", message: "no such project on this machine" },
      });
    }
    try {
      const catalog = await listLocalBranches(seen.path);
      if (!catalog.isRepository) {
        return createMessage("response", {
          requestId: req.requestId,
          ok: false,
          error: { code: "NOT_GIT_REPOSITORY", message: "Not a Git repository" },
        });
      }
      if (!catalog.branches.includes(branch)) {
        return createMessage("response", {
          requestId: req.requestId,
          ok: false,
          error: { code: "UNKNOWN_BRANCH", message: `Branch '${branch}' does not exist` },
        });
      }

      if (catalog.current !== branch) {
        const entry = this.cores.get(projectId);
        const statuses = entry?.core.mainSessionWorkStatuses ?? {};
        const hasActive = Object.values(statuses).some(
          (status) => status === "working" || status === "attention",
        );
        if (hasActive && allowActiveSessions !== true) {
          return createMessage("response", {
            requestId: req.requestId,
            ok: false,
            error: {
              code: "ACTIVE_SESSIONS",
              message: `One or more sessions in this folder are working or need you. Switching to "${branch}" changes the working tree for all of them.`,
            },
          });
        }
      }

      const res = await checkoutLocalBranch(seen.path, branch);
      await this.refreshWarmGitState(projectId, seen.path);
      return createMessage("response", {
        requestId: req.requestId,
        ok: true,
        result: { current: res.current },
      });
    } catch (err: any) {
      return createMessage("response", {
        requestId: req.requestId,
        ok: false,
        error: { code: err.code || "CHECKOUT_FAILED", message: err.message || String(err) },
      });
    }
  }

  /** Dispatch an E2E control-plane verb from the connected account-trusted
   *  phone. Returns a structured result; callers on the bus path discard it
   *  (void). */
  async handleControlPlaneVerb(
    verb: AbMessage,
    bus: MessageBus,
  ): Promise<{ ok: true } | { ok: false; error: { code: string; message: string } }> {
    if (verb.type === "project:start") {
      // SECURITY: checked BEFORE open() — open() runs the project's `terminals:`
      // startup commands, so a rejected start must create NO core.
      if (!this.remoteAccessPolicy.isEnabled()) {
        return { ok: false, error: { code: "NOT_ALLOWED", message: "mobile access is disabled on this machine" } };
      }
      // SECURITY: the path comes from the host's OWN catalog, never from the
      // phone's message (the message has no path field). This lookup is also the
      // only per-project bound on what a phone may name — an id with no path on
      // record is rejected, never opened with a guessed path.
      const seen = this.seenProjects.get(verb.projectId);
      if (!seen) return { ok: false, error: { code: "UNKNOWN_PROJECT", message: "no path on record; open from desktop first" } };
      if (await this.projectRequiresCheckoutRouting(verb.projectId)
        && this.controlPlaneRelay?.peerSupportsCheckoutRouting !== true) {
        return {
          ok: false,
          error: { code: "UPDATE_REQUIRED", message: "update the app to use this project's isolated sessions" },
        };
      }
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
        // surface a terminal rejection (only the retired SESSION_LIMIT_EXCEEDED,
        // from a relay predating the worker-limit change). project:start
        // itself returns ok immediately — the outcome is pushed asynchronously.
        this.reportFirstRegister(handle.firstRegister, projectId, bus, () => {
          // Tear the rejected slot down so a later retry can re-promote, and so
          // the core reads not-promoted again.
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
          this.reportFirstRegister(firstRegister, projectId, bus, () => {
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
      // else: already remote OR already promoted → idempotent. The phone's
      // project:start IS the "what stream do I bind?" question, and the re-advert
      // alone can't answer it — the bus's payload dedup legally suppresses a
      // byte-identical re-advert to a reconnecting phone. stream-ready is
      // dedup-immune (not in REPLAY_TYPES), so publish the binding whenever the
      // slot is actually relay-admitted (same dialable gate as the advert).
      if (this.cores.get(projectId)?.core.isRelayRegistered()) {
        const streamId = this.streamIds.get(projectId);
        if (streamId) {
          bus.publish(createMessage("stream-ready", { projectId, streamId }), "control");
        }
      }
      // Re-advertise so the phone re-reads the current dialable state
      // (running:true only if the slot is actually relay-admitted —
      // buildProjectsAdvertisement gates on that, so a promoted-but-not-yet-
      // registered core still reads not-running here).
      this.sendProjectsAdvertisement(bus);
      return { ok: true };
    }
    return { ok: false, error: { code: "UNKNOWN_VERB", message: `unsupported control-plane verb: ${verb.type}` } };
  }

  /** Report a relay slot's FIRST register outcome to the requesting phone over
   *  the control plane. On success, advertise `running:true` ONLY now — so the
   *  phone never dials a data-plane slot the gate hasn't admitted (the empty-slot
   *  AGENT_OFFLINE loop). On a terminal rejection, run `onFatal` (tear the dead
   *  slot down) and push a structured `control:result` so the phone surfaces the
   *  real reason instead of retrying.
   *  Non-blocking + never throws into the caller. */
  private reportFirstRegister(
    firstRegister: Promise<RegisterOutcome>,
    projectId: string,
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
          this.sendProjectsAdvertisement(bus);
          return;
        }
        onFatal();
        bus.publish(
          createMessage("control:result", {
            ok: false,
            verb: "project:start",
            projectId,
            error: { code: outcome.code, message: outcome.message },
          }),
          "control",
        );
      })
      .catch((e) => log.warn("reportFirstRegister threw for %s: %s", projectId, e));
  }

  /** True once an already-open core has been promoted onto the relay (additive
   *  relay slot). Diagnostic/test seam for the promote path. */
  isPromoted(id: string): boolean {
    return !!this.cores.get(id)?.promotion;
  }

  /** Tear down every active relay slot (PromotionHandle) and return each core
   *  to loopback-only. Called when `mobile-access:set` turns the machine off:
   *  the switch is machine-wide, so no project may be left dialable. NOT wired
   *  to phone disconnect, which must not demote (a transient drop is not a
   *  revocation). Idempotent: safe to call when no core is promoted. The core
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
        log.warn("Failed to demote promoted core %s: %s", projectId, e instanceof Error ? e.message : String(e));
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
      case "project:resolve": {
        const project = await resolveProject(req.folder);
        return {
          id: req.id,
          ok: true,
          type: "project:resolve",
          ...project,
          label: basename(project.repoPath),
        };
      }
      case "tools:list":
        return {
          id: req.id,
          ok: true,
          type: "tools:list",
          // Same builder as the remote `agent:tools` advert: the loopback and
          // relay pickers must describe a tool identically, and a second copy
          // of the entry shape is how they drift.
          tools: this.buildToolsAdvertisement(),
        };
      case "project:open": {
        try {
          const r = await this.open(req.projectId, req.projectPath, req.mode);
          return { id: req.id, ok: true, type: "project:open", running: r.running, connect: r.connect };
        } catch (err) {
          const e = err as Error & { code?: string };
          if (e.code === "PROJECT_ID_MISMATCH") {
            return { id: req.id, ok: false, error: { code: e.code, message: e.message } };
          }
          throw err;
        }
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
      case "phones:unpair":
        return this.handlePhonesVerb(req);
      case "mobile-access:get":
      case "mobile-access:set":
        return this.handleRemoteAccessVerb(req);
      case "git:branches": {
        try {
          const catalog = await listLocalBranches(req.projectPath);
          return {
            id: req.id,
            ok: true,
            type: "git:branches",
            isRepository: catalog.isRepository,
            current: catalog.current,
            branches: catalog.branches,
            worktreeSessionsSupported: catalog.isRepository && WORKTREE_SESSIONS_SUPPORTED,
          };
        } catch (err: any) {
          return {
            id: req.id,
            ok: false,
            error: { code: err.code || "UNKNOWN_ERROR", message: err.message || String(err) },
          };
        }
      }
      case "git:checkout": {
        try {
          const catalog = await listLocalBranches(req.projectPath);
          if (!catalog.isRepository) {
            return { id: req.id, ok: false, error: { code: "NOT_GIT_REPOSITORY", message: "Not a Git repository" } };
          }
          if (!catalog.branches.includes(req.branch)) {
            return { id: req.id, ok: false, error: { code: "UNKNOWN_BRANCH", message: `Branch '${req.branch}' does not exist` } };
          }

          if (catalog.current !== req.branch) {
            const entry = this.cores.get(req.projectId);
            const statuses = entry?.core.mainSessionWorkStatuses ?? {};
            const hasActive = Object.values(statuses).some(
              (status) => status === "working" || status === "attention",
            );
            if (hasActive && req.allowActiveSessions !== true) {
              return {
                id: req.id,
                ok: false,
                error: {
                  code: "ACTIVE_SESSIONS",
                  message: `One or more sessions in this folder are working or need you. Switching to "${req.branch}" changes the working tree for all of them.`,
                },
              };
            }
          }

          const res = await checkoutLocalBranch(req.projectPath, req.branch);
          await this.refreshWarmGitState(req.projectId, req.projectPath);
          return { id: req.id, ok: true, type: "git:checkout", current: res.current };
        } catch (err: any) {
          return {
            id: req.id,
            ok: false,
            error: { code: err.code || "CHECKOUT_FAILED", message: err.message || String(err) },
          };
        }
      }
    }
  }

  private async refreshWarmGitState(projectId: string, projectPath: string): Promise<void> {
    const entry = this.cores.get(projectId);
    if (!entry) return;
    const entryPath = resolve(entry.path);
    const checkoutPath = resolve(projectPath);
    const samePath = process.platform === "win32"
      ? entryPath.toLowerCase() === checkoutPath.toLowerCase()
      : entryPath === checkoutPath;
    if (!samePath) return;
    try {
      await entry.core.refreshGitState();
    } catch (err) {
      // Checkout already succeeded; a failed UI refresh must not report the
      // branch operation itself as failed. The core's poll will retry later.
      log.warn(
        "Failed to refresh Git state for %s after checkout: %s",
        projectId,
        err instanceof Error ? err.message : String(err),
      );
    }
  }

  /** Idempotent: returns the existing running core if already open, and
   *  coalesces concurrent opens of the same not-yet-open project. */
  async open(projectId: string, projectPath: string, mode: "local" | "remote"): Promise<OpenResult> {
    const resolved = await resolveProject(projectPath);
    // AFTER the resolve, not before: the resolve is a git spawn, and a caller
    // that started before this one may have finished its whole core startup
    // (and cleared `opening`) while we were suspended here. Checking `cores`
    // only on the way in would send that late caller on to start a second core.
    const existing = this.cores.get(projectId);
    if (existing) {
      existing.lastFocusedMs = this.tick();
      this.touchSeenProject(projectId);
      return this.resultFor(existing);
    }
    // The host is authoritative for project identity: a linked worktree and its
    // primary checkout are ONE project. A caller naming a folder under its own
    // path hash would otherwise get a second core over the same repository,
    // with its own session store and its own idea of which checkout is main.
    // Checked below the warm-core branch so an already-running legacy alias
    // (validated when it was created) keeps working until migration imports it.
    if (resolved.projectId !== projectId) {
      throw Object.assign(
        new Error(`project ${projectPath} resolves to ${resolved.projectId}, not ${projectId}`),
        { code: "PROJECT_ID_MISMATCH", resolvedProjectId: resolved.projectId },
      );
    }
    projectPath = resolved.repoPath;
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
    let relayUrl: string | undefined;
    if (mode === "remote") {
      await this.ensureRemoteRuntime();
      // A remote core attaches to the ONE machine socket (design §7); ensure it
      // is up (startControlPlane already opened it when launched with remote
      // config — this guards the wizard-bootstrapped path).
      if (!this.controlPlaneRelay) await this.startRemoteControlPlane();
      remote = this.remoteDepsFor(projectId);
      // The core can't derive this itself — only a standalone agent with an
      // explicit antgrid.yaml `relayUrl:` has one in config, so a host-spawned
      // core would otherwise banner a connect URI with no relay coordinate.
      relayUrl = this.requireRemoteConfig().relayUrl;
    }
    const core = new ProjectCore({
      folder: projectPath,
      mode,
      identity: this.identityFor(mode),
      ...(relayUrl ? { relayUrl } : {}),
      pairedPhones: this.pairedPhonesStore,
      // Read live, not captured: a `mobile-access:set` must take effect on every
      // already-warm core's gate without restarting it.
      remoteAccessEnabled: () => this.remoteAccessPolicy.isEnabled(),
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
    // Push the newly-warm project to the connected phone NOW — without this,
    // a project opened from the desktop reaches the phone only when its first
    // work-status transition happens to re-advertise (i.e. late or never).
    this.readvertiseToControlPlane();
    log.info(`host: opened project ${projectId} (mode=${mode}, ${this.cores.size} core(s) warm)`);
    await this.evictIfNeeded(projectId);
    // An open that no phone asked for (host restart re-opening a project, a
    // desktop-side open) changes the catalog with nothing else to announce it —
    // handleControlPlaneVerb only re-advertises for a phone's own project:start.
    // A restart in particular opens projects AFTER the handshake advert has
    // already gone out, so without this the phone's catalog is a snapshot of a
    // host that had nothing open. Payload-equal adverts are deduped by the bus.
    this.readvertiseToControlPlane();
    return this.resultFor(entry);
  }

  /** Build the machine OAuth runtime once, on the first remote open. Coalesces
   *  concurrent first-opens onto a single in-flight mint (the `await oauth.mint()`
   *  yields before `remoteRuntime` is set, so a plain re-check would race). */
  private ensureRemoteRuntime(): Promise<RemoteRuntime> {
    if (this.remoteRuntime) return Promise.resolve(this.remoteRuntime);
    if (this.remoteRuntimePromise) return this.remoteRuntimePromise;
    const r = this.requireRemoteConfig();
    // OAuthClient captures the callback once, at build time, so route it
    // through a closure that reads the arming flag live — that is what lets
    // start() disarm the boot window without rebuilding the runtime.
    const cfg: HostRemoteConfig = {
      ...r,
      onAuthRevoked: () => {
        if (this.fatalRevokeArmed) r.onAuthRevoked();
        else log.warn("host: credentials rejected at boot; serving loopback only until respawned");
      },
    };
    const build = this.opts.remoteRuntimeFactory ?? buildRemoteRuntime;
    // Late binding: the machine RelayClient is constructed AFTER the runtime (its
    // token maintenance) in startRemoteControlPlane/startCore, so this closure
    // reads controlPlaneRelay lazily at each re-mint. A LICENSE_EXPIRED stop keeps
    // maintenance re-minting; the first fresh mint redials the stopped socket. The
    // `?.` no-ops before the client exists and after a real revoke.
    const onMinted = () => this.controlPlaneRelay?.redialWithFreshToken();
    const promise = (async () => {
      this.remoteRuntime = await build(cfg, onMinted);
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
    const r = this.remoteConfig();
    if (!r) throw new Error("HostServer: remote mode requires machine remote config");
    return r;
  }

  /** The machine remote config, or null. `wizardRemote` is the desktop-wizard
   *  promotion of a host launched local-only, so anything that reads only
   *  `opts.remote` silently no-ops on that whole path. */
  private remoteConfig(): HostRemoteConfig | null {
    return this.opts.remote ?? this.wizardRemote;
  }

  /** Push the machine's current mobile-access state (relayUrl, machineName, and
   *  the machine switch) to the account inventory. Called both on relay
   *  (re)authentication and immediately after a `mobile-access:set`, so
   *  `Device.mobileAccessEnabled` in the web DB reflects the actual policy
   *  rather than lagging until the next reconnect — the two are now the same
   *  boolean, not a projection. No-op without remote config or before the OAuth
   *  runtime exists — every real caller has already gone through
   *  startRemoteControlPlane/ensureRemoteRuntime by the time this can fire. */
  private pushHeartbeat(): void {
    const r = this.remoteConfig();
    if (!r || !this.remoteRuntime) return;
    const rt = this.remoteRuntime;
    // Rides the heartbeat cadence to keep the E2E-admission inventory cache
    // warm without a dedicated poll loop.
    void this.trustedPeers?.refresh();
    void sendHeartbeat({
      licenseApiUrl: r.licenseApiUrl,
      getToken: rt.maint.getToken,
      deviceUuid: r.auth.deviceUuid,
      mobileAccessEnabled: this.remoteAccessPolicy.isEnabled(),
      relayUrl: r.relayUrl,
      machineName: process.env.ANTGRID_HOST_NAME ?? hostname(),
    }).then((ok) => {
      if (!ok) log.warn("heartbeat POST failed (non-2xx or network error)", { deviceUuid: r.auth.deviceUuid });
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
      sessionStatuses: e.core.sessionWorkStatuses,
    }));
  }

  async stop(projectId: string): Promise<void> {
    const entry = this.cores.get(projectId);
    if (!entry) return;
    this.cores.delete(projectId);
    // A promoted local core holds a relay slot separate from its loopback session
    // (core.shutdown only closes the core's own `this.relay`, which a local core
    // never set). Stop the slot explicitly so it doesn't leak past teardown.
    try { entry.promotion?.stop(); } catch (e) { log.warn("Failed to stop promotion for %s: %s", projectId, e instanceof Error ? e.message : String(e)); }
    await entry.core.shutdown();
  }

  /** Erase every machine-side trace of a project so reopening the same folder
   *  starts clean. The app calls this on project delete: `sessions.json` is the
   *  AUTHORITATIVE session list (the app merely caches it), so without this a
   *  removed project's sessions reload on the next open. Each step is
   *  best-effort — a failure in one must never strand the others:
   *    1. stop a warm core (kills its PTYs + any relay slot),
   *    2. delete the on-disk store dir (`agents/<id>/`, holding sessions.json),
   *    3. drop the seen-catalog hint (also clears the stale projects.json entry).
   *  Deliberately does NOT touch the machine's mobile-access switch: that is
   *  machine-wide policy, and deleting one project must not turn the machine
   *  off (or on) for every other.
   *  Idempotent: forgetting an unknown/already-forgotten id is a no-op. */
  async forget(projectId: string): Promise<void> {
    await this.stop(projectId);
    this.deleteProjectStores(projectId);
    if (this.seenProjects.delete(projectId)) this.flushSeen();
    // Unconditional: the advert IS the seen catalog now, so a forgotten project
    // must vanish from a live phone's picker without waiting for a reconnect
    // (the advertisement is otherwise only re-sent on handshake).
    this.readvertiseToControlPlane();
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
        log.warn("host: failed to delete %s: %s", dir, e instanceof Error ? e.message : String(e));
      }
    }
  }

  async shutdown(reason?: string): Promise<void> {
    // Persist the hint catalog up front so memory↔disk agree on a clean exit
    // (and so it survives even if a force-kill backstop fires before the slower
    // core teardown below finishes).
    this.flushSeen();
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
    this.controlPlaneRelay?.close();
    this.controlPlaneRelay = null;
    this.controlPlaneBus = null;
    this.remoteRuntime?.maint.stop();
    // Always close the paired-phones fs.watch handle, even if the control plane
    // was never started, so tests don't leak handles (Windows EBUSY).
    this.stopPhonesWatch?.();
    this.stopPhonesWatch = null;
    // Persist admissions coalesced since the last touch flush, so `last seen`
    // reflects the end of the session rather than the last whole minute of it.
    this.pairedPhonesStore.close();
    await this.control?.stop();
    if (this.control) removeHostFile(hostFilePath());
    this.control = null;
    const entries = [...this.cores.values()];
    this.cores.clear();
    for (const e of entries) { try { e.promotion?.stop(); } catch (err) { log.warn("Failed to stop promotion for %s during shutdown: %s", e.core.projectId, err instanceof Error ? err.message : String(err)); } }
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
      currentPeerSupportsCheckoutRouting: () => client.peerSupportsCheckoutRouting,
      sendPushDeliver: (m) => client.sendPushDeliver(m),
    };
  }

  /** Cold projects have no core to inspect, so compatibility derives only from
   * the host-owned session store. A remote request never supplies a path. */
  private async projectRequiresCheckoutRouting(projectId: string): Promise<boolean> {
    const warm = this.cores.get(projectId)?.core;
    if (warm) return warm.hasManagedSessions();
    const sessions = await SessionManager.readPersisted(resolveAbDir(), projectId, true);
    return sessions.some((session) => session.checkoutKind === "managed-worktree");
  }

  /** Cold deletion still owns the same safe worktree lifecycle as a warm core.
   * The repository path is resolved exclusively from this host's seen catalog. */
  private async deleteColdSession(
    projectId: string,
    sessionId: string,
    options: { force?: boolean; removeCheckout?: boolean; deleteBranch?: boolean },
  ): Promise<boolean> {
    const persisted = await SessionManager.readPersisted(resolveAbDir(), projectId, true);
    const session = persisted.find((entry) => entry.id === sessionId);
    if (!session) return false;
    if (session.checkoutKind !== "managed-worktree") {
      return SessionManager.deletePersisted(resolveAbDir(), projectId, sessionId);
    }
    if (options.removeCheckout === false) {
      throw new WorktreeError("WORKTREE_CONFLICT", "An isolated session must remove its managed worktree when deleted.");
    }
    const manager = new WorktreeManager({
      abDir: resolveAbDir(),
      resolveRepoPath: async (id) => this.seenProjects.get(id)?.path,
    });
    // The manager repeats the dirty/unpushed preflight and only removes metadata
    // after Git confirms removal. Persist the session row last.
    await manager.remove({
      checkoutId: session.checkoutId,
      force: options.force === true,
      deleteBranch: options.deleteBranch === true,
    });
    return SessionManager.deletePersisted(resolveAbDir(), projectId, sessionId);
  }

  private async evictIfNeeded(justOpened: string): Promise<void> {
    const cap = this.opts.warmCap ?? kHostWarmCap;
    let evictedAny = false;
    while (this.cores.size > cap) {
      const victim = this.selectEvictionVictim(justOpened);
      if (!victim) break;
      const entry = this.cores.get(victim);
      this.cores.delete(victim);
      try { entry?.promotion?.stop(); } catch (e) { log.warn("Failed to stop promotion for evicted core %s: %s", victim, e instanceof Error ? e.message : String(e)); }
      log.info(`host: evicting LRU core ${victim} (cap ${cap})`);
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
    catch (e) { log.warn("host: failed to persist projects.json (hint only): %s", e); }
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
