// The machine-level directory `docs/session-messaging.md` §5.4 asks for, in
// the sense that matters: resolving a session id to the project core that
// holds it, from whichever project's stream a frame naming it arrived on.
// Nothing on this bridge calls `lookup` yet — it lands on its own so it gets
// its own unit test rather than being an untested implementation detail
// inside the commit that wires it into `self()` and `send`.

import { logger } from "../logger";
import type { SessionEntry } from "../protocol";
import { SessionManager } from "../session-manager";

const log = logger.child({ component: "session-bus" });

export interface SessionIndexEntry {
  projectId: string;
  /** The project's FOLDER basename, which is not always what `sessionBusSelf`
   *  stamps on a bus address today: that reads `project.name`, which prefers
   *  `antgrid.yaml`'s `name:` over the basename. The two agree only for a
   *  project that does not name itself, so whichever commit feeds this into
   *  `SessionMemberRef.projectLabel` owes that difference a decision rather
   *  than inheriting it silently. */
  projectLabel?: string;
  sessionName?: string;
}

export interface SessionBusSessionIndexDeps {
  /** The live session list for a project with a warm core right now — the same
   *  synchronous accessor `HostServer.handleSessionsListRpc`'s peek already
   *  uses to choose warm-vs-disk (`ProjectCore.listSessions`). Null means this
   *  project has no warm core (or one that has not finished initialising),
   *  which is what sends `lookup` to the hydrated disk snapshot instead of
   *  treating an unlisted id as unknown. */
  liveSessions(projectId: string): readonly SessionEntry[] | null;
}

/**
 * sessionId -> owning project, machine-wide.
 *
 * A warm project is never answered from a cache: `lookup` calls back into
 * `deps.liveSessions` on every call. `SessionManager` flushes `sessions.json`
 * on a debounced timer, so a snapshot taken once (at hydrate, or whenever the
 * project last started) would answer a session created moments ago as
 * unknown — exactly the staleness a machine-wide `self()` must not add on top
 * of what one core's own live SessionManager already answered correctly. The
 * disk-hydrated half exists only for the one case a live read cannot cover: a
 * project with no core running right now, where nothing in this process's
 * memory is live to ask.
 *
 * There is no per-session note/forget: a warm project is always read live, so
 * nothing needs to invalidate a cache that a warm lookup never consults, and
 * a cold project's snapshot is refreshed wholesale by `noteProject` — which
 * must therefore run on the edge where a project goes cold, not only where it
 * warms up. See that method's own doc for when it runs and what it accepts
 * staying stale against.
 */
export class SessionBusSessionIndex {
  private readonly labels = new Map<string, string | undefined>();
  private readonly disk = new Map<string, ReadonlyMap<string, SessionEntry>>();
  private hydrated = false;
  private warnedBeforeHydrate = false;

  constructor(private readonly deps: SessionBusSessionIndexDeps) {}

  /**
   * Seed the disk-fallback half from every project this machine has ever
   * opened. Meant to run once, at host start: a synchronous `lookup` cannot
   * await a disk read per call, so this is the only chance a cold project's
   * sessions get an answer before the next time its core happens to warm up.
   */
  async hydrate(abDir: string, projects: Iterable<{ id: string; label?: string }>): Promise<void> {
    for (const project of projects) {
      const entries = await SessionManager.readPersisted(abDir, project.id, true);
      this.noteProject(project.id, project.label, entries);
    }
    this.hydrated = true;
  }

  /**
   * Register (or refresh) one project's label and disk-fallback session set.
   *
   * Runs at three points, keyed by the CORE'S OWN id — never the `cores` map
   * key, which can be a grandfathered legacy alias (`HostServer.open`'s
   * warm-core early return) that disagrees with it:
   *   - `hydrate`, for every project this machine has ever opened;
   *   - when a core STARTS, which is what makes a project this host has never
   *     seen before addressable without waiting for the next restart;
   *   - when a core goes COLD, immediately before it leaves the warm map. That
   *     one is load-bearing rather than tidy: every session created while the
   *     project was warm was answered live and is absent from the snapshot
   *     taken at start, so without a refresh here each one becomes
   *     unresolvable the instant the project is stopped or evicted — the exact
   *     unreachability keeping rows across an eviction exists to prevent.
   *
   * `entries` of null means the core could not answer (it has not finished
   * initialising), which is NOT the same claim as an empty list: the recorded
   * set is left alone rather than overwritten with an emptiness nothing
   * observed.
   */
  noteProject(projectId: string, label: string | undefined, entries: readonly SessionEntry[] | null): void {
    this.labels.set(projectId, label);
    if (!entries) {
      if (!this.disk.has(projectId)) this.disk.set(projectId, new Map());
      return;
    }
    const bySession = new Map<string, SessionEntry>();
    for (const entry of entries) bySession.set(entry.id, entry);
    this.disk.set(projectId, bySession);
  }

  /**
   * Drop a project entirely.
   *
   * Called only when the project itself is forgotten — NEVER on eviction,
   * which leaves a project cold but still real: a session in an evicted
   * project must stay addressable, which is half of what a machine-level
   * index exists to buy.
   */
  forgetProject(projectId: string): void {
    this.labels.delete(projectId);
    this.disk.delete(projectId);
  }

  /** Resolve one session id to its owning project, or null if this machine has
   *  never heard of it. */
  lookup(sessionId: string): SessionIndexEntry | null {
    for (const [projectId, projectLabel] of this.labels) {
      const live = this.deps.liveSessions(projectId);
      if (live) {
        const found = live.find((e) => e.id === sessionId);
        if (found) return { projectId, projectLabel, sessionName: found.name };
        continue; // warm and authoritative: absent here means absent, no disk fallback for it
      }
      const found = this.disk.get(projectId)?.get(sessionId);
      if (found) return { projectId, projectLabel, sessionName: found.name };
    }
    // A miss before hydrate() finishes reads identically to a genuine unknown
    // id, so it earns its own line once: without it, a bug report from the
    // startup window points at the wrong half of this class.
    if (!this.hydrated && !this.warnedBeforeHydrate) {
      this.warnedBeforeHydrate = true;
      log.warn("session-bus: session index queried before startup hydrate finished — a miss here may just be timing, not a real addressing bug");
    }
    return null;
  }
}
