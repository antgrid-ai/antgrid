// Carries session-bus mail between this machine and the account's others over
// the central relay socket. Everything that leaves is sealed to the recipient's
// bus key first (seal.ts), so the relay only queues ciphertext; everything that
// arrives is opened, attributed to a machine the account directory vouches for,
// deduplicated, and handed to the host for the gates that need local state.
//
// Delivery is at-least-once: the sender's outbox resends until a signed ack, so
// the receive side must be idempotent. `seen` is what makes it so, and it also
// remembers the verdict so a resend is re-acked without re-applying.
//
// Logs carry ids, byte counts and outcome codes only. Never a key, blob or body.
import { BUS_MAX_TTL_MS, type BusRefusalReason, type BusServerMessage } from "antgrid-wire";
import { logger } from "../logger";
import type { RemoteHostConnection } from "../remote-host-connection";
import type { AbMessage } from "../protocol";
import type { BusKeyPair } from "./bus-key";
import type { MachineDirectory } from "./machine-directory";
import { isExpired, openBus, sealBus, signBusAck, verifyBusAck, type InnerHeader } from "./seal";

const log = logger.child({ component: "bus-relay-transport" });

/** Shared by bus:send and bus:ack so a burst of mail cannot starve acks, and a
 *  burst of acks (a queue flush on reconnect) cannot trip the relay's limiter. */
export const BUS_LINK_FRAMES_PER_SEC = 8;
export const BUS_LINK_BURST = 24;
export const MAX_PENDING_INBOUND = 64;
/** Matches the relay's own drain interval; a faster request would be refused. */
export const BUS_DRAIN_MIN_INTERVAL_MS = 5_000;
export const BUS_ACK_FLUSH_MS = 125;
const DIRECTORY_WAIT_MS = 5_000;
const MAX_QUEUED_ACKS = 512;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export type BusHeldReason =
  | "no-transport" | "central-offline" | "relay-unsupported" | "directory-unavailable"
  | "no-bus-key" | "paced" | "remote-access-off"
  | "relay-queue-full" | "relay-rate-limited" | "relay-recipient-outdated"
  | "ack-unverified" | "recipient-key-stale";

export type BusSendResult =
  | { sent: true }
  | { sent: false; reason: BusHeldReason }
  | { sent: false; refused: "PLAINTEXT_TOO_LARGE" | "EXPIRED" };

export type TransportOutcome =
  | { kind: "relayed" }
  | { kind: "applied" }
  | { kind: "refused"; code: string }
  | { kind: "retry"; reason: BusHeldReason };

export interface VerifiedInbound {
  from: string;
  id: string;
  header: InnerHeader;
  body: unknown;
  role: "agent" | "orchestrator";
}

export type InboundVerdict =
  | { outcome: "applied"; response?: string }
  | { outcome: "refused"; code: string }
  | { outcome: "defer" };

export interface SeenRow {
  outcome: "applied" | "refused";
  code?: string;
  response?: string;
}

export interface SeenStore {
  get(from: string, id: string): SeenRow | null;
  record(
    from: string,
    id: string,
    outcome: "applied" | "refused",
    code: string | undefined,
    expiresAt: number,
    response?: string,
  ): void;
}

export interface RelayBusTransportDeps {
  selfDeviceId: () => string | null;
  /** Ed25519 seed. Signs acks as well as mail, so an ack the relay forwards
   *  cannot be forged by the relay. */
  signSeed: () => string | null;
  busKey: () => BusKeyPair | null;
  directory: Pick<MachineDirectory, "current" | "machine" | "busKeyFor" | "selfOrchestrator" | "ensureFresh" | "kick">;
  link: () => Pick<RemoteHostConnection, "sendBus" | "busLinkState" | "busNow"> | null;
  /** Gates every send kind and never an ack: acks carry no content, and they are
   *  how a recipient that has remote access off says so. */
  remoteAccessEnabled: () => boolean;
  seen: SeenStore;
  onInbound: (v: VerifiedInbound) => Promise<InboundVerdict>;
  onOutcome: (id: string, to: string, outcome: TransportOutcome) => void;
  onReplayResponse?: (from: string, requestId: string, response: string, expiresAt: number) => void;
  /** Defaults to the relay-corrected clock, so both ends compare on one clock. */
  now?: () => number;
  /** The clock a send input's `sentAt` and `expiresAt` were stamped on. Defaults
   *  to the wall clock, which is what the coordinator stamps with. */
  localNow?: () => number;
}

export interface BusSendInput {
  to: string;
  id: string;
  kind: "message" | "request" | "response";
  correlationId?: string;
  body: AbMessage;
  /** When the message was first sent, on the caller's clock; a resend passes
   *  the same pair, never a fresh one. */
  sentAt: number;
  expiresAt: number;
  role: "agent" | "orchestrator";
}

interface RefusalRule {
  retryable: boolean;
  outcome: TransportOutcome;
}

// Exhaustive on purpose: a reason the relay adds must be classified here before
// this compiles.
const REFUSAL_RULES: Record<BusRefusalReason, RefusalRule> = {
  "queue-full": { retryable: true, outcome: { kind: "retry", reason: "relay-queue-full" } },
  "rate-limited": { retryable: true, outcome: { kind: "retry", reason: "relay-rate-limited" } },
  "recipient-outdated": { retryable: true, outcome: { kind: "retry", reason: "relay-recipient-outdated" } },
  "not-agent": { retryable: false, outcome: { kind: "refused", code: "RELAY_NOT_AGENT" } },
  self: { retryable: false, outcome: { kind: "refused", code: "RELAY_SELF" } },
  expired: { retryable: false, outcome: { kind: "refused", code: "EXPIRED" } },
};

interface AckFrame {
  type: "bus:ack";
  id: string;
  outcome: "applied" | "refused";
  code?: string;
  sig: string;
}

type DeliverFrame = Extract<BusServerMessage, { type: "bus:deliver" }>;

export class RelayBusTransport {
  private tokens = BUS_LINK_BURST;
  private tokensAt: number | null = null;
  private chain: Promise<void> = Promise.resolve();
  private pending = 0;
  private drainWanted = false;
  private lastDrainAt = Number.NEGATIVE_INFINITY;
  private drainTimer: ReturnType<typeof setTimeout> | null = null;
  private ackTimer: ReturnType<typeof setTimeout> | null = null;
  private readonly acks: AckFrame[] = [];
  private stopped = false;

  constructor(private readonly deps: RelayBusTransportDeps) {}

  private now(): number {
    return this.deps.now?.() ?? this.deps.link()?.busNow?.() ?? Date.now();
  }

  private refill(): void {
    const t = this.now();
    if (this.tokensAt !== null && t > this.tokensAt) {
      this.tokens = Math.min(BUS_LINK_BURST, this.tokens + ((t - this.tokensAt) / 1000) * BUS_LINK_FRAMES_PER_SEC);
    }
    this.tokensAt = t;
  }

  private takeToken(): boolean {
    this.refill();
    if (this.tokens < 1) return false;
    this.tokens -= 1;
    return true;
  }

  private returnToken(): void {
    this.tokens = Math.min(BUS_LINK_BURST, this.tokens + 1);
  }

  send(i: BusSendInput): BusSendResult {
    if (!this.deps.remoteAccessEnabled()) return { sent: false, reason: "remote-access-off" };
    const self = this.deps.selfDeviceId();
    if (!self || !UUID.test(i.to) || i.to === self) return { sent: false, reason: "no-transport" };
    // Every copy of one id carries the expiry the first send gave it. A fresh
    // lifetime per resend would let a late copy be applied after the sender's
    // outbox has already reported it expired, and outlive the receiver's
    // record of having applied an earlier copy.
    const lifetime = Math.min(i.expiresAt - i.sentAt, BUS_MAX_TTL_MS);
    const elapsed = Math.max(0, (this.deps.localNow?.() ?? Date.now()) - i.sentAt);
    if (lifetime <= 0 || elapsed >= lifetime) return { sent: false, refused: "EXPIRED" };
    const link = this.deps.link();
    if (!link) return { sent: false, reason: "no-transport" };
    const sendBus = link.sendBus;
    if (!sendBus) return { sent: false, reason: "relay-unsupported" };
    const state = link.busLinkState?.() ?? "unsupported";
    if (state === "offline") return { sent: false, reason: "central-offline" };
    if (state === "unsupported") return { sent: false, reason: "relay-unsupported" };

    if (!this.deps.directory.current()) {
      this.deps.directory.kick();
      return { sent: false, reason: "directory-unavailable" };
    }
    const recipientKey = this.deps.directory.busKeyFor(i.to);
    if (!recipientKey) {
      this.deps.directory.kick();
      return { sent: false, reason: "no-bus-key" };
    }
    const seed = this.deps.signSeed();
    if (!seed) return { sent: false, reason: "no-transport" };

    // Mapped onto the relay-corrected clock so the recipient compares on it too.
    const sentAt = this.now() - elapsed;
    const expiresAt = sentAt + lifetime;
    const header: InnerHeader = {
      v: 1, from: self, to: i.to, id: i.id, role: i.role, kind: i.kind,
      ...(i.correlationId ? { correlationId: i.correlationId } : {}),
      sentAt, expiresAt,
    };
    const body = JSON.stringify(i.body);
    const sealed = sealBus({ header, body, signSeedB64: seed, recipientBusPubB64: recipientKey });
    if (!sealed.ok) {
      if (sealed.code === "PLAINTEXT_TOO_LARGE") return { sent: false, refused: "PLAINTEXT_TOO_LARGE" };
      this.deps.directory.kick();
      return { sent: false, reason: "no-bus-key" };
    }
    if (!this.takeToken()) return { sent: false, reason: "paced" };
    const ok = sendBus.call(link, {
      type: "bus:send", id: i.id, to: i.to, blob: sealed.blob, ttlMs: Math.max(1, expiresAt - this.now()),
    });
    if (!ok) {
      this.returnToken();
      return { sent: false, reason: "central-offline" };
    }
    log.debug("bus send", { id: i.id, to: i.to, bytes: body.length });
    return { sent: true };
  }

  /** The relay flushes anything queued for this machine when asked. */
  onAuthenticated(): void {
    this.sendDrain();
  }

  stop(): void {
    this.stopped = true;
    if (this.drainTimer) clearTimeout(this.drainTimer);
    if (this.ackTimer) clearTimeout(this.ackTimer);
    this.drainTimer = null;
    this.ackTimer = null;
    this.acks.length = 0;
  }

  handleFrame(msg: BusServerMessage): void {
    if (this.stopped) return;
    switch (msg.type) {
      case "bus:receipt":
        this.deps.onOutcome(msg.id, msg.to, { kind: "relayed" });
        return;
      case "bus:acked":
        this.handleAcked(msg);
        return;
      case "bus:refused":
        this.handleRefused(msg);
        return;
      case "bus:deliver":
        this.enqueueDeliver(msg);
        return;
    }
  }

  private handleAcked(msg: Extract<BusServerMessage, { type: "bus:acked" }>): void {
    const self = this.deps.selfDeviceId();
    const peerPub = this.deps.directory.machine(msg.to)?.ed25519Pub;
    let verified = false;
    if (self && peerPub) {
      try {
        verified = verifyBusAck(peerPub, { from: self, to: msg.to, id: msg.id, outcome: msg.outcome, code: msg.code }, msg.sig);
      } catch {
        verified = false;
      }
    }
    if (!verified) {
      if (!peerPub) this.deps.directory.kick();
      log.warn("bus ack not verified", { id: msg.id, to: msg.to, known: !!peerPub });
      this.deps.onOutcome(msg.id, msg.to, { kind: "retry", reason: "ack-unverified" });
      return;
    }
    if (msg.outcome === "applied") {
      this.deps.onOutcome(msg.id, msg.to, { kind: "applied" });
      return;
    }
    const code = msg.code ?? "MALFORMED";
    if (code === "UNOPENABLE") {
      // The recipient could not open what we sealed: our copy of its key is stale.
      this.deps.directory.kick();
      this.deps.onOutcome(msg.id, msg.to, { kind: "retry", reason: "recipient-key-stale" });
      return;
    }
    this.deps.onOutcome(msg.id, msg.to, { kind: "refused", code });
  }

  private handleRefused(msg: Extract<BusServerMessage, { type: "bus:refused" }>): void {
    const rule = REFUSAL_RULES[msg.reason];
    if (rule.retryable !== msg.retryable) {
      log.warn("bus refusal retryable flag disagrees with its reason", { id: msg.id, reason: msg.reason, retryable: msg.retryable });
      // A retry is recoverable and a wrong terminal refusal is not, so a
      // disagreement never becomes a terminal verdict.
      this.deps.onOutcome(msg.id, msg.to, rule.outcome.kind === "retry" ? rule.outcome : { kind: "retry", reason: "relay-rate-limited" });
      return;
    }
    this.deps.onOutcome(msg.id, msg.to, rule.outcome);
  }

  private enqueueDeliver(msg: DeliverFrame): void {
    if (this.pending >= MAX_PENDING_INBOUND) {
      // Unacked, so the relay still holds it; a later drain brings it back.
      this.requestDrain();
      return;
    }
    this.pending++;
    this.chain = this.chain
      .then(() => this.processDeliver(msg))
      .catch((err) => {
        log.warn("bus deliver failed", { id: msg.id, from: msg.from, error: err instanceof Error ? err.name : "error" });
        this.drainWanted = true;
      })
      .finally(() => {
        this.pending--;
        if (this.pending === 0 && this.drainWanted) {
          this.drainWanted = false;
          this.requestDrain();
        }
      });
  }

  private async processDeliver(msg: DeliverFrame): Promise<void> {
    const { from, id } = msg;
    const self = this.deps.selfDeviceId();
    if (!self || from === self) return;
    if (!this.deps.signSeed()) return this.defer(id, from, "no-seed");

    // A refusal is final for the sender, so it is only ever given on a view
    // fetched just now: a machine enrolled since the last refresh, or an account
    // caught mid licence blip, waits for the next drain instead.
    let view = this.deps.directory.current();
    let entry = this.deps.directory.machine(from);
    let fresh = false;
    if (!entry || !view?.allowed) {
      fresh = await this.deps.directory.ensureFresh(DIRECTORY_WAIT_MS);
      view = this.deps.directory.current();
      entry = this.deps.directory.machine(from);
    }
    if (!view || !view.allowed) return this.defer(id, from, "directory-unverified");
    if (!entry) {
      if (!fresh) return this.defer(id, from, "directory-unverified");
      return this.ack(from, id, "refused", "UNKNOWN_SENDER");
    }

    const key = this.deps.busKey();
    if (!key) return this.defer(id, from, "no-bus-key");

    const opened = openBus({
      blob: msg.blob, from, to: self, id,
      ownBusPrivB64: key.privateKey, ownBusPubB64: key.publicKey,
      senderEd25519PubB64: entry.ed25519Pub,
    });
    if (!opened.ok) return this.ack(from, id, "refused", opened.code);
    const h = opened.header;

    const seen = this.deps.seen.get(from, id);
    if (seen) {
      if (seen.response !== undefined) this.deps.onReplayResponse?.(from, h.id, seen.response, h.expiresAt);
      return this.ack(from, id, seen.outcome, seen.code);
    }

    if (isExpired(h, this.now())) return this.ack(from, id, "refused", "STALE");

    // The header's role is the sender's claim; only the directory can make it true.
    const role = h.role === "orchestrator" && entry.orchestrator ? "orchestrator" : "agent";
    let body: unknown;
    try {
      body = JSON.parse(opened.body);
    } catch {
      return this.ack(from, id, "refused", "MALFORMED");
    }

    let verdict: InboundVerdict;
    try {
      verdict = await this.deps.onInbound({ from, id, header: h, body, role });
    } catch (err) {
      log.warn("bus inbound handler threw", { id, from, error: err instanceof Error ? err.name : "error" });
      return this.defer(id, from, "handler-threw");
    }
    if (verdict.outcome === "defer") return this.defer(id, from, "handler-deferred");
    const code = verdict.outcome === "refused" ? verdict.code : undefined;
    this.deps.seen.record(from, id, verdict.outcome, code, h.expiresAt, verdict.outcome === "applied" ? verdict.response : undefined);
    this.ack(from, id, verdict.outcome, code);
  }

  private defer(id: string, from: string, why: string): void {
    log.debug("bus deliver deferred", { id, from, why });
    this.drainWanted = true;
  }

  private ack(from: string, id: string, outcome: "applied" | "refused", code?: string): void {
    const self = this.deps.selfDeviceId();
    const seed = this.deps.signSeed();
    if (!self || !seed) {
      this.drainWanted = true;
      return;
    }
    const sig = signBusAck(seed, { from, to: self, id, outcome, code });
    // Dropping the oldest is safe: an unacked delivery is redelivered on drain.
    if (this.acks.length >= MAX_QUEUED_ACKS) this.acks.shift();
    this.acks.push({ type: "bus:ack", id, outcome, ...(code ? { code } : {}), sig });
    log.debug("bus ack queued", { id, from, outcome, code });
    this.scheduleAckFlush(0);
  }

  private scheduleAckFlush(delay: number): void {
    if (this.ackTimer || this.stopped) return;
    this.ackTimer = setTimeout(() => {
      this.ackTimer = null;
      this.flushAcks();
    }, delay);
    this.ackTimer.unref?.();
  }

  private flushAcks(): void {
    if (this.stopped) return;
    const link = this.deps.link();
    const sendBus = link?.sendBus;
    if (link && sendBus) {
      while (this.acks.length > 0) {
        if (!this.takeToken()) break;
        if (!sendBus.call(link, this.acks[0]!)) {
          this.returnToken();
          break;
        }
        this.acks.shift();
      }
    }
    if (this.acks.length > 0) this.scheduleAckFlush(BUS_ACK_FLUSH_MS);
  }

  private requestDrain(): void {
    if (this.stopped) return;
    const wait = this.lastDrainAt + BUS_DRAIN_MIN_INTERVAL_MS - this.now();
    if (wait <= 0) {
      if (this.drainTimer) clearTimeout(this.drainTimer);
      this.drainTimer = null;
      this.sendDrain();
      return;
    }
    if (this.drainTimer) return;
    this.drainTimer = setTimeout(() => {
      this.drainTimer = null;
      this.sendDrain();
    }, wait);
    this.drainTimer.unref?.();
  }

  private sendDrain(): void {
    if (this.stopped) return;
    this.lastDrainAt = this.now();
    const link = this.deps.link();
    link?.sendBus?.call(link, { type: "bus:drain" });
  }
}
