import { createHash } from "node:crypto";
import type { Channel } from "./message-bus";

/** Which way the frame crossed the socket. */
export type NetwatchDir = "tx" | "rx";

/**
 * Frame classification at the transport edge:
 *   - `sealed`    — an E2E-encrypted app or session frame (FrameKind.sealed)
 *   - `handshake` — a kind-1 plaintext handshake frame
 *   - `control`   — a relay control JSON message (welcome / error / peer-*)
 *   - `json`      — a loopback frame: plain JSON, no seal, no frames, no streams
 *   - `drop`      — a frame that never left, or never reached dispatch
 */
export type NetwatchKind = "sealed" | "handshake" | "control" | "json" | "drop";

export interface NetwatchEvent {
  /** Monotonic counter of the process that RECORDED this — this bridge, or the
   *  app named by `origin`. Gaps across a capture mean events were evicted
   *  faster than the reader drained them. Never compare across origins. */
  seq: number;
  at: number;
  dir: NetwatchDir;
  kind: NetwatchKind;
  /**
   * Which transport carried this. The two are not the same wire — the relay
   * path is sealed frames over a routed socket, the loopback LocalListener path
   * is plain JSON with no seal, no frames and no streams — so a capture that
   * did not say which one it came from could be read as relay traffic it never
   * was. The app picks relay first and falls back to loopback
   * (app/lib/providers/agent_transport.dart), and nothing else tells you which
   * one you got.
   */
  transport: "relay" | "local";
  channel?: Channel;
  streamId?: string;
  /** Plaintext message type, once the pipeline knows it. Never a payload. */
  msgType?: string;
  bytes?: number;
  frameId?: string;
  /** Why a frame never left, or never reached dispatch. `kind: "drop"` only. */
  reason?: string;
  /** Flat extras — relay error codes, peer ids, fragment counters. */
  detail?: Record<string, string | number | boolean>;
  /**
   * The frame's own plaintext, present only while body capture is armed. It is
   * truncated at the RECORD site (`captureBody`), never at render: the cap is
   * there to bound what the ring HOLDS, and a full body admitted now is memory
   * no later formatting decision can give back.
   */
  body?: string;
  /**
   * Which endpoint saw this. Absent means this bridge saw it — the overwhelming
   * majority, and stamping every locally recorded frame would cost a field per
   * event to say the one thing a reader can already assume. Only an event
   * shipped in by a remote app carries it (`ingestRemote`).
   */
  origin?: "app";
}

/** Sealed framing is `nonce(12) || ciphertext || tag(16)` — see e2e/transport.ts. */
const NONCE_LENGTH = 12;

/**
 * The cross-endpoint join key.
 *
 * A sealed payload opens with a per-seal RANDOM nonce, and the relay forwards
 * the payload byte-for-byte (`decoded.payload` in relay/src/server.ts), so that
 * nonce is already a unique id for this exact frame that BOTH endpoints can
 * compute — with no wire change, no header space, and no key material. This is
 * what closes the gap `AgentTransport.droppedFrames` documents: "the route
 * header carries no message id — so a listener learns that something in flight
 * died, never which one."
 *
 * Plaintext frames (kind-1 handshake, relay control JSON) carry no nonce, and
 * are rare enough that a hash prefix costs nothing.
 */
export function frameIdFor(payload: Uint8Array, sealed: boolean): string {
  if (sealed && payload.length >= NONCE_LENGTH) {
    return Buffer.from(payload.subarray(0, NONCE_LENGTH)).toString("hex");
  }
  return createHash("sha256").update(payload).digest("hex").slice(0, 24);
}

/**
 * Sized for loopback rather than for the relay. A desktop's terminal output all
 * crosses the loopback socket, so a scrolling build evicts a few-thousand-event
 * ring within seconds — and what it evicts is the minute BEFORE the failure,
 * which is the part anyone attaching a watcher came to read.
 */
const DEFAULT_CAPACITY = 16384;

/**
 * Per-machine override, because the right window is a property of the workload:
 * a chatty repo can outrun any default, and a capture whose history ends before
 * the bug does answers nothing. Anything unparseable, fractional, zero or
 * negative falls back rather than being honoured — the capacity is the modulus
 * of every ring index, so a bad one does not fail loudly, it produces a ring
 * that silently records nothing.
 */
function resolveCapacity(raw: string | undefined): number {
  if (raw === undefined) return DEFAULT_CAPACITY;
  const n = Number(raw);
  return Number.isInteger(n) && n > 0 ? n : DEFAULT_CAPACITY;
}

/** Bodies are the one thing the ring would hold that is payload, so they are
 *  capped hard — a single terminal-output frame can carry a whole screen of
 *  build log, and the ring keeps thousands of them. */
export const NETWATCH_BODY_MAX_CHARS = 4096;

let bodyCaptureEnabled = false;
let bodyCaptureTimer: (ReturnType<typeof setTimeout> & { unref?: () => void }) | null = null;

/**
 * Arm or disarm body capture for at most `ttlMs`.
 *
 * Metadata is always recorded; bodies never are unless someone explicitly asked
 * for them, so a capture nobody is reading costs a message type and a byte count
 * and nothing the user typed. The TTL is a dead man's switch rather than a
 * policy: the only thing that ever disarms is the watcher that armed it, and a
 * watcher killed with SIGKILL sends no disarm — without the lapse, one
 * `antgrid watch` would leave the host recording payloads for the rest of its
 * life with nothing on the machine able to turn it off. Re-arming restarts the
 * window; a disarm is idempotent.
 */
export function armBodyCapture(enabled: boolean, ttlMs: number): void {
  if (bodyCaptureTimer) clearTimeout(bodyCaptureTimer);
  bodyCaptureTimer = null;
  // An arm with no expiry is the one request this refuses, for the reason above.
  if (!enabled || !Number.isFinite(ttlMs) || ttlMs <= 0) {
    bodyCaptureEnabled = false;
    return;
  }
  bodyCaptureEnabled = true;
  bodyCaptureTimer = setTimeout(() => {
    bodyCaptureEnabled = false;
    bodyCaptureTimer = null;
  }, ttlMs) as ReturnType<typeof setTimeout> & { unref?: () => void };
  // An observer must never be the reason the bridge outlives its work.
  bodyCaptureTimer.unref?.();
}

export function isBodyCaptureArmed(): boolean {
  return bodyCaptureEnabled;
}

function truncationMarker(dropped: number): string {
  return `…[+${dropped} chars]`;
}

/**
 * The body a tap should record for this wire text, or `undefined` while
 * disarmed — the caller passes the answer straight into the event, so the
 * disarmed one has to be the absent field rather than an empty string.
 *
 * The marker is counted INSIDE the cap, not appended past it: the cap is what
 * bounds the ring's memory, so a body that announces its own truncation by
 * growing past the ceiling has defeated the thing it reports. Reserving against
 * the untruncated length can only over-reserve — the number finally printed is
 * smaller, so never longer — which is what keeps the count exact.
 */
export function captureBody(text: string): string | undefined {
  if (!bodyCaptureEnabled) return undefined;
  if (text.length <= NETWATCH_BODY_MAX_CHARS) return text;
  const keep = NETWATCH_BODY_MAX_CHARS - truncationMarker(text.length).length;
  return text.slice(0, keep) + truncationMarker(text.length - keep);
}

export type NetwatchSubscriber = (event: NetwatchEvent) => void;

/**
 * Bounded in-memory record of every frame crossing a transport this machine
 * owns — the relay socket, and the loopback socket the desktop app rides.
 *
 * Always recording, deliberately: the failure worth reading has already
 * happened by the time anyone attaches a watcher, so a buffer that only fills
 * once asked is a buffer that is empty exactly when it matters. The cost is one
 * small object and a 24-char hex slice per frame, against an AES-GCM seal and a
 * JSON.stringify already on that path.
 */
export class Netwatch {
  private readonly ring: (NetwatchEvent | undefined)[];
  private write = 0;
  private count = 0;
  private seq = 0;
  /** Everything the ring took in, local and remote. `seq` counts only what this
   *  process recorded, so it cannot answer what the ring dropped. */
  private admitted = 0;
  private readonly subscribers = new Set<NetwatchSubscriber>();

  constructor(
    private readonly capacity: number = resolveCapacity(process.env.ANTGRID_NETWATCH_CAPACITY),
  ) {
    this.ring = new Array<NetwatchEvent | undefined>(capacity);
  }

  record(event: Omit<NetwatchEvent, "seq" | "at"> & { at?: number }): void {
    this.push({ ...event, seq: ++this.seq, at: event.at ?? Date.now() });
  }

  /**
   * Admit a batch a remote app captured on ITS side of the same socket.
   *
   * Two things are preserved verbatim and must stay that way: the app's own
   * `seq` (renumbering it destroys the only signal that the app's uploader hit
   * its budget) and the field set, which is passed through rather than rebuilt —
   * a newer app may record a field this bridge has no name for, and dropping it
   * would defeat the whole point of reading what THAT endpoint saw. Only the
   * shape is policed, never the vocabulary.
   *
   * `skewMs` shifts each `at` onto this machine's clock. Two devices' wall
   * clocks differ by seconds routinely, which is enough to make an app-tx land
   * "after" the bridge-rx it caused and turn every latency in a join into
   * fiction. The estimate ignores one-way relay latency — small next to the skew
   * it corrects, and it biases every event the same way, so deltas BETWEEN
   * app-side events stay exact.
   */
  ingestRemote(events: readonly unknown[], skewMs = 0): number {
    let admitted = 0;
    // The batch is peer-supplied and its declared bound is not enforced
    // anywhere: the inbound path is `parseMessageFast`, which checks the
    // `type` and returns — the Zod `.max()` on the schema never runs. Taking
    // only the tail costs nothing in fidelity (anything before it would be
    // evicted by the events behind it in this very loop) and keeps one
    // oversized batch from churning the whole ring through every subscriber.
    const start = Math.max(0, events.length - this.capacity);
    // Skipped entries still count as admitted: `evicted` is the reader's
    // blind-spot number, and a ring that took a shortcut must not report a
    // smaller blind spot than it actually has.
    this.admitted += start;
    for (let i = start; i < events.length; i++) {
      const raw = events[i];
      if (typeof raw !== "object" || raw === null) continue;
      const e = raw as Record<string, unknown>;
      const dir = e.dir;
      const kind = e.kind;
      const at = e.at;
      if ((dir !== "tx" && dir !== "rx") || typeof kind !== "string" || typeof at !== "number") continue;
      this.push({
        ...(e as unknown as NetwatchEvent),
        seq: typeof e.seq === "number" ? e.seq : 0,
        at: at + skewMs,
        dir,
        origin: "app",
      });
      admitted++;
    }
    return admitted;
  }

  private push(full: NetwatchEvent): void {
    this.admitted++;
    this.ring[this.write] = full;
    this.write = (this.write + 1) % this.capacity;
    if (this.count < this.capacity) this.count++;
    for (const fn of this.subscribers) {
      try {
        fn(full);
      } catch {
        // A watcher is an observer. It must never be able to fail a send.
      }
    }
  }

  /** Events currently in the ring — the ceiling on what a replay can return. */
  get buffered(): number {
    return this.count;
  }

  /** Buffered events, oldest first. */
  snapshot(limit = this.capacity): NetwatchEvent[] {
    const take = Math.min(limit, this.count);
    const out: NetwatchEvent[] = [];
    const start = (this.write - take + this.capacity * 2) % this.capacity;
    for (let i = 0; i < take; i++) {
      const e = this.ring[(start + i) % this.capacity];
      if (e) out.push(e);
    }
    return out;
  }

  subscribe(fn: NetwatchSubscriber): () => void {
    this.subscribers.add(fn);
    return () => {
      this.subscribers.delete(fn);
    };
  }

  /** Events admitted, then evicted by the ring — a reader's blind spot. */
  get evicted(): number {
    return this.admitted - this.count;
  }

  get recorded(): number {
    return this.seq;
  }
}

/**
 * Process-global, because the bridge holds exactly ONE machine relay socket
 * (host-server.ts builds the single RelayClient; promoted project cores attach
 * to it as streams rather than opening their own). Threading a recorder through
 * every construction site would buy nothing and be missed by the next one.
 */
export const netwatch = new Netwatch();

/**
 * Test seam — the suite shares one module cache across every spec file, so an
 * arm left standing by one file would decide whether the next one's events carry
 * bodies, and the suite would pass or fail on file order.
 */
export function __resetNetwatchForTest(): void {
  armBodyCapture(false, 0);
  const w = netwatch as unknown as {
    ring: (NetwatchEvent | undefined)[];
    write: number;
    count: number;
    seq: number;
    admitted: number;
    subscribers: Set<NetwatchSubscriber>;
  };
  w.ring.fill(undefined);
  w.write = 0;
  w.count = 0;
  w.seq = 0;
  w.admitted = 0;
  w.subscribers.clear();
}
