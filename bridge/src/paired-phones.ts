import { existsSync, mkdirSync, readFileSync, watch as fsWatch } from "node:fs";
import { join } from "node:path";
import { atomicWriteFile, isWatchEventFor } from "./discovery";
import { logger } from "./logger";
const log = logger.child({ component: "paired-phones" });

/** A phone's identity/bookkeeping row: label, last-seen, push routing. NOT an
 *  authorization record — admission is the account inventory (see
 *  `relay-client.ts` `handleClientHello`) and authorization is the machine-level
 *  switch in `remote-access-policy.ts`. */
export interface PairedPhone {
  phonePubkey: string;
  phoneDeviceId: string;
  label?: string;
  pairedAt: string;
  lastSeenAt: string;
  // Push: persistent X25519 push pubkey + the current FCM/APNs token. The relay
  // never stores these; the bridge supplies them per push:deliver.
  pushPubkey?: string;
  pushToken?: string;
  pushProvider?: "fcm" | "apns";
  pushUpdatedAt?: string;
  /** When an accepted authorization snapshot first left this row out; cleared
   *  by the next one that names it again, and the row is collected once it is
   *  old enough. Persisted, not held in memory, so a restart neither resets
   *  that clock nor reopens pushes to a phone the account revoked before its
   *  first snapshot lands (see `accountDisowns`). */
  disownedAt?: string;
}

export interface PairedPhonesStore {
  list(): PairedPhone[];
  has(phonePubkey: string): boolean;
  get(phonePubkey: string): PairedPhone | undefined;
  upsert(phone: PairedPhone): void;
  remove(phonePubkey: string): void;
  /** Rewrite every row through `next` in ONE file write: return the row to
   *  keep it (a changed copy to update it), `null` to remove it. Returns the
   *  removed rows. No write at all when nothing changes, so a caller sweeping
   *  on a timer never trips the watcher's re-advertise for a no-op. `next`
   *  judges the rows on disk with this process's coalesced `touchLastSeen`
   *  stamps applied, so a phone admitted moments ago is never judged on the
   *  `last seen` its file row still carries. `next` must be pure: it may run
   *  more than once per row. */
  reconcile(next: (phone: PairedPhone) => PairedPhone | null): PairedPhone[];
  /** Record a fresh admission for `phonePubkey` WITHOUT writing to disk.
   *  Every session establishment re-runs admission, so a phone that
   *  reconnects often would, with a straight `upsert` here, rewrite (and
   *  re-flush) the file on each one
   *  — tripping the watcher's re-advertise. The row is updated in memory and
   *  the write is coalesced onto a timer (see `flushLastSeen`). No-op for an
   *  unknown phone. */
  touchLastSeen(phonePubkey: string, at?: string): void;
  /** Persist any coalesced `touchLastSeen` writes now, cancelling the pending
   *  timer. The resulting write is invisible to `watch` (see below). */
  flushLastSeen(): void;
  /** Release the store: flush coalesced touches and drop the timer. Call from
   *  the owner's shutdown so a `last seen` from the final minutes of a session
   *  survives the process. Does NOT stop a `watch` — that has its own stop fn. */
  close(): void;
  /** Watch the backing file for external changes. Calls `onChange` (after a
   *  50ms debounce) and reloads the in-memory store on each change. Returns a
   *  stop function that cancels the watcher and any pending debounce timer.
   *
   *  A `flushLastSeen` write is deliberately NOT reported: it carries nothing a
   *  connected phone could observe, and `onChange` drives a re-advertise to
   *  every one of them. Suppression is one-shot and applies only to a write that
   *  carried touches alone — a flush that absorbed a concurrent external edit
   *  still notifies, and so does any later edit. */
  watch(onChange: () => void): () => void;
}

export interface PairedPhonesOptions {
  /** How long to coalesce `touchLastSeen` writes. Tests drive this to 0-ish;
   *  production trades up to this much staleness in `antgrid phones list` for
   *  one write per active minute instead of one per reconnect. */
  lastSeenFlushMs?: number;
}

const DEFAULT_LAST_SEEN_FLUSH_MS = 60_000;

interface FileShape {
  version: 1;
  phones: PairedPhone[];
}

export function loadPairedPhones(abDir: string, opts: PairedPhonesOptions = {}): PairedPhonesStore {
  const dir = join(abDir, "agents");
  const path = join(dir, "paired-phones.json");
  const lastSeenFlushMs = opts.lastSeenFlushMs ?? DEFAULT_LAST_SEEN_FLUSH_MS;

  // Nothing in memory to protect yet, so an unreadable file starts empty —
  // every other caller must handle the null case (see readFile).
  let phones: PairedPhone[] = readFile(path) ?? [];

  // phonePubkey → admission timestamp already applied in memory but not yet on
  // disk. Survives a watcher reload so a concurrent CLI write — which loaded
  // the file before our touch landed — can't roll `last seen` backwards.
  const pendingTouches = new Map<string, string>();
  let touchTimer: ReturnType<typeof setTimeout> | null = null;
  // Exact bytes memory already reflects AND no one still needs to hear about:
  // our own touch-only write, or what the watcher last reloaded. A watcher fire
  // on them is silent — a touch must not re-advertise, and macOS delivers one
  // burst of writes as batches ~50ms apart, so a straggler can fire after the
  // debounce on bytes already handled.
  let knownRaw: string | null = null;

  function flush(silent = false) {
    const data: FileShape = { version: 1, phones };
    const raw = JSON.stringify(data, null, 2);
    // Cleared BEFORE the write, set only after one lands. Any write carrying
    // more than touches MUST still notify, and bytes left known by a write
    // that threw would silence a later external edit that happens to match them.
    // Re-notifying costs a re-advertise; under-notifying costs correctness.
    knownRaw = null;
    atomicWriteFile(path, raw, { fileMode: 0o600 });
    if (silent) knownRaw = raw;
  }

  // For a write that runs off a background timer rather than a store caller:
  // merge onto the on-disk rows instead of writing our in-memory array. Such a
  // write can land in the window between a CLI `phones remove` writing the
  // file and our watcher debounce reloading it, putting the removed row
  // straight back — and the reload then reads our bytes, not the CLI's, so
  // nothing ever corrects it. Disk is authoritative here because
  // all other mutators flush synchronously; pending touches are the only state
  // memory legitimately holds ahead of it.
  //
  // Adopt only a SUCCESSFUL read. A row-count guard would take `phones remove
  // <last phone>` for a failure and write the removed row straight back; an
  // existence guard has the mirror failure, adopting the zero rows a torn
  // concurrent write or malformed JSON yields and flushing the whole store
  // away. `readFile` separates the two: null = could not read, [] = a
  // well-formed empty file.
  function adoptDisk() {
    const disk = readFile(path);
    if (disk) phones = disk;
    applyPendingTouches();
  }

  function applyPendingTouches() {
    for (const [pk, at] of pendingTouches) {
      const phone = phones.find((p) => p.phonePubkey === pk);
      if (phone) phone.lastSeenAt = at;
    }
  }

  function flushLastSeen() {
    if (touchTimer) {
      clearTimeout(touchTimer);
      touchTimer = null;
    }
    if (pendingTouches.size === 0) return;
    const before = JSON.stringify(phones);
    adoptDisk();
    // Silent only when the write carries nothing but our own touches. When we
    // absorbed a concurrent external edit, the watcher event our write triggers
    // is the ONLY notification that edit will ever get — suppressing it strands
    // every connected phone on a stale catalog.
    flush(JSON.stringify(phones) === before);
    // Dropped only once the write landed. The timer is already cleared, so
    // clearing these first would discard a minute of coalesced admissions on a
    // throw with nothing armed to retry them.
    pendingTouches.clear();
  }

  return {
    list: () => phones.slice(),
    has: (pk) => phones.some((p) => p.phonePubkey === pk),
    get: (pk) => phones.find((p) => p.phonePubkey === pk),
    upsert: (phone: PairedPhone) => {
      // Displace by pubkey OR device id, so a re-provisioned device (same
      // device, new pubkey) replaces the old row instead of leaving an orphan alongside it.
      const displaced = phones.filter(
        (p) =>
          p.phonePubkey === phone.phonePubkey ||
          (phone.phoneDeviceId && p.phoneDeviceId === phone.phoneDeviceId),
      );
      phones = phones.filter((p) => !displaced.includes(p));
      phones.push({ ...phone });
      flush();
    },
    remove: (pk) => {
      phones = phones.filter((p) => p.phonePubkey !== pk);
      flush();
    },
    reconcile: (next) => {
      const judge = () => {
        let changed = false;
        const removed: PairedPhone[] = [];
        const kept: PairedPhone[] = [];
        for (const phone of phones) {
          const row = next({ ...phone });
          if (row === null) {
            removed.push(phone);
            changed = true;
            continue;
          }
          if (!changed && JSON.stringify(row) !== JSON.stringify(phone)) changed = true;
          kept.push({ ...row });
        }
        return changed ? { removed, kept } : null;
      };
      // Memory already carries every touch, so it answers "anything to do?"
      // without the file read a sweep on every lease refresh would cost.
      if (!judge()) return [];
      adoptDisk();
      const verdict = judge();
      if (!verdict) return [];
      const { removed, kept } = verdict;
      phones = kept;
      // A stamp left pending for a removed key would land on the row a later
      // re-admission of that key creates, rolling its fresh `last seen` back.
      for (const p of removed) pendingTouches.delete(p.phonePubkey);
      flush();
      return removed.map((p) => ({ ...p }));
    },
    touchLastSeen: (pk, at) => {
      const phone = phones.find((p) => p.phonePubkey === pk);
      if (!phone) return;
      const stamp = at ?? new Date().toISOString();
      if (phone.lastSeenAt === stamp) return;
      phone.lastSeenAt = stamp;
      pendingTouches.set(pk, stamp);
      if (touchTimer) return;
      touchTimer = setTimeout(() => {
        touchTimer = null;
        // Nothing awaits this callback and the flush renames a file the CLI or a
        // scanner may hold open, so an EPERM here would reach the event loop as
        // an uncaughtException and take the whole bridge down over a `last seen`
        // timestamp. Same guard as handler/engine.ts's park timer.
        try { flushLastSeen(); } catch (err) { log.warn("paired-phones last-seen flush failed: %s", err); }
      }, lastSeenFlushMs);
      // A pending `last seen` write must never be the reason the process lives.
      touchTimer.unref?.();
    },
    flushLastSeen,
    // Shutdown runs this before it stops the control plane and removes
    // host.json, so a failed `last seen` write must not abort the teardown and
    // leave a stale host record pointing at a dead port.
    close: () => {
      try { flushLastSeen(); } catch (err) { log.warn("paired-phones close flush failed: %s", err); }
    },
    watch: (onChange) => {
      if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
      let timer: ReturnType<typeof setTimeout> | null = null;
      const w = fsWatch(dir, (_event, filename) => {
        // Must accept the scratch name too, not just "paired-phones.json": Bun
        // on Linux delivers exactly ONE event for a rename-publish into a watched
        // directory and names the SCRATCH file, never the target. An exact
        // compare here made this watcher permanently silent on the runtime the
        // bridge ships — no reload after `antgrid phones remove`, no re-advertise.
        if (!isWatchEventFor(filename, "paired-phones.json")) return;
        if (timer) clearTimeout(timer);
        timer = setTimeout(() => {
          const raw = readRaw(path);
          if (raw !== null && raw === knownRaw) return;
          // A failed read is a write in flight, not an emptied store — keep
          // memory and wait for the completing write's own event.
          const next = parsePhones(raw);
          if (!next) return;
          // Replacing the known bytes on every reload is what keeps a touch
          // snapshot from outliving an external write that landed inside the
          // debounce: left in place, it would silence a LATER edit restoring
          // those bytes, stranding the host on rows it no longer has.
          knownRaw = raw;
          phones = next;
          applyPendingTouches();
          onChange();
        }, 50);
      });
      // FSWatcher emits async 'error' events (EPERM/ENOENT on Windows when the
      // dir is locked or removed); unhandled, Node rethrows them as uncaught.
      w.on("error", (err) => log.error("paired-phones watcher error: %s", err));
      return () => { if (timer) clearTimeout(timer); w.close(); };
    },
  };
}

function readRaw(path: string): string | null {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return null;
  }
}

/**
 * Rows on disk, or **null when the file could not be read** — missing, locked,
 * torn by a concurrent write, or malformed. Callers holding in-memory state
 * MUST distinguish that from `[]` (a well-formed file with no rows, which is
 * what `phones remove <last phone>` leaves): adopting a failed read as an empty
 * store and flushing it back wipes every phone's label and push routing.
 */
function readFile(path: string): PairedPhone[] | null {
  return parsePhones(readRaw(path));
}

function parsePhones(raw: string | null): PairedPhone[] | null {
  if (raw === null) return null;
  try {
    const parsed = JSON.parse(raw) as FileShape;
    if (parsed.version !== 1 || !Array.isArray(parsed.phones)) return null;
    // Destructure off the stale keys older builds left on disk — `admission`
    // (pre-account-trust) and `allowedProjects` (pre-machine-switch) — instead
    // of a `{...p}` spread; unlike an explicit field whitelist, new
    // `PairedPhone` fields forward automatically without an edit here. Both are
    // shed on the next flush(); the file stays `version: 1` so an older bridge
    // reading one we wrote still works.
    return parsed.phones.map(
      ({ admission: _admission, allowedProjects: _allowedProjects, ...rest }: PairedPhone & {
        admission?: string;
        allowedProjects?: string[];
      }) => ({ ...rest }),
    );
  } catch {
    return null;
  }
}
