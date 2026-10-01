import type { Channel, InboundSource, MessageBus } from "./message-bus";
import { createMessage, type AbMessage } from "./protocol";
import { logger } from "./logger";

const log = logger.child({ component: "screen-relay" });

/** How long {@link ScreenRelay.revokeAll} waits for its notices to reach the
 *  viewers' streams. Handing a record to a stream is a local buffer write, so
 *  this bounds only a stalled stream — and the caller holds a switch open for
 *  as long as it waits. */
export const REVOKE_NOTICE_BUDGET_MS = 250;

/** Prefix match rather than a type list, so a `screen:*` type added later is
 *  gated and routed by default instead of falling through to the core dispatch
 *  unnoticed. Only types in protocol.ts's KNOWN_TYPES ever reach here. */
export function isScreenFrame(msg: AbMessage): boolean {
  return msg.type.startsWith("screen:");
}

export interface ScreenRelayDeps {
  bus: MessageBus;
  /** Whether the desktop capture host (this core's loopback owner) is connected. */
  hasOwner: () => boolean;
  /** Both read live, so a switch flipped on an already-warm core takes effect on
   *  the next frame. Fail-closed when unwired. */
  remoteAccessEnabled?: () => boolean;
  screenControlEnabled?: () => boolean;
}

/** Routes `screen:*` WebRTC signalling between remote viewers and the desktop
 *  capture host, which is the core's loopback owner.
 *
 *  Every hop is addressed, never broadcast. A viewer's frame goes to the
 *  loopback wire alone (`publishOnly(…, "loopback")`), stamped with the Iroh
 *  peer id its project stream was admitted under; the host's reply names that
 *  `viewerId` and goes to that one peer alone. Two viewers can therefore never
 *  read each other's SDP, and nothing a viewer sends can come back to it as an
 *  echo — the bus's audience targeting does what a subscriber-side "ignore your
 *  own signalling" rule used to.
 *
 *  `viewerId` is the bridge's to set on the way in, overwriting whatever the
 *  frame carried: the peer id comes from the authorization lease that admitted
 *  the connection (`acceptPeer`), which is the only identity the viewer cannot
 *  choose. */
export class ScreenRelay {
  /** Viewers that have reached the host since it last went away — who to tell
   *  when the host disappears or the switch goes off. Not an authorization
   *  record: every frame is re-gated on arrival regardless. */
  private readonly viewers = new Set<string>();

  constructor(private readonly deps: ScreenRelayDeps) {}

  /** True if [msg] was a screen frame and has been handled (routed or dropped);
   *  false means the caller's own dispatch should take it. */
  handleInbound(msg: AbMessage, channel: Channel, source: InboundSource, peerId?: string): boolean {
    if (!isScreenFrame(msg)) return false;
    if (source === "loopback") this.fromHost(msg, channel);
    else this.fromViewer(msg, channel, peerId);
    return true;
  }

  /** A client's transport went away. `"loopback"` is the capture host; anything
   *  else is a viewer's Iroh peer id. */
  clientGone(client: string): void {
    if (client === "loopback") {
      this.hostGone();
      return;
    }
    if (!this.viewers.delete(client)) return;
    // The host would otherwise hold a live capture until ICE gives up — tens of
    // seconds of a window streaming to nobody. The bridge sees the viewer's
    // Iroh stream close the moment it happens, so it says so.
    this.toHost(createMessage("screen:stop", { reason: "viewer-gone", viewerId: client }), "control");
  }

  /** The screen-control or remote-access switch went off. Tells the host to
   *  tear its capture down and each viewer why its picture stopped.
   *
   *  The host's stop names no viewer: it is the one `screen:stop` a viewer can
   *  never produce, since every viewer frame is stamped on the way in, and it
   *  ends whatever the host is running. So it reaches a capture even when
   *  {@link viewers} no longer lists its viewer — as after the host's socket
   *  dropped and came back with the session still live.
   *
   *  Resolves once each viewer's notice is on its stream, or after
   *  {@link REVOKE_NOTICE_BUDGET_MS}: a caller about to close those streams
   *  waits for it, and a stalled one must not hold that caller up. */
  async revokeAll(reason: string): Promise<void> {
    this.toHost(createMessage("screen:stop", { reason }), "control");
    const viewers = [...this.viewers];
    this.viewers.clear();
    if (viewers.length === 0) return;
    const budget = new AbortController();
    const notices = viewers.map((viewerId) =>
      this.deps.bus
        .deliverTo(
          createMessage("screen:state", { status: "ended", reason, viewerId }),
          "control",
          "relay",
          budget.signal,
          viewerId,
        )
        .catch((err: unknown) => {
          log.warn("Could not tell %s its screen session ended: %s", viewerId, err instanceof Error ? err.message : String(err));
        }),
    );
    let timer: ReturnType<typeof setTimeout> | undefined;
    await Promise.race([
      Promise.all(notices),
      new Promise<void>((resolve) => { timer = setTimeout(resolve, REVOKE_NOTICE_BUDGET_MS); }),
    ]);
    clearTimeout(timer);
    budget.abort();
  }

  private allowed(): boolean {
    return (this.deps.remoteAccessEnabled?.() ?? false) && (this.deps.screenControlEnabled?.() ?? false);
  }

  private fromViewer(msg: AbMessage, channel: Channel, peerId: string | undefined): void {
    // A frame with no peer id has nowhere for the reply to go, and the Iroh
    // transport always threads one — anything without it is not a viewer.
    if (!peerId) {
      log.warn("Dropping inbound %s: no peer id to answer", msg.type);
      return;
    }
    // This handler sits AHEAD of agent-core's inbound chokepoint, so the gate
    // there never runs for these frames and the equivalent check has to happen
    // here. Screen capture plus input injection is a capability of its own, so
    // it answers to BOTH machine switches.
    if (!this.allowed()) {
      log.warn("Dropping inbound %s: screen control is disabled", msg.type);
      return;
    }
    if (!this.deps.hasOwner()) {
      // Without this the viewer waits forever with nothing to time out against.
      this.toViewer(createMessage("screen:state", { status: "no-host", viewerId: peerId }), channel, peerId);
      return;
    }
    // A viewer's own stop leaves it with nothing to be told about when the host
    // or a switch later goes away.
    if (msg.type === "screen:stop") this.viewers.delete(peerId);
    else this.viewers.add(peerId);
    this.toHost({ ...msg, viewerId: peerId } as AbMessage, channel);
  }

  private fromHost(msg: AbMessage, channel: Channel): void {
    const viewerId = (msg as { viewerId?: string }).viewerId;
    // Unaddressed host signalling has no single right recipient, and a
    // broadcast would hand one viewer's session description to every device on
    // the project. Fail closed.
    if (!viewerId) {
      log.warn("Dropping outbound %s: no viewerId", msg.type);
      return;
    }
    // An `ended` state discloses nothing and is the one frame a viewer needs
    // AFTER the switch goes off — without it the viewer reads the dying ICE
    // session as a network blip and keeps showing the last frame.
    const isEnded = msg.type === "screen:state" && (msg as { status?: string }).status === "ended";
    if (!isEnded && !this.allowed()) {
      log.warn("Dropping outbound %s: screen control is disabled", msg.type);
      return;
    }
    if (isEnded || msg.type === "screen:stop") this.viewers.delete(viewerId);
    this.toViewer(msg, channel, viewerId);
  }

  private hostGone(): void {
    for (const viewerId of this.viewers) {
      this.toViewer(createMessage("screen:state", { status: "no-host", viewerId }), "control", viewerId);
    }
    this.viewers.clear();
  }

  private toHost(msg: AbMessage, channel: Channel): void {
    this.deps.bus.publishOnly(msg, channel, "loopback");
  }

  private toViewer(msg: AbMessage, channel: Channel, viewerId: string): void {
    this.deps.bus.publishOnly(msg, channel, "relay", viewerId);
  }
}
