import { existsSync, mkdirSync, readFileSync, writeFileSync, chmodSync, watch as fsWatch } from "node:fs";
import { join } from "node:path";
import { logger } from "./logger";
const log = logger.child({ component: "paired-phones" });

export interface PairedPhone {
  phonePubkey: string;
  phoneDeviceId: string;
  label?: string;
  pairedAt: string;
  lastSeenAt: string;
  allowedProjects: string[];
  // Push (Phase 1): persistent X25519 push pubkey + current FCM token. The relay
  // never stores these; the bridge supplies them per push:deliver.
  pushPubkey?: string;
  pushToken?: string;
  pushProvider?: "fcm" | "apns";
  pushUpdatedAt?: string;
}

/** Input to upsert. `allowedProjects` is optional here (defaults to []) so the
 *  pairing path — which doesn't manage the allowlist — needn't supply it.
 *  Reads always return the required-field PairedPhone. */
export type UpsertPhone = Omit<PairedPhone, "allowedProjects"> & {
  allowedProjects?: string[];
};

export interface PairedPhonesStore {
  list(): PairedPhone[];
  has(phonePubkey: string): boolean;
  get(phonePubkey: string): PairedPhone | undefined;
  upsert(phone: UpsertPhone): void;
  remove(phonePubkey: string): void;
  isAllowed(phonePubkey: string, projectId: string): boolean;
  allowProject(phonePubkey: string, projectId: string): void;
  /** Revoke `projectId` from the phone's allowlist. Returns true if the project
   *  was present and removed, false if the phone or grant didn't exist (no-op).
   *  Callers use the return value to avoid reporting a revocation that did
   *  nothing — a silent no-op reads as "access revoked" when it isn't. */
  denyProject(phonePubkey: string, projectId: string): boolean;
  /** Grant `projectId` to every phone missing it, flushing ONCE. The
   *  same-account default toggle is inherently a bulk op; looping
   *  allowProject would rewrite the whole file (and trip the watcher) once per
   *  phone. Returns true if any phone changed. */
  allowProjectForSameAccount(projectId: string): boolean;
  /** Revoke `projectId` from every phone's allowlist, flushing ONCE —
   *  regardless of whether the grant came from the same-account default or an
   *  explicit `allowProject`. Returns true if any phone changed. */
  denyProjectForSameAccount(projectId: string): boolean;
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
   *  A `flushLastSeen` write is deliberately NOT reported: it carries no
   *  authorization change, and `onChange` drives a re-advertise to every
   *  connected phone. Suppression is one-shot and applies only to a write that
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

/** On-disk representation: allowedProjects may be absent in legacy files. */
interface PhoneOnDisk extends Omit<PairedPhone, "allowedProjects"> {
  allowedProjects?: string[];
}
interface FileShapeOnDisk {
  version: 1;
  phones: PhoneOnDisk[];
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
    // Cleared on any authorization-bearing write: those MUST still notify, and
    // a stale value could silence a later external edit that happens to match.
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
    // land in the window between a CLI `phones allow` writing the file and our
    // watcher debounce reloading it — and the self-write check below would then
    // hide the clobbered grant entirely. Disk is authoritative here because all
    // other mutators flush synchronously; pending touches are the only state
    // memory legitimately holds ahead of it.
    //
    // Adopt only a SUCCESSFUL read. A row-count guard would take `phones remove
    // <last phone>` for a failure and write the removed row — grants included —
    // straight back; an existence guard has the mirror failure, adopting the
    // zero rows a torn concurrent write or malformed JSON yields and flushing
    // the whole store away. `readFile` separates the two: null = could not
    // read, [] = a well-formed empty file.
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
    upsert: (phone: UpsertPhone) => {
      phones = phones.filter((p) => p.phonePubkey !== phone.phonePubkey);
      phones.push({ ...phone, allowedProjects: phone.allowedProjects ?? [] });
      flush();
    },
    remove: (pk) => {
      phones = phones.filter((p) => p.phonePubkey !== pk);
      flush();
    },
    isAllowed: (pk, projectId) => {
      const phone = phones.find((p) => p.phonePubkey === pk);
      return !!phone && phone.allowedProjects.includes(projectId);
    },
    allowProject: (pk, projectId) => {
      const phone = phones.find((p) => p.phonePubkey === pk);
      if (!phone || phone.allowedProjects.includes(projectId)) return;
      phone.allowedProjects.push(projectId);
      flush();
    },
    denyProject: (pk, projectId) => {
      const phone = phones.find((p) => p.phonePubkey === pk);
      if (!phone) return false;
      const next = phone.allowedProjects.filter((p) => p !== projectId);
      if (next.length === phone.allowedProjects.length) return false;
      phone.allowedProjects = next;
      flush();
      return true;
    },
    allowProjectForSameAccount: (projectId) => {
      let changed = false;
      for (const phone of phones) {
        if (phone.allowedProjects.includes(projectId)) continue;
        phone.allowedProjects.push(projectId);
        changed = true;
      }
      if (changed) flush();
      return changed;
    },
    denyProjectForSameAccount: (projectId) => {
      let changed = false;
      for (const phone of phones) {
        const next = phone.allowedProjects.filter((p) => p !== projectId);
        if (next.length === phone.allowedProjects.length) continue;
        phone.allowedProjects = next;
        changed = true;
      }
      if (changed) flush();
      return changed;
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
          // that would silence a LATER external edit that happens to restore
          // it (allow-then-deny of one project round-trips the file exactly),
          // losing the revocation until restart. Re-notifying costs a
          // re-advertise; under-notifying costs the gate.
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
 * store and flushing it back wipes every phone's trust row and grants.
 */
function readFile(path: string): PairedPhone[] | null {
  if (!existsSync(path)) return null;
  try {
    const raw = readFileSync(path, "utf8");
    const parsed = JSON.parse(raw) as FileShapeOnDisk;
    if (parsed.version !== 1 || !Array.isArray(parsed.phones)) return null;
    // Destructure off the stale `admission` key left on disk by a
    // pre-account-trust build (shed on the next flush()) instead of a `{...p}`
    // spread; unlike an explicit field whitelist, new `PairedPhone` fields
    // forward automatically without needing a matching edit here.
    return parsed.phones.map(({ admission: _stale, allowedProjects, ...rest }: PhoneOnDisk & { admission?: string }) => ({
      ...rest,
      allowedProjects: allowedProjects ?? [],
    }));
  } catch {
    return null;
  }
}
