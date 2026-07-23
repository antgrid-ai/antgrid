import { hostname } from "node:os";
import { logger } from "./logger";
import { AgentEnableRelayMessage, createMessage, type AbMessage } from "./protocol";
import { MessageBus } from "./message-bus";
import type { AttachStreamOpts, StreamHandle } from "./stream-mux";
import type { ProjectCoreRemoteDeps } from "./project-core";
import { buildPairingUri } from "./pairing";
import type { PairingWindow } from "./pairing-window";
import type { AgentCore } from "./agent-core";

type EnableMsg = Extract<AbMessage, { type: "agent:enableRelay" }>;

/**
 * The machine relay socket surface the wizard promotion path needs. Provided by
 * HostServer (which owns the single {@link RelayClient}): the wizard never builds
 * a relay client of its own — it brings the machine socket up (from the
 * app-supplied credentials if it isn't already) and attaches the local core as a
 * stream (design §7.4).
 */
export interface MachineRelaySession {
  attachStream(bus: MessageBus, opts: AttachStreamOpts): StreamHandle;
  currentPeerPubkey(): string | null;
  sendPushDeliver(msg: { pushToken: string; provider: "fcm" | "apns"; blob: { epk: string; box: string } }): void;
  /** The machine control-plane pairing window (opened for a wizard pair). */
  pairingWindow: PairingWindow;
  /** Bare machine deviceUuid — the QR `d=` payload (no `.projectId`; §7.4). */
  agentDeviceId: string;
  /** Account-device Ed25519 public key (standard base64). */
  ed25519Pub: string;
  relayBase: string;
}

/** ProjectCore's local-core stream attachment, reused so the wizard path shares
 *  the exact tunnel-hook / allowlist-gate / push wiring of the remote path. */
export interface LocalStreamAttachment {
  handle: StreamHandle;
  detach(): void;
}

export interface RelayPromotionDeps {
  core: AgentCore;
  bus: MessageBus;
  /** Host machine name advertised in the pairing QR. */
  hostName?: string;
  /** Bring the machine relay socket up (from the wizard credentials if absent)
   *  and return its pairing + attach surface. Absent for a bare agent with no
   *  host — enabling relay is then unsupported. */
  ensureMachineRelay?: (msg: EnableMsg) => Promise<MachineRelaySession>;
  /** Attach the local core as a stream on the machine session, reusing
   *  ProjectCore's full stream wiring. Provided by ProjectCore. */
  attach?: (remote: ProjectCoreRemoteDeps) => LocalStreamAttachment;
}

export interface RelayPromotionController {
  /** Returns true if the message was an enable/disable directive (consumed). */
  handleInbound(msg: AbMessage): boolean;
  /** Tear the stream down (idempotent). Safe to call when never enabled. */
  stop(): void;
}

/**
 * Local-mode relay promotion controller (the desktop "enable mobile access"
 * wizard).
 *
 * In local (loopback) mode the agent serves the desktop app over a localhost
 * listener. When the user enables mobile access, the app sends
 * `agent:enableRelay` carrying the signed-in account device's credentials. In
 * v3 this controller does NOT build its own relay connection: it asks the host
 * to bring the single machine socket up (design §7), opens the pairing window,
 * builds the QR (bare deviceUuid), and attaches the local core's bus as a
 * stream. `agent:disableRelay` detaches the stream — the machine socket stays,
 * owned by the control plane.
 *
 * Encryption is never optional: the machine socket owns the one E2E session
 * every stream is sealed under; the relay only ever sees opaque blobs.
 */
export function createRelayPromotion(deps: RelayPromotionDeps): RelayPromotionController {
  const { core, bus } = deps;
  const hostName = deps.hostName ?? process.env.ANTGRID_HOST_NAME ?? hostname();

  let session: MachineRelaySession | null = null;
  let attachment: LocalStreamAttachment | null = null;
  let starting = false;
  // Bumped by every stop(). An in-flight start() captures the value before its
  // one `await` and re-checks after, so a disableRelay that lands mid-start
  // cancels the attach instead of stranding a stream the user just turned off.
  let activeGen = 0;

  function emitError(code: string, message: string): void {
    bus.publish(createMessage("agent:relayError", { code, message }), "control");
  }

  function openPairingAndEmit(s: MachineRelaySession): void {
    const { code, expiresAt } = s.pairingWindow.open();
    const pairingQr = buildPairingUri({
      relayUrl: s.relayBase,
      agentDeviceId: s.agentDeviceId,
      // Standard base64 to match how the app encodes ed25519Pub and how the
      // relay decodes it — keep the decoder symmetric rather than leaning on
      // Node's lenient base64url alphabet.
      agentEd25519PublicKey: Buffer.from(s.ed25519Pub, "base64"),
      pairCode: code,
      agentName: core.identity.deviceName,
      hostMachineName: hostName,
    });
    bus.publish(
      createMessage("agent:pairingReady", {
        pairingQr,
        pairCode: code,
        pairCodeExpiresAt: expiresAt,
        agentDeviceId: s.agentDeviceId,
      }),
      "control",
    );
  }

  async function start(msg: EnableMsg): Promise<void> {
    if (starting) return; // coalesce a concurrent enable — see finally.
    if (session && attachment) {
      // Already promoted. A repeat enableRelay ("Pair another phone") re-opens a
      // fresh pairing window against the existing machine session. Guard on
      // isOpen() so a window still live from a prior request isn't rotated.
      if (!session.pairingWindow.isOpen()) openPairingAndEmit(session);
      return;
    }
    starting = true;
    const myGen = ++activeGen;
    try {
      // Re-validate the loopback-delivered message: the local listener uses
      // parseMessageFast (skips Zod), so a malformed deviceUuid / non-base64 key
      // / schemeless relayUrl would otherwise fail late inside the crypto layers.
      const validated = AgentEnableRelayMessage.safeParse(msg);
      if (!validated.success) {
        emitError("INVALID_REQUEST", `Malformed enableRelay: ${validated.error.issues[0]?.message ?? "invalid request"}`);
        return;
      }
      const auth = msg.auth;
      if (!auth || !auth.ed25519Pub || !auth.ed25519Priv || !auth.deviceUuid) {
        emitError("NO_CREDENTIALS", "Enable mobile access requires a signed-in account device. Sign in and retry.");
        return;
      }
      if (!deps.ensureMachineRelay || !deps.attach) {
        emitError("NO_HOST", "Mobile access is unavailable without a host.");
        return;
      }

      let ensured: MachineRelaySession;
      try {
        ensured = await deps.ensureMachineRelay(msg);
      } catch (e) {
        emitError("ENABLE_FAILED", e instanceof Error ? e.message : String(e));
        return;
      }
      if (myGen !== activeGen) {
        // disableRelay landed while we were bringing the machine socket up.
        return;
      }

      const remote: ProjectCoreRemoteDeps = {
        attachStream: (b, opts) => ensured.attachStream(b, opts),
        currentPeerPubkey: () => ensured.currentPeerPubkey(),
        sendPushDeliver: (m) => ensured.sendPushDeliver(m),
      };
      attachment = deps.attach(remote);
      session = ensured;
      if (!ensured.pairingWindow.isOpen()) openPairingAndEmit(ensured);
    } catch (e) {
      emitError("ENABLE_FAILED", e instanceof Error ? e.message : String(e));
      stop();
    } finally {
      starting = false;
    }
  }

  function stop(): void {
    activeGen++;
    if (attachment) {
      try { attachment.detach(); } catch { /* best-effort */ }
      attachment = null;
    }
    if (session) {
      try { session.pairingWindow.close(); } catch { /* best-effort */ }
      session = null;
    }
  }

  return {
    handleInbound(msg) {
      if (msg.type === "agent:enableRelay") {
        void start(msg);
        return true;
      }
      if (msg.type === "agent:disableRelay") {
        stop();
        return true;
      }
      return false;
    },
    stop,
  };
}
