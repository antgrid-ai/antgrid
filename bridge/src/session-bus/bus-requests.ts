// Request and response between this machine and the account's others, carried
// as sealed bus mail. A request is resent under one id until it is answered, so
// the responder's seen-store (which remembers the response it gave) is what
// makes a lost response or a restarted responder recoverable without running
// the method twice.
//
// Logs carry ids, codes and counts only. Never params, results or keys.
import { randomUUID } from "node:crypto";
import { createMessage, type AbMessage } from "../protocol";
import { BUS_REQUEST_MAX_TIMEOUT_MS } from "./constants";
import type { BusHeldReason, BusSendInput, RelayBusTransport, TransportOutcome } from "./relay-transport";

export const BUS_REQUEST_RESEND_MIN_MS = 1_000;
export const BUS_REQUEST_RESEND_MAX_MS = 8_000;
const RESPOND_RETRY_MS = 2_000;
/** Bounds what a flood of requests can park here awaiting an ack. */
const MAX_PENDING_RESPONSES = 256;

export type BusRequestResult =
  | { ok: true; result: unknown }
  | { ok: false; code: string; held?: BusHeldReason };

export interface BusRequestsDeps {
  transport: Pick<RelayBusTransport, "send">;
  selfRole: () => "agent" | "orchestrator";
  /** The wall clock: the transport maps it onto the relay's. */
  now?: () => number;
  /** Returns a canceller. Injected so tests drive the cadence by hand. */
  schedule?: (fn: () => void, ms: number) => () => void;
}

interface Waiter {
  id: string;
  to: string;
  body: AbMessage;
  sentAt: number;
  expiresAt: number;
  backoffMs: number;
  lastHeld?: BusHeldReason;
  cancel: (() => void) | null;
  resolve: (r: BusRequestResult) => void;
  reject: (err: Error) => void;
}

interface PendingResponse {
  id: string;
  to: string;
  requestId: string;
  body: AbMessage;
  sentAt: number;
  expiresAt: number;
  cancel: (() => void) | null;
}

function defaultSchedule(fn: () => void, ms: number): () => void {
  const t = setTimeout(fn, ms);
  t.unref?.();
  return () => clearTimeout(t);
}

export class BusRequests {
  private readonly waiters = new Map<string, Waiter>();
  // Each pending response is indexed twice: by `to:requestId`, which finds it
  // for a duplicate request, and by its own frame id, which finds it for the
  // ack of that frame.
  private readonly responses = new Map<string, PendingResponse>();
  private readonly now: () => number;
  private readonly schedule: (fn: () => void, ms: number) => () => void;
  private stopped = false;

  constructor(private readonly deps: BusRequestsDeps) {
    this.now = deps.now ?? Date.now;
    this.schedule = deps.schedule ?? defaultSchedule;
  }

  request(i: { to: string; method: string; params?: unknown; timeoutMs: number }): Promise<BusRequestResult> {
    if (this.stopped) return Promise.reject(new Error("bus requests stopped"));
    const id = randomUUID();
    const sentAt = this.now();
    const timeoutMs = Math.max(1, Math.min(i.timeoutMs, BUS_REQUEST_MAX_TIMEOUT_MS));
    const body: AbMessage = createMessage("request", { requestId: id, method: i.method, params: i.params });
    return new Promise<BusRequestResult>((resolve, reject) => {
      const w: Waiter = {
        id, to: i.to, body, sentAt, expiresAt: sentAt + timeoutMs,
        backoffMs: BUS_REQUEST_RESEND_MIN_MS, cancel: null, resolve, reject,
      };
      this.waiters.set(id, w);
      this.attempt(w);
    });
  }

  private finish(w: Waiter, r: BusRequestResult): void {
    if (this.waiters.get(w.id) !== w) return;
    this.waiters.delete(w.id);
    w.cancel?.();
    w.cancel = null;
    w.resolve(r);
  }

  private attempt(w: Waiter): void {
    if (this.waiters.get(w.id) !== w) return;
    w.cancel?.();
    w.cancel = null;
    const t = this.now();
    if (t >= w.expiresAt) {
      this.finish(w, { ok: false, code: "REQUEST_TIMEOUT", ...(w.lastHeld ? { held: w.lastHeld } : {}) });
      return;
    }
    const r = this.deps.transport.send(this.input(w, "request", w.body, w.id));
    if ("refused" in r) {
      this.finish(w, { ok: false, code: r.refused });
      return;
    }
    if (!r.sent) {
      // Resolved at once: a switch the user turned off does not turn itself
      // back on inside the deadline.
      if (r.reason === "remote-access-off") {
        this.finish(w, { ok: false, code: "REMOTE_ACCESS_OFF" });
        return;
      }
      w.lastHeld = r.reason;
    }
    const delay = Math.min(w.backoffMs, Math.max(1, w.expiresAt - t));
    w.backoffMs = Math.min(BUS_REQUEST_RESEND_MAX_MS, w.backoffMs * 2);
    w.cancel = this.schedule(() => this.attempt(w), delay);
  }

  private input(
    p: { to: string; sentAt: number; expiresAt: number },
    kind: "request" | "response",
    body: AbMessage,
    id: string,
    correlationId?: string,
  ): BusSendInput {
    return {
      to: p.to, id, kind, ...(correlationId ? { correlationId } : {}), body,
      sentAt: p.sentAt, expiresAt: p.expiresAt, role: this.deps.selfRole(),
    };
  }

  /** What the transport learned about a frame this side sent. */
  onTransportOutcome(id: string, _to: string, o: TransportOutcome): void {
    const w = this.waiters.get(id);
    if (w) {
      if (o.kind === "refused") this.finish(w, { ok: false, code: o.code });
      else if (o.kind === "retry") w.lastHeld = o.reason;
      return;
    }
    const p = this.responses.get(id);
    // Applied or refused is the far side's verdict that it has the response, or
    // never will; either way resending cannot help.
    if (p && (o.kind === "applied" || o.kind === "refused")) this.dropResponse(p);
  }

  /** A response arrived. Matched on the sender as well as the id: a machine
   *  that is not the one asked cannot answer for it. */
  onResponse(from: string, correlationId: string, body: unknown): boolean {
    const w = this.waiters.get(correlationId);
    if (!w || w.to !== from) return false;
    const m = body as { type?: unknown; ok?: unknown; result?: unknown; error?: { code?: unknown } } | null;
    if (!m || typeof m !== "object" || m.type !== "response") return false;
    if (m.ok === true) this.finish(w, { ok: true, result: m.result });
    else this.finish(w, { ok: false, code: typeof m.error?.code === "string" ? m.error.code : "E_UNKNOWN" });
    return true;
  }

  /** Sends `response` to the machine that asked, resending until acknowledged
   *  or past `expiresAt`. In memory only: after a restart the requester's
   *  resend is answered from the seen-store instead. */
  respond(to: string, requestId: string, response: AbMessage, expiresAt: number): void {
    if (this.stopped) return;
    const key = `${to}:${requestId}`;
    const existing = this.responses.get(key);
    if (existing) {
      this.sendResponse(existing);
      return;
    }
    if (this.responses.size >= MAX_PENDING_RESPONSES * 2) {
      const oldest = this.responses.values().next().value;
      if (oldest) this.dropResponse(oldest);
    }
    const p: PendingResponse = { id: randomUUID(), to, requestId, body: response, sentAt: this.now(), expiresAt, cancel: null };
    this.responses.set(key, p);
    this.responses.set(p.id, p);
    this.sendResponse(p);
  }

  private dropResponse(p: PendingResponse): void {
    p.cancel?.();
    p.cancel = null;
    this.responses.delete(`${p.to}:${p.requestId}`);
    this.responses.delete(p.id);
  }

  private sendResponse(p: PendingResponse): void {
    p.cancel?.();
    p.cancel = null;
    if (this.now() >= p.expiresAt) {
      this.dropResponse(p);
      return;
    }
    const r = this.deps.transport.send(this.input(p, "response", p.body, p.id, p.requestId));
    if ("refused" in r || (!r.sent && r.reason === "remote-access-off")) {
      this.dropResponse(p);
      return;
    }
    p.cancel = this.schedule(() => this.sendResponse(p), Math.min(RESPOND_RETRY_MS, Math.max(1, p.expiresAt - this.now())));
  }

  /** A peer is back: resend what was waiting on it now rather than at the next
   *  backoff step. */
  retryNow(machineId: string): void {
    for (const w of [...this.waiters.values()]) {
      if (w.to !== machineId) continue;
      w.backoffMs = BUS_REQUEST_RESEND_MIN_MS;
      this.attempt(w);
    }
    for (const p of new Set(this.responses.values())) {
      if (p.to === machineId) this.sendResponse(p);
    }
  }

  stop(): void {
    this.stopped = true;
    for (const w of [...this.waiters.values()]) {
      this.waiters.delete(w.id);
      w.cancel?.();
      w.reject(new Error("bus requests stopped"));
    }
    for (const p of new Set(this.responses.values())) this.dropResponse(p);
  }
}
