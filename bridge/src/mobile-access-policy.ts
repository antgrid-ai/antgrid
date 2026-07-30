import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

/** Whether this machine is reachable from mobile at all — one boolean for the
 *  whole machine, the sole authorization gate for a remote (account-trusted)
 *  phone. There is deliberately NO watcher on the backing file: the bridge is
 *  its only writer and every mutation arrives through the loopback
 *  `mobile-access:set` verb, so an out-of-band edit is not a supported input. */
export interface MobileAccessPolicyStore {
  isEnabled(): boolean;
  /** Returns true if the value changed — callers use it to skip the re-advertise
   *  and heartbeat that a no-op set doesn't warrant. */
  setEnabled(enabled: boolean): boolean;
}

interface FileShape {
  version: 2;
  enabled: boolean;
}

export function loadMobileAccessPolicy(abDir: string): MobileAccessPolicyStore {
  const dir = join(abDir, "agents");
  const path = join(dir, "mobile-access-policy.json");

  function flush() {
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    const data: FileShape = { version: 2, enabled };
    writeFileSync(path, JSON.stringify(data, null, 2));
    if (process.platform !== "win32") chmodSync(path, 0o600);
  }

  const current = readCurrent(path);
  let enabled = current ?? migrateFromV1(path, join(dir, "paired-phones.json"));
  // Write v2 even when the migration landed on `false`: without a v2 file on
  // disk the migration re-runs every load, and a later `setEnabled(false)` would
  // be undone on the next reboot by grants still sitting in paired-phones.json.
  if (current === null) flush();

  return {
    isEnabled: () => enabled,
    setEnabled: (next) => {
      if (next === enabled) return false;
      enabled = next;
      flush();
      return true;
    },
  };
}

/** The current (v2) value, or null when the file is absent, unreadable, or
 *  still on v1 — all of which mean "migrate". */
function readCurrent(path: string): boolean | null {
  if (!existsSync(path)) return null;
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as Partial<FileShape>;
    if (parsed.version !== 2 || typeof parsed.enabled !== "boolean") return null;
    return parsed.enabled;
  } catch {
    return null;
  }
}

/**
 * Derive the machine switch from the two v1 stores that used to hold
 * authorization: the per-project opt-in list here, and the per-phone
 * allowlists in paired-phones.json. Either being non-empty means the user had
 * already granted mobile access to something, so the machine switch starts on.
 *
 * The paired-phones half is load-bearing, not belt-and-braces: a user who
 * granted only through `antgrid phones allow` never wrote a project into this
 * file, and without that clause the upgrade silently revokes their access.
 */
function migrateFromV1(policyPath: string, pairedPhonesPath: string): boolean {
  return hasV1Projects(policyPath) || hasPhoneGrants(pairedPhonesPath);
}

function hasV1Projects(path: string): boolean {
  if (!existsSync(path)) return false;
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as { sameAccountDefaultProjects?: unknown };
    return Array.isArray(parsed.sameAccountDefaultProjects) && parsed.sameAccountDefaultProjects.length > 0;
  } catch {
    return false;
  }
}

/** Read paired-phones.json directly rather than taking a `PairedPhonesStore`
 *  parameter: this is a one-shot migration read of a field that no longer
 *  exists in that store's type, not an ongoing dependency, and the two stores
 *  must stay uncoupled. */
function hasPhoneGrants(path: string): boolean {
  if (!existsSync(path)) return false;
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as { phones?: { allowedProjects?: unknown }[] };
    if (!Array.isArray(parsed.phones)) return false;
    return parsed.phones.some((p) => Array.isArray(p?.allowedProjects) && p.allowedProjects.length > 0);
  } catch {
    return false;
  }
}
