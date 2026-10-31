import {
  MachineDirectorySchema,
  PEER_LEASE_MS,
  PEER_REFRESH_MS,
  type MachineDirectory as MachineDirectoryView,
  type MachineEntry,
} from "antgrid-wire";
import { logger } from "../logger";

const log = logger.child({ component: "machine-directory" });

/** A kick inside this window of the last fetch is deferred to the window's end,
 *  keeping bus-path kicks well under the route's refill rate. */
export const MACHINE_DIRECTORY_KICK_MIN_MS = 15_000;
/** A view older than this is not served: the account may have revoked a machine
 *  since, and the peer lease expires on the same bound. */
export const MACHINE_DIRECTORY_STALE_MS = PEER_LEASE_MS;
const FETCH_TIMEOUT_MS = 10_000;
const BACKOFF_MIN_MS = 2_000;
const BACKOFF_MAX_MS = 60_000;
const JITTER = 0.1;

export interface MachineDirectoryOptions {
  licenseApiUrl: string;
  getToken: () => Promise<string> | string;
  selfDeviceId: string;
  fetchFn?: typeof fetch;
  now?: () => number;
  /** Returns a canceller. Injected so tests drive the cadence by hand. */
  schedule?: (fn: () => void, ms: number) => () => void;
  random?: () => number;
}

function defaultSchedule(fn: () => void, ms: number): () => void {
  const t = setTimeout(fn, ms);
  t.unref?.();
  return () => clearTimeout(t);
}

/** Client for the account's machine directory: the other agent machines, their
 *  bus public keys and orchestrator flags, as web reports them. Holds only the
 *  last good view and never serves one past its staleness bound. */
export class MachineDirectory {
  private readonly fetchFn: typeof fetch;
  private readonly now: () => number;
  private readonly schedule: (fn: () => void, ms: number) => () => void;
  private readonly random: () => number;
  private view: MachineDirectoryView | null = null;
  private fetchedAt = 0;
  private lastFetchStartedAt = Number.NEGATIVE_INFINITY;
  private failures = 0;
  private started = false;
  private inflight: Promise<boolean> | null = null;
  private cancelLoop: (() => void) | null = null;
  private cancelKick: (() => void) | null = null;
  private readonly listeners = new Set<() => void>();

  constructor(private readonly opts: MachineDirectoryOptions) {
    this.fetchFn = opts.fetchFn ?? fetch;
    this.now = opts.now ?? Date.now;
    this.schedule = opts.schedule ?? defaultSchedule;
    this.random = opts.random ?? Math.random;
  }

  start(): void {
    if (this.started) return;
    this.started = true;
    void this.tick();
  }

  stop(): void {
    this.started = false;
    this.cancelLoop?.();
    this.cancelLoop = null;
    this.cancelKick?.();
    this.cancelKick = null;
    this.listeners.clear();
  }

  private async tick(): Promise<void> {
    this.cancelLoop = null;
    const ok = await this.refresh();
    if (!this.started) return;
    const delay = ok
      ? PEER_REFRESH_MS * (1 + (this.random() * 2 - 1) * JITTER)
      : Math.min(BACKOFF_MAX_MS, BACKOFF_MIN_MS * 2 ** Math.max(0, this.failures - 1));
    this.cancelLoop = this.schedule(() => void this.tick(), delay);
  }

  refresh(): Promise<boolean> {
    if (this.inflight) return this.inflight;
    this.lastFetchStartedAt = this.now();
    const run = this.fetchOnce().finally(() => {
      this.inflight = null;
    });
    this.inflight = run;
    return run;
  }

  private async fetchOnce(): Promise<boolean> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
    try {
      const token = await this.opts.getToken();
      const res = await this.fetchFn(`${this.opts.licenseApiUrl}/account/devices/me/machines`, {
        headers: { authorization: `Bearer ${token}` },
        signal: controller.signal,
      });
      if (!res.ok) return this.fail(`status ${res.status}`);
      const parsed = MachineDirectorySchema.safeParse(await res.json());
      if (!parsed.success) return this.fail("invalid body");
      // A directory built for another device would hand this machine someone
      // else's view of "self"; discard it rather than act on it.
      if (parsed.data.deviceId !== this.opts.selfDeviceId) return this.fail("device mismatch");
      this.view = parsed.data;
      this.fetchedAt = this.now();
      this.failures = 0;
      log.debug("machine directory refreshed", { machines: parsed.data.machines.length });
      for (const l of [...this.listeners]) {
        try {
          l();
        } catch (err) {
          log.warn("machine directory listener threw: %s", err instanceof Error ? err.message : String(err));
        }
      }
      return true;
    } catch (err) {
      return this.fail(err instanceof Error ? err.name : "error");
    } finally {
      clearTimeout(timer);
    }
  }

  private fail(reason: string): false {
    this.failures++;
    log.warn("machine directory refresh failed", { reason, failures: this.failures });
    return false;
  }

  /** Coalesced refresh request: at most one fetch per window; a kick inside the
   *  window is deferred to its end rather than dropped. */
  kick(): void {
    if (this.cancelKick) return;
    const wait = this.lastFetchStartedAt + MACHINE_DIRECTORY_KICK_MIN_MS - this.now();
    if (wait <= 0) {
      void this.refresh();
      return;
    }
    this.cancelKick = this.schedule(() => {
      this.cancelKick = null;
      void this.refresh();
    }, wait);
  }

  async ensureFresh(maxAgeMs: number): Promise<boolean> {
    if (this.view && this.now() - this.fetchedAt <= maxAgeMs) return true;
    return this.refresh();
  }

  current(): MachineDirectoryView | null {
    if (!this.view) return null;
    return this.now() - this.fetchedAt > MACHINE_DIRECTORY_STALE_MS ? null : this.view;
  }

  machine(deviceId: string): MachineEntry | null {
    return this.current()?.machines.find((m) => m.deviceId === deviceId) ?? null;
  }

  /** Null unless the account currently allows this machine and the target has
   *  registered a key: nothing is ever sealed to a key the directory does not vouch for. */
  busKeyFor(deviceId: string): string | null {
    const v = this.current();
    if (!v || !v.allowed) return null;
    return v.machines.find((m) => m.deviceId === deviceId)?.busPublicKey ?? null;
  }

  selfOrchestrator(): boolean {
    return this.current()?.self.orchestrator ?? false;
  }

  selfBusControl(): boolean {
    return this.current()?.self.busControl ?? false;
  }

  selfBusKey(): string | null {
    return this.current()?.self.busPublicKey ?? null;
  }

  onChange(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }
}
