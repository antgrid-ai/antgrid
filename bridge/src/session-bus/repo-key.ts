// The addressable set is keyed on a normalized git remote, not on a project id
// (`docs/session-messaging.md` §5.1): a managed worktree and the repo it was cut
// from hash to different project ids and must still reach each other, which is
// the whole reason Wave 1 moved the bus to the machine.
//
// The probe is a `git` spawn and every reader of this map is synchronous — the
// outbox needs a synchronous boolean, which is what shaped `SessionBusSessionIndex`
// too — so the answer is refreshed on edges and read from memory, never awaited
// at a call site.

import { readRepoKey } from "../capability-card";
import { logger } from "../logger";

const log = logger.child({ component: "session-bus" });

/**
 * projectId -> normalized repo key, machine-wide.
 *
 * A project with no remote records `null` and is remembered as such: a MISSING
 * entry means "never probed" and a null entry means "probed, has none". The
 * directory renders those differently — one is a project still warming up, the
 * other is a project that can never be addressed.
 *
 * There is no TTL here on purpose. `readRepoKey` already caches by path on its
 * own clock so that `git remote set-url` takes effect without a bridge restart,
 * and a second interval over the top of it could only ever be the shorter of the
 * two — a policy stated twice, where the copy that loses is invisible. Every
 * `note` calls through, and a call inside the probe's own window is a map hit.
 */
export class SessionBusRepoKeys {
  private readonly keys = new Map<string, string | null>();

  /**
   * Probe `projectPath` and record its key.
   *
   * Runs on the same three edges `SessionBusSessionIndex.noteProject` does —
   * host hydrate, core start, core going cold — because a project that is
   * addressable is exactly a project the index can enumerate, and an edge that
   * refreshed one but not the other would leave sessions listed with no key or
   * a key with no sessions.
   */
  async note(projectId: string, projectPath: string | undefined): Promise<void> {
    if (!projectPath) return;
    try {
      this.keys.set(projectId, await readRepoKey(projectPath));
    } catch (err) {
      // A probe that threw is not evidence the project has no remote, so an
      // existing key survives it. A project that has never answered is left
      // unrecorded, which reads as "not addressable yet" rather than as "not
      // addressable" — see the class doc for why those must stay separable.
      log.warn("session-bus: could not read the repo key for %s: %s", projectId, err);
    }
  }

  /** Probe every project this machine has ever opened, at host start. Serial on
   *  purpose: `readRepoKey` spawns git, this runs beside live PTY I/O, and
   *  nothing is waiting on the answer — the first read that needs it is a human
   *  typing a tool call. */
  async hydrate(projects: Iterable<{ id: string; path?: string }>): Promise<void> {
    for (const project of projects) await this.note(project.id, project.path);
  }

  /** The key, or null for a project with no remote OR one never probed. A
   *  caller cannot act on the difference — both mean "no peers" — so the two are
   *  collapsed here and separated only by {@link probed}. */
  keyFor(projectId: string): string | null {
    return this.keys.get(projectId) ?? null;
  }

  /** Whether this project has ever answered the probe. Only the directory's
   *  refusal text reads this: "no git remote" and "not read yet" are the same
   *  empty list and very different bug reports. */
  probed(projectId: string): boolean {
    return this.keys.has(projectId);
  }

  /** Every project sharing `key`. Empty for a null key — a project with no
   *  remote is not addressable and, crucially, is not addressable BY the other
   *  projects that also have none (§5.1 fails closed). */
  projectsSharing(key: string | null): string[] {
    if (!key) return [];
    return [...this.keys].filter(([, v]) => v === key).map(([id]) => id);
  }

  forgetProject(projectId: string): void {
    this.keys.delete(projectId);
  }
}
