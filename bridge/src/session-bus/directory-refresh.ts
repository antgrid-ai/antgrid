// Fills the remote directory by asking each of the account's other machines for
// its capability card over the bus. This machine cannot dial another bridge, so
// the mirror is only ever as fresh as the last answer that came back; this is
// the loop that keeps asking.
//
// Every ask is a sealed bus request, so it is refused up front while this
// machine's remote-access switch is off, and a peer answers it only when its own
// switch and agent reach allow. Logs carry machine ids and outcomes only, never
// a row.
import type { MachineEntry } from "antgrid-wire";
import { logger } from "../logger";
import type { BusRequestResult, BusRequests } from "./bus-requests";
import { MAX_REMOTE_DIRECTORY_MACHINES, REMOTE_DIRECTORY_REFRESH_MS } from "./constants";
import type { MachineDirectory } from "./machine-directory";
import type { RemoteDirectoryCache, RemoteMachineOutcome } from "./remote-directory";

const log = logger.child({ component: "directory-refresh" });

export const DIRECTORY_ASK_TIMEOUT_MS = 20_000;
/** A kick (an unserved read, a peer coming online) asks a machine at most this
 *  often, so a burst of reads cannot become a burst of requests. */
export const DIRECTORY_KICK_MIN_MS = 5_000;

export const CAPABILITY_CARD_METHOD = "machine.capability-card";

export interface DirectoryRefresherDeps {
  directory: Pick<MachineDirectory, "current">;
  requests: Pick<BusRequests, "request">;
  cache: Pick<RemoteDirectoryCache, "ingest" | "syncAccount" | "wantedRepoKeys">;
  online: () => ReadonlySet<string>;
  remoteAccessEnabled: () => boolean;
  now?: () => number;
  /** Returns a canceller. Injected so tests drive the cadence by hand. */
  schedule?: (fn: () => void, ms: number) => () => void;
}

function defaultSchedule(fn: () => void, ms: number): () => void {
  const t = setTimeout(fn, ms);
  t.unref?.();
  return () => clearTimeout(t);
}

/** What one request's result means for the reach line. Refusals keep apart the
 *  two switches they can name: the peer's remote access and its agent reach. */
export function outcomeFor(r: BusRequestResult): { outcome: RemoteMachineOutcome; rows: unknown[]; truncated: number } {
  if (r.ok) {
    const card = r.result as { sessions?: unknown; sessionsTruncated?: unknown } | null | undefined;
    if (card && typeof card === "object" && Array.isArray(card.sessions)) {
      const truncated = typeof card.sessionsTruncated === "number" ? card.sessionsTruncated : 0;
      return { outcome: "rows", rows: card.sessions, truncated };
    }
    // A card without the key is a peer too old to know the flag, which is not
    // the same as a peer with nothing running.
    return { outcome: "no-card", rows: [], truncated: 0 };
  }
  switch (r.code) {
    case "NOT_ALLOWED_AGENT_REACH":
      return { outcome: "reach-refused", rows: [], truncated: 0 };
    case "NOT_ALLOWED":
    case "REMOTE_ACCESS_OFF":
      return { outcome: "refused", rows: [], truncated: 0 };
    case "E_UNKNOWN_METHOD":
    case "E_BAD_PARAMS":
    case "METHOD_NOT_ALLOWED":
      return { outcome: "no-card", rows: [], truncated: 0 };
    default:
      return { outcome: "unreachable", rows: [], truncated: 0 };
  }
}

export class DirectoryRefresher {
  private readonly now: () => number;
  private readonly schedule: (fn: () => void, ms: number) => () => void;
  private readonly lastAskedAt = new Map<string, number>();
  private readonly inflight = new Set<string>();
  private cancelTick: (() => void) | null = null;
  private started = false;

  constructor(private readonly deps: DirectoryRefresherDeps) {
    this.now = deps.now ?? Date.now;
    this.schedule = deps.schedule ?? defaultSchedule;
  }

  start(): void {
    if (this.started) return;
    this.started = true;
    void this.tick();
  }

  stop(): void {
    this.started = false;
    this.cancelTick?.();
    this.cancelTick = null;
  }

  private async tick(): Promise<void> {
    this.cancelTick = null;
    await this.refresh();
    if (!this.started) return;
    this.cancelTick = this.schedule(() => void this.tick(), REMOTE_DIRECTORY_REFRESH_MS);
  }

  /** Asks now, for a read the mirror could not serve or a peer that just came
   *  online. Throttled per machine; a no-op while remote access is off. */
  kick(machineId?: string): Promise<void> {
    return this.refresh(machineId, DIRECTORY_KICK_MIN_MS);
  }

  private candidates(): { askable: MachineEntry[]; unaskable: number; self: string } | null {
    const view = this.deps.directory.current();
    if (!view || !view.allowed) return null;
    const others = view.machines.filter((m) => m.deviceId !== view.deviceId);
    return {
      askable: others.filter((m) => m.busPublicKey !== null),
      unaskable: others.filter((m) => m.busPublicKey === null).length,
      self: view.deviceId,
    };
  }

  private async refresh(only?: string, minGapMs = 0): Promise<void> {
    if (!this.deps.remoteAccessEnabled()) return;
    const c = this.candidates();
    if (!c) return;
    this.deps.cache.syncAccount(new Set(c.askable.map((m) => m.deviceId)), c.unaskable);
    // The far side narrows its card to these, so an ask naming none costs its
    // git probes and answers nothing. The first read that wants a repository
    // kicks an ask that names it.
    const repoKeys = this.deps.cache.wantedRepoKeys();
    if (repoKeys.length === 0) return;

    const t = this.now();
    const online = this.deps.online();
    const picked = c.askable
      .filter((m) => only === undefined || m.deviceId === only)
      .filter((m) => !this.inflight.has(m.deviceId))
      .filter((m) => t - (this.lastAskedAt.get(m.deviceId) ?? Number.NEGATIVE_INFINITY) >= minGapMs)
      .sort((a, b) => {
        const ao = online.has(a.deviceId) ? 0 : 1;
        const bo = online.has(b.deviceId) ? 0 : 1;
        if (ao !== bo) return ao - bo;
        return (this.lastAskedAt.get(a.deviceId) ?? 0) - (this.lastAskedAt.get(b.deviceId) ?? 0);
      })
      .slice(0, MAX_REMOTE_DIRECTORY_MACHINES);
    await Promise.all(picked.map((m) => this.ask(m, c.self, repoKeys)));
  }

  private async ask(m: MachineEntry, self: string, repoKeys: string[]): Promise<void> {
    this.inflight.add(m.deviceId);
    this.lastAskedAt.set(m.deviceId, this.now());
    try {
      const result = await this.deps.requests.request({
        to: m.deviceId,
        method: CAPABILITY_CARD_METHOD,
        params: { includeSessions: true, repoKeys },
        timeoutMs: DIRECTORY_ASK_TIMEOUT_MS,
      });
      const { outcome, rows, truncated } = outcomeFor(result);
      const ingested = this.deps.cache.ingest(
        { machineId: m.deviceId, machineLabel: m.machineName ?? m.displayName, observedAt: this.now(), outcome, rows, repoKeys, truncated },
        self,
      );
      log.debug("directory refresh", {
        machine: m.deviceId, outcome, accepted: ingested.accepted, dropped: ingested.dropped,
        ...(result.ok ? {} : { code: result.code }),
      });
    } catch (err) {
      // The requester was stopped under the ask; there is no answer to record.
      log.debug("directory refresh abandoned", { machine: m.deviceId, error: err instanceof Error ? err.name : "error" });
    } finally {
      this.inflight.delete(m.deviceId);
    }
  }
}
