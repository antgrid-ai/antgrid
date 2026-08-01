import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

/** Whether this machine is reachable from your other devices at all — one
 *  boolean for the whole machine, the sole authorization gate for a remote
 *  (account-trusted) device. There is deliberately NO watcher on the backing
 *  file: the bridge is its only writer and every mutation arrives through the
 *  loopback `mobile-access:set` verb, so an out-of-band edit is not a supported
 *  input.
 *
 *  The `mobile-access` spelling survives in the verb and the filename on
 *  purpose: both cross a version boundary this rename cannot reach — an app
 *  build that predates it, and the file already on every existing install. */
export interface RemoteAccessPolicyStore {
  isEnabled(): boolean;
  /** Returns true if the value changed — callers use it to skip the re-advertise
   *  and heartbeat that a no-op set doesn't warrant. */
  setEnabled(enabled: boolean): boolean;
}

interface FileShape {
  version: 2;
  enabled: boolean;
}

export function loadRemoteAccessPolicy(abDir: string): RemoteAccessPolicyStore {
  const dir = join(abDir, "agents");
  const path = join(dir, "mobile-access-policy.json");

  function flush() {
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    const data: FileShape = { version: 2, enabled };
    writeFileSync(path, JSON.stringify(data, null, 2));
    if (process.platform !== "win32") chmodSync(path, 0o600);
  }

  const stored = readStored(path);
  let enabled = stored.kind === "v2" ? stored.enabled : migrateFromV1(path, join(dir, "paired-phones.json"));
  // Write v2 even when the migration landed on `false`: without a v2 file on
  // disk the migration re-runs every load, and a later `setEnabled(false)` would
  // be undone on the next reboot by grants still sitting in paired-phones.json.
  //
  // But NEVER write over bytes we could not parse. `writeFileSync` truncates
  // before it writes, so a load racing a `setEnabled` flush (the host toggling
  // while `antgrid phones remove` runs its migration) can read a torn file — and
  // once the v1 grants are shed, re-deriving from them yields `false`. Flushing
  // that would silently revoke a machine the user had enabled, with the damage
  // only surfacing at the next restart. Unreadable is fail-closed in memory and
  // untouched on disk, so a clean read later still recovers the real value.
  if (stored.kind === "migrate") flush();

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

/** What the backing file holds. `migrate` and `unreadable` both derive the value
 *  from the v1 stores; they differ only in whether that derivation may be
 *  written back (see the flush in {@link loadRemoteAccessPolicy}). */
type StoredPolicy =
  | { kind: "v2"; enabled: boolean }
  /** Absent, or well-formed but on an older version — a real state to upgrade. */
  | { kind: "migrate" }
  /** Bytes we could not make sense of; the real value is unknown, not absent. */
  | { kind: "unreadable" };

function readStored(path: string): StoredPolicy {
  if (!existsSync(path)) return { kind: "migrate" };
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return { kind: "unreadable" };
  }
  if (typeof parsed !== "object" || parsed === null) return { kind: "unreadable" };
  const { version, enabled } = parsed as Partial<FileShape>;
  if (version === 2) {
    // A v2 file whose `enabled` isn't a boolean is corrupt, not older.
    return typeof enabled === "boolean" ? { kind: "v2", enabled } : { kind: "unreadable" };
  }
  // A recognisable older version upgrades; an unknown one (a newer build wrote
  // it, then the user rolled back) must not be overwritten with a guess.
  return version === 1 ? { kind: "migrate" } : { kind: "unreadable" };
}

/**
 * Derive the machine switch from the two v1 stores that used to hold
 * authorization: the per-project opt-in list here, and the per-phone
 * allowlists in paired-phones.json. Either being non-empty means the user had
 * already granted remote access to something, so the machine switch starts on.
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
