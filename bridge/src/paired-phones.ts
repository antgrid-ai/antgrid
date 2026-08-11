import { existsSync, mkdirSync, readFileSync, writeFileSync, chmodSync, watch as fsWatch } from "node:fs";
import { join } from "node:path";
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
}

export interface PairedPhonesStore {
  list(): PairedPhone[];
  has(phonePubkey: string): boolean;
  get(phonePubkey: string): PairedPhone | undefined;
  upsert(phone: PairedPhone): void;
  remove(phonePubkey: string): void;
  /** Record a fresh admission for `phonePubkey` WITHOUT writing to disk.
   *  A phone rekeys on a schedule and every rekey re-runs the client-hello, so
   *  a straight `upsert` here would rewrite (and re-flush) the file on each one
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
   *  one write per active minute instead of one per rekey. */
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
  // Exact bytes of our last touch-only write, for the watcher's silence check.
  let touchWriteRaw: string | null = null;

  function flush(silent = false) {
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    const data: FileShape = { version: 1, phones };
    const raw = JSON.stringify(data, null, 2);
    writeFileSync(path, raw);
    if (process.platform !== "win32") chmodSync(path, 0o600);
    // Cleared on any write carrying more than touches: those MUST still notify,
    // and a stale value could silence a later external edit that happens to match.
    touchWriteRaw = silent ? raw : null;
  }

  function flushLastSeen() {
    if (touchTimer) {
      clearTimeout(touchTimer);
      touchTimer = null;
    }
    if (pendingTouches.size === 0) return;
    // Merge onto the on-disk rows rather than writing our in-memory array.
    // Unlike every other flush this one fires on a background timer, so it can
    // land in the window between a CLI `phones remove` writing the file and our
    // watcher debounce reloading it — and the self-write check below would then
    // hide the resurrected row entirely. Disk is authoritative here because all
    // other mutators flush synchronously; pending touches are the only state
    // memory legitimately holds ahead of it.
    //
    // Adopt only a SUCCESSFUL read. A row-count guard would take `phones remove
    // <last phone>` for a failure and write the removed row straight back; an
    // existence guard has the mirror failure, adopting the zero rows a torn
    // concurrent write or malformed JSON yields and flushing the whole store
    // away. `readFile` separates the two: null = could not read, [] = a
    // well-formed empty file.
    const before = JSON.stringify(phones);
    const disk = readFile(path);
    if (disk) phones = disk;
    for (const [pk, at] of pendingTouches) {
      const phone = phones.find((p) => p.phonePubkey === pk);
      if (phone) phone.lastSeenAt = at;
    }
    pendingTouches.clear();
    // Silent only when the write carries nothing but our own touches. When we
    // absorbed a concurrent external edit, the watcher event our write triggers
    // is the ONLY notification that edit will ever get — suppressing it strands
    // every connected phone on a stale catalog.
    flush(JSON.stringify(phones) === before);
  }

  return {
    list: () => phones.slice(),
    has: (pk) => phones.some((p) => p.phonePubkey === pk),
    get: (pk) => phones.find((p) => p.phonePubkey === pk),
    upsert: (phone: PairedPhone) => {
      // Displace by pubkey OR device id, so a rekey (same device, new pubkey)
      // replaces the old row instead of leaving an orphan alongside it.
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
        flushLastSeen();
      }, lastSeenFlushMs);
      // A pending `last seen` write must never be the reason the process lives.
      touchTimer.unref?.();
    },
    flushLastSeen,
    close: flushLastSeen,
    watch: (onChange) => {
      if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
      let timer: ReturnType<typeof setTimeout> | null = null;
      const w = fsWatch(dir, (_event, filename) => {
        if (filename && filename.toString() !== "paired-phones.json") return;
        if (timer) clearTimeout(timer);
        timer = setTimeout(() => {
          const raw = readRaw(path);
          // Resolve the touch-write snapshot on EVERY fire, not only a matching
          // one: an external write landing inside the debounce makes our own
          // event read someone else's bytes, and a snapshot left armed past
          // that would silence a LATER external edit that happens to restore it
          // byte-for-byte, stranding the running host on rows it no longer has.
          // Re-notifying costs a re-advertise; under-notifying costs correctness.
          const armed = touchWriteRaw;
          touchWriteRaw = null;
          // Our own touch flush: memory already holds it, and re-advertising on
          // it would put every rekey back on the wire indirectly.
          if (armed !== null && raw === armed) return;
          // A failed read is a write in flight, not an emptied store — keep
          // memory and wait for the completing write's own event.
          const next = readFile(path);
          if (!next) return;
          phones = next;
          for (const [pk, at] of pendingTouches) {
            const phone = phones.find((p) => p.phonePubkey === pk);
            if (phone) phone.lastSeenAt = at;
          }
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
  if (!existsSync(path)) return null;
  try {
    const raw = readFileSync(path, "utf8");
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
