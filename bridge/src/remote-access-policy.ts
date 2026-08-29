import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { atomicWriteFile } from "./discovery";

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

  function flush(value: boolean) {
    const data: FileShape = { version: 2, enabled: value };
    atomicWriteFile(path, JSON.stringify(data, null, 2), { fileMode: 0o600 });
  }

  const stored = readStored(path);
  const migrated = stored.kind === "v2" ? null : migrateFromV1(path, join(dir, "paired-phones.json"));
  let enabled = stored.kind === "v2" ? stored.enabled : migrated!.enabled;
  // Write v2 even when the migration landed on `false`: without a v2 file on
  // disk the migration re-runs every load, and a later `setEnabled(false)` would
  // be undone on the next reboot by grants still sitting in paired-phones.json.
  //
  // But a `false` is only safe to persist when we actually READ every v1 store.
  // A v2 file never re-migrates, so one lost read is permanent: a user who
  // granted access through `antgrid phones allow` alone, whose paired-phones.json
  // was locked by a concurrent CLI write or a scanner at this instant, would be
  // silently revoked with the damage surfacing only at the next restart. Bytes
  // we could not parse get the same treatment — fail-closed in memory, untouched
  // on disk, so a clean read later still recovers the real value.
  if (stored.kind === "migrate" && migrated!.complete) flush(enabled);

  return {
    isEnabled: () => enabled,
    setEnabled: (next) => {
      if (next === enabled) return false;
      // Persist BEFORE flipping memory. A failed write must not leave the sole
      // authorization gate reading "off" in memory while disk still says "on":
      // the caller would skip its demote/re-advertise on the throw, and the next
      // restart would silently re-enable the machine from the stale file.
      flush(next);
      enabled = next;
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
  if (looksAbsent(path)) return { kind: "migrate" };
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

/** Absence is only believed after a re-check. The file is published by rename,
 *  and on Windows MoveFileEx leaves the target briefly unlinked, so a load
 *  racing a concurrent `setEnabled` can see a live v2 file as missing. Missing
 *  is the ONE verdict that writes: it routes to the v1 migration, which derives
 *  `false` from grants shed on the first upgrade and persists it — permanently
 *  revoking a machine the user had enabled, since a v2 file never re-migrates.
 *  A genuinely fresh install pays this once at load. */
function looksAbsent(path: string): boolean {
  for (let attempt = 0; attempt < 4; attempt++) {
    if (existsSync(path)) return false;
    if (attempt < 3) Bun.sleepSync(2);
  }
  return true;
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
 *
 * `complete` reports whether both stores answered. An unreadable one cannot
 * distinguish "no grants" from "grants we could not see", so the caller must not
 * persist the derived value — see the flush in {@link loadRemoteAccessPolicy}.
 */
function migrateFromV1(policyPath: string, pairedPhonesPath: string): { enabled: boolean; complete: boolean } {
  const projects = hasV1Projects(policyPath);
  const grants = hasPhoneGrants(pairedPhonesPath);
  return {
    enabled: projects === true || grants === true,
    complete: projects !== null && grants !== null,
  };
}

/** True/false when the store answered, null when it could not be read. */
function hasV1Projects(path: string): boolean | null {
  if (!existsSync(path)) return false;
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as { sameAccountDefaultProjects?: unknown };
    return Array.isArray(parsed.sameAccountDefaultProjects) && parsed.sameAccountDefaultProjects.length > 0;
  } catch {
    return null;
  }
}

/** Read paired-phones.json directly rather than taking a `PairedPhonesStore`
 *  parameter: this is a one-shot migration read of a field that no longer
 *  exists in that store's type, not an ongoing dependency, and the two stores
 *  must stay uncoupled. */
function hasPhoneGrants(path: string): boolean | null {
  if (!existsSync(path)) return false;
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as { phones?: { allowedProjects?: unknown }[] };
    if (!Array.isArray(parsed.phones)) return null;
    return parsed.phones.some((p) => Array.isArray(p?.allowedProjects) && p.allowedProjects.length > 0);
  } catch {
    return null;
  }
}
