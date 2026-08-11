import type { AbMessage } from "./protocol";

export type Channel = "control" | "preview";

export interface TransportSubscriber {
  /** Bus calls this to deliver an outbound message to the wire. */
  deliver(msg: AbMessage, channel: Channel): void;
}

/** Where an inbound frame entered the core. The allowlist gate keys off this:
 *  `loopback` is the desktop owner (trusted by the loopback socket + token and
 *  NEVER gated); `relay` is a remote phone (gated against its per-phone project
 *  allowlist). A promoted core shares ONE bus + inbound handler across both, so
 *  the source — not the mere presence of a relay peer — is what decides gating. */
export type InboundSource = "loopback" | "relay";

export type InboundHandler = (
  msg: AbMessage,
  channel: Channel,
  source: InboundSource,
) => void;

/**
 * Message types that carry durable snapshot state (vs. streaming events).
 * The bus caches the most recent frame per type; `getSnapshot(types)` reads
 * them to serve the `state.snapshot` RPC.
 */
const REPLAY_TYPES: ReadonlySet<string> = new Set([
  "agent:hello",
  "agent:status",
  // Control-plane adverts (host-server.ts publishes both at handshake). They
  // MUST be cached so the app's `state.snapshot` welcome-replay seeds the
  // picker with the project catalog + installed tools on first connect — without
  // this the phone sees neither until an unrelated re-advertise. Both are
  // control-plane only; the per-project data-plane bus never publishes them.
  "agent:projects",
  "agent:tools",
  "git:status",
  "tree:full",
  // Latest per-project handler snapshot (armed sessions + open escalations).
  // Must be cached: the app rebuilds its escalation list from the status
  // replay after a restart/reconnect — without this, an escalation raised
  // while the app was away is invisible until the next live emit.
  "handler:status",
]);

/**
 * Session-scoped replay: cached per (type, sessionId), not per type — one
 * frame per TYPE would clobber capabilities across concurrent chat sessions.
 *
 * `agent:background-tasks` is here for the same reason as the handler snapshot
 * above: it is a latest-wins full list, so an app that attaches after the last
 * change has nothing to rebuild the strip from — a shell backgrounded before
 * the reconnect would be invisible, and therefore unstoppable, until it
 * settled.
 */
const SESSION_REPLAY_TYPES: ReadonlySet<string> = new Set([
  "agent:capabilities",
  "agent:background-tasks",
]);

interface CachedFrame {
  msg: AbMessage;
  channel: Channel;
}

export class MessageBus {
  private subs = new Set<TransportSubscriber>();
  private handler: InboundHandler | null = null;
  /** Latest cached frame per type (insertion-ordered Map). */
  private replayCache = new Map<string, CachedFrame>();

  subscribe(sub: TransportSubscriber): () => void {
    this.subs.add(sub);
    return () => this.subs.delete(sub);
  }

  publish(msg: AbMessage, channel: Channel): void {
    const key = this.replayKey(msg);
    if (key !== null) {
      const prev = this.replayCache.get(key);
      // Payload-equality dedup: identical re-publishes (token-refresh poll
      // returns the same auth, FileWatcher re-emits an unchanged tree)
      // become no-ops to both existing subscribers and the replay cache.
      // `createMessage` stamps a fresh `id`/`timestamp` per call, so we
      // strip those before comparing.
      if (prev && payloadEquals(prev.msg, msg)) return;
      this.replayCache.set(key, { msg, channel });
    }
    // A throwing deliver() propagates to the caller (the agent's primary send
    // path) so a genuine subscriber bug stays visible rather than vanishing into
    // a log. The one subscriber that must NOT abort the emit — the best-effort
    // push dispatcher — wraps its own deliver at the subscribe site (see
    // project-core.ts attachRelayStream).
    for (const s of this.subs) {
      s.deliver(msg, channel);
    }
  }

  private replayKey(msg: AbMessage): string | null {
    if (SESSION_REPLAY_TYPES.has(msg.type)) {
      const sessionId = (msg as { sessionId?: string }).sessionId ?? "";
      return `${msg.type} ${sessionId}`;
    }
    if (!REPLAY_TYPES.has(msg.type)) return null;
    // Checkout-scoped for the same reason the types above are session-scoped:
    // every checkout runtime publishes its own tree:full / git:status /
    // agent:status, so one frame per TYPE let an isolated session's worktree
    // evict the primary checkout's — and the app, which filters replayed frames
    // by checkoutId, then had nothing left to draw the main file tree from.
    const checkoutId = (msg as { checkoutId?: string }).checkoutId ?? "main";
    return `${msg.type} ${checkoutId}`;
  }

  /** Drop a checkout's replay entries at teardown, so a deleted worktree's tree
   *  and git status stop being replayed to every app that reconnects. */
  dropCheckoutReplay(checkoutId: string): void {
    for (const [key, cached] of this.replayCache) {
      if ((cached.msg as { checkoutId?: string }).checkoutId === checkoutId) {
        this.replayCache.delete(key);
      }
    }
  }

  setInboundHandler(fn: InboundHandler): void {
    this.handler = fn;
  }

  /** Used by callers (e.g. `serve --local`) that want to layer their own
   *  control-message handling on top of the core's dispatcher. */
  get inboundHandler(): InboundHandler | null {
    return this.handler;
  }

  /** `source` defaults to `relay` so any caller that omits it is gated by
   *  default (fail-closed); only an explicit `loopback` frame bypasses the
   *  allowlist gate. */
  dispatchInbound(msg: AbMessage, channel: Channel, source: InboundSource = "relay"): void {
    this.handler?.(msg, channel, source);
  }

  /** Drop a session's session-scoped replay entries. Called at session
   *  teardown AFTER the empty teardown frame is published: live subscribers
   *  still see the clear, but the cache doesn't keep one tombstone per
   *  sessionId ever started (and `getSnapshot`'s scan stays bounded by live
   *  sessions). */
  dropSessionReplay(sessionId: string): void {
    for (const type of SESSION_REPLAY_TYPES) {
      this.replayCache.delete(`${type} ${sessionId}`);
    }
  }

  /** Read the latest cached frame(s) for each requested type. Pass `["*"]` for all. */
  getSnapshot(types: readonly string[]): AbMessage[] {
    if (types.length === 1 && types[0] === "*") {
      return Array.from(this.replayCache.values(), (c) => c.msg);
    }
    // Match on the frame's type, not the cache key — session-scoped types
    // store several frames under composite keys.
    const wanted = new Set(types);
    const out: AbMessage[] = [];
    for (const c of this.replayCache.values()) {
      if (wanted.has(c.msg.type)) out.push(c.msg);
    }
    return out;
  }
}

function payloadEquals(a: AbMessage, b: AbMessage): boolean {
  // Strip the envelope (id, timestamp — randomised per `createMessage`
  // call) and compare only the semantic payload.
  const { id: _ai, timestamp: _at, ...ap } = a;
  const { id: _bi, timestamp: _bt, ...bp } = b;
  return JSON.stringify(ap) === JSON.stringify(bp);
}
