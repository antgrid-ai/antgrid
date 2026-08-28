import { existsSync, readFileSync, watch, type FSWatcher } from "node:fs";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { logger } from "../../logger";
import { parseAntigravityRenames } from "./title";

/** True for the agy file a user-chosen conversation name can change in: the
 *  command log, where `/rename` is recorded. agy's OWN names live in
 *  conversation_summaries.db and are deliberately not watched — we generate our
 *  titles rather than wait on agy's. Everything else in the home dir —
 *  especially the churning `cli.log` — is ignored. */
function isTitleSource(filename: string): boolean {
  return filename === "history.jsonl";
}

/**
 * Watches agy's command log and reports each conversation's `/rename` as it
 * happens, so the app follows a rename instantly — agy fires no hook on one, so
 * without this it would not surface until the next turn.
 *
 * Renames ONLY. agy also names conversations itself in conversation_summaries.db
 * (its `preview`), and that used to be reported here as a lagging upgrade; it is
 * no longer read anywhere, because we generate our own name from the first user
 * message instead of waiting to see whether agy writes one (see ResolvedTitle).
 * The first-user-message fallback is not here either — that one is instant and
 * already supplied by the hook -> resolver path.
 *
 * Reports only CHANGED titles (deduped per conversation), and only ones produced
 * after `start()` — the current state is seeded silently so a resume doesn't
 * re-announce an existing name. Self-disables when the agy home is absent (agy
 * not installed). Fail-open throughout.
 */
export class AntigravityTitleWatcher {
  private watcher: FSWatcher | null = null;
  private debounce: ReturnType<typeof setTimeout> | null = null;
  private readonly lastSeen = new Map<string, string>();

  constructor(
    private readonly home: string,
    private readonly onTitle: (conversationId: string, title: string) => void,
    private readonly debounceMs = 150,
  ) {}

  start(): void {
    if (this.watcher || !existsSync(this.home)) return;
    // Seed the dedupe map from the current state without emitting. Synchronous
    // so a title written immediately after start() is genuinely "new" and not
    // swallowed by a seed still in flight.
    this.seed();
    try {
      // Watch the DIRECTORY, not the file: agy rewrites history.jsonl via atomic
      // replace, which drops a file-level watch on Windows.
      this.watcher = watch(this.home, (_event, filename) => {
        // A null filename (some platforms/events omit it) is unclassifiable, so
        // scan rather than risk dropping a real title change; a named event is
        // filtered to the title sources to skip the churning cli.log.
        if (!filename || isTitleSource(filename.toString())) this.schedule();
      });
      // An FSWatcher emits "error" asynchronously (e.g. the agy home is deleted
      // mid-session); with no listener that throws and takes down the bridge,
      // breaking this module's fail-open contract. Log and let the watcher lapse.
      this.watcher.on("error", (err) => {
        logger.warn("antigravity title watcher error: %s", err);
      });
    } catch (err) {
      logger.warn("antigravity title watch failed to start: %s", err);
    }
  }

  stop(): void {
    if (this.debounce) { clearTimeout(this.debounce); this.debounce = null; }
    this.watcher?.close();
    this.watcher = null;
    this.lastSeen.clear();
  }

  /** Coalesce the burst of fs events one write raises into a single scan. */
  private schedule(): void {
    if (this.debounce) return;
    this.debounce = setTimeout(() => {
      this.debounce = null;
      void this.scan();
    }, this.debounceMs);
  }

  /** Live scan on the debounced timer. history.jsonl is append-only and grows
   *  unbounded over a machine's lifetime, so it's read ASYNC here — a sync read
   *  on every directory change would stall the bridge's event loop (and its WS
   *  sockets) once the log reaches multi-MB. The seed at start() reads it sync
   *  instead (see seed()); that one must be synchronous to stay race-free. */
  private async scan(): Promise<void> {
    const renames = parseAntigravityRenames(await this.readHistory());
    // Bail if stop() ran while we were awaiting the read — don't emit into a
    // torn-down watcher.
    if (!this.watcher) return;
    this.apply(renames, false);
  }

  /** Seed the dedupe map from current state without emitting. Synchronous by
   *  design (see start()): an async read could race a title written right after
   *  start() and swallow it as already-seen. */
  private seed(): void {
    let raw = "";
    try {
      raw = readFileSync(join(this.home, "history.jsonl"), "utf8");
    } catch {
      // missing/unreadable — no renames to seed
    }
    this.apply(parseAntigravityRenames(raw), true);
  }

  private apply(renames: Map<string, string>, seedOnly: boolean): void {
    for (const [cid, title] of renames) {
      if (!title || this.lastSeen.get(cid) === title) continue;
      this.lastSeen.set(cid, title);
      if (!seedOnly) this.onTitle(cid, title);
    }
  }

  private async readHistory(): Promise<string> {
    try {
      return await readFile(join(this.home, "history.jsonl"), "utf8");
    } catch {
      return ""; // missing/unreadable — parses to no renames
    }
  }
}
