import { existsSync, mkdirSync, readFileSync, writeFileSync, chmodSync, watch as fsWatch } from "node:fs";
import { join } from "node:path";
import { logger } from "./logger";
const log = logger.child({ component: "paired-phones" });

export type PhoneAdmission = "same-account" | "pair-code";

export interface PairedPhone {
  phonePubkey: string;
  phoneDeviceId: string;
  label?: string;
  pairedAt: string;
  lastSeenAt: string;
  admission: PhoneAdmission;
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
  /** Grant `projectId` to every same-account phone missing it, flushing ONCE.
   *  The same-account default toggle is inherently a bulk op; looping
   *  allowProject would rewrite the whole file (and trip the watcher) once per
   *  phone. Returns true if any phone changed. */
  allowProjectForSameAccount(projectId: string): boolean;
  /** Revoke `projectId` from every same-account phone, flushing ONCE. Scoped to
   *  same-account admission on purpose: the toggle governs the same-account
   *  default only, so a pair-code phone granted `projectId` explicitly via
   *  allowProject keeps it. Returns true if any phone changed. */
  denyProjectForSameAccount(projectId: string): boolean;
  /** Watch the backing file for external changes. Calls `onChange` (after a
   *  50ms debounce) and reloads the in-memory store on each change. Returns a
   *  stop function that cancels the watcher and any pending debounce timer. */
  watch(onChange: () => void): () => void;
}

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

export function loadPairedPhones(abDir: string): PairedPhonesStore {
  const dir = join(abDir, "agents");
  const path = join(dir, "paired-phones.json");

  let phones: PairedPhone[] = readFile(path);

  function flush() {
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    const data: FileShape = { version: 1, phones };
    writeFileSync(path, JSON.stringify(data, null, 2));
    if (process.platform !== "win32") chmodSync(path, 0o600);
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
        if (phone.admission !== "same-account") continue;
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
        if (phone.admission !== "same-account") continue;
        const next = phone.allowedProjects.filter((p) => p !== projectId);
        if (next.length === phone.allowedProjects.length) continue;
        phone.allowedProjects = next;
        changed = true;
      }
      if (changed) flush();
      return changed;
    },
    watch: (onChange) => {
      if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
      let timer: ReturnType<typeof setTimeout> | null = null;
      const w = fsWatch(dir, (_event, filename) => {
        if (filename && filename.toString() !== "paired-phones.json") return;
        if (timer) clearTimeout(timer);
        timer = setTimeout(() => {
          phones = readFile(path);
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

function readFile(path: string): PairedPhone[] {
  if (!existsSync(path)) return [];
  try {
    const raw = readFileSync(path, "utf8");
    const parsed = JSON.parse(raw) as FileShapeOnDisk;
    if (parsed.version !== 1 || !Array.isArray(parsed.phones)) return [];
    // Deliberately drops rows without a known admission value — phones paired
    // before this field existed must re-pair so the trust model is unambiguous.
    const kept = parsed.phones.filter(
      (p) => p.admission === "same-account" || p.admission === "pair-code",
    );
    // Surface the drop: without this the operator sees every legacy phone
    // silently vanish (and re-pair-required) with nothing in the logs to explain
    // why. One line turns an undiagnosable support ticket into a self-evident one.
    const dropped = parsed.phones.length - kept.length;
    if (dropped > 0) {
      log.warn(
        "paired-phones: dropped %d phone(s) with no admission field (paired before the admission migration); re-pair required",
        dropped,
      );
    }
    return kept.map((p) => ({ ...p, allowedProjects: p.allowedProjects ?? [] }));
  } catch {
    return [];
  }
}
